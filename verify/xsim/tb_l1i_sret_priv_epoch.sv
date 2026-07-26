`include "rapt.svh"
`include "rapt_if.svh"

module tb_l1i_sret_priv_epoch;
  localparam int XLEN = 32;
  localparam logic [31:0] OldSupervisorPc = 32'hc000_1000;
  localparam logic [31:0] UserTargetPc = 32'h0001_0000;
  localparam logic [31:0] RedirectedUserPc = 32'h0002_0000;
  localparam logic [31:0] UserLeafPte = 32'h2000_0059;

  logic clock = 1'b0;
  logic reset = 1'b1;

  cmu_bcast_if cmu_bcast();
  ifu_l1i_if ifu_l1i();
  l1i_bus_if l1i_bus();
  csr_bcast_if csr_bcast();
  pmp_state_if pmp_state();

  rapt_l1i dut (
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
      ifu_l1i.invalid = 1'b0;
      ifu_l1i.prefetch_pc = '0;
      ifu_l1i.prefetch_valid = 1'b0;

      l1i_bus.rready = 1'b0;
      l1i_bus.rdata = '0;
      l1i_bus.rvalid = 1'b0;
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
      pmp_state.pmp_napot_base[0] = '0;
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

  task automatic return_ptw_pte(input logic [31:0] pte);
    begin
      l1i_bus.rdata = pte;
      l1i_bus.ptw_rvalid = 1'b1;
      tick(1);
      l1i_bus.ptw_rvalid = 1'b0;
    end
  endtask

  initial begin
    bit saw_user_refill;

    init_inputs();
    tick(4);
    reset = 1'b0;
    tick(2);

    wait_for_ptw_request("S-mode fetch did not start its PTW");
    accept_ptw_request();

    cmu_bcast.flush_pipe = 1'b1;
    tick(1);
    cmu_bcast.flush_pipe = 1'b0;
    csr_bcast.priv = `RAPT_PRIV_U;
        cmu_bcast.flush_redirect = 1'b1;

    return_ptw_pte(32'h0000_0000);
        #1;
        check(!dut.ptw_req,
          "SRET redirect cycle restarted PTW for the old PC under U privilege");
        ifu_l1i.pc = UserTargetPc;
        cmu_bcast.flush_redirect = 1'b0;
    repeat (3) begin
      check(!ifu_l1i.trap,
            "pre-SRET PTW fault leaked into the post-SRET user fetch");
      check(!ifu_l1i.valid,
            "pre-SRET PTW response produced a post-SRET instruction");
      tick(1);
    end

    wait_for_ptw_request("post-SRET U-mode target did not restart its PTW");
    accept_ptw_request();
    return_ptw_pte(UserLeafPte);

    saw_user_refill = 1'b0;
    for (int cycle = 0; cycle < 32; cycle++) begin
      #1;
      check(!ifu_l1i.trap,
            "U-mode executable user PTE was rejected after SRET");
      if (l1i_bus.arvalid && !l1i_bus.ar_ptw) begin
        saw_user_refill = 1'b1;
          check(l1i_bus.araddr[31:12] == 20'h80010,
              "post-SRET user PTE translated to the wrong physical page");
        cycle = 32;
      end else begin
        tick(1);
      end
    end
    check(saw_user_refill,
          "post-SRET U-mode target did not reach instruction-cache refill");

        cmu_bcast.flush_pipe = 1'b1;
        tick(1);
        cmu_bcast.flush_pipe = 1'b0;
        ifu_l1i.pc = RedirectedUserPc;

        l1i_bus.rerr = 1'b1;
        l1i_bus.rready = 1'b1;
        tick(1);
        l1i_bus.rready = 1'b0;
        l1i_bus.rerr = 1'b0;
        #1;
        check(!ifu_l1i.trap,
          "pre-redirect refill error was attributed to the redirected PC");

        $display("PASS: L1I SRET privilege, PTW epoch, and refill ownership checks passed");
    $finish;
  end
endmodule
