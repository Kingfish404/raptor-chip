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
  initial begin
    scenario(XLEN'('h80001000), XLEN'('h80001040), 0, 0, 1);
    scenario(XLEN'('h80001000), XLEN'('h80001000), 0, 0, 0);
    scenario(XLEN'('h80001007), XLEN'('h80001008), 0, 0, 0);
    scenario(XLEN'('h80001008), XLEN'('h80001007), 0, 0, 0);
    scenario(XLEN'('h80001000), XLEN'('h80001040), 1, 0, 0);
    scenario(XLEN'('h80001000), XLEN'('h80001040), 0, 1, 0);
    $display("PASS: forwarded load fresh-address disambiguation XLEN=%0d", XLEN);
    $finish;
  end
endmodule
