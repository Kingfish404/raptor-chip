module formal_completion_guard #(
    parameter int Entries = 7,
    parameter int IndexBits = Entries > 1 ? $clog2(Entries) : 1,
    parameter int GenerationBits = 3,
    parameter int PhysBits = 6,
    parameter int ArchBits = 5,
    parameter bit EnforcePayload = 1'b1
) (
    input logic candidate_valid,
    input logic [IndexBits-1:0] candidate_index,
    input logic [GenerationBits-1:0] candidate_generation,
    input logic [PhysBits-1:0] candidate_prd,
    input logic [ArchBits-1:0] candidate_rd,
    input logic [Entries-1:0] live,
    input logic [Entries-1:0] executing,
    input logic [GenerationBits-1:0] owner_generation[Entries],
    input logic [PhysBits-1:0] owner_prd[Entries],
    input logic [ArchBits-1:0] owner_rd[Entries],
    output logic correct
);
  logic accept, identity_match, payload_match;
  logic ref_accept, ref_identity, ref_payload;
  rapt_completion_guard #(
      .Entries(Entries),
      .IndexBits(IndexBits),
      .GenerationBits(GenerationBits),
      .PhysBits(PhysBits),
      .ArchBits(ArchBits),
      .EnforcePayload(EnforcePayload)
  ) dut (
      .*
  );

  always_comb begin
    ref_identity = 1'b0;
    ref_payload = 1'b0;
    ref_accept = 1'b0;
    // Independent one-hot walk: do not reuse the DUT's variable-index lookup.
    for (int e = 0; e < Entries; e++) begin
      if (candidate_valid && candidate_index == IndexBits'(e)) begin
        ref_identity = live[e] && owner_generation[e] == candidate_generation;
        ref_payload = owner_prd[e] == candidate_prd && owner_rd[e] == candidate_rd;
        ref_accept = ref_identity && executing[e] && (!EnforcePayload || ref_payload);
      end
    end
    correct = accept == ref_accept && identity_match == ref_identity
        && payload_match == ref_payload;
  end
endmodule

// Production synthesis proxy. Diagnostic payload comparisons are deliberately
// not observable here, matching a SYNTHESIS core where their SVA consumer is
// absent and allowing the implementation to prune those wide table reads.
module completion_identity_guard_bank #(
    parameter int Entries = 64,
    parameter int Ports = 7,
    parameter int IndexBits = Entries > 1 ? $clog2(Entries) : 1,
    parameter int GenerationBits = 4,
    parameter int PhysBits = 7,
    parameter int ArchBits = 5
) (
    input logic candidate_valid[Ports],
    input logic [IndexBits-1:0] candidate_index[Ports],
    input logic [GenerationBits-1:0] candidate_generation[Ports],
    input logic [PhysBits-1:0] candidate_prd[Ports],
    input logic [ArchBits-1:0] candidate_rd[Ports],
    input logic [Entries-1:0] live,
    input logic [Entries-1:0] executing,
    input logic [GenerationBits-1:0] owner_generation[Entries],
    input logic [PhysBits-1:0] owner_prd[Entries],
    input logic [ArchBits-1:0] owner_rd[Entries],
    output logic accept[Ports]
);
  for (genvar p = 0; p < Ports; p++) begin : g_guard
    rapt_completion_guard #(
        .Entries(Entries),
        .IndexBits(IndexBits),
        .GenerationBits(GenerationBits),
        .PhysBits(PhysBits),
        .ArchBits(ArchBits),
        .EnforcePayload(1'b0)
    ) guard (
        .candidate_valid(candidate_valid[p]),
        .candidate_index(candidate_index[p]),
        .candidate_generation(candidate_generation[p]),
        .candidate_prd(candidate_prd[p]),
        .candidate_rd(candidate_rd[p]),
        .live(live),
        .executing(executing),
        .owner_generation(owner_generation),
        .owner_prd(owner_prd),
        .owner_rd(owner_rd),
        .accept(accept[p]),
        .identity_match(),
        .payload_match()
    );
  end
endmodule

// Synthesis-only integration proxy: all completion endpoints share the same
// authoritative owner directory but retain independent candidate/accept paths.
// Keeping this separate from the proof harness makes the cost of the actual
// seven-producer composition visible instead of multiplying a single-port
// estimate by hand.
module completion_guard_bank #(
    parameter int Entries = 64,
    parameter int Ports = 7,
    parameter int IndexBits = Entries > 1 ? $clog2(Entries) : 1,
    parameter int GenerationBits = 4,
    parameter int PhysBits = 7,
    parameter int ArchBits = 5,
    parameter bit EnforcePayload = 1'b1
) (
    input logic candidate_valid[Ports],
    input logic [IndexBits-1:0] candidate_index[Ports],
    input logic [GenerationBits-1:0] candidate_generation[Ports],
    input logic [PhysBits-1:0] candidate_prd[Ports],
    input logic [ArchBits-1:0] candidate_rd[Ports],
    input logic [Entries-1:0] live,
    input logic [Entries-1:0] executing,
    input logic [GenerationBits-1:0] owner_generation[Entries],
    input logic [PhysBits-1:0] owner_prd[Entries],
    input logic [ArchBits-1:0] owner_rd[Entries],
    output logic accept[Ports],
    output logic identity_match[Ports],
    output logic payload_match[Ports]
);
  for (genvar p = 0; p < Ports; p++) begin : g_guard
    rapt_completion_guard #(
        .Entries(Entries),
        .IndexBits(IndexBits),
        .GenerationBits(GenerationBits),
        .PhysBits(PhysBits),
        .ArchBits(ArchBits),
        .EnforcePayload(EnforcePayload)
    ) guard (
        .candidate_valid(candidate_valid[p]),
        .candidate_index(candidate_index[p]),
        .candidate_generation(candidate_generation[p]),
        .candidate_prd(candidate_prd[p]),
        .candidate_rd(candidate_rd[p]),
        .live(live),
        .executing(executing),
        .owner_generation(owner_generation),
        .owner_prd(owner_prd),
        .owner_rd(owner_rd),
        .accept(accept[p]),
        .identity_match(identity_match[p]),
        .payload_match(payload_match[p])
    );
  end
endmodule
