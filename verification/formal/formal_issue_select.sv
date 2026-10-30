module issue_select_reference #(
    parameter int Entries = 4,
    Ports = 2,
    parameter bit InOrder = 0
) (
    input logic [Entries-1:0] valid,
    ready,
    input logic [Entries-1:0] older[Entries],
    input logic [Ports-1:0] compatible[Entries],
    input logic [Ports-1:0] enabled,
    output logic [Entries-1:0] selected[Ports],
    output logic [Entries-1:0] claimed
);
  // Retain the port-first reference equations, but elaborate each comparison
  // structurally. One procedural Ports*Entries*Entries loop hits frontend
  // interpreter limits at production-sized geometries.
  for (genvar p = 0; p < Ports; p++) begin : g_port
    wire [Entries-1:0] used_before, used_after, candidates;
    if (p == 0) assign used_before = '0;
    else assign used_before = g_port[p-1].used_after;
    for (genvar e = 0; e < Entries; e++) begin : g_entry
      logic [Entries-1:0] predecessors;
      assign candidates[e] = valid[e] && !used_before[e]
          && (InOrder || (ready[e] && compatible[e][p]));
      // Keep this bounded loop local to one entry. Generating all
      // Ports*Entries*Entries comparisons exhausts the generate budget at
      // 128 entries and 8 ports; a single procedural loop stays small.
      always_comb begin
        for (int o = 0; o < Entries; o++) predecessors[o] = o != e && candidates[o] && older[o][e];
      end
      assign selected[p][e] = enabled[p] && candidates[e] && !(|predecessors)
          && ready[e] && compatible[e][p];
    end
    assign used_after = used_before | selected[p];
  end
  assign claimed = g_port[Ports-1].used_after;
endmodule

module formal_issue_select #(
    parameter int Entries = 4,
    Ports = 2,
    parameter bit InOrder = 0,
    parameter int RankBits = Entries > 1 ? $clog2(Entries) : 1
) (
    input logic [Entries-1:0] valid,
    ready,
    input logic [RankBits-1:0] age_rank[Entries],
    input logic [Ports-1:0] compatible[Entries],
    input logic [Ports-1:0] enabled,
    output logic correct
);
  logic [Entries-1:0] older[Entries];
  logic [Entries-1:0] selected[Ports], legacy[Ports], disabled[Ports];
  logic [Entries-1:0] claimed, baseline, reference_claimed, disabled_claimed, unused_base;
  for (genvar o = 0; o < Entries; o++)
  for (genvar e = 0; e < Entries; e++) assign older[o][e] = age_rank[o] < age_rank[e];
  rapt_issue_select #(
      .Entries(Entries),
      .Ports  (Ports),
      .InOrder(InOrder)
  ) dut (
      .*,
      .baseline_claimed(baseline)
  );
  rapt_issue_select #(
      .Entries(Entries),
      .Ports(Ports),
      .InOrder(InOrder),
      .Rebalance(0)
  ) off_dut (
      .*,
      .selected(disabled),
      .claimed(disabled_claimed),
      .baseline_claimed(unused_base)
  );
  issue_select_reference #(
      .Entries(Entries),
      .Ports  (Ports),
      .InOrder(InOrder)
  ) reference_dut (
      .*,
      .selected(legacy),
      .claimed (reference_claimed)
  );
  logic legal, properties;
  logic [Entries-1:0] union_selected;
  wire [Entries*Entries-1:0] legal_pairs;
  wire [Entries*Entries-1:0] cardinality_pairs;
  for (genvar e = 0; e < Entries; e++) begin : g_legal_entry
    for (genvar o = 0; o < Entries; o++) begin : g_pair
      assign legal_pairs[e*Entries+o] = o <= e || !(valid[e] && valid[o])
          || age_rank[e] != age_rank[o];
      if (Ports == 2 && !InOrder) begin : g_two_ports
        assign cardinality_pairs[e*Entries+o] = !(e != o && valid[e] && ready[e]
            && compatible[e][0] && enabled[0] && valid[o] && ready[o]
            && compatible[o][1] && enabled[1]) || $countones(
            claimed
        ) == 2;
      end else begin : g_other_ports
        assign cardinality_pairs[e*Entries+o] = 1'b1;
      end
    end
  end
  assign legal = &legal_pairs;
  always_comb begin
    properties = baseline == reference_claimed && disabled_claimed == reference_claimed
        && (baseline & ~claimed) == '0 && (claimed & ~(valid & ready)) == '0;
    union_selected = '0;
    for (int p = 0; p < Ports; p++) begin
      properties &= disabled[p] == legacy[p];
      if (InOrder) properties &= selected[p] == legacy[p];
      properties &= $countones(selected[p]) <= 1 && ((selected[p] & union_selected) == '0);
      union_selected |= selected[p];
      for (int e = 0; e < Entries; e++)
      properties &= !selected[p][e] || (enabled[p] && compatible[e][p]);
    end
    properties &= union_selected == claimed;
    // For two ports, every augmenting path needed after greedy is one hop.
    // Prove maximum instantaneous cardinality, not maximum program IPC.
    properties &= &cardinality_pairs;
    correct = !legal || properties;
  end
endmodule
