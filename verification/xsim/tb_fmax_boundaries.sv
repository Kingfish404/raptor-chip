`include "rapt.svh"
`include "rapt_if.svh"
module tb_fmax_boundaries;
  localparam int XLEN = `RAPT_XLEN;
  logic clock = 0, reset = 1, flush = 0, cancel_valid = 0;
  logic [$clog2(`RAPT_ROB_SIZE)-1:0] cancel_head = 0, cancel_owner = 0;
  always #5 clock = ~clock;
  `include "tb_common.svh"
rapt_pkg::completion_t integer_result, fp_result, shared_result;
  logic integer_accept = 1, fp_accept = 1;
  logic integer_enable, fp_ready;
  rapt_cdb_arb arb (
      .clock,
      .reset,
      .flush,
      .cancel_valid,
      .cancel_head,
      .cancel_owner,
      .fpu_completion_ready(fp_ready),
      .integer_system_pipe_enable(1'b1),
      .fpu_issue_enable(1'b1),
      .wb_integer_system_raw(integer_result),
      .wb_fpu(fp_result),
      .wb_integer_system_accept(integer_accept),
      .wb_fpu_accept(fp_accept),
      .wb_shared(shared_result),
      .integer_system_issue_enable(integer_enable)
  );
  rapt_pkg::issue_packet_t selected, execute;
  logic occupied;
  rapt_execute_stage stage (
      .clock,
      .reset,
      .flush,
      .cancel_valid,
      .cancel_head,
      .cancel_owner,
      .selected,
      .execute,
      .occupied
  );
  rnu_rou_if #(.Width(3)) source ();
  rnu_rou_if #(.Width(3)) sink ();
  rapt_operand_stage #(
      .Width(3)
  ) operands (
      .clock,
      .reset,
      .flush,
      .upstream(source),
      .downstream(sink)
  );
  task automatic clear_inputs;
    integer_result = '0;
    fp_result = '0;
    selected = '0;
    for (int s = 0; s < 3; s++) begin
      source.valid[s] = 0;
      source.slot[s] = '0;
      source.checkpoint_valid[s] = 0;
      source.checkpoint[s] = '0;
      sink.ready[s] = 0;
    end
    source.empty = 1;
  endtask
  initial begin
    clear_inputs();
    tick(3);
    reset = 0;
    // Simultaneous producers are captured independently, then emitted once.
    integer_result.valid = 1;
    integer_result.dest = 2;
    integer_result.generation = 3;
    integer_result.result = XLEN'('h12345678);
    fp_result.valid = 1;
    fp_result.dest = 3;
    fp_result.generation = 4;
    fp_result.result = XLEN'('habcd0123);
    fp_result.fp_flags_valid = 1;
    fp_result.fp_flags = 5'h15;
    integer_result.valid = 0;
    #1;
    check(!shared_result.valid && integer_enable, "raw FP result feeds issue or output");
    integer_result.valid = 1;
    #1;
    check(integer_enable, "raw FP result feeds issue enable");
    check(
        shared_result.valid && shared_result.dest == 2 && shared_result.generation == 3
          && shared_result.result == XLEN'('h12345678),
        "integer bypass lost packet");
    tick(1);
    integer_result.valid = 0;
    fp_result.valid = 0;
    #1;
    check(!integer_enable && !fp_ready, "occupied shared slots admitted another result");
    check(
        shared_result.valid && shared_result.dest == 3 && shared_result.fp_flags == 5'h15
          && shared_result.generation == 4,
        "simultaneous FP result dropped");
    tick(1);
    check(!shared_result.valid && integer_enable, "completion duplicated or capacity lost");
    // The integer completion register is replaceable every cycle. Pending FP
    // stops new issues but cannot block the final already-issued integer.
    for (int n = 0; n < 8; n++) begin
      integer_result.valid = 1;
      integer_result.dest = 5;
      integer_result.result = XLEN'(100+n);
      #1;
      check(integer_enable, "integer stream acquired a bubble");
      check(shared_result.valid && shared_result.result == XLEN'(100 + n),
            "integer stream lost/repeated a packet");
      tick(1);
    end
    fp_result.valid = 1;
    integer_result.result = 200;
    tick(1);
    fp_result.valid = 0;
    check(!integer_enable && shared_result.dest == 3, "FP did not stop new issues");
    integer_result.result = 201;
    tick(1);
    integer_result.valid = 0;
    #1;
    check(shared_result.result == 201, "in-flight integer lost");
    tick(1);
    check(!shared_result.valid && fp_ready, "FP emitted more than once");
    integer_accept = 0;
    integer_result.valid = 1;
    tick(1);
    integer_result.valid = 0;
    integer_accept = 1;
    check(!shared_result.valid, "rejected generation entered buffer");
    // Selective cancellation including ROB wrap; owner and older survive.
    for (int n = 0; n < 4; n++) begin
      integer_result.valid = 1;
      integer_result.dest = $bits(integer_result.dest)'(n == 0 ? 29 : n == 1 ? 30 : n == 2 ? 31 : 0);
      cancel_head = 28;
      cancel_owner = 30;
      cancel_valid = 1;
      #1;
      check(shared_result.valid == (n < 2), "buffer cancellation age incorrect");
      tick(1);
      integer_result.valid = 0;
      cancel_valid = 0;
    end
    integer_result.valid = 1;
    tick(1);
    integer_result.valid = 0;
    flush = 1;
    #1;
    check(!shared_result.valid, "flush leaked completion");
    tick(1);
    flush = 0;
    check(!shared_result.valid, "flushed packet resurrected");
    // Execution payload is stable and no combinational selection reaches it.
    selected.valid = 1;
    selected.dest = 31;
    selected.generation = 7;
    selected.op1 = XLEN'('h9876);
    tick(1);
    selected.op1 = 0;
    selected.valid = 0;
    check(execute.valid && execute.op1 == XLEN'('h9876) && execute.generation == 7,
          "execution stage did not capture payload");
    cancel_valid = 1;
    #1;
    check(!execute.valid, "execution packet survived selective cancel");
    tick(1);
    cancel_valid = 0;
    // Three-lane input and arbitrary prefix consumption; PR tags/checkpoints
    // must follow the same suffix compaction as payload.
    for (int s = 0; s < 3; s++) begin
      source.valid[s] = 1;
      source.slot[s].op1 = XLEN'(100+s);
      source.slot[s].pr1 = $bits(source.slot[s].pr1)'(10+s);
      source.checkpoint_valid[s] = 1;
      source.checkpoint[s] = $bits(source.checkpoint[s])'(s+1);
    end
    source.empty = 0;
    tick(1);
    for (int s = 0; s < 3; s++) source.valid[s] = 0;
    source.empty = 1;
    check(!sink.empty && sink.valid[2] && sink.slot[0].op1 == 100, "operand batch missing");
    tick(3);
    check(sink.slot[0].pr1 == 10 && !source.ready[0], "stalled operand batch changed");
    sink.ready[0] = 1;
    tick(1);
    sink.ready[0] = 0;
    check(
        sink.valid[1] && !sink.valid[2] && sink.slot[0].op1 == 101
        && sink.slot[0].pr1 == 11 && sink.checkpoint[0] == 2,
        "partial prefix lost identity");
    // Refill on the same edge that consumes the remaining suffix.
    sink.ready[0] = 1;
    sink.ready[1] = 1;
    source.valid[0] = 1;
    source.slot[0].op1 = 200;
    source.slot[0].pr1 = 20;
    #1;
    check(source.ready[0], "draining operand stage could not refill");
    tick(1);
    source.valid[0] = 0;
    sink.ready[0] = 0;
    sink.ready[1] = 0;
    check(sink.valid[0] && !sink.valid[1] && sink.slot[0].op1 == 200 && sink.slot[0].pr1 == 20,
          "operand refill reordered packets");
    flush = 1;
    tick(1);
    flush = 0;
    check(sink.empty && !sink.valid[0], "operand stage retained flushed rename");
    $display("PASS: shared completion, execution ownership and operand prefix boundaries XLEN=%0d",
             XLEN);
    $finish;
  end
endmodule
