`include "rapt.svh"
`include "rapt_if.svh"

// Tool-facing wrapper for the current K-candidate/W-winner DPU boundary.
// It deliberately mirrors the product domain/token interface; no historical
// A/B issue-lane interfaces are instantiated here.
module rapt_dpu_syn_top #(
    parameter int unsigned NumCandidates = rapt_pkg::SteerScanEntries,
    parameter int unsigned NumSlots = rapt_pkg::DispatchWidth,
    parameter int unsigned NumDomains = rapt_pkg::ExecutionDomains,
    parameter int unsigned StimulusBits =
        NumCandidates * $bits(rapt_pkg::execution_domain_t) + NumCandidates
        + NumDomains * $bits(rapt_pkg::dispatch_capacity_t),
    parameter int unsigned ResponseBits = NumCandidates + NumSlots
        + NumSlots * rapt_pkg::index_bits(NumCandidates) + NumDomains * NumSlots
        + NumDomains * NumSlots * $bits(rapt_pkg::queue_index_t)
) (
    input  logic          clock,
    input  logic          reset,
    input  logic [StimulusBits-1:0] stimulus,
    output logic [ResponseBits-1:0] response
);
  localparam int unsigned DomainBits = $bits(rapt_pkg::execution_domain_t);
  localparam int unsigned CandidateBits = rapt_pkg::index_bits(NumCandidates);
  localparam int unsigned QueueBits = $bits(rapt_pkg::queue_index_t);
  localparam int unsigned CapacityBits = $bits(rapt_pkg::dispatch_capacity_t);
  localparam int unsigned ValidBase = NumCandidates * DomainBits;
  localparam int unsigned CapacityBase = ValidBase + NumCandidates;

  rapt_pkg::execution_domain_t candidate_domain[NumCandidates];
  logic candidate_valid[NumCandidates], candidate_ready[NumCandidates];
  logic selected_valid[NumSlots];
  logic [CandidateBits-1:0] selected_candidate[NumSlots];
  rapt_pkg::dispatch_capacity_t capacity[NumDomains];
  rapt_pkg::dispatch_grant_t grant[NumDomains];

  logic [NumCandidates-1:0] candidate_ready_packed;
  logic [NumSlots-1:0] selected_valid_packed;
  logic [NumSlots*CandidateBits-1:0] selected_candidate_packed;
  logic [NumDomains*NumSlots-1:0] grant_accept_packed;
  logic [NumDomains*NumSlots*QueueBits-1:0] grant_index_packed;

  for (genvar c = 0; c < NumCandidates; c++) begin : g_candidate
    assign candidate_domain[c] = rapt_pkg::execution_domain_t'(
        stimulus[c*DomainBits +: DomainBits]);
    assign candidate_valid[c] = stimulus[ValidBase+c];
    assign candidate_ready_packed[c] = candidate_ready[c];
  end
  for (genvar d = 0; d < NumDomains; d++) begin : g_capacity
    assign capacity[d] = rapt_pkg::dispatch_capacity_t'(
        stimulus[CapacityBase+d*CapacityBits +: CapacityBits]);
    for (genvar s = 0; s < NumSlots; s++) begin : g_grant
      assign grant_accept_packed[d*NumSlots+s] = grant[d].accept[s];
      assign grant_index_packed[(d*NumSlots+s)*QueueBits +: QueueBits] = grant[d].index[s];
    end
  end
  for (genvar s = 0; s < NumSlots; s++) begin : g_selected
    assign selected_valid_packed[s] = selected_valid[s];
    assign selected_candidate_packed[s*CandidateBits +: CandidateBits] = selected_candidate[s];
  end

  assign response = {
    grant_index_packed,
    grant_accept_packed,
    selected_candidate_packed,
    selected_valid_packed,
    candidate_ready_packed
  };

  rapt_dpu #(
      .NumDomains(NumDomains),
      .NumSlots(NumSlots),
      .NumCandidates(NumCandidates)
  ) dut (
      .*
  );
endmodule
