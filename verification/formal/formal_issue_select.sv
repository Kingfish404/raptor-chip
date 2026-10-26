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
  logic [Entries-1:0] candidates;
  logic preceded;
  always_comb begin
    claimed = '0;
    candidates = '0;
    preceded = 0;
    for (int p = 0; p < Ports; p++) begin
      for (int e = 0; e < Entries; e++)
      candidates[e] = valid[e] && !claimed[e] && (InOrder || (ready[e] && compatible[e][p]));
      selected[p] = '0;
      for (int e = 0; e < Entries; e++) begin
        preceded = 0;
        for (int o = 0; o < Entries; o++) preceded |= o != e && candidates[o] && older[o][e];
        selected[p][e] = enabled[p] && candidates[e] && !preceded && ready[e] && compatible[e][p];
      end
      claimed |= selected[p];
    end
  end
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
  always_comb begin
    legal = 1;
    for (int e = 0; e < Entries; e++)
    for (int o = e + 1; o < Entries; o++)
    legal &= !(valid[e] && valid[o]) || age_rank[e] != age_rank[o];
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
    if (Ports == 2 && !InOrder)
      for (int a = 0; a < Entries; a++)
      for (int b = 0; b < Entries; b++)
      if (a != b && valid[a] && ready[a] && compatible[a][0] && enabled[0]
              && valid[b] && ready[b] && compatible[b][1] && enabled[1])
        properties &= $countones(claimed) == 2;
    correct = !legal || properties;
  end
endmodule
