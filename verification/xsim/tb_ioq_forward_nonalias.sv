`include "rapt.svh"
`include "rapt_if.svh"
module tb_ioq_forward_nonalias;
  localparam int XLEN = `RAPT_XLEN;
  `include "tb_ioq_harness.svh"
  task automatic scenario(input logic [XLEN-1:0] store_addr, input logic [XLEN-1:0] load_addr,
                          input bit unknown_store, input bit atomic_store,
                          input bit expect_request);
    reset = 1;
    init_ioq_inputs(0);
    tick(3);
    reset = 0;
    tick(1);
    dispatch[0] = '0;
    dispatch[0].uop.execute.memory.store = 1;
    dispatch[0].uop.execute.memory.atomic = atomic_store;
    dispatch[0].uop.execute.int_op.alu = atomic_store ? `RAPT_ATO_ADD_ : `RAPT_SW_WSTRB;
    dispatch[0].uop.execute.int_op.word = 1;
    dispatch[0].op1 = store_addr;
    dispatch[0].pr1 = unknown_store ? 8 : 0;
    dispatch[0].pr2 = 7;
    dispatch[0].dest = 3;
    disp.accept[0] = 1;
    tick(1);
    dispatch[0] = '0;
    dispatch[0].uop.execute.memory.load = 1;
    dispatch[0].uop.execute.int_op.alu = `RAPT_ALU_LW__;
    dispatch[0].uop.rd = 5;
    dispatch[0].pr1 = 9;
    dispatch[0].prd = 11;
    dispatch[0].dest = 4;
    tick(1);
    disp.accept[0] = 0;
    tick(2);
    exu_rou = '0;
    exu_rou.valid = 1;
    exu_rou.prd = 9;
    exu_rou.result = load_addr;
    #1;
    check(dut.wake_next_req_valid == expect_request,
          "current forwarded address violated older-store/atomic eligibility");
    tick(1);
    exu_rou.valid = 0;
    #1;
    check(exu_lsu.rvalid == expect_request, "forwarded request capture mismatch");
    if (expect_request) begin
      check(exu_lsu.raddr == load_addr, "request captured a stale load address");
      tick(2);
      check(exu_lsu.rvalid && exu_lsu.raddr == load_addr, "request changed under backpressure");
      cmu_bcast.flush_pipe = 1;
      tick(1);
      cmu_bcast.flush_pipe = 0;
      check(!exu_lsu.rvalid, "flush retained forwarded request");
    end
  endtask
  task automatic uncacheable_candidate;
    logic [XLEN-1:0] cached_addr;
    cached_addr = XLEN'(32'h80000000) + XLEN'(rapt_pkg::PmemBytes) - XLEN'(64);
    check(rapt_pkg::addr_cacheable(cached_addr) && !rapt_pkg::addr_cacheable(cached_addr + XLEN'(64)
          ), "forwarded selection fixture must straddle the PMEM boundary");
    reset = 1;
    init_ioq_inputs(0);
    tick(3);
    reset = 0;
    tick(1);
    // Both loads wake on the same tag. Only the younger cacheable load may
    // use the forwarding shortcut. It must make progress without issuing
    // the older device access before that instruction reaches the ROB head.
    for (int n = 0; n < 2; n++) begin
      dispatch[0] = '0;
      dispatch[0].uop.execute.memory.load = 1;
      dispatch[0].uop.execute.int_op.alu = n == 0 ? `RAPT_ALU_LW__ : `RAPT_ALU_LHU_;
      dispatch[0].uop.pc = XLEN'('h80010000 + n * 4);
      dispatch[0].uop.imm = n == 0 ? XLEN'(64) : '0;
      dispatch[0].uop.rd = 5'(5 + n);
      dispatch[0].pr1 = 9;
      dispatch[0].prd = $bits(dispatch[0].prd)'(11 + n);
      dispatch[0].dest = $bits(dispatch[0].dest)'(3 + n);
      disp.accept[0] = 1;
      tick(1);
    end
    disp.accept[0] = 0;
    tick(2);
    check(!exu_lsu.rvalid, "unresolved forwarding candidates issued");
    exu_rou = '0;
    exu_rou.valid = 1;
    exu_rou.prd = 9;
    exu_rou.result = cached_addr;
    #1;
    if (dut.wake_next_req_valid)
      check(dut.wake_next_addr == cached_addr && dut.wake_next_idx == 1,
            "uncacheable candidate entered the forwarding shortcut");
    tick(1);
    exu_rou.valid = 0;
    for (int n = 0; n < 4 && !exu_lsu.rvalid; n++) tick(1);
    check(exu_lsu.rvalid && exu_lsu.raddr == cached_addr, "cacheable follower failed to progress");
    check(exu_lsu.pc == XLEN'('h80010004) && exu_lsu.ralu == `RAPT_ALU_LHU_,
          "request selected the wrong metadata");
    tick(3);
    check(exu_lsu.rvalid && exu_lsu.raddr == cached_addr && !exu_lsu.atomic_lock,
          "forwarded candidate corrupted a held request");
    cmu_bcast.flush_pipe = 1;
    tick(1);
    check(!exu_lsu.rvalid, "flush retained forwarded request");
  endtask
  initial begin
    scenario(XLEN'('h80001000), XLEN'('h80001040), 0, 0, 1);
    scenario(XLEN'('h80001000), XLEN'('h80001000), 0, 0, 0);
    scenario(XLEN'('h80001007), XLEN'('h80001008), 0, 0, 0);
    scenario(XLEN'('h80001008), XLEN'('h80001007), 0, 0, 0);
    scenario(XLEN'('h80001000), XLEN'('h80001040), 1, 0, 0);
    scenario(XLEN'('h80001000), XLEN'('h80001040), 0, 1, 0);
    uncacheable_candidate();
    $display("PASS: forwarded load fresh-address disambiguation XLEN=%0d", XLEN);
    $finish;
  end
endmodule
