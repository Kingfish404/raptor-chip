// Decode-ordered speculative return stack with an independent retirement image.
// Querying never mutates state. A flush restores the POST-commit image, including
// data overwritten by wrong-path pushes. Pop on empty is a no-op; overflow drops
// the oldest entry. Simultaneous pop/push is one coroutine action (pop first).
module rapt_ras #(
    parameter int Depth = 16,
    parameter int Xlen = 32,
    parameter int IndexBits = (Depth > 1 ? $clog2(Depth) : 1),
    parameter int CountBits = $clog2(Depth + 1)
) (
    input logic clock,
    reset,
    clear,
    flush,
    input logic spec_push,
    spec_pop,
    input logic [Xlen-1:0] spec_addr,
    input logic commit_push,
    commit_pop,
    input logic [Xlen-1:0] commit_addr,
    output logic top_valid,
    output logic [Xlen-1:0] top_addr
);
  typedef struct packed {
    // RISC-V instruction addresses are at least halfword aligned.
    logic [Depth-1:0][Xlen-1:1] data;
    logic [IndexBits-1:0] next_index;
    logic [CountBits-1:0] count;
  } state_t;
  typedef struct packed {
    logic [IndexBits-1:0] next_index;
    logic [CountBits-1:0] count;
  } metadata_t;
  state_t speculative, committed;
  metadata_t next_committed, next_speculative;
  logic [IndexBits-1:0] spec_write_index, commit_write_index;

  function automatic logic [IndexBits-1:0] previous(input logic [IndexBits-1:0] ptr);
    return ptr == 0 ? IndexBits'(Depth - 1) : ptr - 1'b1;
  endfunction

  function automatic logic [Xlen-1:1] payload(input logic [Xlen-1:0] addr);
    return addr[Xlen-1:1];
  endfunction

  function automatic metadata_t advance(input metadata_t old_state, input logic push,
                                        input logic pop);
    metadata_t result;
    result = old_state;
    if (pop && result.count != 0) begin
      result.next_index = previous(result.next_index);
      result.count = result.count - 1'b1;
    end
    if (push) begin
      result.next_index = result.next_index == IndexBits'(Depth - 1)
          ? '0 : result.next_index + 1'b1;
      if (result.count < CountBits'(Depth)) result.count = result.count + 1'b1;
    end
    return result;
  endfunction

  assign next_committed = advance(metadata_t'(committed), commit_push, commit_pop);
  assign next_speculative = advance(metadata_t'(speculative), spec_push, spec_pop);
  assign spec_write_index = spec_pop && speculative.count != 0
      ? previous(speculative.next_index) : speculative.next_index;
  assign commit_write_index = commit_pop && committed.count != 0
      ? previous(committed.next_index) : committed.next_index;
  assign top_valid = speculative.count != 0;
  assign top_addr = top_valid
      ? {speculative.data[previous(speculative.next_index)], 1'b0} : '0;
  // Decode one write enable per entry; avoid a packed-vector data mask.
  // On flush, bypass a same-edge commit push into the restored full image.
  // Payload remains unreset and is hidden by the corresponding live count.
  wire [Xlen-1:1] push_data = flush ? payload(commit_addr) : payload(spec_addr);
  for (genvar e = 0; e < Depth; e++) begin : g_data
    wire spec_write = spec_push && spec_write_index == IndexBits'(e);
    wire commit_write = commit_push && commit_write_index == IndexBits'(e);
    always_ff @(posedge clock) begin
      if (commit_write) committed.data[e] <= payload(commit_addr);
      if (flush || spec_write)
        speculative.data[e] <= flush && !commit_write ? committed.data[e] : push_data;
    end
  end
  always_ff @(posedge clock) begin
    committed.next_index <= next_committed.next_index;
    committed.count <= next_committed.count;
    speculative.next_index <= flush ? next_committed.next_index : next_speculative.next_index;
    speculative.count <= flush ? next_committed.count : next_speculative.count;
    if (reset || clear) begin
      speculative.next_index <= '0;
      speculative.count <= '0;
      committed.next_index <= '0;
      committed.count <= '0;
    end
  end
  if (!(Depth > 0 && Xlen > 0)) begin : g_invalid_config_0
    $error("Invalid rapt_ras configuration");
  end
`ifdef RAPT_ASSERT_EN
`ifndef SYNTHESIS
  always_ff @(posedge clock)
    if (!reset) begin
      assert (int'(speculative.count) <= Depth && int'(committed.count) <= Depth);
      assert (int'(speculative.next_index) < Depth && int'(committed.next_index) < Depth);
    end
`endif
`endif
endmodule
