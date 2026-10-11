`include "rapt.svh"
`include "rapt_if.svh"
module tb_ioq_fp_ooo;
  localparam int XLEN = `RAPT_XLEN;
  `include "tb_ioq_harness.svh"
  integer completions = 0;
  logic [63:0] observed = 0;
  always @(posedge clock)
    if (!reset && exu_ioq_bcast.valid && exu_ioq_bcast.dest == 4) begin
      check(exu_ioq_bcast.fp_wen && !exu_ioq_bcast.trap, "FP load lost renamed completion");
      completions++;
      observed = exu_ioq_bcast.fp_result;
    end
  task automatic scenario(input int kind, input bit use_b, cancel, input bit b_becomes_head = 0);
    logic [63:0] expected;
    reset = 1;
    init_ioq_inputs(0);
    completions = 0;
    observed = 0;
    tick(3);
    reset = 0;
    tick(1);
    // Keep the older integer load incomplete, with either an unresolved base
    // or an active A miss. The younger FP load must publish independently.
    dispatch[0] = '0;
    dispatch[0].uop.execute.memory.load = 1;
    dispatch[0].uop.execute.int_op.alu = `RAPT_ALU_LW__;
    dispatch[0].pr1 = use_b ? 0 : 9;
    dispatch[0].op1 = XLEN'('h80002000);
    dispatch[0].prd = 10;
    dispatch[0].dest = 3;
    disp.accept[0] = 1;
    tick(1);
    disp.accept[0] = 0;
    dispatch[0] = '0;
    dispatch[0].uop.execute.memory.load = 1;
    dispatch[0].uop.execute.fp.valid = 1;
    dispatch[0].uop.execute.fp.op = kind == 0 ? `RAPT_FP_OP_FLW
        : kind == 1 ? `RAPT_FP_OP_FLD : `RAPT_FP_OP_ZFHMIN;
    dispatch[0].uop.execute.int_op.alu = kind == 0 ? `RAPT_ALU_LW__
        : kind == 1 ? `RAPT_ALU_LD__ : `RAPT_ALU_LH__;
    dispatch[0].op1 = XLEN'('h80003000);
    dispatch[0].dest = 4;
    disp.accept[0] = 1;
    tick(1);
    disp.accept[0] = 0;
    for (int timeout = 0; timeout < 40 && !(use_b ? exu_lsu.rvalid_b : exu_lsu.rvalid); timeout++)
      tick(1);
    check(use_b ? exu_lsu.rvalid_b : exu_lsu.rvalid, "younger FP load was not issued");
    check((use_b ? exu_lsu.raddr_b : exu_lsu.raddr) == XLEN'('h80003000),
          "FP load used older request address");
    if (b_becomes_head) begin
      // The younger B request can become head before its response arrives.
      // Its live FLD payload must come from B, not an old captured A value.
      exu_lsu.rdata = XLEN'('h11223344);
      exu_lsu.fp_rdata64 = 64'h0123456789abcdef;
      exu_lsu.rready = 1;
      tick(1);
      exu_lsu.rready = 0;
      tick(3);
      check(dut.ioq_head == 1 && exu_lsu.rvalid_b, "B request did not survive transition to head");
    end
    expected = kind == 0 ? 64'hffffffffc1234567
        : kind == 1 ? 64'hfedcba9876543210 : 64'hffffffffffffbeef;
    if (b_becomes_head && kind == 1) expected = 64'h8123456789abcdef;
    exu_lsu.rdata = kind == 0 ? XLEN'('hc1234567) : kind == 1 ? XLEN'(expected) : XLEN'('hbeef);
    exu_lsu.rdata_b = exu_lsu.rdata;
    exu_lsu.fp_rdata64 = expected;
    exu_lsu.rready = !use_b;
    exu_lsu.rready_b = use_b;
    cmu_bcast.flush_pipe = cancel;
    tick(1);
    exu_lsu.rready = 0;
    exu_lsu.rready_b = 0;
    tick(4);
    if (cancel) check(completions == 0, "cancelled FP response escaped");
    else begin
      if (completions != 1 || observed != expected)
        $display(
            "FP completion kind=%0d B=%0b head=%0b count=%0d got=%016h expected=%016h",
            kind,
            use_b,
            b_becomes_head,
            completions,
            observed,
            expected
        );
      check(completions == 1 && observed == expected,
            "younger FP completion missing or boxing/payload wrong");
      if (b_becomes_head) begin
        check(dut.ioq_valid == 0, "B head completion was not removed");
        return;
      end
      check(dut.ioq_head == 0 && dut.ioq_valid[0], "FP completion removed older owner");
      // Complete the older load and make sure ordered removal of the already
      // published FP entry does not duplicate its completion.
      if (!use_b) begin
        exu_rou.valid = 1;
        exu_rou.prd = 9;
        exu_rou.result = XLEN'('h80002000);
        tick(1);
        exu_rou.valid = 0;
        for (int timeout = 0; timeout < 30 && !exu_lsu.rvalid; timeout++) tick(1);
      end
      exu_lsu.rready = 1;
      tick(1);
      exu_lsu.rready = 0;
      tick(8);
      check(completions == 1 && dut.ioq_valid == 0, "FP load duplicated on ordered removal");
    end
  endtask
  initial begin
    for (int kind = 0; kind < 3; kind++) begin
      scenario(kind, 0, 0);
      scenario(kind, 0, 1);
      if (kind != 1 || XLEN == 64) begin
        scenario(kind, 1, 0);
        scenario(kind, 1, 1);
        scenario(kind, 1, 0, 1);
      end
    end
    $display(
        "PASS: FP load out-of-order A/B publication, boxing, cancellation and ordered removal XLEN=%0d",
        XLEN);
    $finish;
  end
endmodule
