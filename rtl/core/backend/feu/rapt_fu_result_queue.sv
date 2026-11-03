`include "rapt.svh"

// Common owner transport for pipelined and iterative execution units. Arithmetic
// returns results in launch order, but different units may complete in any order.
// Credits reserve room for every launched operation before the arithmetic starts;
// an output stall therefore never loses a one-cycle result pulse. Metadata and
// results share one owner ring with registered launch and completion boundaries.
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
    output logic credit_available,
    input logic result_valid,
    input logic [63:0] result,
    input logic [4:0] flags,
    output CompletionT completion,
    input logic completion_ready
);
  localparam int CountBits = $clog2(Depth + 1);
  localparam int PtrBits   = rapt_pkg::index_bits(Depth);
  localparam int WordBits  = $bits(launch.result);
  localparam int OwnerBits = $bits(launch.dest);
  logic [PtrBits-1:0] head, tail, result_head;
  logic [CountBits-1:0] count, completed;
  CompletionT owner_input;
  (* ram_style = "distributed" *) CompletionT owners[Depth];
  (* ram_style = "distributed" *) logic [68:0] results[Depth];
  logic [OwnerBits-1:0] destinations[Depth];
  logic [Depth-1:0] killed;
  logic push, capture, pop;

  function automatic logic [PtrBits-1:0] advance(input logic [PtrBits-1:0] ptr);
    return ptr == PtrBits'(Depth - 1) ? '0 : ptr + 1'b1;
  endfunction
  function automatic logic [PtrBits-1:0] offset_pointer(input logic [PtrBits-1:0] base,
                                                        input logic [CountBits-1:0] distance);
    logic [PtrBits:0] sum;
    sum = {1'b0, base} + (PtrBits + 1)'(distance);
    return PtrBits'(sum >= (PtrBits + 1)'(Depth) ? sum - (PtrBits + 1)'(Depth) : sum);
  endfunction
  function automatic logic killed_now(input logic [IndexBits-1:0] owner);
    return cancel_valid && `RAPT_ROB_YOUNGER(owner, cancel_owner, cancel_head);
  endfunction

  // Occupancy locates both write positions relative to the oldest owner. Each
  // sum is below twice Depth, so one subtraction replaces redundant pointers.
  assign tail = offset_pointer(head, count);
  assign result_head = offset_pointer(head, completed);
  // A credit covers an owner from launch through completion acceptance. Full
  // queues do not reclaim a departing credit until the following cycle.
  // Selection may observe capacity during recovery; only ready permits a push.
  assign ready = !reset && !flush && credit_available;
  assign push = launch.valid && ready;
  assign capture = !reset && !flush && result_valid && count > completed;
  assign pop = !reset && !flush && completed != '0 && (completion_ready || !completion.valid);
  always_comb begin
    owner_input = launch;
    // These fields are supplied by the arithmetic pulse, not stored twice.
    owner_input.dest = '0;
    owner_input.result = '0;
    owner_input.fp_result = '0;
    owner_input.fp_flags = '0;
    completion = owners[head];
    completion.dest = destinations[head];
    completion.result = WordBits'(results[head][68:5]);
    completion.fp_result = results[head][68:5];
    completion.fp_flags = results[head][4:0];
    // Same-cycle cancellation remains the consumer's responsibility.
    completion.valid = !reset && !flush && completed != '0 && !killed[head];
  end

  // Completed entries form a prefix of the owner FIFO. Result arrival writes
  // only the 69-bit side-band at the oldest still-pending owner; delivery reads
  // the oldest completed owner. Neither boundary has a combinational bypass.
  always_ff @(posedge clock) begin
    if (reset || flush) begin
      head <= '0;
      count <= '0;
      credit_available <= 1'b1;
      completed <= '0;
    end else begin
      if (pop) head <= advance(head);
      // Mirror next occupancy so selection does not wait on a count comparison.
      if (push && !pop) credit_available <= int'(count) < Depth - 1;
      else if (pop && !push) credit_available <= 1'b1;
      count <= count + CountBits'(push) - CountBits'(pop);
      completed <= completed + CountBits'(capture) - CountBits'(pop);
    end
    if (launch.valid && credit_available) begin
      owners[tail] <= owner_input;
      destinations[tail] <= launch.dest;
    end
    if (result_valid && count > completed) results[result_head] <= {result, flags};
  end
  // Owner numbers need parallel recovery reads. Keep them separate so the
  // remaining metadata retains one read port and can map to FPGA LUTRAM.
  for (genvar e = 0; e < Depth; e++) begin : g_cancel
    always_ff @(posedge clock) begin
      if (reset || flush) killed[e] <= 1'b0;
      else if (push && tail == PtrBits'(e)) killed[e] <= killed_now(launch.dest);
      // Preserve the original ROB-indexed table's launch priority, including
      // destination reuse while an earlier cancelled arithmetic pulse drains.
      else if (push && launch.dest == destinations[e]) killed[e] <= killed_now(launch.dest);
      else if (killed_now(destinations[e])) killed[e] <= 1'b1;
    end
  end
  `RAPT_SVA_IMPLY(clock, reset || flush, FU_LAUNCH_HAS_CREDIT, launch.valid, ready)
  `RAPT_SVA_IMPLY(clock, reset || flush, FU_RESULT_HAS_OWNER, result_valid, count > completed)
  `RAPT_SVA(clock, reset || flush, FU_CREDIT_MIRRORS_COUNT,
            credit_available == (int'(count) < Depth))
  `RAPT_SVA(clock, reset || flush, FU_RESULT_CREDITS, int'(count) <= Depth && completed <= count)
endmodule
