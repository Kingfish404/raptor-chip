`include "rapt.svh"

// Select the oldest pending ROB owners for execution-domain steering. The
// candidate vector is compact and age ordered, but acceptance is deliberately
// independent per candidate: a blocked older domain does not suppress a ready
// younger candidate from another domain. Retirement remains strictly ordered.
module rapt_rob_dispatch_select #(
    parameter int unsigned Entries = rapt_pkg::ROBEntries,
    parameter int unsigned Width = rapt_pkg::DispatchWidth,
    parameter int unsigned ScanEntries = Width,
    parameter int unsigned IndexBits = rapt_pkg::index_bits(Entries)
) (
    input  logic [Entries-1:0] pending,
    input  logic [IndexBits-1:0] head,
    input  logic incoming_valid[Width],
    input  logic [IndexBits-1:0] incoming_index[Width],
    input  logic endpoint_ready[ScanEntries],
    output logic candidate_valid[ScanEntries],
    output logic [IndexBits-1:0] candidate_index[ScanEntries],
    output logic candidate_incoming[ScanEntries],
    output logic [rapt_pkg::index_bits(Width)-1:0] candidate_source_slot[ScanEntries],
    output logic accepted[ScanEntries],
    output int unsigned candidate_count,
    output int unsigned accepted_count,
    output int unsigned bypass_count,
    output logic oldest_blocked
);
  localparam int SourceSlotBits = rapt_pkg::index_bits(Width);

  // Present the circular ROB occupancy in age order, with age zero at head.
  // The doubled vector makes the wrap a single bounded variable shift.  Age
  // ranking is then delegated to the shared hierarchical selector instead of
  // building Width cascaded, full-ROB priority scans here.
  logic [2*Entries-1:0] pending_doubled;
  logic [2*Entries-1:0] pending_shifted;
  logic [Entries-1:0] age_pending;
  logic age_found[ScanEntries];
  logic [IndexBits-1:0] age_index[ScanEntries];

  assign pending_doubled = {pending, pending};
  assign pending_shifted = pending_doubled >> head;
  assign age_pending = pending_shifted[Entries-1:0];

  rapt_rank_select #(
      .Entries(Entries),
      .NumSelect(ScanEntries),
      .IndexBits(IndexBits)
  ) u_age_rank_select (
      .available(age_pending),
      .found(age_found),
      .index(age_index)
  );

  always_comb begin
    automatic int unsigned selected;
    selected = 0;
    for (int s = 0; s < ScanEntries; s++) begin
      candidate_valid[s] = 1'b0;
      candidate_index[s] = '0;
      candidate_incoming[s] = 1'b0;
      candidate_source_slot[s] = '0;
    end
    for (int rank = 0; rank < ScanEntries; rank++) begin
      automatic logic [IndexBits:0] physical_sum;
      automatic logic [IndexBits:0] physical_index;
      physical_sum = {1'b0, head} + {1'b0, age_index[rank]};
      physical_index = physical_sum >= (IndexBits + 1)'(Entries)
          ? physical_sum - (IndexBits + 1)'(Entries) : physical_sum;
      if (age_found[rank]) begin
        candidate_valid[selected] = 1'b1;
        candidate_index[selected] = physical_index[IndexBits-1:0];
        selected++;
      end
    end
    // Empty candidate lanes fall through from this cycle's ordered ROB
    // allocations.  Existing pending owners retain age priority; the common
    // no-backpressure path therefore pays no extra dispatch cycle.
    for (int incoming = 0; incoming < Width; incoming++) begin
      if (incoming_valid[incoming] && selected < ScanEntries) begin
        candidate_valid[selected] = 1'b1;
        candidate_index[selected] = incoming_index[incoming];
        candidate_incoming[selected] = 1'b1;
        candidate_source_slot[selected] = SourceSlotBits'(incoming);
        selected++;
      end
    end
    candidate_count = selected;
  end

  // Keep ready-dependent acceptance in a separate combinational cone. This
  // makes the structural boundary explicit to synthesis: candidate identity
  // drives domain routing, while endpoint ready never feeds age selection.
  always_comb begin
    automatic logic blocked_older;
    accepted_count = 0;
    bypass_count = 0;
    blocked_older = 1'b0;
    for (int s = 0; s < ScanEntries; s++) begin
      accepted[s] = candidate_valid[s] && endpoint_ready[s];
      if (accepted[s]) begin
        accepted_count++;
        if (blocked_older) bypass_count++;
      end
      blocked_older |= candidate_valid[s] && !endpoint_ready[s];
    end
    oldest_blocked = candidate_valid[0] && !endpoint_ready[0];
  end

  if (!(Entries > 0 && Width > 0 && ScanEntries > 0)) begin : g_invalid_config_0
    $error("Invalid rapt_rob_dispatch_select configuration");
  end
  if (!(Width <= Entries && ScanEntries <= Entries)) begin : g_invalid_config_1
    $error("Invalid rapt_rob_dispatch_select configuration");
  end
  if (!((1 << IndexBits) >= Entries)) begin : g_invalid_config_2
    $error("Invalid rapt_rob_dispatch_select configuration");
  end
endmodule
