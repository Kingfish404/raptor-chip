`include "rapt.svh"

// Registered ROB dispatch window. This retimes rapt_rob_dispatch_select's
// age ranking across the clock edge: at the end of each cycle the oldest
// pending owners that were not accepted are ranked and captured together
// with their immutable steering payload (domain and spill slot). The next
// cycle steers from registers, so the full-ROB rank/compaction tree is no
// longer in series with domain steering, operand reads and queue writes.
//
// Candidate lanes keep age order:
//   [0, Resident)                 ranked resident owners (registered)
//   [Resident, Resident+Width)    last cycle's unaccepted allocations
//   [Resident+Width, ScanEntries) this cycle's allocations (live)
// Allocation lanes are younger than every resident owner. They are offered
// only when the registered window covered every remaining pending owner, so
// a younger uop never passes an invisible older owner of the same domain.
module rapt_rob_dispatch_window #(
    parameter int unsigned Entries = rapt_pkg::ROBEntries,
    parameter int unsigned Width = rapt_pkg::DispatchWidth,
    parameter int unsigned ScanEntries = 3 * Width,
    parameter int unsigned IndexBits = rapt_pkg::index_bits(Entries),
    parameter int unsigned PayloadBits = 1,
    parameter bit AllocationBypass = 1'b1
) (
    input logic clock,
    input logic reset,
    input logic flush,
    // Raw ROB_DP occupancy ranks the window; the live eligibility vector
    // additionally applies the recovery fence when a lane is offered.
    input logic [Entries-1:0] pending,
    input logic [Entries-1:0] eligible,
    input logic [IndexBits-1:0] head,
    input logic [PayloadBits-1:0] entry_payload[Entries],
    input logic incoming_valid[Width],
    input logic [IndexBits-1:0] incoming_index[Width],
    input logic [PayloadBits-1:0] incoming_payload[Width],
    input logic endpoint_ready[ScanEntries],
    output logic candidate_valid[ScanEntries],
    output logic [IndexBits-1:0] candidate_index[ScanEntries],
    output logic [PayloadBits-1:0] candidate_payload[ScanEntries],
    output logic candidate_incoming[ScanEntries],
    output logic [rapt_pkg::index_bits(Width)-1:0] candidate_source_slot[ScanEntries],
    output logic accepted[ScanEntries],
    output int unsigned candidate_count,
    output int unsigned accepted_count,
    output int unsigned bypass_count,
    output logic oldest_blocked,
    // Immutable payload reads may finish alongside the next owner selection.
    output logic prefetch_valid[ScanEntries-2*Width],
    output logic [PayloadBits-1:0] prefetch_payload[ScanEntries-2*Width]
);
  localparam int unsigned Resident = ScanEntries - 2 * Width;
  localparam int unsigned CarryBase = Resident;
  localparam int unsigned IncomingBase = Resident + Width;
  localparam int unsigned SourceSlotBits = rapt_pkg::index_bits(Width);
  // One extra rank detects owners beyond the window.
  localparam int unsigned NumRank = Resident + 1;

  if (!(Entries > 0 && Width > 0 && ScanEntries > 2 * Width)) begin : g_invalid_config_0
    $error("Invalid rapt_rob_dispatch_window configuration");
  end
  if (!(Resident <= Entries && (1 << IndexBits) >= Entries)) begin : g_invalid_config_1
    $error("Invalid rapt_rob_dispatch_window configuration");
  end

  logic window_valid_q[Resident];
  logic [IndexBits-1:0] window_index_q[Resident];
  logic [PayloadBits-1:0] window_payload_q[Resident];
  logic carry_valid_q[Width];
  logic [IndexBits-1:0] carry_index_q[Width];
  logic [PayloadBits-1:0] carry_payload_q[Width];
  logic complete_q;

  // ---- Current-cycle lanes: registered state plus live allocations ----
  for (genvar r = 0; r < Resident; r++) begin : g_window_lane
    assign candidate_valid[r] = window_valid_q[r] && eligible[window_index_q[r]];
    assign candidate_index[r] = window_index_q[r];
    assign candidate_payload[r] = window_payload_q[r];
    assign candidate_incoming[r] = 1'b0;
    assign candidate_source_slot[r] = '0;
  end
  for (genvar w = 0; w < Width; w++) begin : g_allocation_lane
    assign candidate_valid[CarryBase+w] = complete_q && carry_valid_q[w]
        && eligible[carry_index_q[w]];
    assign candidate_index[CarryBase+w] = carry_index_q[w];
    assign candidate_payload[CarryBase+w] = carry_payload_q[w];
    assign candidate_incoming[CarryBase+w] = 1'b0;
    assign candidate_source_slot[CarryBase+w] = '0;
    assign candidate_valid[IncomingBase+w] = AllocationBypass && complete_q && incoming_valid[w];
    assign candidate_index[IncomingBase+w] = incoming_index[w];
    assign candidate_payload[IncomingBase+w] = incoming_payload[w];
    assign candidate_incoming[IncomingBase+w] = 1'b1;
    assign candidate_source_slot[IncomingBase+w] = SourceSlotBits'(w);
  end

  always_comb begin
    automatic logic blocked_older;
    candidate_count = 0;
    accepted_count = 0;
    bypass_count = 0;
    blocked_older = 1'b0;
    for (int s = 0; s < ScanEntries; s++) begin
      accepted[s] = candidate_valid[s] && endpoint_ready[s];
      candidate_count += int'(candidate_valid[s]);
      if (accepted[s]) begin
        accepted_count++;
        if (blocked_older) bypass_count++;
      end
      blocked_older |= candidate_valid[s] && !endpoint_ready[s];
    end
    oldest_blocked = candidate_valid[0] && !endpoint_ready[0];
  end

  // ---- Next window: rank owners that remain pending after this edge ----
  logic [Entries-1:0] fired;
  logic [Entries-1:0] remaining;
  always_comb begin
    fired = '0;
    for (int s = 0; s < IncomingBase; s++) if (accepted[s]) fired[candidate_index[s]] = 1'b1;
  end
  assign remaining = pending & ~fired;

  // Rotate occupancy to age order, with age zero at the head.
  logic [2*Entries-1:0] remaining_doubled, remaining_shifted;
  logic [Entries-1:0] age_pending;
  assign remaining_doubled = {remaining, remaining};
  assign remaining_shifted = remaining_doubled >> head;
  assign age_pending = remaining_shifted[Entries-1:0];

  // The extra rank indicates that at least one owner lies beyond the window.
  logic ranked_found[NumRank];
  logic [IndexBits-1:0] ranked_age[NumRank];
  rapt_rank_select #(
      .Entries(Entries),
      .NumSelect(NumRank),
      .IndexBits(IndexBits)
  ) u_age_rank_select (
      .available(age_pending),
      .found(ranked_found),
      .index(ranked_age)
  );

  logic [IndexBits-1:0] next_index[Resident];
  logic [PayloadBits-1:0] next_payload[Resident];
  for (genvar r = 0; r < Resident; r++) begin : g_rank
    assign prefetch_valid[r] = ranked_found[r];
    assign prefetch_payload[r] = next_payload[r];
    // Invalid ranks may read arbitrary payload; validity is registered separately.
    assign next_payload[r] = entry_payload[next_index[r]];
    always_comb begin
      automatic logic [IndexBits:0] physical_sum;
      physical_sum = {1'b0, head} + {1'b0, ranked_age[r]};
      next_index[r] = physical_sum >= (IndexBits + 1)'(Entries)
          ? IndexBits'(physical_sum - (IndexBits + 1)'(Entries)) : IndexBits'(physical_sum);
    end
  end

  always_ff @(posedge clock) begin
    if (reset || flush) begin
      complete_q <= 1'b1;
      for (int r = 0; r < Resident; r++) window_valid_q[r] <= 1'b0;
      for (int w = 0; w < Width; w++) carry_valid_q[w] <= 1'b0;
    end else begin
      // Owners beyond the window are older than every allocation lane.
      complete_q <= !ranked_found[Resident];
      for (int r = 0; r < Resident; r++) begin
        window_valid_q[r] <= ranked_found[r];
        window_index_q[r] <= next_index[r];
        window_payload_q[r] <= next_payload[r];
      end
      // Allocations become ROB_DP on this edge unless an endpoint took them.
      for (int w = 0; w < Width; w++) begin
        carry_valid_q[w] <= incoming_valid[w] && !accepted[IncomingBase+w];
        carry_index_q[w] <= incoming_index[w];
        carry_payload_q[w] <= incoming_payload[w];
      end
    end
  end

`ifndef SYNTHESIS
  // A registered owner must still be pending when offered; only the
  // recovery fence (eligible) may hide it.
  for (genvar r = 0; r < Resident; r++) begin : g_window_contract
    `RAPT_SVA_IMPLY(clock, reset || flush, ROB_WINDOW_OWNER_PENDING, window_valid_q[r],
                    pending[window_index_q[r]])
  end
  for (genvar w = 0; w < Width; w++) begin : g_carry_contract
    `RAPT_SVA_IMPLY(clock, reset || flush, ROB_WINDOW_CARRY_PENDING, carry_valid_q[w],
                    pending[carry_index_q[w]])
  end
`endif
endmodule
