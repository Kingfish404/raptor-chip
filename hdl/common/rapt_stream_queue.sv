`include "rapt.svh"

// Ordered instruction stream, not a queue of indivisible fetch/rename groups.
// Valid inputs and accepted outputs are contiguous prefixes. No fall-through:
// storage decouples producer data from consumer selection. Flush cancels both.
module rapt_stream_queue #(
    parameter type ItemT = logic [31:0],
    parameter int Depth = 8,
    parameter int InWidth = 2,
    parameter int OutWidth = 2
) (
    input logic clock,
    reset,
    flush,
    input ItemT in_data[InWidth],
    input logic in_valid[InWidth],
    output logic in_ready[InWidth],
    output ItemT out_data[OutWidth],
    output logic out_valid[OutWidth],
    input logic out_ready[OutWidth],
    output logic [$clog2(Depth+1)-1:0] occupancy
);
  localparam int PtrBits = rapt_pkg::index_bits(Depth);
  ItemT storage[Depth];
  logic [PtrBits-1:0] head, tail;
  logic [PtrBits-1:0] push_index[InWidth];
  int unsigned push_count, pop_count;
  function automatic int unsigned advance(input int unsigned ptr, input int unsigned amount);
    int unsigned sum;
    // Reachable pointers are below Depth and each advance is at most Depth.
    // One subtraction suffices, including non-power-of-two depths.
    sum = ptr + amount;
    return sum >= Depth ? sum - Depth : sum;
  endfunction
  if (!(Depth > 0 && InWidth > 0 && OutWidth > 0)) begin : g_invalid_config_0
    $error("Invalid rapt_stream_queue configuration");
  end
  if (!(Depth >= InWidth && Depth >= OutWidth)) begin : g_invalid_config_1
    $error("Invalid rapt_stream_queue configuration");
  end
  for (genvar s = 0; s < OutWidth; s++) begin : g_read
    assign out_data[s]  = storage[advance(int'(head), s)];
    assign out_valid[s] = !flush && !reset && int'(occupancy) > s;
  end
  always_comb begin
    pop_count = 0;
    for (int s = 0; s < OutWidth; s++)
    if (s == pop_count && out_valid[s] && out_ready[s]) pop_count++;
  end
  for (genvar s = 0; s < InWidth; s++) begin : g_ready
    assign in_ready[s] = !flush && !reset && s < Depth - int'(occupancy) + pop_count;
    assign push_index[s] = PtrBits'(advance(int'(tail), s));
  end
  always_comb begin
    push_count = 0;
    for (int s = 0; s < InWidth; s++)
    if (s == push_count && in_valid[s] && in_ready[s]) push_count++;
  end
  always_ff @(posedge clock) begin
    if (reset || flush) begin
      head <= '0;
      tail <= '0;
      occupancy <= '0;
    end else begin
      head <= PtrBits'(advance(int'(head), pop_count));
      tail <= PtrBits'(advance(int'(tail), push_count));
      occupancy <= $clog2(Depth + 1)'(int'(occupancy) + push_count - pop_count);
    end
  end
  // Each entry owns its storage update. Accepted slots have distinct indices;
  // enqueue replaces a reclaimed entry after its old value is consumed.
  // Data is intentionally not reset: occupancy owns validity.
  for (genvar e = 0; e < Depth; e++) begin : g_entry
    always_ff @(posedge clock) begin
      if (!reset && !flush) begin
        for (int s = 0; s < InWidth; s++)
        if (s < push_count && push_index[s] == PtrBits'(e)) storage[e] <= in_data[s];
      end
    end
  end
  for (genvar s = 1; s < InWidth; s++) begin : g_input_contract
    `RAPT_SVA_IMPLY(clock, reset || flush, STREAM_INPUT_PREFIX, in_valid[s], in_valid[s-1])
  end
  for (genvar s = 1; s < OutWidth; s++) begin : g_output_contract
    `RAPT_SVA_IMPLY(clock, reset || flush, STREAM_ACCEPT_PREFIX, out_valid[s] && out_ready[s],
                    out_valid[s-1] && out_ready[s-1])
  end
  `RAPT_SVA(clock, reset, STREAM_CAPACITY, int'(occupancy) <= Depth)
  `RAPT_SVA(clock, reset, STREAM_POINTER_RANGE, int'(head) < Depth && int'(tail) < Depth)
endmodule
