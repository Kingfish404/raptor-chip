// Pure combinational equivalence against the original cascaded allocator.
// No assumptions: every availability bitmap is legal, including empty/full.
module formal_rank_select #(
    parameter int Entries = 13,
    NumSelect = 4,
    parameter int IndexBits = Entries > 1 ? $clog2(Entries) : 1
) (
    input logic [Entries-1:0] available,
    output logic equivalent
);
  logic found[NumSelect], reference_found[NumSelect];
  logic [IndexBits-1:0] index[NumSelect], reference_index[NumSelect];
  rapt_rank_select #(
      .Entries  (Entries),
      .NumSelect(NumSelect),
      .IndexBits(IndexBits)
  ) dut (
      .*
  );
  rank_select_reference #(
      .Entries  (Entries),
      .NumSelect(NumSelect),
      .IndexBits(IndexBits)
  ) reference_dut (
      .available,
      .found(reference_found),
      .index(reference_index)
  );
  always_comb begin
    equivalent = 1'b1;
    for (int s = 0; s < NumSelect; s++) begin
      equivalent &= found[s] == reference_found[s] && index[s] == reference_index[s];
    end
  end
endmodule

// Retained only as an independent verification / synthesis-comparison model.
module rank_select_reference #(
    parameter int Entries = 128,
    NumSelect = 4,
    parameter int IndexBits = Entries > 1 ? $clog2(Entries) : 1
) (
    input logic [Entries-1:0] available,
    output logic found[NumSelect],
    output logic [IndexBits-1:0] index[NumSelect]
);
  logic [Entries-1:0] remaining;
  always_comb begin
    remaining = available;
    for (int s = 0; s < NumSelect; s++) begin
      found[s] = 0;
      index[s] = 0;
      for (int e = Entries - 1; e >= 0; e--)
      if (remaining[e]) begin
        found[s] = 1;
        index[s] = IndexBits'(e);
      end
      if (found[s]) remaining[index[s]] = 0;
    end
  end
endmodule
