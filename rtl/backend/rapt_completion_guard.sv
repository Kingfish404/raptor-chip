// Combinational ownership firewall for execution results.
//
// The ROB owns the authoritative allocation identity.  Execution producers
// present dest+generation before shared-port arbitration; only a candidate
// naming a live executing allocation is admitted. Optional immutable-payload
// enforcement is retained for untrusted/test boundaries; integrated hardware
// checks that payload with SVA so consumers still see one accepted completion
// fabric rather than each implementing a subtly different liveness check.
module rapt_completion_guard #(
    parameter int unsigned Entries = 64,
    parameter int unsigned IndexBits = Entries > 1 ? $clog2(Entries) : 1,
    parameter int unsigned GenerationBits = 4,
    parameter int unsigned PhysBits = 7,
    parameter int unsigned ArchBits = 5,
    // Payload checking is useful at untrusted/test boundaries. In the core,
    // prd/rd are typed packet payload and are asserted separately, so the
    // production acceptance cone only needs the allocation identity.
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

    output logic accept,
    output logic identity_match,
    output logic payload_match
);
  if (!(Entries > 0 && GenerationBits > 0)) begin : g_invalid_config_0
    $error("Invalid rapt_completion_guard configuration");
  end

  always_comb begin
    identity_match = 1'b0;
    payload_match = 1'b0;
    accept = 1'b0;
    if (candidate_valid && int'(candidate_index) < Entries) begin
      identity_match = live[candidate_index]
          && owner_generation[candidate_index] == candidate_generation;
      payload_match = owner_prd[candidate_index] == candidate_prd
          && owner_rd[candidate_index] == candidate_rd;
      accept = identity_match && executing[candidate_index]
          && (!EnforcePayload || payload_match);
    end
  end
endmodule
