`include "rapt.svh"
`include "rapt_if.svh"

module tb_mdq_selective_recovery;
  localparam int Xlen = `RAPT_XLEN;
  localparam int XLEN = Xlen;
  localparam int RobBits = $clog2(`RAPT_ROB_SIZE);
  logic clock = 0, reset = 1;
  logic cancel_valid = 0;
  logic [RobBits-1:0] cancel_head = RobBits'(28), cancel_owner = RobBits'(31);
  cmu_bcast_if cmu_bcast ();
  csr_bcast_if csr_bcast ();
  rapt_pkg::dispatch_slot_t dispatch[rapt_pkg::DispatchWidth];
  rapt_pkg::completion_t completion[rapt_pkg::CompletionPorts];
  rapt_pkg::completion_t wb, external_wb;
  dpu_iq_if #(.RS_SIZE(4)) disp ();
  assign completion[0] = external_wb;
  assign completion[1] = wb;
  for (genvar p = 2; p < rapt_pkg::CompletionPorts; p++) assign completion[p] = '0;
  rapt_ieu_muldiv #(
      .MDQ_SIZE(4)
  ) dut (
      .clock,
      .reset,
      .cancel_valid,
      .cancel_head,
      .cancel_owner,
      .cmu_bcast,
      .completion,
      .dispatch,
      .disp,
      .exu_wb_mul(wb)
  );
  always #5 clock = ~clock;
  `include "tb_core_bcast_defaults.svh"

  bit expected[`RAPT_ROB_SIZE];
  logic [Xlen-1:0] result[`RAPT_ROB_SIZE];
  logic [3:0] generation[`RAPT_ROB_SIZE];
  int returned = 0;
  always @(posedge clock) begin
    if (!reset && !cmu_bcast.flush_pipe && wb.valid) begin
      assert (expected[wb.dest])
      else $fatal(1, "unexpected/stale completion dest=%0d", wb.dest);
      assert (wb.result == result[wb.dest] && wb.generation == generation[wb.dest])
      else $fatal(1, "completion payload/identity mismatch dest=%0d", wb.dest);
      expected[wb.dest] = 0;
      returned++;
    end
  end
  task automatic tick;
    @(posedge clock);
    #1;
    @(negedge clock);
    #1;
  endtask
  task automatic enqueue(input int dest, input logic [4:0] op, input logic [Xlen-1:0] a, b, answer,
                         input int wait_tag = 0, input bit survives = 1, input int gen = 1);
    assert (disp.free_found[0])
    else $fatal(1, "MDQ full");
    dispatch[0] = '0;
    dispatch[0].dest = RobBits'(dest);
    dispatch[0].generation = 4'(gen);
    dispatch[0].prd = `RAPT_PHY_LEN'(40 + (dest % 16));
    dispatch[0].uop.rd = 5'(dest);
    dispatch[0].uop.pc = Xlen'('h80000000 + dest * 4);
    dispatch[0].uop.execute.int_op.alu = {1'b0, op};
    dispatch[0].op1 = a;
    dispatch[0].op2 = b;
    dispatch[0].pr1 = `RAPT_PHY_LEN'(wait_tag);
    disp.accept[0] = 1;
    disp.rs_idx[0] = disp.free_idx[0];
    expected[dest] = survives;
    result[dest] = answer;
    generation[dest] = 4'(gen);
    tick();
    disp.accept[0] = 0;
  endtask
  task automatic wait_returns(input int target);
    for (int cycle = 0; cycle < 4 * Xlen + 32 && returned < target; cycle++) tick();
    assert (returned == target)
    else $fatal(1, "missing surviving completion");
  endtask
  task automatic cancel_younger(input int dest);
    expected[dest] = 0;
    cancel_valid = 1;
    #1;
    assert (!wb.valid || wb.dest != RobBits'(dest))
    else $fatal(1, "same-cycle cancelled output");
    tick();
    cancel_valid = 0;
  endtask

  initial begin
    init_cmu_bcast_defaults();
    external_wb = '0;
    foreach (dispatch[s]) begin
      dispatch[s] = '0;
      disp.accept[s] = 0;
      disp.rs_idx[s] = '0;
    end
    foreach (expected[e]) expected[e] = 0;
    repeat (3) tick();
    reset = 0;
    tick();

    // Ring wrap: head 28, older 30, owner 31, younger 1.
    enqueue(30, `RAPT_ALU_MUL___, 0, 6, 42, 5);
    enqueue(1, `RAPT_ALU_DIVU__, '1, 3, Xlen'('1) / 3, 5);
    cancel_younger(1);
    assert ($countones(dut.mdq_valid) == 1)
    else
      $fatal(
          1,
          "queued cancellation age valid=%b head=%0d owner=%0d d0=%0d d1=%0d issued=%b",
          dut.mdq_valid,
          cancel_head,
          cancel_owner,
          dut.mdq_dest[0],
          dut.mdq_dest[1],
          dut.mdq_issued
      );
    external_wb.valid = 1;
    external_wb.prd = 5;
    external_wb.result = 7;
    tick();
    external_wb = '0;
    wait_returns(1);

    // A younger running divider must release the FU before normal completion.
    enqueue(1, `RAPT_ALU_DIVU__, '1, 3, Xlen'('1) / 3);
    tick();
    assert (!dut.fu_in_ready)
    else $fatal(1, "divider did not start");
    enqueue(30, `RAPT_ALU_MUL___, 6, 7, 42);
    cancel_younger(1);
    assert (dut.fu_in_ready)
    else $fatal(1, "cancel did not abort divider");
    enqueue(2, `RAPT_ALU_MUL___, 7, 8, 56, 0, 1, 2);
    wait_returns(3);
    repeat (2 * Xlen + 8) tick();
    assert (returned == 3)
    else $fatal(1, "late cancelled producer survived tag reuse");

    // Preserve an older divider while deleting a younger queued multiply.
    enqueue(30, `RAPT_ALU_DIVU__, '1, 3, Xlen'('1) / 3);
    tick();
    enqueue(1, `RAPT_ALU_MUL___, 6, 7, 42);
    cancel_younger(1);
    assert (!dut.fu_in_ready)
    else $fatal(1, "older divider was incorrectly cancelled");
    wait_returns(4);

    // A result becoming visible on the recovery cycle must be suppressed.
    enqueue(1, `RAPT_ALU_MUL___, 6, 7, 42);
    for (int cycle = 0; cycle < 3 * Xlen + 16 && !wb.valid; cycle++) tick();
    assert (wb.valid && returned == 4)
    else $fatal(1, "completion collision not exercised");
    cancel_younger(1);
    repeat (3) tick();
    assert (returned == 4 && dut.mdq_valid == 0)
    else $fatal(1, "cancelled output retained");

    // Admission concurrent with recovery rejects younger but preserves older.
    cancel_valid = 1;
    enqueue(1, `RAPT_ALU_MUL___, 6, 7, 42, 0, 0);
    assert (dut.mdq_valid == 0)
    else $fatal(1, "same-edge younger allocation survived");
    enqueue(30, `RAPT_ALU_MUL___, 6, 7, 42);
    cancel_valid = 0;
    wait_returns(5);

    // Cancel between MUL input capture and output visibility, then reuse.
    enqueue(1, `RAPT_ALU_MUL___, 6, 7, 42);
    tick();
    cancel_younger(1);
    enqueue(2, `RAPT_ALU_MUL___, 9, 7, 63, 0, 1, 3);
    wait_returns(6);

    // The recovery owner itself is retained (strictly younger cancellation).
    enqueue(31, `RAPT_ALU_DIVU__, '1, 3, Xlen'('1) / 3);
    tick();
    cancel_valid = 1;
    tick();
    cancel_valid = 0;
    wait_returns(7);

    // Exercise normalizer and several active divider iterations, each
    // followed immediately by reuse with a different generation and payload.
    for (int cut = 0; cut < Xlen / 2; cut += 3) begin
      enqueue(1, `RAPT_ALU_DIVU__, '1, 3, Xlen'('1) / 3);
      repeat (cut + 1) tick();
      cancel_younger(1);
      enqueue(2, `RAPT_ALU_MUL___, Xlen'(cut + 2), 7, Xlen'((cut + 2) * 7), 0, 1, cut % 15 + 1);
      wait_returns(8 + cut / 3);
    end
    repeat (2 * Xlen + 8) tick();
    assert (dut.mdq_valid == 0)
    else $fatal(1, "cancelled divider leaked an owner");
    $display(
        "PASS: MDQ selective recovery, abort, wrap, late-output suppression and reuse XLEN=%0d",
        Xlen);
    $finish;
  end
  initial begin
    #100000;
    $fatal(1, "timeout");
  end
endmodule
