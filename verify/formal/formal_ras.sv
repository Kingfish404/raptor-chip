// Sequential equivalence against an independent top-at-zero shift stack.
// All actions and addresses are unrestricted, including commit+flush+spec action.
module formal_ras #(
    parameter int Depth = 3,
    parameter int Xlen = 8
) (
    input logic clock,
    reset,
    clear,
    flush,
    input logic spec_push,
    spec_pop,
    commit_push,
    commit_pop,
    input logic [Xlen-1:0] spec_addr,
    commit_addr,
    output logic correct
);
  logic top_valid;
  logic [Xlen-1:0] top_addr;
  rapt_ras #(
      .Depth(Depth),
      .Xlen(Xlen)
  ) dut (
      .*
  );
  typedef struct packed {
    logic [Depth-1:0][Xlen-1:0] data;
    logic [$clog2(Depth+1)-1:0] count;
  } model_t;
  model_t spec, commit, commit_next;
  function automatic model_t step(input model_t old, input logic push, pop,
                                  input logic [Xlen-1:0] addr);
    model_t next_state;
    next_state = old;
    if (pop && old.count != 0) begin
      for (int i = 0; i < Depth; i++) next_state.data[i] = i + 1 < Depth ? old.data[i+1] : '0;
      next_state.count--;
    end
    if (push) begin
      for (int i = Depth - 1; i > 0; i--) next_state.data[i] = next_state.data[i-1];
      next_state.data[0] = addr;
      if (next_state.count < Depth) next_state.count++;
    end
    return next_state;
  endfunction
  assign commit_next = step(commit, commit_push, commit_pop, commit_addr);
  always_ff @(posedge clock) begin
    if (reset || clear) begin
      spec <= '0;
      commit <= '0;
    end else begin
      commit <= commit_next;
      spec <= flush ? commit_next : step(spec, spec_push, spec_pop, spec_addr);
    end
  end
  // Strengthen the observable contract with the live-entry state relation.
  // Dead storage is intentionally unconstrained: popping need not erase bits.
  always_comb begin
    correct = top_valid == (spec.count != 0)
        && top_addr == (spec.count == 0 ? '0 : spec.data[0])
        && dut.speculative.count == spec.count && dut.committed.count == commit.count
        && spec.count <= Depth && commit.count <= Depth
        && dut.speculative.next_index < Depth && dut.committed.next_index < Depth;
    for (int i = 0; i < Depth; i++) begin
      automatic int si = int'(dut.speculative.next_index) - 1 - i;
      automatic int ci = int'(dut.committed.next_index) - 1 - i;
      if (si < 0) si += Depth;
      if (ci < 0) ci += Depth;
      if (i < spec.count) correct &= dut.speculative.data[si] == spec.data[i];
      if (i < commit.count) correct &= dut.committed.data[ci] == commit.data[i];
    end
  end
endmodule
