// Verification-only sequential reference for the capacity-aware compactor.
// Production RTL uses parallel domain ranks plus a tree rank selector.
module dispatch_compact_reference #(
    parameter int unsigned NumDomains = rapt_pkg::ExecutionDomains,
    parameter int unsigned NumSlots = rapt_pkg::DispatchWidth,
    parameter int unsigned NumCandidates = NumSlots,
    parameter type CapacityT = rapt_pkg::dispatch_capacity_t,
    parameter type GrantT = rapt_pkg::dispatch_grant_t
) (
    input rapt_pkg::execution_domain_t candidate_domain[NumCandidates],
    input logic candidate_valid[NumCandidates],
    output logic candidate_ready[NumCandidates],
    output logic selected_valid[NumSlots],
    output logic [rapt_pkg::index_bits(NumCandidates)-1:0] selected_candidate[NumSlots],
    input CapacityT capacity[NumDomains],
    output GrantT grant[NumDomains]
);
  localparam int CandidateBits = rapt_pkg::index_bits(NumCandidates);

  always_comb begin
    automatic int unsigned selected;
    automatic int unsigned used[NumDomains];
    selected = 0;
    for (int d = 0; d < NumDomains; d++) begin
      used[d] = 0;
      grant[d] = '0;
    end
    for (int s = 0; s < NumSlots; s++) begin
      selected_valid[s] = 1'b0;
      selected_candidate[s] = '0;
    end
    for (int c = 0; c < NumCandidates; c++) begin
      automatic int unsigned domain;
      automatic int unsigned rank;
      candidate_ready[c] = 1'b0;
      domain = int'(candidate_domain[c]);
      rank = domain < NumDomains ? used[domain] : 0;
      if (candidate_valid[c] && domain < NumDomains && selected < NumSlots
          && rank < NumSlots && capacity[domain].ready[rank]) begin
        candidate_ready[c] = 1'b1;
        selected_valid[selected] = 1'b1;
        selected_candidate[selected] = CandidateBits'(c);
        grant[domain].accept[selected] = 1'b1;
        grant[domain].index[selected] = capacity[domain].free_index[rank];
        for (int d = 0; d < NumDomains; d++) if (domain == d) used[d]++;
        selected++;
      end
    end
  end
endmodule

module formal_dispatch_compact #(
    parameter int unsigned NumDomains = rapt_pkg::ExecutionDomains,
    parameter int unsigned NumSlots = rapt_pkg::DispatchWidth,
    parameter int unsigned NumCandidates = NumSlots,
    parameter type CapacityT = rapt_pkg::dispatch_capacity_t,
    parameter type GrantT = rapt_pkg::dispatch_grant_t
) (
    input rapt_pkg::execution_domain_t candidate_domain[NumCandidates],
    input logic candidate_valid[NumCandidates],
    input CapacityT capacity[NumDomains],
    output logic correct
);
  logic dut_ready[NumCandidates], ref_ready[NumCandidates];
  logic dut_valid[NumSlots], ref_valid[NumSlots];
  logic [rapt_pkg::index_bits(NumCandidates)-1:0] dut_selected[NumSlots], ref_selected[NumSlots];
  GrantT dut_grant[NumDomains], ref_grant[NumDomains];

  rapt_dpu #(
      .NumDomains(NumDomains),
      .NumSlots(NumSlots),
      .NumCandidates(NumCandidates),
      .CapacityT(CapacityT),
      .GrantT(GrantT)
  ) dut (
      .clock(1'b0),
      .reset(1'b0),
      .candidate_ready(dut_ready),
      .selected_valid(dut_valid),
      .selected_candidate(dut_selected),
      .grant(dut_grant),
      .*
  );
  dispatch_compact_reference #(
      .NumDomains(NumDomains),
      .NumSlots(NumSlots),
      .NumCandidates(NumCandidates),
      .CapacityT(CapacityT),
      .GrantT(GrantT)
  ) reference (
      .candidate_ready(ref_ready),
      .selected_valid(ref_valid),
      .selected_candidate(ref_selected),
      .grant(ref_grant),
      .*
  );

  always_comb begin
    automatic logic capacity_is_prefix;
    capacity_is_prefix = 1'b1;
    for (int d = 0; d < NumDomains; d++)
    for (int r = 1; r < NumSlots; r++)
    capacity_is_prefix &= !capacity[d].ready[r] || capacity[d].ready[r-1];
    correct = !capacity_is_prefix;
    if (capacity_is_prefix) begin
      correct = 1'b1;
      for (int c = 0; c < NumCandidates; c++) correct &= dut_ready[c] == ref_ready[c];
      for (int s = 0; s < NumSlots; s++) begin
        correct &= dut_valid[s] == ref_valid[s];
        correct &= dut_selected[s] == ref_selected[s];
      end
      for (int d = 0; d < NumDomains; d++) correct &= dut_grant[d] == ref_grant[d];
    end
    // Candidate zero has no older competitor. Its acceptance depends only on
    // its domain's first capacity token, never on younger traffic or width
    // saturation. Check independently even for non-prefix capacity vectors.
    if (candidate_valid[0] && int'(candidate_domain[0]) < NumDomains)
      correct &= dut_ready[0] == capacity[int'(candidate_domain[0])].ready[0];
    else correct &= !dut_ready[0];
  end
endmodule
