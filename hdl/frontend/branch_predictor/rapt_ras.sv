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
    logic [Depth-1:0][Xlen-1:0] data;
    logic [IndexBits-1:0] next_index;
    logic [CountBits-1:0] count;
  } state_t;
  state_t speculative, committed, next_committed;

  function automatic logic [IndexBits-1:0] previous(input logic [IndexBits-1:0] ptr);
    return ptr == 0 ? IndexBits'(Depth - 1) : ptr - 1'b1;
  endfunction

  function automatic state_t advance(input state_t old_state, input logic push, pop,
                                     input logic [Xlen-1:0] addr);
    state_t result;
    result = old_state;
    if (pop && result.count != 0) begin
      result.next_index = previous(result.next_index);
      result.count = result.count - 1'b1;
    end
    if (push) begin
      result.data[result.next_index] = addr;
      result.next_index = result.next_index == IndexBits'(Depth - 1)
          ? '0 : result.next_index + 1'b1;
      if (result.count < CountBits'(Depth)) result.count = result.count + 1'b1;
    end
    return result;
  endfunction

  assign next_committed = advance(committed, commit_push, commit_pop, commit_addr);
  assign top_valid = speculative.count != 0;
  assign top_addr = top_valid ? speculative.data[previous(speculative.next_index)] : '0;
  always_ff @(posedge clock) begin
    if (reset || clear) begin
      speculative <= '0;
      committed <= '0;
    end else begin
      committed <= next_committed;
      speculative <= flush ? next_committed : advance(speculative, spec_push, spec_pop, spec_addr);
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
