// Select the first NumSelect available identities in ascending index order.
// Shared bounded-count up/down trees replace cascaded priority encoders. All
// ranks are computed independently of acceptance; the owner consumes a prefix.
module rapt_rank_select #(
    parameter int Entries   = 128,
    parameter int NumSelect = 4,
    parameter int IndexBits = Entries > 1 ? $clog2(Entries) : 1
) (
    input logic [Entries-1:0] available,
    output logic found[NumSelect],
    output logic [IndexBits-1:0] index[NumSelect]
);
  localparam int Leaves = 2 ** $clog2(Entries);
  localparam int CountBits = $clog2(NumSelect + 1);
  logic [CountBits-1:0] count[2*Leaves], before_count[2*Leaves];
  function automatic logic [CountBits-1:0] capped_add(input logic [CountBits-1:0] left, right);
    logic [CountBits:0] sum;
    sum = {1'b0, left} + {1'b0, right};
    return sum > (CountBits + 1)'(NumSelect) ? CountBits'(NumSelect) : CountBits'(sum);
  endfunction
  assign count[0] = '0;
  assign before_count[0] = '0;
  assign before_count[1] = '0;
  for (genvar e = 0; e < Leaves; e++) begin : g_leaf
    if (e < Entries) assign count[Leaves+e] = CountBits'(available[e]);
    else assign count[Leaves+e] = '0;
  end
  for (genvar n = 1; n < Leaves; n++) begin : g_tree
    assign count[n] = capped_add(count[2*n], count[2*n+1]);
    assign before_count[2*n] = before_count[n];
    assign before_count[2*n+1] = capped_add(before_count[n], count[2*n]);
  end
  for (genvar s = 0; s < NumSelect; s++) begin : g_rank
    assign found[s] = count[1] > CountBits'(s);
    always_comb begin
      index[s] = '0;
      for (int e = 0; e < Entries; e++)
      index[s] |= IndexBits'(e) & {IndexBits{available[e] && before_count[Leaves+e] == CountBits'(s)}};
    end
  end
  if (!(Entries > 0 && NumSelect > 0)) begin : g_invalid_config_0
    $error("Invalid rapt_rank_select configuration");
  end
  if (!(IndexBits >= (Entries > 1 ? $clog2(Entries) : 1))) begin : g_invalid_config_1
    $error("Invalid rapt_rank_select configuration");
  end
endmodule
