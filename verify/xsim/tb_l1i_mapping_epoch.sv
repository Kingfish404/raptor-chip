`include "rapt.svh"
`include "rapt_if.svh"

module tb_l1i_mapping_epoch;
  localparam int Levels = `RAPT_XLEN == 64 ? 3 : 2;
  localparam int XLEN = `RAPT_XLEN;
  localparam logic [XLEN-1:0] OldSupervisorPc = XLEN'(32'hc000_1000);
`ifdef RAPT_TEST_ZERO_PC
  localparam logic [XLEN-1:0] UserTargetPc = '0;
`else
  localparam logic [XLEN-1:0] UserTargetPc = XLEN'(32'h0001_0000);
`endif
  localparam logic [XLEN-1:0] RedirectedUserPc = XLEN'(32'h0002_0000);
  // PA 0x80000000 is aligned for a root-level leaf in both Sv32 and Sv39.
  localparam logic [XLEN-1:0] UserLeafPte = XLEN'(32'h2000_0059);

  logic clock = 1'b0;
  logic reset = 1'b1;

  cmu_bcast_if cmu_bcast ();
  ifu_l1i_if ifu_l1i ();
  l1i_bus_if l1i_bus ();
  csr_bcast_if csr_bcast ();
  pmp_state_if pmp_state ();

  rapt_l1i dut (
      .io_authorized(1'b0),
      .io_start(),
      .io_owner_pc(),
      .clock(clock),
      .cmu_bcast(cmu_bcast),
      .ifu_l1i(ifu_l1i),
      .l1i_bus(l1i_bus),
      .csr_bcast(csr_bcast),
      .pmp_state(pmp_state),
      .reset(reset)
  );

  always #5 clock = ~clock;

  `include "tb_common.svh"
  `include "tb_core_bcast_defaults.svh"
  `include "tb_pmp_state_defaults.svh"

  task automatic init_inputs;
    begin
      init_cmu_bcast_defaults();
      init_csr_bcast_defaults(`RAPT_PRIV_S, '0, 1'b0);
      init_pmp_state_defaults(1'b0);

      ifu_l1i.pc = OldSupervisorPc;
      ifu_l1i.consumed = 0;
      ifu_l1i.cancel = 0;
      ifu_l1i.invalid = 1'b0;
      ifu_l1i.prefetch_pc = '0;
      ifu_l1i.prefetch_valid = 1'b0;

      l1i_bus.rready = 1'b0;
      l1i_bus.rdata = '0;
      l1i_bus.rvalid = 1'b0;
      l1i_bus.ptw_rerr = 0;
      l1i_bus.ptw_rvalid = 1'b0;
      l1i_bus.rlast = 1'b1;
      l1i_bus.rerr = 1'b0;
      l1i_bus.wready = 1'b0;
      l1i_bus.werr = 1'b0;
      l1i_bus.ptw_wready = 1'b0;
      l1i_bus.ptw_werr = 1'b0;

      csr_bcast.immu_en = 1'b1;
      csr_bcast.satp_ppn = `RAPT_CSR_SATP_PPN_W'(32'h8000_0);
      pmp_state.pmp_cfg_r[0] = 1'b1;
      pmp_state.pmp_cfg_w[0] = 1'b1;
      pmp_state.pmp_cfg_x[0] = 1'b1;
      pmp_state.pmp_mode_off[0] = 1'b0;
      pmp_state.pmp_mode_napot[0] = 1'b1;
      pmp_state.pmp_raw_addr[0] = '1;
      pmp_state.pmp_napot_mask[0] = '1;
    end
  endtask

  task automatic wait_for_ptw_request(input string message);
    bit found;
    begin
      found = 1'b0;
      for (int cycle = 0; cycle < 32; cycle++) begin
        #1;
        if (l1i_bus.arvalid && l1i_bus.ar_ptw) begin
          found = 1'b1;
          cycle = 32;
        end else begin
          tick(1);
        end
      end
      if (!found) fail(message);
    end
  endtask

  task automatic accept_ptw_request;
    begin
      l1i_bus.rready = 1'b1;
      tick(1);
      l1i_bus.rready = 1'b0;
    end
  endtask

  task automatic return_ptw_pte(input logic [XLEN-1:0] pte);
    begin
      l1i_bus.rdata = pte;
      l1i_bus.ptw_rvalid = 1'b1;
      tick(1);
      l1i_bus.ptw_rvalid = 1'b0;
    end
  endtask

  task automatic new_root_result(input bit spaced_data);
    bit saw_refill, saw_instruction, take_ar, send_r;
    int outstanding, accepted, returned;
    begin
      for (int n = 0; n < Levels; n++) begin
        wait_for_ptw_request("new root walk did not restart");
        if (n == 0)
          check(l1i_bus.araddr == XLEN'('h80010000) + XLEN'(XLEN == 64 ? 8 : 'h400),
                "new translation used old page-table root");
        accept_ptw_request();
        return_ptw_pte(
            n==Levels-1 ? (XLEN'('h81000000)>>2)|XLEN'('h4b)
                                  : (XLEN'('h80030000)>>2)|XLEN'(1));
      end
      saw_refill = 0;
      repeat (30) begin
        #1;
        check(!ifu_l1i.trap, "cancelled PTE error escaped into new fetch");
        if (l1i_bus.arvalid && !l1i_bus.ar_ptw) begin
          check(l1i_bus.araddr == XLEN'('h81000000), "new fetch used stale physical mapping");
          saw_refill = 1;
          break;
        end
        tick(1);
      end
      check(saw_refill, "new mapped fetch did not reach refill");
      outstanding=0;
      accepted=0;
      returned=0;
      saw_instruction=0;
      // Complete the new refill through the real cache SRAM. Each address
      // handshake represents one 32-bit word, with its RV64 lane duplicated.
      for (int cycle = 0; cycle < 100; cycle++) begin
        take_ar = l1i_bus.arvalid;
        if (take_ar)
          check(
              !l1i_bus.ar_ptw && !l1i_bus.arburst
            && l1i_bus.araddr>=XLEN'('h81000000) && l1i_bus.araddr<XLEN'('h81000040),
              "new refill escaped the replacement physical line");
        send_r=outstanding>0 && (!spaced_data || cycle%4==0);
        l1i_bus.rready=1;
        l1i_bus.rvalid=send_r;
        l1i_bus.rdata=XLEN==64 ? XLEN'(64'h00200513_00200513) : XLEN'(32'h00200513);
        tick(1);
        outstanding += int'(take_ar) - int'(send_r);
        accepted += int'(take_ar);
        returned += int'(send_r);
        if (ifu_l1i.valid) begin
          check(!ifu_l1i.trap && ifu_l1i.inst_n0 == 32'h00200513,
                "replacement did not deliver the new instruction");
          saw_instruction = 1;
        end
      end
      l1i_bus.rready=0;
      l1i_bus.rvalid=0;
      check(saw_instruction && accepted > 0 && returned == accepted && outstanding == 0,
            "replacement instruction/refill did not finish");
    end
  endtask

  task automatic mapping_epoch(input int depth, input bit delayed, input int payload,
                               input bit spaced_data);
    logic [XLEN-1:0] old_pte;
    begin
      reset = 1;
      init_inputs();
      ifu_l1i.pc = XLEN'('h40000000);
      tick(4);
      reset = 0;
      tick(1);
      for (int n = 0; n < depth; n++) begin
        wait_for_ptw_request("old walk did not reach ancestor");
        accept_ptw_request();
        return_ptw_pte((XLEN'('h80020000) >> 2) | XLEN'('h21));
      end
      wait_for_ptw_request("old walk did not reach cancellation level");
      accept_ptw_request();
      csr_bcast.satp_ppn='h80010;
      cmu_bcast.fence_time=1;
      cmu_bcast.flush_pipe=1;
      if (delayed) begin
        tick(1);
        cmu_bcast.fence_time=0;
        cmu_bcast.flush_pipe=0;
        repeat (3) begin
          check(!l1i_bus.arvalid && !ifu_l1i.valid, "new translation overtook old PTE response");
          tick(1);
        end
      end
      case (payload)
        0:old_pte=(XLEN'('h80000000)>>2)|XLEN'('h6b);
        1:old_pte='0;
        default:old_pte=(XLEN'('h80020000)>>2)|XLEN'('h21);
      endcase
      l1i_bus.ptw_rerr = payload == 3;
      return_ptw_pte(old_pte);
      l1i_bus.ptw_rerr=0;
      cmu_bcast.fence_time=0;
      cmu_bcast.flush_pipe=0;
      check(!ifu_l1i.valid && !dut.tlb_hit, "old PTE became a new-epoch translation/result");
      new_root_result(spaced_data);
      $display("PASS MAPPING EPOCH XLEN=%0d depth=%0d delayed=%0d payload=%0d spaced_data=%0d",
               XLEN, depth, delayed, payload, spaced_data);
    end
  endtask
  task automatic data_epoch(input bit old_error, input bit delayed, input bit spaced_data);
    bit saw_old_request;
    begin
      reset = 1;
      init_inputs();
      ifu_l1i.pc = XLEN'('h40000000);
      tick(4);
      reset = 0;
      tick(1);
      wait_for_ptw_request("old mapping did not start");
      accept_ptw_request();
      return_ptw_pte((XLEN'('h80000000) >> 2) | XLEN'('h4b));
      saw_old_request = 0;
      repeat (30) begin
        #1;
        if (l1i_bus.arvalid && !l1i_bus.ar_ptw) begin
          check(l1i_bus.araddr == XLEN'('h80000000) && !l1i_bus.arburst,
                "old mapping did not request its own data word");
          saw_old_request = 1;
          break;
        end
        tick(1);
      end
      check(saw_old_request, "old data request was not staged");
      l1i_bus.rready = 1;
      tick(1);
      l1i_bus.rready=0;
      csr_bcast.satp_ppn='h80010;
      cmu_bcast.fence_time=1;
      cmu_bcast.flush_pipe=1;
      ifu_l1i.invalid=1;
      if (delayed) begin
        tick(1);
        cmu_bcast.fence_time=0;
        cmu_bcast.flush_pipe=0;
        ifu_l1i.invalid=0;
        repeat (3) begin
          check(!l1i_bus.arvalid && !ifu_l1i.valid, "new mapping overtook old data response");
          tick(1);
        end
      end
      l1i_bus.rdata=XLEN==64 ? XLEN'(64'h00100513_00100513) : XLEN'(32'h00100513);
      l1i_bus.rvalid=1;
      l1i_bus.rerr=old_error;
      tick(1);
      l1i_bus.rvalid=0;
      l1i_bus.rerr=0;
      cmu_bcast.fence_time=0;
      cmu_bcast.flush_pipe=0;
      ifu_l1i.invalid=0;
      check(!ifu_l1i.valid, "cancelled data escaped as new instruction or exception");
      new_root_result(spaced_data);
      $display("PASS DATA EPOCH XLEN=%0d old_error=%0d delayed=%0d spaced_data=%0d", XLEN,
               old_error, delayed, spaced_data);
    end
  endtask

  initial begin
    for (int depth = 0; depth < Levels; depth++)
    for (int delayed = 0; delayed < 2; delayed++)
    for (int payload = 0; payload < 4; payload++)
    for (int spaced = 0; spaced < 2; spaced++)
    mapping_epoch(depth, 1'(delayed), payload, 1'(spaced));
    for (int old_error = 0; old_error < 2; old_error++)
    for (int delayed = 0; delayed < 2; delayed++)
    for (int spaced = 0; spaced < 2; spaced++) data_epoch(1'(old_error), 1'(delayed), 1'(spaced));
    $display(
        "PASS: integrated L1I mapping epoch, old PTE drain, new root and delivered instruction XLEN=%0d",
        XLEN);
    $finish;
  end
endmodule
