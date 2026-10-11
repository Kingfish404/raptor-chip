`include "rapt.svh"

// Common owner transport for pipelined and iterative execution units. Arithmetic
// returns results in launch order, but different units may complete in any order.
// Credits reserve room for every launched operation before the arithmetic starts;
// an output stall therefore never loses a one-cycle result pulse. Metadata and
// completed packets use the same registered-capacity queues as the frontend.
module rapt_fu_result_queue #(
    parameter type CompletionT = rapt_pkg::completion_t,
    parameter int Depth = 8,
    parameter int Entries = rapt_pkg::CoreConfig.rob_entries,
    parameter int IndexBits = rapt_pkg::index_bits(Entries)
) (
    input logic clock,
    reset,
    flush,
    input logic cancel_valid,
    input logic [IndexBits-1:0] cancel_head,
    cancel_owner,
    input CompletionT launch,
    output logic ready,
    input logic result_valid,
    input logic [63:0] result,
    input logic [4:0] flags,
    output CompletionT completion,
    input logic completion_ready
);
  localparam int CountBits = $clog2(Depth + 1);
  localparam int WordBits  = $bits(launch.result);
  logic [CountBits-1:0] meta_count, result_count;
  CompletionT meta_input[1], meta_output[1], result_input[1], result_output[1];
  logic meta_push[1], meta_ready[1], meta_valid[1], meta_pop[1];
  logic result_push[1], result_ready[1], result_out_valid[1], result_pop[1];
  logic [Entries-1:0] killed_q;
  function automatic logic killed_now(input logic [IndexBits-1:0] owner);
    logic younger;
    younger = ((owner < cancel_head) == (cancel_owner < cancel_head))
        ? owner > cancel_owner : owner < cancel_head;
    return cancel_valid && younger;
  endfunction
  assign ready = !reset && !flush && (int'(meta_count) + int'(result_count) < Depth);
  assign meta_input[0] = launch;
  assign meta_push[0] = launch.valid && ready;
  assign meta_pop[0] = result_valid;
  assign result_push[0] = result_valid && meta_valid[0];
  always_comb begin
    result_input[0] = meta_output[0];
    result_input[0].result = WordBits'(result);
    result_input[0].fp_result = result;
    result_input[0].fp_flags = flags;
    completion = result_output[0];
    completion.valid = result_out_valid[0] && !killed_q[result_output[0].dest]
        && !killed_now(result_output[0].dest);
  end
  // Cancelled owners drain through both queues in order. This preserves the
  // identity of later arithmetic pulses without restarting an older operation.
  assign result_pop[0] = completion_ready || !completion.valid;
  for (genvar e = 0; e < Entries; e++) begin : g_cancel
    always_ff @(posedge clock) begin
      if (reset || flush) killed_q[e] <= 1'b0;
      else if (meta_push[0] && launch.dest == IndexBits'(e))
        killed_q[e] <= killed_now(IndexBits'(e));
      else if (killed_now(IndexBits'(e))) killed_q[e] <= 1'b1;
    end
  end
  rapt_stream_queue #(
      .ItemT(CompletionT),
      .Depth(Depth),
      .InWidth(1),
      .OutWidth(1),
      .ReclaimSameCycle(1'b0)
  ) owners (
      .clock,
      .reset,
      .flush,
      .in_data(meta_input),
      .in_valid(meta_push),
      .in_ready(meta_ready),
      .out_data(meta_output),
      .out_valid(meta_valid),
      .out_ready(meta_pop),
      .occupancy(meta_count)
  );
  rapt_stream_queue #(
      .ItemT(CompletionT),
      .Depth(Depth),
      .InWidth(1),
      .OutWidth(1),
      .ReclaimSameCycle(1'b0)
  ) results (
      .clock,
      .reset,
      .flush,
      .in_data(result_input),
      .in_valid(result_push),
      .in_ready(result_ready),
      .out_data(result_output),
      .out_valid(result_out_valid),
      .out_ready(result_pop),
      .occupancy(result_count)
  );
  `RAPT_SVA_IMPLY(clock, reset || flush, FU_LAUNCH_HAS_CREDIT, launch.valid, ready && meta_ready[0])
  `RAPT_SVA_IMPLY(clock, reset || flush, FU_RESULT_HAS_OWNER, result_valid,
                  meta_valid[0] && result_ready[0])
  `RAPT_SVA(clock, reset || flush, FU_RESULT_CREDITS,
            int'(meta_count) + int'(result_count) <= Depth)
endmodule
