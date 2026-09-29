`include "rapt.svh"
`include "rapt_if.svh"
module tb_ioq_store_precheck;
  localparam int XLEN = `RAPT_XLEN;
  `include "tb_ioq_harness.svh"
  wire payload_accept = disp.accept[0];
  wire [XLEN-1:0] payload_op1 = dispatch[0].op1;
  wire [XLEN-1:0] payload_stable_op1 = dispatch[0].stable_op1;
  wire payload_stable_op1_valid = dispatch[0].stable_op1_valid;
  string store_trace;
  initial
    if ($value$plusargs("IOQ_STORE_TRACE=%s", store_trace)) begin
      $dumpfile(store_trace);
      $dumpvars(0, tb_ioq_store_stage);
    end
  `include "tb_ioq_store_tasks.svh"
  initial begin
    boot();
    enqueue(XLEN'('h20000000), 3, 2, 7);
    check(!dut.head_store_check_valid_q, "unready dispatch entered store precheck");
    repeat (3) begin
      check(!exu_ioq_bcast.valid && !exu_ioq_bcast.wen && !exu_l1d.valid,
            "unready address escaped into a store stage");
      tick(1);
    end
    exu_rou = '0;
    exu_rou.valid = 1;
    exu_rou.prd = 7;
    exu_rou.result = XLEN'('h80001000);
    tick(1);
    exu_rou.valid = 0;
    tick(3);
    enqueue(XLEN'('h80002000), 4, 5, 0);
    tick(2);
    check(!exu_ioq_bcast.valid, "SQ backpressure did not retain the head");
    exu_lsu.stq_ready = 1;
    #1;
    expect_store(XLEN'('h80001000), 3, 2);
    // The previous head may precheck the new head on its completion edge.
    // If it does, the registered check must belong to the new address.
    if (exu_ioq_bcast.valid)
      check(dut.head_store_check_valid_q && dut.head_store_check_tval_q == XLEN'('h80002000),
            "new head reused previous permission state");
    expect_store(XLEN'('h80002000), 4, 5);
    for (int stage = 0; stage < 3; stage++) begin
      boot();
      enqueue(XLEN'('h20001000), 3, 2, 0);
      tick(stage);
      cmu_bcast.flush_pipe = 1;
      exu_l1d.ready = 1;
      tick(1);
      cmu_bcast.flush_pipe = 0;
      exu_l1d.ready = 0;
      exu_lsu.stq_ready = 1;
      repeat (3) begin
        check(!exu_ioq_bcast.valid && !exu_l1d.valid,
              "flushed store stage produced a stale request/completion");
        tick(1);
      end
      enqueue(XLEN'('h80003000), 3, 6, 0);
      expect_store(XLEN'('h80003000), 3, 6);
    end
    // Stable and freshly bypassed ROU sources both stop at the IOQ address
    // register.  Permission checking starts only after allocation owns it.
    for (int stable_source = 0; stable_source < 2; stable_source++) begin
      boot();
      dispatch[0] = '0;
      dispatch[0].uop.pc = XLEN'('h80000040);
      dispatch[0].uop.execute.memory.store = 1;
      dispatch[0].uop.execute.int_op.alu = `RAPT_SW_WSTRB;
      dispatch[0].op1 = XLEN'('h80004000);
      dispatch[0].stable_op1 = XLEN'('h80004000);
      dispatch[0].stable_op1_valid = 1'(stable_source);
      dispatch[0].pr1 = '0;
      dispatch[0].pr2 = '0;
      dispatch[0].dest = 5;
      #1;
      check(!dut.head_store_check_valid_q, "store was checked before address allocation");
      disp.accept[0] = 1;
      tick(1);
      disp.accept[0] = 0;
      #1;
      check(!dut.head_store_check_valid_q,
            "dispatch-to-PMP path crossed the address-register boundary");
      tick(2);
      check(dut.head_store_check_valid_q && dut.head_store_check_tval_q == XLEN'('h80004000),
            "registered address did not reach the resident store checker");
    end
    // The resident checker retains CBO management's R-or-W PMP policy.
    for (int cmo_mgmt = 0; cmo_mgmt < 2; cmo_mgmt++) begin
      boot();
      pmp_state.pmp_mode_na4[0] = 1'b1;
      pmp_state.pmp_raw_addr[0] = 'h20001000;
      pmp_state.pmp_cfg_l[0] = 1'b1;
      pmp_state.pmp_cfg_r[0] = 1'b1;
      dispatch[0] = '0;
      dispatch[0].uop.execute.memory.store = 1'b1;
      dispatch[0].uop.execute.int_op.alu = cmo_mgmt ? `RAPT_CBO_MGMT_WALU : `RAPT_SW_WSTRB;
      dispatch[0].op1 = XLEN'('h80004000);
      dispatch[0].stable_op1 = XLEN'('h80004000);
      dispatch[0].stable_op1_valid = 1'b1;
      disp.accept[0] = 1'b1;
      tick(1);
      disp.accept[0] = 1'b0;
      #1;
      check(!dut.head_store_check_valid_q, "CBO permission result bypassed the address register");
      tick(2);
      check(dut.head_store_check_valid_q && dut.head_store_check_fault_q == !cmo_mgmt,
            "resident store checker changed CBO PMP policy");
    end
    // Credit is an owned-entry count, not a combinational view of the head
    // completion.  Releasing one full-queue entry publishes exactly one
    // credit on the following cycle; flush restores every credit.
    boot();
    for (int e = 0; e < $bits(dut.ioq_valid); e++) begin
      check(disp.ready[0], "IOQ lost a credit before reaching capacity");
      enqueue(XLEN'('h80005000) + XLEN'(e * 4), e + 1, e + 1, 0);
    end
    check(!disp.ready[0] && !disp.ready[1] && dut.ioq_free_q == 0,
          "full IOQ advertised a stale dispatch credit");
    exu_lsu.stq_ready = 1;
    #1;
    check(exu_ioq_bcast.valid && !disp.ready[0],
          "head completion leaked into same-cycle dispatch ready");
    tick(1);
    check(disp.ready[0] && !disp.ready[1] && dut.ioq_free_q == 1,
          "retired head did not publish exactly one registered credit");
    cmu_bcast.flush_pipe = 1;
    tick(1);
    cmu_bcast.flush_pipe = 0;
    #1;
    check(int'(dut.ioq_free_q) == $bits(dut.ioq_valid) && disp.ready[0] && disp.ready[1],
          "flush did not restore dispatch credit ownership");
    // An address-ready ordinary store can cache permission independently
    // of its data. Neither current CDB data nor the older load response may
    // change the selected address, and no store effect precedes data capture.
    boot();
    dispatch[0] = '0;
    dispatch[0].uop.execute.memory.load = 1'b1;
    dispatch[0].uop.execute.int_op.alu = `RAPT_ALU_LW__;
    dispatch[0].op1 = XLEN'('h80006000);
    disp.accept[0] = 1'b1;
    tick(1);
    disp.accept[0] = 1'b0;
    dispatch[0] = '0;
    dispatch[0].uop.execute.memory.store = 1'b1;
    dispatch[0].uop.execute.int_op.alu = `RAPT_SW_WSTRB;
    dispatch[0].op1 = XLEN'('h80007000);
    dispatch[0].pr2 = $bits(dispatch[0].pr2)'(7);
    disp.accept[0] = 1'b1;
    tick(1);
    disp.accept[0] = 1'b0;
    #1;
    check(dut.store_check_selected && dut.store_check_idx == dut.ioq_head + 1'b1,
          "address-ready successor was not selected for precheck");
    check(dut.store_check_vaddr == XLEN'('h80007000), "wrong precheck address");
    exu_rou.valid = 1'b1;
    exu_rou.prd = $bits(exu_rou.prd)'(7);
    exu_rou.result = XLEN'('h1234);
    #1;
    check(dut.store_check_vaddr == XLEN'('h80007000),
          "same-cycle store-data wake changed permission address");
    exu_rou.valid = 1'b0;
    tick(1);
    check(dut.store_prechecked[dut.ioq_head+1'b1], "precheck did not retain owner");
    exu_lsu.rready = 1'b1;
    tick(1);
    exu_lsu.rready = 1'b0;
    #1;
    check(dut.head_store_check_valid_q && !exu_ioq_bcast.valid && !sq_handoff_valid,
          "permission-ready store escaped while data was unavailable");
    exu_rou.valid = 1'b1;
    exu_rou.prd = $bits(exu_rou.prd)'(7);
    exu_rou.result = XLEN'('h1234);
    #1;
    check(!exu_ioq_bcast.valid && !sq_handoff_valid,
          "store-data CDB bypass crossed the registered handoff boundary");
    exu_lsu.stq_ready = 1'b1;
    tick(1);
    exu_rou.valid = 1'b0;
    #1;
    check(
        exu_ioq_bcast.valid && sq_handoff_valid && !exu_ioq_bcast.trap
          && exu_ioq_bcast.sq_waddr == XLEN'('h80007000)
          && exu_ioq_bcast.sq_wdata == XLEN'('h1234),
        "prechecked store lost registered data or address ownership");
    $display("PASS: IOQ store stages preserve wakeup, identity, backpressure and flush ownership");
    $finish;
  end
endmodule
