`include "rapt.svh"
`include "rapt_if.svh"
module tb_l1i_response_error #(
    parameter int Ways = `RAPT_L1I_N_WAYS
);
  localparam int XLEN = `RAPT_XLEN;
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  cmu_bcast_if cmu_bcast ();
  csr_bcast_if csr_bcast ();
  pmp_state_if pmp_state ();
  ifu_l1i_if ifu_l1i ();
  l1i_bus_if l1i_bus ();
  rapt_l1i #(
      .L1I_N_WAYS(Ways)
  ) dut (
      .*,
      .io_authorized(1'b0),
      .io_start(),
      .io_owner_pc()
  );
  `include "tb_core_bcast_defaults.svh"
  `include "tb_pmp_state_defaults.svh"
  `include "tb_common.svh"
  typedef struct packed {
    logic [XLEN-1:0] data;
    logic error;
    logic walk;
  } response_t;
  response_t pending[$], response;
  logic permit_response = 0, inject_error = 0;
  int pattern = 0;
  logic [XLEN-1:0] error_address, error_va;
  int accepted = 0, returned = 0;
  localparam logic [31:0] GoodInst = 32'h00100513;
  assign l1i_bus.rready = l1i_bus.arvalid;
  always @(posedge clock) begin
    if (!reset && l1i_bus.arvalid && l1i_bus.rready) begin
      check(!l1i_bus.arburst, "unexpected burst in fixture");
      response.walk = l1i_bus.ar_ptw;
      if (response.walk) begin
        response.error = 0;
        // Real Sv32/Sv39 walk: VA 0x40000000 maps to PA 0x80000000.
        if (l1i_bus.araddr == XLEN'(XLEN == 64 ? 'h81000008 : 'h81000400))
          response.data = (XLEN'('h81001000) >> 2) | XLEN'(1);
        else if (XLEN == 64 && l1i_bus.araddr == XLEN'('h81001000))
          response.data = (XLEN'('h81002000) >> 2) | XLEN'(1);
        else begin
          check(l1i_bus.araddr == XLEN'(XLEN == 64 ? 'h81002000 : 'h81001000),
                "unexpected leaf PTE address");
          response.data = (XLEN'('h80000000) >> 2) | XLEN'('h4b);
        end
      end else begin
        response.error = inject_error && l1i_bus.araddr == error_address;
        if (pattern != 0) begin
          // At PC+2: either a 32-bit ADDI spanning words or a C.NOP wholly
          // inside the first word; the following-word error must distinguish them.
          response.data=l1i_bus.araddr[2] ? XLEN'(32'h00010010)
                                  : (pattern==2 ? XLEN'(32'h00010001) : XLEN'(32'h05130001));
          if (XLEN == 64 && l1i_bus.araddr[2]) response.data = response.data << 32;
        end else begin
          response.data=XLEN==64 ? XLEN'({2{response.error ? 32'h00200513:GoodInst}})
                              : XLEN'(response.error ? 32'h00200513:GoodInst);
        end
        accepted++;
      end
      pending.push_back(response);
    end
  end
  always @(negedge clock) begin
    l1i_bus.rvalid=0;
    l1i_bus.rerr=0;
    l1i_bus.ptw_rvalid=0;
    if (!reset && pending.size() != 0 && (permit_response || pending[0].walk)) begin
      response=pending.pop_front();
      l1i_bus.rdata=response.data;
      l1i_bus.rerr=response.error;
      if (response.walk) l1i_bus.ptw_rvalid = 1;
      else begin
        l1i_bus.rvalid = 1;
        returned++;
      end
    end
  end
  task automatic scenario(input bit error_enabled, input bit speculative,
                          input int instruction_pattern = 0, input bit early = 0,
                          input bit translated = 0, input int cancel_mode = 0);
    bit saw_instruction, saw_trap, cancelled;
    int accepted_before;
    begin
      reset=1;
      permit_response=0;
      inject_error=error_enabled;
      pattern=instruction_pattern;
      error_address=XLEN'('h80000000)+(pattern!=0 ? XLEN'(4) : speculative ? XLEN'(16):XLEN'(0));
      pending.delete();
      accepted=0;
      returned=0;
      init_cmu_bcast_defaults();
      init_csr_bcast_defaults(`RAPT_PRIV_M, '0, 1);
      init_pmp_state_defaults(1);
      if (translated) begin
        csr_bcast.priv=`RAPT_PRIV_S;
        csr_bcast.immu_en=1;
        csr_bcast.satp_ppn='h81000;
        pmp_state.pmp_mode_off[0]=0;
        pmp_state.pmp_mode_napot[0]=1;
        pmp_state.pmp_raw_addr[0]='1;
        pmp_state.pmp_napot_mask[0]='1;
        pmp_state.pmp_cfg_r[0]=1;
        pmp_state.pmp_cfg_w[0]=1;
        pmp_state.pmp_cfg_x[0]=1;
      end
      error_va=error_address-(translated ? XLEN'('h40000000) : XLEN'(0));
      ifu_l1i.pc=XLEN'(translated ? 'h40000000 : 'h80000000)+(pattern!=0 ? XLEN'(2):XLEN'(0));
      ifu_l1i.consumed=0;
      ifu_l1i.cancel=0;
      ifu_l1i.invalid=0;
      ifu_l1i.prefetch_valid=0;
      ifu_l1i.prefetch_pc=0;
      l1i_bus.rdata=0;
      l1i_bus.ptw_rerr=0;
      l1i_bus.ptw_rvalid=0;
      l1i_bus.rlast=1;
      l1i_bus.wready=0;
      l1i_bus.werr=0;
      l1i_bus.ptw_wready=0;
      l1i_bus.ptw_werr=0;
      tick(4);
      reset = 0;
      if (early) begin
        repeat (30) begin
          if (accepted > 0) break;
          tick(1);
        end
        check(accepted > 0 && returned == 0, "no pending request for overlapped response");
      end else begin
        tick(60);
        check(accepted > 0 && returned == 0 && !l1i_bus.arvalid,
              "failed to stage delayed response after AR sequence");
      end
      permit_response=1;
      saw_instruction=0;
      saw_trap=0;
      cancelled=0;
      repeat (100) begin
        tick(1);
        if (cancel_mode != 0 && !cancelled && dut.second_error_pending) begin
          // Exercise the new retained-error state, not merely cancellation
          // before an error response has arrived. The replacement fetch must
          // not inherit the old halfword's exception.
          cancelled=1;
          inject_error=0;
          error_enabled=0;
          cmu_bcast.flush_pipe=cancel_mode==1;
          cmu_bcast.flush_redirect=cancel_mode==2;
          ifu_l1i.invalid=cancel_mode==3;
          if (cancel_mode == 4) ifu_l1i.pc = XLEN'(translated ? 'h40000022 : 'h80000022);
          tick(1);
          check(!dut.second_error_pending, "cancel/PC change retained old second-word error");
          cmu_bcast.flush_pipe=0;
          cmu_bcast.flush_redirect=0;
          ifu_l1i.invalid=0;
        end
        if (ifu_l1i.valid) begin
          if (ifu_l1i.trap) begin
            saw_trap = 1;
            check(error_enabled && !speculative,
                  "speculative word error trapped current instruction");
            check(ifu_l1i.cause == 1 && ifu_l1i.tval == error_va, "fetch error lost cause/address");
          end else begin
            saw_instruction = 1;
            check(!error_enabled || speculative, "errored demand word delivered as instruction");
            // The fetch window is 32 bits, but C.NOP consumes only its low
            // halfword; the following halfword is not part of this instruction.
            if (pattern == 2)
              check(ifu_l1i.inst_n0[15:0] == 16'h0001, "incorrect compressed instruction data");
            else check(ifu_l1i.inst_n0 == GoodInst, "incorrect instruction data");
          end
        end
      end
      if (cancel_mode != 0) check(cancelled, "pending-error cancellation case was not reached");
      if (error_enabled && !speculative)
        check(saw_trap && !saw_instruction, "demand error never reported");
      else check(saw_instruction && !saw_trap, "valid demand blocked by speculative error");
      if (error_enabled && speculative && pattern == 0) begin
        // A failed lookahead must remain absent from the cache. Making it
        // architectural later must request it again and report its own fault.
        accepted_before=accepted;
        ifu_l1i.pc=error_va;
        saw_trap=0;
        repeat (100) begin
          tick(1);
          if (ifu_l1i.valid) begin
            check(ifu_l1i.trap, "failed prefetch became a valid cached instruction");
            check(ifu_l1i.cause == 1 && ifu_l1i.tval == error_va,
                  "later demand lost fault address");
            saw_trap = 1;
          end
        end
        check(saw_trap && accepted > accepted_before, "failed prefetch was not retried on demand");
        // Let the same physical word recover without resetting or invalidating
        // the cache, including any error responses already in flight.
        inject_error=0;
        saw_instruction=0;
        repeat (100) begin
          tick(1);
          if (ifu_l1i.valid && !ifu_l1i.trap) begin
            check(ifu_l1i.inst_n0 == GoodInst, "bad data survived error recovery");
            saw_instruction = 1;
          end
        end
        check(saw_instruction, "fetch did not recover after response errors stopped");
      end
      $display(
          "PASS RESPONSE ERROR enabled=%0d speculative=%0d pattern=%0d early=%0d cancel=%0d translated=%0d XLEN=%0d",
          error_enabled, speculative, pattern, early, cancel_mode, translated, XLEN);
    end
  endtask
  initial begin
    scenario(0, 0);
    if ($test$plusargs("SPECULATIVE")) scenario(1, 1);
    else
      for (int translated = 0; translated < 2; translated++)
      for (int early = 0; early < 2; early++) begin
        scenario(0, 0, 1, 1'(early), 1'(translated), 0);
        scenario(0, 1, 2, 1'(early), 1'(translated), 0);
        scenario(1, 0, 0, 1'(early), 1'(translated), 0);
        scenario(1, 1, 0, 1'(early), 1'(translated), 0);
        scenario(1, 0, 1, 1'(early), 1'(translated), 0);
        scenario(1, 1, 2, 1'(early), 1'(translated), 0);
        for (int cancel_mode = 1; cancel_mode <= 4; cancel_mode++)
        scenario(1, 0, 1, 1'(early), 1'(translated), cancel_mode);
      end
    if (!$test$plusargs("SPECULATIVE"))
      for (int translated = 0; translated < 2; translated++)
      for (int mode = 1; mode <= 4; mode++) scenario(1, 0, 1, 0, 1'(translated), mode);
    $display("PASS: L1I live response error XLEN=%0d", XLEN);
    $finish;
  end
endmodule
