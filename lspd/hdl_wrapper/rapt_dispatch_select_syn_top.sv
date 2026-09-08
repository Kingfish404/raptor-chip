`include "rapt.svh"

// Tool-facing boundary for the ROB age-window selector alone. This separates
// pending rotation/ranking and ready-dependent accounting from domain routing
// in rapt_dpu, making K-scaling costs attributable instead of anecdotal.
module rapt_dispatch_select_syn_top #(
    parameter int unsigned Entries = rapt_pkg::ROBEntries,
    parameter int unsigned Width = rapt_pkg::DispatchWidth,
    parameter int unsigned ScanEntries = rapt_pkg::SteerScanEntries,
    parameter int unsigned IndexBits = rapt_pkg::index_bits(Entries),
    parameter int unsigned SourceBits = rapt_pkg::index_bits(Width),
    parameter int unsigned StimulusBits = Entries + IndexBits + Width
        + Width * IndexBits + ScanEntries,
    parameter int unsigned ResponseBits = 3 * ScanEntries
        + ScanEntries * (IndexBits + SourceBits) + 3 * 32 + 1
) (
    input  logic                    clock,
    input  logic                    reset,
    input  logic [StimulusBits-1:0] stimulus,
    output logic [ResponseBits-1:0] response
);
  localparam int unsigned HeadBase = Entries;
  localparam int unsigned IncomingValidBase = HeadBase + IndexBits;
  localparam int unsigned IncomingIndexBase = IncomingValidBase + Width;
  localparam int unsigned ReadyBase = IncomingIndexBase + Width * IndexBits;

  logic [Entries-1:0] pending;
  logic [IndexBits-1:0] head;
  logic incoming_valid[Width];
  logic [IndexBits-1:0] incoming_index[Width];
  logic endpoint_ready[ScanEntries];
  logic candidate_valid[ScanEntries];
  logic [IndexBits-1:0] candidate_index[ScanEntries];
  logic candidate_incoming[ScanEntries];
  logic [SourceBits-1:0] candidate_source_slot[ScanEntries];
  logic accepted[ScanEntries];
  int unsigned candidate_count, accepted_count, bypass_count;
  logic oldest_blocked;

  logic [ScanEntries-1:0] endpoint_ready_packed, candidate_valid_packed;
  logic [ScanEntries*IndexBits-1:0] candidate_index_packed;
  logic [ScanEntries-1:0] candidate_incoming_packed, accepted_packed;
  logic [ScanEntries*SourceBits-1:0] candidate_source_slot_packed;

  assign pending = stimulus[Entries-1:0];
  assign head = stimulus[HeadBase +: IndexBits];
  for (genvar w = 0; w < Width; w++) begin : g_incoming
    assign incoming_valid[w] = stimulus[IncomingValidBase+w];
    assign incoming_index[w] = stimulus[IncomingIndexBase+w*IndexBits +: IndexBits];
  end
  for (genvar c = 0; c < ScanEntries; c++) begin : g_candidate
    assign endpoint_ready_packed[c] = stimulus[ReadyBase+c];
    assign endpoint_ready[c] = endpoint_ready_packed[c];
    assign candidate_valid_packed[c] = candidate_valid[c];
    assign candidate_index_packed[c*IndexBits +: IndexBits] = candidate_index[c];
    assign candidate_incoming_packed[c] = candidate_incoming[c];
    assign candidate_source_slot_packed[c*SourceBits +: SourceBits] = candidate_source_slot[c];
    assign accepted_packed[c] = accepted[c];
  end

  assign response = {
    oldest_blocked,
    bypass_count,
    accepted_count,
    candidate_count,
    accepted_packed,
    candidate_source_slot_packed,
    candidate_incoming_packed,
    candidate_index_packed,
    candidate_valid_packed
  };

  rapt_rob_dispatch_select #(
      .Entries(Entries),
      .Width(Width),
      .ScanEntries(ScanEntries),
      .IndexBits(IndexBits)
  ) dut (
      .*
  );

  logic unused_clock_reset;
  assign unused_clock_reset = clock ^ reset;
endmodule
