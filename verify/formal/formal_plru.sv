// Prove the live cache PLRU against a sequential tree-walk reference model.
module formal_plru #(
    parameter int Ways = 4,
    parameter int SetBits = 2,
    parameter int WayBits = $clog2(Ways)
) (
    input logic clock,
    input logic reset,
    input logic invalidate,
    input logic [SetBits-1:0] read_set[2],
    input logic [1:0] update_valid,
    input logic [SetBits-1:0] update_set[2],
    input logic [WayBits-1:0] update_way[2]
);
  localparam int Sets  = 2 ** SetBits;
  localparam int Nodes = Ways - 1;
  wire [WayBits-1:0] victim[2];
  wire [Nodes-1:0] dut_recent[Sets];
  rapt_cache_plru #(
      .Ways(Ways),
      .SetBits(SetBits),
      .ReadPorts(2),
      .UpdatePorts(2)
  ) dut (
      .clock,
      .reset,
      .invalidate,
      .read_set,
      .victim,
      .update_valid,
      .update_set,
      .update_way,
      .formal_recent(dut_recent)
  );

  // Walk from the root to the accessed leaf; each node records the taken child.
  // This differs from the DUT's per-node matching of all update ports.
  function automatic logic [Nodes-1:0] touch(input logic [Nodes-1:0] tree,
                                             input logic [WayBits-1:0] way);
    logic [Nodes-1:0] result;
    int node;
    result = tree;
    node = 0;
    for (int bit_idx = WayBits - 1; bit_idx >= 0; bit_idx--) begin
      result[node] = way[bit_idx];
      node = 2 * node + 1 + int'(way[bit_idx]);
    end
    return result;
  endfunction

  // Follow the least recently used child down the binary heap.
  function automatic logic [WayBits-1:0] select_victim(input logic [Nodes-1:0] tree);
    int node;
    node = 0;
    for (int level = 0; level < WayBits; level++) begin
      node = 2 * node + (tree[node] ? 1 : 2);
    end
    return WayBits'(node - Nodes);
  endfunction

  logic [Nodes-1:0] model[Sets], next_model[Sets];
  logic f_past_valid = 1'b0;
  always_comb begin
    for (int s = 0; s < Sets; s++) next_model[s] = model[s];
    // Blocking assignments explicitly apply port 0, then port 1, including
    // different paths in the same set. Unshared nodes retain the earlier write.
    for (int p = 0; p < 2; p++) begin
      if (update_valid[p])
        next_model[update_set[p]] = touch(next_model[update_set[p]], update_way[p]);
    end
  end
  always_ff @(posedge clock) begin
    f_past_valid <= 1'b1;
    for (int s = 0; s < Sets; s++) begin
      if (reset || invalidate) model[s] <= '0;
      else model[s] <= next_model[s];
    end
  end

  always_comb assume (f_past_valid || reset);

  // Explicit history registers also work with frontends lacking $past support.
  logic previous_clear;
  logic [1:0] previous_valid;
  logic [SetBits-1:0] previous_set[2];
  logic [WayBits-1:0] previous_way[2];
  always_ff @(posedge clock) begin
    previous_clear <= reset || invalidate;
    previous_valid <= update_valid;
    for (int p = 0; p < 2; p++) begin
      previous_set[p] <= update_set[p];
      previous_way[p] <= update_way[p];
    end
  end

  for (genvar s = 0; s < Sets; s++) begin : g_set
    wire [Nodes-1:0] state_bits = dut_recent[s];
    wire [WayBits-1:0] set_victim = select_victim(state_bits);
    logic [Nodes-1:0] previous_state, previous_model;
    logic [WayBits-1:0] previous_victim;
    always_ff @(posedge clock) begin
      previous_state <= state_bits;
      previous_model <= model[s];
      previous_victim <= set_victim;
    end
    always_comb begin
      if (f_past_valid) begin
        assert (state_bits == model[s]);
        if (previous_clear) begin
          assert (state_bits == '0);
        end else begin
          // Check the complete node vector for ordered same-set collisions.
          if (&previous_valid && previous_set[0] == SetBits'(s) && previous_set[1] == SetBits'(s))
            assert (state_bits == touch(touch(previous_model, previous_way[0]), previous_way[1]));
          // Updates to other sets must preserve both state and victim.
          if ((!previous_valid[0] || previous_set[0] != SetBits'(s))
              && (!previous_valid[1] || previous_set[1] != SetBits'(s))) begin
            assert (state_bits == previous_state);
            assert (set_victim == previous_victim);
          end
          for (int p = 0; p < 2; p++) begin
            if (previous_valid[p] && previous_set[p] == SetBits'(s)
                && (!previous_valid[1-p] || previous_set[1-p] != SetBits'(s)))
              assert (set_victim != previous_way[p]);
          end
        end
      end
    end
  end

  for (genvar p = 0; p < 2; p++) begin : g_read
    always_comb begin
      if (f_past_valid) begin
        assert (int'(victim[p]) < Ways);
        assert (victim[p] == select_victim(model[read_set[p]]));
      end
    end
    for (genvar w = 0; w < Ways; w++) begin : g_way
      always_ff @(posedge clock) begin
        cover (f_past_valid && !reset && !invalidate && victim[p] == WayBits'(w));
      end
    end
  end
  always_ff @(posedge clock) begin
    cover (f_past_valid && !reset && !invalidate && &update_valid
           && update_set[0] == update_set[1] && update_way[0] != update_way[1]);
    cover (f_past_valid && !reset && !invalidate && read_set[0] != read_set[1]
           && victim[0] != victim[1]);
    cover (f_past_valid && !reset && invalidate);
  end
endmodule
