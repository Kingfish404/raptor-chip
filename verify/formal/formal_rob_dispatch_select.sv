// Verification-only flat reference for the ROB dispatch selector.  It keeps
// the original age scan so equivalence does not depend on the implementation's
// bitmap rotation or rank tree.
module rob_dispatch_select_reference #(
    parameter int unsigned Entries = 16,
    parameter int unsigned Width = 4,
    parameter int unsigned ScanEntries = Width,
    parameter int unsigned IndexBits = Entries > 1 ? $clog2(Entries) : 1
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

  always_comb begin
    automatic int unsigned selected;
    selected = 0;
    for (int s = 0; s < ScanEntries; s++) begin
      candidate_valid[s] = 1'b0;
      candidate_index[s] = '0;
      candidate_incoming[s] = 1'b0;
      candidate_source_slot[s] = '0;
    end
    for (int offset = 0; offset < Entries; offset++) begin
      automatic int unsigned index;
      index = (int'(head) + offset) % Entries;
      if (pending[index] && selected < ScanEntries) begin
        candidate_valid[selected] = 1'b1;
        candidate_index[selected] = IndexBits'(index);
        selected++;
      end
    end
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
endmodule

module formal_rob_dispatch_select #(
    parameter int unsigned Entries = 16,
    parameter int unsigned Width = 4,
    parameter int unsigned ScanEntries = Width,
    parameter int unsigned IndexBits = Entries > 1 ? $clog2(Entries) : 1
) (
    input logic [Entries-1:0] pending,
    input logic [IndexBits-1:0] head,
    input logic incoming_valid[Width],
    input logic [IndexBits-1:0] incoming_index[Width],
    input logic endpoint_ready[ScanEntries],
    output logic correct
);
  logic dut_candidate_valid[ScanEntries], ref_candidate_valid[ScanEntries];
  logic [IndexBits-1:0] dut_candidate_index[ScanEntries], ref_candidate_index[ScanEntries];
  logic dut_candidate_incoming[ScanEntries], ref_candidate_incoming[ScanEntries];
  logic [rapt_pkg::index_bits(Width)-1:0]
      dut_source_slot[ScanEntries], ref_source_slot[ScanEntries];
  logic dut_accepted[ScanEntries], ref_accepted[ScanEntries];
  int unsigned dut_candidate_count, ref_candidate_count;
  int unsigned dut_accepted_count, ref_accepted_count;
  int unsigned dut_bypass_count, ref_bypass_count;
  logic dut_oldest_blocked, ref_oldest_blocked;

  rapt_rob_dispatch_select #(
      .Entries(Entries),
      .Width(Width),
      .ScanEntries(ScanEntries),
      .IndexBits(IndexBits)
  ) dut (
      .candidate_source_slot(dut_source_slot),
      .candidate_count(dut_candidate_count),
      .accepted_count(dut_accepted_count),
      .bypass_count(dut_bypass_count),
      .oldest_blocked(dut_oldest_blocked),
      .candidate_valid(dut_candidate_valid),
      .candidate_index(dut_candidate_index),
      .candidate_incoming(dut_candidate_incoming),
      .accepted(dut_accepted),
      .*
  );
  rob_dispatch_select_reference #(
      .Entries(Entries),
      .Width(Width),
      .ScanEntries(ScanEntries),
      .IndexBits(IndexBits)
  ) reference (
      .candidate_source_slot(ref_source_slot),
      .candidate_count(ref_candidate_count),
      .accepted_count(ref_accepted_count),
      .bypass_count(ref_bypass_count),
      .oldest_blocked(ref_oldest_blocked),
      .candidate_valid(ref_candidate_valid),
      .candidate_index(ref_candidate_index),
      .candidate_incoming(ref_candidate_incoming),
      .accepted(ref_accepted),
      .*
  );

  always_comb begin
    // A ROB pointer is always in range.  Make out-of-contract encodings
    // vacuously true so bounded proof does not invent impossible pointers.
    correct = int'(head) >= Entries;
    if (int'(head) < Entries) begin
      correct = dut_candidate_count == ref_candidate_count
          && dut_accepted_count == ref_accepted_count
          && dut_bypass_count == ref_bypass_count
          && dut_oldest_blocked == ref_oldest_blocked;
      for (int s = 0; s < ScanEntries; s++) begin
        correct &= dut_candidate_valid[s] == ref_candidate_valid[s];
        correct &= dut_candidate_index[s] == ref_candidate_index[s];
        correct &= dut_candidate_incoming[s] == ref_candidate_incoming[s];
        correct &= dut_source_slot[s] == ref_source_slot[s];
        correct &= dut_accepted[s] == ref_accepted[s];
      end
    end
  end
endmodule
