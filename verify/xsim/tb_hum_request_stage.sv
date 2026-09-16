`include "rapt.svh"
`include "rapt_if.svh"
module tb_hum_request_stage;
  localparam int XLEN = `RAPT_XLEN;
  `include "tb_ioq_harness.svh"

  task automatic enqueue(input int slot, input logic [XLEN-1:0] addr, input int dependency = 0,
                         input bit fp64 = 0);
    dispatch[0] = '0;
    dispatch[0].uop.pc = XLEN'('h80000000 + 4*slot);
    dispatch[0].uop.pnpc = dispatch[0].uop.pc + 4;
    dispatch[0].uop.execute.memory.load = 1;
    dispatch[0].uop.execute.int_op.alu = `RAPT_ALU_LW__;
    if (fp64) begin
      dispatch[0].uop.execute.fp.valid = 1;
      dispatch[0].uop.execute.fp.op = `RAPT_FP_OP_FLD;
      dispatch[0].uop.execute.fp.rd = 5;
      dispatch[0].uop.inst = 32'h00003287; // fld f5, 0(x0)
    end
    dispatch[0].uop.rd = 5'(slot+1);
    dispatch[0].op1 = addr;
    dispatch[0].pr1 = `RAPT_PHY_LEN'(dependency);
    dispatch[0].prd = `RAPT_PHY_LEN'(slot+1);
    dispatch[0].dest = $bits(dispatch[0].dest)'(slot);
    dispatch[0].generation = 1;
    disp.accept[0] = 1;
    tick(1);
    disp.accept[0] = 0;
  endtask

  task automatic await_a(input logic [XLEN-1:0] addr);
    for (int n = 0; n < 12 && !exu_lsu.rvalid; n++) tick(1);
    check(exu_lsu.rvalid && exu_lsu.raddr == addr, "A request not staged");
    tick(1);
  endtask

  initial begin
`ifndef RAPT_LSU_HUM
    $fatal(1, "test requires RAPT_LSU_HUM");
`endif
    init_ioq_inputs(0);
    for (int s = 0; s < rapt_pkg::DispatchWidth; s++) dispatch[s] = '0;
    tick(3);
    reset = 0;
    tick(1);
    enqueue(0, XLEN'('h80001000));
    await_a(XLEN'('h80001000));
    enqueue(1, XLEN'('h80002000), 9);
    enqueue(2, XLEN'('h80003000));
    check(!exu_lsu.rvalid_b, "B bypassed its request register");
    tick(1);
    check(!exu_lsu.rvalid_b, "B bypassed address preparation");
    tick(1);
    check(exu_lsu.rvalid_b && exu_lsu.raddr_b == XLEN'('h80003000),
          "B did not capture the ready younger load");

    // Wake an older candidate while B is stalled: the live selector changes,
    // but the held request and its eventual completion owner must not.
    exu_rou='0;
    exu_rou.valid=1;
    exu_rou.prd=9;
    exu_rou.result=XLEN'('h80002000);
    tick(1);
    exu_rou.valid = 0;
    repeat (5) begin
      tick(1);
      check(exu_lsu.rvalid_b && exu_lsu.raddr_b == XLEN'('h80003000),
            "B changed payload under backpressure");
    end
    exu_lsu.rready_b=1;
    exu_lsu.rdata_b=XLEN'('h13579bdf);
    tick(1);
    exu_lsu.rready_b = 0;
    check(dut.ioq_complete[2] && !dut.ioq_complete[1],
          "B completed the live selector instead of the captured owner");
    check(!exu_lsu.rvalid_b, "B reissued on completion edge");
    tick(1);
    check(exu_lsu.rvalid_b && exu_lsu.raddr_b == XLEN'('h80002000),
          "B did not refill with the newly ready older load");

    exu_lsu.rready=1;
    exu_lsu.rdata=XLEN'('h11112222);
    exu_lsu.rready_b=1;
    exu_lsu.rdata_b=XLEN'('h33334444);
    tick(1);
    exu_lsu.rready=0;
    exu_lsu.rready_b=0;
    check(!exu_lsu.rvalid_b, "B outlived completed A miss");
    check(
        exu_ioq_bcast.valid && exu_ioq_bcast.dest == 0 && exu_ioq_bcast.result == XLEN'('h11112222),
        "A head response missing");
    tick(1);
    check(
        exu_ioq_bcast.valid && exu_ioq_bcast.dest == 1 && exu_ioq_bcast.result == XLEN'('h33334444),
        "wrong simultaneous B result");
    tick(1);
    check(
        exu_ioq_bcast.valid && exu_ioq_bcast.dest == 2 && exu_ioq_bcast.result == XLEN'('h13579bdf),
        "lost earlier B result");
    tick(1);
    check(!exu_ioq_bcast.valid, "duplicate completion");

    // Flush a captured, unaccepted B request; late ready must not complete
    // or resurrect either entry. Exercise the same request-stage boundary
    // again with A returning before B is accepted.
    for (int scenario = 0; scenario < 2; scenario++) begin
      cmu_bcast.flush_pipe = 1;
      tick(1);
      cmu_bcast.flush_pipe=0;
      cmu_bcast.rob_head=0;
      enqueue(0, XLEN'('h80004000));
      await_a(XLEN'('h80004000));
      enqueue(1, XLEN'('h80005000));
      tick(2);
      check(exu_lsu.rvalid_b, "second B request missing");
      if (scenario == 0) cmu_bcast.flush_pipe = 1;
      else exu_lsu.rready = 1;
      tick(1);
      cmu_bcast.flush_pipe=0;
      exu_lsu.rready=0;
      check(!exu_lsu.rvalid_b, "cancelled B request remained active");
      exu_lsu.rready_b = 1;
      tick(1);
      exu_lsu.rready_b = 0;
      check(!dut.ioq_complete[1], "late B response completed cancelled probe");
      if (scenario == 0) check(!exu_ioq_bcast.valid, "flush resurrected completion");
      else
        check(exu_lsu.rvalid && exu_lsu.raddr == XLEN'('h80005000),
              "failed B probe did not retry through A");
    end
    cmu_bcast.flush_pipe = 1;
    tick(1);
    cmu_bcast.flush_pipe=0;
    cmu_bcast.rob_head=0;
    enqueue(0, XLEN'('h80006000));
    await_a(XLEN'('h80006000));
    enqueue(1, XLEN'('h80007000), 0, 1);
    repeat (4) begin
      tick(1);
      check(!exu_lsu.rvalid_b, "FLD used B without a FP64 response payload");
    end
    exu_lsu.rready = 1;
    tick(1);
    exu_lsu.rready = 0;
    await_a(XLEN'('h80007000));
    check(exu_lsu.fp_rdata64_req, "FLD fallback lost its 64-bit request");
    exu_lsu.fp_rdata64=64'hfedcba9876543210;
    exu_lsu.rready=1;
    tick(1);
    exu_lsu.rready = 0;
    check(fpr.ioq_wvalid && fpr.ioq_waddr == 5, "FLD fallback lost FPR write identity");
    check(fpr.ioq_wdata == 64'hfedcba9876543210, "FLD fallback lost FPR data");
    $display("PASS: registered HUM ownership/backpressure/flush/FP64 XLEN=%0d", XLEN);
    $finish;
  end
  initial begin
    #20000;
    $fatal(1, "HUM request-stage timeout");
  end
endmodule
