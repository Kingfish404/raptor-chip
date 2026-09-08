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
    parameter bit Rebalance = 1
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
  // Port-oriented view of the same wires, shared by every repair stage.
  logic [Entries-1:0] port_compatible[Ports];
  for (genvar p = 0; p < Ports; p++) begin : g_compatibility
    for (genvar e = 0; e < Entries; e++) begin : g_entry
      assign port_compatible[p][e] = compatible[e][p];
    end
  end
  for (genvar p = 0; p < Ports; p++) begin : g_greedy
    // Explicit stage-local wires preserve the forward-only dependency even
    // when a simulator schedules an unpacked array as a single object.
    logic [Entries-1:0] candidates, grant, used_before, used_after;
    if (p == 0) begin : g_first
      assign used_before = '0;
    end else begin : g_later
      assign used_before = g_greedy[p-1].used_after;
    end
    for (genvar e = 0; e < Entries; e++)
      assign candidates[e] = valid[e] && ready[e] && !used_before[e] && compatible[e][p];
    assign grant = !enabled[p] ? '0 : InOrder ? oldest(
        valid & ~used_before
    ) & candidates : oldest(
        candidates
    );
    assign used_after = used_before | grant;
    assign greedy[p] = grant;
  end
  assign baseline_claimed = g_greedy[Ports-1].used_after;
  if (Rebalance && !InOrder && Ports > 1) begin : g_rebalance
    for (genvar p = 0; p < Ports; p++) begin : g_idle_port
      // Keep stage signals in separate generate scopes: a single unpacked
      // stage array obscures the acyclic dependency for event simulators.
      logic [Entries-1:0] previous[Ports], next_selection[Ports];
      logic [Entries-1:0] previous_used, next_used;
      if (p == 0) begin
        assign previous = greedy;
        assign previous_used = g_greedy[Ports-1].used_after;
      end else begin
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
    for (genvar p = 0; p < Ports; p++) assign selected[p] = g_idle_port[Ports-1].next_selection[p];
    assign claimed = g_idle_port[Ports-1].next_used;
  end else begin : g_no_rebalance
    for (genvar p = 0; p < Ports; p++) assign selected[p] = greedy[p];
    assign claimed = g_greedy[Ports-1].used_after;
  end
  if (!(Entries > 0 && Ports > 0)) begin : g_invalid_config_0
    $error("Invalid rapt_issue_select configuration");
  end
endmodule
