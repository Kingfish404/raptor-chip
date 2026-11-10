`include "rapt.svh"
`include "rapt_if.svh"

// Reach refill state through the real request path; drive DUT inputs only.
module tb_l1i_reset_dominance;
  localparam int XLEN = `RAPT_XLEN;
  logic clock = 0;
  logic reset = 1;
  always #5 clock = ~clock;

  cmu_bcast_if cmu_bcast ();
  csr_bcast_if csr_bcast ();
  pmp_state_if pmp_state ();
  ifu_l1i_if ifu_l1i ();
  l1i_bus_if l1i_bus ();
  rapt_l1i dut (
      .sram_ctrl_i(rapt_pkg::SramCtrlReset),
      .l2tlb_req_o(),
      .l2tlb_ready_i(1'b0),
      .l2tlb_rsp_i('0),
      .io_authorized(1'b0),
      .io_start(),
      .io_owner_pc(),
      .*
  );
  `include "tb_core_bcast_defaults.svh"
  `include "tb_pmp_state_defaults.svh"

  task automatic check(input logic condition, input string message);
    if (condition !== 1'b1) $fatal(1, "FAIL: %s XLEN=%0d", message, XLEN);
  endtask

  task automatic tick;
    @(posedge clock);
    #1;
  endtask

  task automatic init_inputs;
    init_cmu_bcast_defaults();
    init_csr_bcast_defaults(`RAPT_PRIV_M, '0, 1);
    init_pmp_state_defaults(1);
    ifu_l1i.pc = $bits(ifu_l1i.pc)'('h80000000);
    ifu_l1i.consumed = 0;
    ifu_l1i.cancel = 0;
    ifu_l1i.invalid = 0;
    ifu_l1i.prefetch_valid = 0;
    ifu_l1i.prefetch_pc = 0;
    // Backpressure leaves a real miss in RD_0 without an accepted read.
    l1i_bus.rready = 0;
    l1i_bus.rdata = 0;
    l1i_bus.rvalid = 0;
    l1i_bus.rerr = 0;
    l1i_bus.ptw_rerr = 0;
    l1i_bus.ptw_rvalid = 0;
  endtask

  task automatic check_reset_controls(input string phase);
    check(dut.wait_invalid === 1'b0, {phase, ": wait_invalid"});
    check(dut.l1i_state === 3'b000, {phase, ": state"});
    check(dut.ifq_valid === '0, {phase, ": IFQ valid"});
    check(dut.cache_pending === '0, {phase, ": pending count"});
    check(l1i_bus.arvalid === 1'b0, {phase, ": bus valid"});
  endtask

  task automatic await_stalled_refill;
    repeat (80) begin
      tick();
      check(ifu_l1i.trap === 1'b0, "unexpected trap in Bare executable memory");
      if (l1i_bus.arvalid === 1'b1) begin
        check(l1i_bus.ar_ptw === 1'b0, "unexpected PTW");
        check(dut.l1i_state === 3'b010, "request is not an RD_0 refill");
        check(dut.cache_pending === '0, "backpressured read was accepted");
        return;
      end
    end
    $fatal(1, "FAIL: refill timeout XLEN=%0d", XLEN);
  endtask

  initial begin
    init_inputs();
    repeat (4) begin
      tick();
      check_reset_controls("cold reset");
    end
    @(negedge clock);
    reset = 0;
    await_stalled_refill();
    $display("REACHED_STALLED_REFILL XLEN=%0d state=%b", XLEN, dut.l1i_state);

    // Known 0/1 counterexample: old state RD_0 and invalid=1 must not override reset.
    @(negedge clock);
    reset = 1;
    ifu_l1i.invalid = 1;
    tick();
    check(dut.wait_invalid === 1'b0, "L1I_RESET_PRIORITY_NONIDLE");
    check_reset_controls("reset plus invalidation");
    tick();
    check_reset_controls("held reset plus invalidation");
    @(negedge clock);
    reset = 0;
    ifu_l1i.invalid = 0;
    await_stalled_refill();

    // A real cancellation sets the pending flag before reset clears it.
    @(negedge clock);
    ifu_l1i.invalid = 1;
    tick();
    check(dut.wait_invalid === 1'b1, "invalidation did not become pending");
    check(dut.l1i_state === 3'b000, "cancellation did not return to IDLE");
    @(negedge clock);
    reset = 1;
    ifu_l1i.invalid = 0;
    tick();
    check_reset_controls("reset with pending invalidation");
    @(negedge clock);
    reset = 0;
    await_stalled_refill();

    // Exercise the existing reset guards on the two pipeline recovery inputs.
    for (int mode = 0; mode < 2; mode++) begin
      @(negedge clock);
      reset = 1;
      cmu_bcast.flush_pipe = mode == 0;
      cmu_bcast.flush_redirect = mode == 1;
      tick();
      check_reset_controls("reset plus pipeline recovery");
      @(negedge clock);
      reset = 0;
      cmu_bcast.flush_pipe = 0;
      cmu_bcast.flush_redirect = 0;
      await_stalled_refill();
    end
    $display("PASS: L1I reset dominance XLEN=%0d", XLEN);
    $finish;
  end

  initial begin
    #20000;
    $fatal(1, "FAIL: test watchdog XLEN=%0d", XLEN);
  end
endmodule
