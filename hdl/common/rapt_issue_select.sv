// Payload-independent oldest-ready selection. older[i][j] means i precedes j.
// Rows involving invalid entries may be stale; only valid candidates matter.
// Port-first greedy selection is optionally followed by bounded one-hop
// augmentation: move an already selected uop to an idle compatible port and
// fill its old port with the oldest eligible unselected uop. Never evict a uop.
// This is not arbitrary-length maximum matching for three or more ports.
module rapt_issue_select #(
    parameter int Entries = 8,
    parameter int Ports = 2,
    parameter bit InOrder = 0,
    parameter bit Rebalance = 1,
    // Static arbitration order only; compatibility and physical port identity
    // are unchanged. Defer a higher-latency port when another can execute a uop.
    parameter int LastPort = Ports - 1,
    // All non-LastPort compatibility bits must agree for each valid entry.
    // Parallel age ranks then replace the serial per-port exclusion chain.
    // InOrder and Rebalance retain the general selector below.
    parameter bit UniformSimplePorts = 0
) (
    input logic [Entries-1:0] valid,
    input logic [Entries-1:0] ready,
    input logic [Entries-1:0] older[Entries],
    input logic [Ports-1:0] compatible[Entries],
    input logic [Ports-1:0] enabled,
    output logic [Entries-1:0] selected[Ports],
    output logic [Entries-1:0] claimed,
    output logic [Entries-1:0] baseline_claimed
);
  // Column e identifies entries older than e. Diagonal and invalid-entry
  // filtering are separate: self-age is ignored here, candidates gate validity.
  logic [Entries-1:0] older_mask[Entries];
  for (genvar e = 0; e < Entries; e++) begin : g_age_column
    for (genvar o = 0; o < Entries; o++) begin : g_predecessor
      assign older_mask[e][o] = o != e && older[o][e];
    end
  end
  function automatic logic [Entries-1:0] oldest(input logic [Entries-1:0] candidates);
    logic [Entries-1:0] result;
    for (int e = 0; e < Entries; e++) begin
      result[e] = candidates[e] && !(|(candidates & older_mask[e]));
    end
    return result;
  endfunction
  logic [Entries-1:0] greedy[Ports];
  logic [Entries-1:0] greedy_claimed;
  // Port-oriented view of the same wires, shared by every repair stage.
  logic [Entries-1:0] port_compatible[Ports];
  for (genvar p = 0; p < Ports; p++) begin : g_compatibility
    for (genvar e = 0; e < Entries; e++) begin : g_entry
      assign port_compatible[p][e] = compatible[e][p];
    end
  end
  if (UniformSimplePorts && Ports > 1 && !InOrder && !Rebalance) begin : g_uniform
    localparam int FirstSimplePort = LastPort == 0 ? 1 : 0;
    localparam int CountBits = $clog2((Entries > Ports ? Entries : Ports) + 1);
    localparam int CountLeaves = 1 << $clog2(Entries);
    localparam int PortCountBits = CountBits;
    logic [Entries-1:0] candidates, last_candidates, used;
    logic [CountBits-1:0] older_count[Entries];
    logic [PortCountBits-1:0] simple_capacity;
    assign simple_capacity = PortCountBits'($countones(enabled & ~(Ports'(1) << LastPort)));
    for (genvar e = 0; e < Entries; e++) begin : g_entry
      wire [CountBits-1:0] count_tree[2*CountLeaves];
      assign candidates[e] = valid[e] && ready[e] && compatible[e][FirstSimplePort];
      for (genvar o = 0; o < CountLeaves; o++) begin : g_leaf
        if (o < Entries)
          assign count_tree[CountLeaves+o] = CountBits'(candidates[o] && older_mask[e][o]);
        else assign count_tree[CountLeaves+o] = '0;
      end
      for (genvar node = 1; node < CountLeaves; node++) begin : g_count
        assign count_tree[node] = count_tree[2*node] + count_tree[2*node+1];
      end
      assign older_count[e] = count_tree[1];
      assign last_candidates[e] = valid[e] && ready[e] && compatible[e][LastPort]
          && (!candidates[e] || older_count[e] >= simple_capacity);
      assign used[e] = (candidates[e] && older_count[e] < simple_capacity)
          || greedy[LastPort][e];
    end
    for (genvar p = 0; p < Ports; p++) begin : g_port
      if (p == LastPort) assign greedy[p] = enabled[p] ? oldest(last_candidates) : '0;
      else begin : g_simple
        wire [PortCountBits-1:0] port_rank;
        assign port_rank = PortCountBits'($countones(
            enabled & ((Ports'(1) << p) - 1'b1) & ~(Ports'(1) << LastPort)
        ));
        for (genvar e = 0; e < Entries; e++) begin : g_entry
          assign greedy[p][e] = enabled[p] && candidates[e] && older_count[e] == port_rank;
        end
      end
    end
    assign greedy_claimed = used;
  end else begin : g_general
    for (genvar rank = 0; rank < Ports; rank++) begin : g_greedy
      localparam int p = rank == Ports - 1 ? LastPort : rank < LastPort ? rank : rank + 1;
      // Explicit stage-local wires preserve the forward-only dependency even
      // when a simulator schedules an unpacked array as a single object.
      logic [Entries-1:0] candidates, grant, used_before, used_after;
      if (rank == 0) begin : g_first
        assign used_before = '0;
      end else begin : g_later
        assign used_before = g_greedy[rank-1].used_after;
      end
      for (genvar e = 0; e < Entries; e++) begin : g_candidate
        assign candidates[e] = valid[e] && ready[e] && !used_before[e] && compatible[e][p];
      end
      assign grant = !enabled[p] ? '0 : InOrder ? oldest(
        valid & ~used_before
    ) & candidates : oldest(
        candidates
    );
      assign used_after = used_before | grant;
      assign greedy[p] = grant;
    end
    assign greedy_claimed = g_greedy[Ports-1].used_after;
  end
  assign baseline_claimed = greedy_claimed;
  if (Rebalance && !InOrder && Ports > 1) begin : g_rebalance
    for (genvar p = 0; p < Ports; p++) begin : g_idle_port
      // Keep stage signals in separate generate scopes: a single unpacked
      // stage array obscures the acyclic dependency for event simulators.
      logic [Entries-1:0] previous[Ports], next_selection[Ports];
      logic [Entries-1:0] previous_used, next_used;
      if (p == 0) begin : g_first
        assign previous = greedy;
        assign previous_used = greedy_claimed;
      end else begin : g_chain
        assign previous = g_idle_port[p-1].next_selection;
        assign previous_used = g_idle_port[p-1].next_used;
      end
      logic [Ports-1:0] can_move;
      logic [Entries-1:0] alternatives, extra;
      logic [Ports-1:0] donor_eligible, donor_selected;
      for (genvar d = 0; d < Ports; d++) begin : g_donor
        assign can_move[d] = d != p && (|(previous[d] & port_compatible[p]));
        assign donor_eligible[d] = can_move[d] && (|(extra & port_compatible[d]));
        if (d == 0) begin : g_first
          assign donor_selected[d] = donor_eligible[d];
        end else begin : g_later
          assign donor_selected[d] = donor_eligible[d] && !(|donor_eligible[d-1:0]);
        end
      end
      // Qualify the replacement before donor selection; do not co-schedule
      // its producer with the result block that consumes donor_selected.
      for (genvar e = 0; e < Entries; e++) begin : g_alternative
        assign alternatives[e] = valid[e] && ready[e] && !previous_used[e]
            && (|(compatible[e] & can_move));
      end
      assign extra = oldest(alternatives);
      always_comb begin
        next_used = previous_used;
        for (int d = 0; d < Ports; d++) next_selection[d] = previous[d];
        if (enabled[p] && previous[p] == '0 && extra != '0) begin
          // Eligibility is reduced in parallel over entries. Only the donor
          // priority remains; do not build a Ports*Entries "moved" chain.
          for (int d = 0; d < Ports; d++)
          if (donor_selected[d]) begin
            next_selection[p] = previous[d];
            next_selection[d] = extra;
            next_used = previous_used | extra;
          end
        end
      end
    end
    for (genvar p = 0; p < Ports; p++) begin : g_select
      assign selected[p] = g_idle_port[Ports-1].next_selection[p];
    end
    assign claimed = g_idle_port[Ports-1].next_used;
  end else begin : g_no_rebalance
    for (genvar p = 0; p < Ports; p++) begin : g_select
      assign selected[p] = greedy[p];
    end
    assign claimed = greedy_claimed;
  end
  if (!(Entries > 0 && Ports > 0 && LastPort >= 0 && LastPort < Ports)) begin : g_invalid_config_0
    $error("Invalid rapt_issue_select configuration");
  end
endmodule
