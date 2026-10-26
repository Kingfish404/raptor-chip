`include "rapt.svh"
`include "rapt_if.svh"
module tb_ioq_dispatch_stable;
  localparam int XLEN = `RAPT_XLEN;
  `include "tb_ioq_harness.svh"
  task automatic boot;
    reset = 1;
    init_ioq_inputs(0);
    for (int s = 0; s < rapt_pkg::DispatchWidth; s++) dispatch[s] = '0;
    tick(3);
    reset = 0;
    tick(1);
  endtask
  initial begin
    for (int stable = 0; stable < 2; stable++) begin
      boot();
      dispatch[0] = '0;
      dispatch[0].uop.execute.memory.load = 1;
      dispatch[0].uop.execute.int_op.alu = `RAPT_ALU_LW__;
      dispatch[0].uop.imm = 12;
      dispatch[0].uop.pc = XLEN'('h80000000);
      dispatch[0].op1 = XLEN'('h80004000);
      // Keep the invalid snapshot cacheable so only its valid bit blocks bypass.
      dispatch[0].stable_op1 = stable ? XLEN'('h80004000) : XLEN'('h80005000);
      dispatch[0].stable_op1_valid = 1'(stable);
      dispatch[0].dest = 3;
      dispatch[0].prd = 7;
      dispatch[0].uop.rd = 1;
      cmu_bcast.rob_head = 3;
      disp.accept[0] = 1;
      #1;
      check(dut.dispatch_load_found == 1'(stable), "dispatch bypass accepted an unstable base");
      tick(1);
      disp.accept[0] = 0;
      check(exu_lsu.rvalid == 1'(stable), "dispatch request stage latency");
      for (int n = 0; n < 5 && !exu_lsu.rvalid; n++) tick(1);
      check(exu_lsu.rvalid && exu_lsu.raddr == XLEN'('h8000400c),
            "stable/fallback request address");
      for (int n = 0; n < 4; n++) begin
        dispatch[0].op1 = XLEN'('h90000000+n*16);
        dispatch[0].stable_op1 = XLEN'('ha0000000+n*16);
        tick(1);
        check(exu_lsu.rvalid && exu_lsu.raddr == XLEN'('h8000400c),
              "held request changed with unaccepted dispatch");
      end
      cmu_bcast.flush_pipe = 1;
      tick(1);
      cmu_bcast.flush_pipe = 0;
      check(!exu_lsu.rvalid && dut.ioq_valid == '0, "flush retained a request");
    end
    // A response and a new allocation may share an edge, but the new load
    // must enter through its resident address stage while the old owner exists.
    boot();
    dispatch[0].uop.execute.memory.load = 1;
    dispatch[0].uop.execute.int_op.alu = `RAPT_ALU_LW__;
    dispatch[0].op1 = XLEN'('h80006000);
    dispatch[0].stable_op1 = dispatch[0].op1;
    dispatch[0].stable_op1_valid = 1;
    dispatch[0].dest = 3;
    dispatch[0].prd = 7;
    dispatch[0].uop.rd = 1;
    cmu_bcast.rob_head = 3;
    disp.accept[0] = 1;
    tick(1);
    disp.accept[0] = 0;
    check(exu_lsu.rvalid, "initial fast request missing");
    exu_lsu.rready = 1;
    exu_lsu.rdata = XLEN'('h1234);
    dispatch[0].op1 = XLEN'('h80007000);
    dispatch[0].stable_op1 = dispatch[0].op1;
    dispatch[0].dest = 4;
    dispatch[0].prd = 8;
    disp.accept[0] = 1;
    #1;
    check(dut.ioq_valid_found, "old owner did not complete on replacement edge");
    check(!dut.dispatch_load_found, "completion reopened the dispatch bypass");
    tick(1);
    disp.accept[0] = 0;
    exu_lsu.rready = 0;
    check(!exu_lsu.rvalid, "replacement skipped the resident address stage");
    for (int n = 0; n < 5 && !exu_lsu.rvalid; n++) tick(1);
    check(exu_lsu.rvalid && exu_lsu.raddr == XLEN'('h80007000),
          "replacement load lost its address");
    $display("PASS: stable dispatch base gate, fallback, request hold and flush XLEN = %0d", XLEN);
    $finish;
  end
endmodule
