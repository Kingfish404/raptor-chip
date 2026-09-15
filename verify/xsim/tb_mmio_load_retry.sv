`include "rapt.svh"
`include "rapt_if.svh"

// Regression for the CU08 Linux hang: a younger translated MMIO load owns
// request A when the older load's address dependency becomes ready.
module tb_mmio_load_retry;
  localparam int XLEN = `RAPT_XLEN;
  localparam logic [XLEN-1:0] RamVA = XLEN'('hc0001000);
  localparam logic [XLEN-1:0] IoVA = XLEN'('ha0281004);
  `include "tb_ioq_harness.svh"

  initial begin
    init_ioq_inputs(1'b1);
    tick(3);
    reset = 0;
    csr_bcast.dmmu_en = 1;
    csr_bcast.menvcfg_pbmte = 0;
    cmu_bcast.rob_head = 3;
    dispatch[0] = '0;
    dispatch[0].uop.execute.memory.load = 1;
    dispatch[0].uop.execute.int_op.alu = `RAPT_ALU_LW__;
    dispatch[0].pr1 = 9;
    dispatch[0].prd = 10;
    dispatch[0].uop.rd = 10;
    dispatch[0].dest = 3;
    dispatch[1] = '0;
    dispatch[1].uop.execute.memory.load = 1;
    dispatch[1].uop.execute.int_op.alu = `RAPT_ALU_LW__;
    dispatch[1].op1 = IoVA;
    dispatch[1].prd = 11;
    dispatch[1].uop.rd = 11;
    dispatch[1].dest = 4;
    disp.accept[0] = 1;
    disp.accept[1] = 1;
    tick(1);
    disp.accept[0] = 0;
    disp.accept[1] = 0;
    for (int c = 0; c < 20 && !exu_lsu.rvalid; c++) tick(1);
    check(exu_lsu.rvalid && exu_lsu.raddr == IoVA && !exu_lsu.ordered,
          "younger translated load did not issue out of order");

    // Address-producing completion arrives after the younger request owns A.
    exu_wb_mul.valid = 1;
    exu_wb_mul.prd = 9;
    exu_wb_mul.result = RamVA;
    tick(1);
    exu_wb_mul.valid = 0;
    check(dut.ioq_pr1[0] == 0, "older address dependency did not wake");

    // Translation discovers MMIO: release A, but neither complete nor wake.
    exu_lsu.rretry = 1;
    check(!exu_ioq_bcast.valid && !load_fast.valid, "retry completed MMIO");
    tick(1);
    exu_lsu.rretry = 0;
    check(!dut.ioq_complete[1], "retry marked the entry complete");
    for (int c = 0; c < 40; c++) begin
      if (exu_lsu.rvalid && exu_lsu.raddr == RamVA) begin
        break;
      end
      check(!exu_lsu.ordered, "younger MMIO acquired premature ordering permit");
      check(!exu_ioq_bcast.valid && !load_fast.valid,
            "blocked MMIO generated an architectural completion or wakeup");
      tick(1);
    end
    check(exu_lsu.rvalid && exu_lsu.raddr == RamVA,
          "older ready RAM load blocked behind younger unordered MMIO request");
    exu_lsu.rdata = XLEN'('h12345678);
    exu_lsu.rready = 1;
    tick(1);
    exu_lsu.rready = 0;
    for (int c = 0; c < 20 && dut.ioq_head == 0; c++) tick(1);
    check(dut.ioq_head == 1, "older RAM load did not complete");
    repeat (4) begin
      check(!exu_lsu.rvalid, "deferred MMIO retried before ROB head");
      tick(1);
    end
    cmu_bcast.rob_head = 4;
    for (int c = 0; c < 20 && !exu_lsu.rvalid; c++) tick(1);
    check(exu_lsu.rvalid && exu_lsu.raddr == IoVA && exu_lsu.ordered,
          "deferred MMIO did not retry with ordering permit");
    exu_lsu.rdata = 7;
    exu_lsu.rready = 1;
    tick(1);
    exu_lsu.rready = 0;
    for (int c = 0; c < 20 && dut.ioq_valid != 0; c++) tick(1);
    check(dut.ioq_valid == 0, "retried MMIO did not complete");
    $display("PASS: older RAM then ordered MMIO retry XLEN=%0d", XLEN);
    $finish;
  end
endmodule
