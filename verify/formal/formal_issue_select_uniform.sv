// Compare parallel age ranking with the independent port-first reference.
// Non-last ports share a capability; the last port has its own capability.
module formal_issue_select_uniform #(
    parameter int Entries = 8,
    parameter int Ports = 4,
    parameter int LastPort = 0,
    parameter int RankBits = Entries > 1 ? $clog2(Entries) : 1
) (
    input logic [Entries-1:0] valid,
    input logic [Entries-1:0] ready,
    input logic [RankBits-1:0] age_rank[Entries],
    input logic [Entries-1:0] simple_capable,
    input logic [Entries-1:0] last_capable,
    input logic [Ports-1:0] enabled,
    output logic correct
);
  logic [Entries-1:0] older[Entries], selected[Ports], reference_selected[Ports];
  logic [Entries-1:0] claimed, baseline, reference_claimed;
  logic [Ports-1:0] compatible[Entries], reference_compatible[Entries], reference_enabled;
  for (genvar e = 0; e < Entries; e++) begin : g_entry
    for (genvar o = 0; o < Entries; o++) assign older[o][e] = age_rank[o] < age_rank[e];
    for (genvar p = 0; p < Ports; p++)
      assign compatible[e][p] = p == LastPort ? last_capable[e] : simple_capable[e];
  end
  // The reference visits physical ports in increasing order. Reorder only
  // its port views to put LastPort at the end of that unchanged algorithm.
  for (genvar rank = 0; rank < Ports; rank++) begin : g_port
    localparam int p = rank == Ports - 1 ? LastPort : rank < LastPort ? rank : rank + 1;
    assign reference_enabled[rank] = enabled[p];
    for (genvar e = 0; e < Entries; e++) assign reference_compatible[e][rank] = compatible[e][p];
  end
  rapt_issue_select #(
      .Entries(Entries),
      .Ports(Ports),
      .LastPort(LastPort),
      .Rebalance(0),
      .UniformSimplePorts(1)
  ) dut (
      .valid,
      .ready,
      .older,
      .compatible,
      .enabled,
      .selected,
      .claimed,
      .baseline_claimed(baseline)
  );
  issue_select_reference #(
      .Entries(Entries),
      .Ports(Ports),
      .InOrder(0)
  ) reference_dut (
      .valid,
      .ready,
      .older,
      .compatible(reference_compatible),
      .enabled(reference_enabled),
      .selected(reference_selected),
      .claimed(reference_claimed)
  );
  logic legal, equal_results;
  always_comb begin
    legal = 1'b1;
    for (int e = 0; e < Entries; e++)
    for (int o = e + 1; o < Entries; o++)
    legal &= !(valid[e] && valid[o]) || age_rank[e] != age_rank[o];
    equal_results = claimed == reference_claimed && baseline == reference_claimed;
    for (int rank = 0; rank < Ports; rank++) begin
      automatic int p = rank == Ports - 1 ? LastPort : rank < LastPort ? rank : rank + 1;
      equal_results &= selected[p] == reference_selected[rank];
    end
    correct = !legal || equal_results;
  end
endmodule
