`include "rapt.svh"
`include "rapt_if.svh"

// Pre-layout timing proxy for the product steering cone:
// pending rotation/rank -> K candidate identities -> ROB-domain lookup ->
// capacity-aware DPU compaction -> W selected physical identities.
// Operand payload read/forwarding and endpoint adapters are intentionally not
// modeled; report those separately as part of ROU/core STA.
module rapt_dispatch_steer_syn_top #(
    parameter int unsigned Entries = rapt_pkg::ROBEntries,
    parameter int unsigned Width = rapt_pkg::DispatchWidth,
    parameter int unsigned ScanEntries = rapt_pkg::SteerScanEntries,
    parameter int unsigned NumDomains = rapt_pkg::ExecutionDomains,
    parameter int unsigned IndexBits = rapt_pkg::index_bits(Entries),
    parameter int unsigned StimulusBits = Entries + IndexBits + Width
        + Width * IndexBits + Entries * $bits(rapt_pkg::execution_domain_t)
        + NumDomains * $bits(rapt_pkg::dispatch_capacity_t),
    parameter int unsigned ResponseBits = 2 * ScanEntries + ScanEntries * IndexBits
        + Width + Width * IndexBits + 3 * 32 + 1
) (
    input  logic          clock,
    input  logic          reset,
    input  logic [StimulusBits-1:0] stimulus,
    output logic [ResponseBits-1:0] response
);
  localparam int unsigned DomainBits = $bits(rapt_pkg::execution_domain_t);
  localparam int unsigned CandidateBits = rapt_pkg::index_bits(ScanEntries);
  localparam int unsigned CapacityBits = $bits(rapt_pkg::dispatch_capacity_t);
  localparam int unsigned HeadBase = Entries;
  localparam int unsigned IncomingValidBase = HeadBase + IndexBits;
  localparam int unsigned IncomingIndexBase = IncomingValidBase + Width;
  localparam int unsigned DomainTableBase = IncomingIndexBase + Width * IndexBits;
  localparam int unsigned CapacityBase = DomainTableBase + Entries * DomainBits;

  logic [Entries-1:0] pending;
  logic [IndexBits-1:0] head;
  logic incoming_valid[Width];
  logic [IndexBits-1:0] incoming_index[Width];
  rapt_pkg::execution_domain_t domain_table[Entries];
  rapt_pkg::dispatch_capacity_t capacity[NumDomains];
  rapt_pkg::dispatch_grant_t grant[NumDomains];

  logic candidate_valid[ScanEntries], candidate_ready[ScanEntries];
  logic [IndexBits-1:0] candidate_index[ScanEntries];
  logic candidate_incoming[ScanEntries];
  logic [rapt_pkg::index_bits(Width)-1:0] candidate_source_slot[ScanEntries];
  logic accepted[ScanEntries];
  rapt_pkg::execution_domain_t candidate_domain[ScanEntries];
  logic selected_valid[Width];
  logic [CandidateBits-1:0] selected_candidate[Width];
  logic [IndexBits-1:0] selected_index[Width];
  int unsigned candidate_count, accepted_count, bypass_count;
  logic oldest_blocked;

  logic [ScanEntries-1:0] candidate_valid_packed, candidate_ready_packed;
  logic [ScanEntries*IndexBits-1:0] candidate_index_packed;
  logic [Width-1:0] selected_valid_packed;
  logic [Width*IndexBits-1:0] selected_index_packed;

  assign pending = stimulus[Entries-1:0];
  assign head = stimulus[HeadBase +: IndexBits];
  for (genvar w = 0; w < Width; w++) begin : g_incoming
    assign incoming_valid[w] = stimulus[IncomingValidBase+w];
    assign incoming_index[w] = stimulus[IncomingIndexBase+w*IndexBits +: IndexBits];
    assign selected_valid_packed[w] = selected_valid[w];
    assign selected_index[w] = selected_valid[w]
        ? candidate_index[selected_candidate[w]] : '0;
    assign selected_index_packed[w*IndexBits +: IndexBits] = selected_index[w];
  end
  for (genvar e = 0; e < Entries; e++) begin : g_domain_table
    assign domain_table[e] = rapt_pkg::execution_domain_t'(
        stimulus[DomainTableBase+e*DomainBits +: DomainBits]);
  end
  for (genvar c = 0; c < ScanEntries; c++) begin : g_candidate
    assign candidate_domain[c] = candidate_valid[c] ? domain_table[candidate_index[c]]
        : rapt_pkg::execution_domain_t'('0);
    assign candidate_valid_packed[c] = candidate_valid[c];
    assign candidate_ready_packed[c] = candidate_ready[c];
    assign candidate_index_packed[c*IndexBits +: IndexBits] = candidate_index[c];
  end
  for (genvar d = 0; d < NumDomains; d++) begin : g_capacity
    assign capacity[d] = rapt_pkg::dispatch_capacity_t'(
        stimulus[CapacityBase+d*CapacityBits +: CapacityBits]);
  end

  assign response = {
    oldest_blocked,
    bypass_count,
    accepted_count,
    candidate_count,
    selected_index_packed,
    selected_valid_packed,
    candidate_index_packed,
    candidate_ready_packed,
    candidate_valid_packed
  };

  rapt_rob_dispatch_select #(
      .Entries(Entries),
      .Width(Width),
      .ScanEntries(ScanEntries),
      .IndexBits(IndexBits)
  ) selector (
      .pending,
      .head,
      .incoming_valid,
      .incoming_index,
      .endpoint_ready(candidate_ready),
      .candidate_valid,
      .candidate_index,
      .candidate_incoming,
      .candidate_source_slot,
      .accepted,
      .candidate_count,
      .accepted_count,
      .bypass_count,
      .oldest_blocked
  );

  rapt_dpu #(
      .NumDomains(NumDomains),
      .NumSlots(Width),
      .NumCandidates(ScanEntries)
  ) dpu (
      .clock,
      .reset,
      .candidate_domain,
      .candidate_valid,
      .candidate_ready,
      .selected_valid,
      .selected_candidate,
      .capacity,
      .grant
  );
endmodule
