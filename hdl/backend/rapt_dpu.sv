`include "rapt.svh"
`include "rapt_if.svh"

// Capacity-aware dispatch compactor. The ROB exposes an age-ordered candidate
// window that may be wider than the physical dispatch bandwidth.  This router
// skips candidates whose target domain is full, preserves age among every
// candidate it can accept, and compacts at most NumSlots winners onto the
// fixed-width execution-queue interface.
module rapt_dpu #(
    parameter rapt_pkg::core_config_t Cfg = rapt_pkg::CoreConfig,
    parameter int unsigned NumDomains = Cfg.execution_domains,
    parameter int unsigned NumSlots = Cfg.dispatch_width,
    parameter int unsigned NumCandidates = NumSlots,
    parameter type CapacityT = rapt_pkg::dispatch_capacity_t,
    parameter type GrantT = rapt_pkg::dispatch_grant_t
) (
    input logic clock,
    input logic reset,
    input rapt_pkg::execution_domain_t candidate_domain[NumCandidates],
    input logic candidate_valid[NumCandidates],
    output logic candidate_ready[NumCandidates],
    output logic selected_valid[NumSlots],
    output logic [rapt_pkg::index_bits(NumCandidates)-1:0] selected_candidate[NumSlots],
    input CapacityT capacity[NumDomains],
    output GrantT grant[NumDomains]
);
  int unsigned target[NumCandidates];
  localparam int CandidateBits = rapt_pkg::index_bits(NumCandidates);
  localparam int RankBits = rapt_pkg::index_bits(NumCandidates + 1);
  logic [RankBits-1:0] domain_rank[NumCandidates];
  logic [NumCandidates-1:0] admissible;
  if (!(NumSlots > 0 && NumCandidates > 0 && NumDomains > 0)) begin : g_invalid_config_0
    $error("Invalid rapt_dpu configuration");
  end
  if (!(NumCandidates >= NumSlots)) begin : g_invalid_config_1
    $error("Invalid rapt_dpu configuration");
  end
  if (!($size(
          candidate_domain
      ) == NumCandidates && $size(
          selected_candidate
      ) == NumSlots && $bits(
          grant[0].accept
      ) == NumSlots && $bits(
          capacity[0].ready
      ) == NumSlots)) begin : g_invalid_config_2
    $error("dispatch slot/type dimensions do not agree");
  end
  for (genvar c = 0; c < NumCandidates; c++) begin : g_target
    assign target[c] = int'(candidate_domain[c]);
    always_comb begin
      domain_rank[c] = '0;
      for (int older = 0; older < c; older++)
      if (candidate_valid[older] && candidate_domain[older] == candidate_domain[c])
        domain_rank[c]++;
      admissible[c] = candidate_valid[c] && target[c] < NumDomains
          && int'(domain_rank[c]) < NumSlots
          && capacity[target[c]].ready[domain_rank[c]];
    end
    `RAPT_SVA_IMPLY(clock, reset, DISPATCH_DOMAIN_EXISTS, candidate_valid[c],
                    int'(candidate_domain[c]) < NumDomains)
  end

  rapt_rank_select #(
      .Entries(NumCandidates),
      .NumSelect(NumSlots),
      .IndexBits(CandidateBits)
  ) select_oldest_admissible (
      .available(admissible),
      .found(selected_valid),
      .index(selected_candidate)
  );

  always_comb begin
    for (int d = 0; d < NumDomains; d++) begin
      grant[d] = '0;
      for (int s = 0; s < NumSlots; s++) begin
        automatic int unsigned c;
        c = int'(selected_candidate[s]);
        if (selected_valid[s] && target[c] == d) begin
          grant[d].accept[s] = 1'b1;
          grant[d].index[s] = capacity[d].free_index[domain_rank[c]];
        end
      end
    end
    for (int c = 0; c < NumCandidates; c++) begin
      candidate_ready[c] = 1'b0;
      for (int s = 0; s < NumSlots; s++)
      candidate_ready[c] |= selected_valid[s] && selected_candidate[s] == CandidateBits'(c);
    end
  end
  for (genvar d = 0; d < NumDomains; d++) begin : g_capacity_prefix
    for (genvar r = 1; r < NumSlots; r++) begin : g_rank
      `RAPT_SVA_IMPLY(clock, reset, DISPATCH_CAPACITY_PREFIX, capacity[d].ready[r],
                      capacity[d].ready[r-1])
    end
  end
endmodule
