// One oldest outstanding recovery transaction. New older requests supersede
// younger ones; ties keep the existing owner, then the lowest candidate port.
// Ages are ROB-ring distances from the CURRENT head, never raw index order.
// The transaction holds slot + generation atomically. A revoked/reused slot
// cannot keep an old request alive. Cancellation acknowledgements and generation
// wrap protection remain integration responsibilities; full flush ends lifetime.
module rapt_recovery_pending #(
    parameter int Entries = 128,
    parameter int Ports = 5,
    parameter int Xlen = 32,
    parameter int GenerationBits = 4,
    parameter int IndexBits = Entries > 1 ? $clog2(Entries) : 1
) (
    input logic clock,
    reset,
    flush,
    input logic [Entries-1:0] live,
    input logic [GenerationBits-1:0] owner_generation[Entries],
    input logic [IndexBits-1:0] head,
    input logic candidate_valid[Ports],
    input logic [IndexBits-1:0] candidate_index[Ports],
    input logic [Xlen-1:0] candidate_target[Ports],
    input logic [GenerationBits-1:0] candidate_generation[Ports],
    output logic pending,
    output logic [IndexBits-1:0] owner,
    output logic [Xlen-1:0] target,
    output logic [GenerationBits-1:0] generation
);
  localparam int Sources = Ports + 1;
  localparam int TreeLeaves = 1 << $clog2(Sources);
  localparam int TreeNodes = 2 * TreeLeaves;
  wire tree_valid[TreeNodes];
  wire [IndexBits-1:0] tree_owner[TreeNodes], tree_age[TreeNodes];
  wire [Xlen-1:0] tree_target[TreeNodes];
  wire [GenerationBits-1:0] tree_generation[TreeNodes];

  function automatic logic [IndexBits-1:0] age(input logic [IndexBits-1:0] index);
    return IndexBits'(index >= head ? int'(index) - int'(head)
        : Entries + int'(index) - int'(head));
  endfunction

  // Leaf zero is the held request. It therefore wins every equal-age tie.
  // Candidate leaves follow in port order, so lower port numbers win their
  // ties as each balanced node selects its left input on equality.
  for (genvar leaf = 0; leaf < TreeLeaves; leaf++) begin : g_leaf
    if (leaf == 0) begin : g_held
      assign tree_valid[TreeLeaves + leaf] = pending && int'(owner) < Entries && live[owner]
          && owner_generation[owner] == generation;
      assign tree_generation[TreeLeaves + leaf] = generation;
      assign tree_owner[TreeLeaves + leaf] = owner;
      assign tree_target[TreeLeaves + leaf] = target;
      assign tree_age[TreeLeaves + leaf] = age(owner);
    end else if (leaf < Sources) begin : g_candidate
      localparam int Port = leaf - 1;
      assign tree_valid[TreeLeaves + leaf] = candidate_valid[Port]
          && int'(candidate_index[Port]) < Entries && live[candidate_index[Port]]
          && owner_generation[candidate_index[Port]] == candidate_generation[Port];
      assign tree_generation[TreeLeaves + leaf] = candidate_generation[Port];
      assign tree_owner[TreeLeaves + leaf] = candidate_index[Port];
      assign tree_target[TreeLeaves + leaf] = candidate_target[Port];
      assign tree_age[TreeLeaves + leaf] = age(candidate_index[Port]);
    end else begin : g_padding
      assign tree_valid[TreeLeaves + leaf] = 1'b0;
      assign tree_generation[TreeLeaves + leaf] = '0;
      assign tree_owner[TreeLeaves + leaf] = '0;
      assign tree_target[TreeLeaves + leaf] = '0;
      assign tree_age[TreeLeaves + leaf] = '0;
    end
  end

  // Parallel leaf ages feed a balanced oldest-wins reduction. This keeps the
  // completion-port scaling logarithmic instead of creating a priority chain.
  for (genvar node = 1; node < TreeLeaves; node++) begin : g_reduce
    wire choose_left = tree_valid[2*node]
        && (!tree_valid[2*node+1] || tree_age[2*node] <= tree_age[2*node+1]);
    assign tree_valid[node] = tree_valid[2*node] || tree_valid[2*node+1];
    assign tree_owner[node] = choose_left ? tree_owner[2*node] : tree_owner[2*node+1];
    assign tree_target[node] = choose_left ? tree_target[2*node] : tree_target[2*node+1];
    assign tree_generation[node] = choose_left ? tree_generation[2*node] : tree_generation[2*node+1];
    assign tree_age[node] = choose_left ? tree_age[2*node] : tree_age[2*node+1];
  end

  always_ff @(posedge clock) begin
    if (reset || flush) begin
      pending <= 1'b0;
      owner <= '0;
      target <= '0;
      generation <= '0;
    end else begin
      pending <= tree_valid[1];
      owner <= tree_valid[1] ? tree_owner[1] : '0;
      target <= tree_valid[1] ? tree_target[1] : '0;
      generation <= tree_valid[1] ? tree_generation[1] : '0;
    end
  end
  if (!(Entries > 0 && Ports > 0 && Xlen > 0 && GenerationBits > 0)) begin : g_invalid_config_0
    $error("Invalid rapt_recovery_pending configuration");
  end
  if (IndexBits < (Entries > 1 ? $clog2(Entries) : 1)) begin : g_invalid_index_width
    $error("Invalid rapt_recovery_pending configuration: insufficient index width");
  end
`ifdef RAPT_ASSERT_EN
`ifndef SYNTHESIS
  always_ff @(posedge clock) if (!reset) assert (int'(head) < Entries);
`endif
`endif
endmodule
