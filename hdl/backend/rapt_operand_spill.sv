`include "rapt.svh"

// Compact storage for execution operands which cannot fall through directly
// to an execution-domain queue. Physical slots are independent of ROB slots;
// the ROB retains the returned spill index while its owner is in ROB_DP.
//
// Releases are registered before they participate in allocation. This keeps
// endpoint ready/acceptance out of the allocation-ready cone while allowing a
// released physical slot to be overwritten on the following cycle.
module rapt_operand_spill #(
    parameter type PayloadT = logic [0:0],
    parameter int unsigned Entries = 8,
    parameter int unsigned AllocateWidth = 2,
    parameter int unsigned ReleaseWidth = AllocateWidth,
    parameter int unsigned ReadPorts = AllocateWidth,
    parameter int unsigned IndexBits = Entries > 1 ? $clog2(Entries) : 1
) (
    input logic clock,
    reset,
    flush,

    input  logic                    allocate_valid[AllocateWidth],
    input  PayloadT                 allocate_payload[AllocateWidth],
    output logic                    allocate_ready[AllocateWidth],
    output logic [IndexBits-1:0]    allocate_index[AllocateWidth],

    input  logic                    release_valid[ReleaseWidth],
    input  logic [IndexBits-1:0]    release_index[ReleaseWidth],

    input  logic [IndexBits-1:0]    read_index[ReadPorts],
    output logic                    read_valid[ReadPorts],
    output PayloadT                 read_payload[ReadPorts],

    // Compact, fixed-position observation/update ports let an operand-aware
    // wrapper perform local completion matching without ROB-sized indexed
    // writes into the value bank. Updates never change allocation validity.
    input  logic                    update_valid[Entries],
    input  PayloadT                 update_payload[Entries],
    output logic                    entry_valid[Entries],
    output PayloadT                 entry_payload[Entries]
);
  logic [Entries-1:0] valid_q;
  PayloadT payload_q[Entries];
  logic release_valid_q[ReleaseWidth];
  logic [IndexBits-1:0] release_index_q[ReleaseWidth];
  logic [Entries-1:0] reclaim_mask, available;

  function automatic logic allocated_now(input logic [IndexBits-1:0] index);
    allocated_now = 1'b0;
    for (int a = 0; a < AllocateWidth; a++) begin
      allocated_now |= allocate_valid[a] && allocate_ready[a] && allocate_index[a] == index;
    end
  endfunction

  // Only releases captured on the preceding edge can create allocation
  // capacity. Invalid or duplicated releases are forbidden by the contract
  // below, so the mask is also the complete set of same-edge overwrites.
  always_comb begin
    reclaim_mask = '0;
    for (int r = 0; r < ReleaseWidth; r++) begin
      if (release_valid_q[r] && int'(release_index_q[r]) < Entries)
        reclaim_mask[release_index_q[r]] = 1'b1;
    end
  end
  assign available = ~valid_q | reclaim_mask;

  // Ordered multi-allocation from the lowest numbered free physical slots.
  // Ready/index depend only on registered capacity and lane position, not on
  // allocate_valid. Reserving every earlier lane removes admission-valid from
  // the capacity cone and matches the ROU's conservative full-prefix policy.
  always_comb begin
    automatic logic [Entries-1:0] remaining;
    remaining = available;
    for (int a = 0; a < AllocateWidth; a++) begin
      allocate_ready[a] = 1'b0;
      allocate_index[a] = '0;
      for (int e = 0; e < Entries; e++) begin
        if (!allocate_ready[a] && remaining[e]) begin
          allocate_index[a] = IndexBits'(e);
          allocate_ready[a] = 1'b1;
          remaining[e] = 1'b0;
        end
      end
    end
  end

  for (genvar p = 0; p < ReadPorts; p++) begin : g_read
    always_comb begin
      read_valid[p] = 1'b0;
      read_payload[p] = '0;
      if (int'(read_index[p]) < Entries) begin
        read_valid[p] = valid_q[read_index[p]] && !reclaim_mask[read_index[p]];
        read_payload[p] = payload_q[read_index[p]];
      end
    end
  end

  for (genvar e = 0; e < Entries; e++) begin : g_entry_view
    assign entry_valid[e] = valid_q[e] && !reclaim_mask[e];
    assign entry_payload[e] = payload_q[e];
  end

  always_ff @(posedge clock) begin
    if (reset || flush) begin
      valid_q <= '0;
      for (int r = 0; r < ReleaseWidth; r++) release_valid_q[r] <= 1'b0;
    end else begin
      for (int r = 0; r < ReleaseWidth; r++) begin
        if (release_valid_q[r]) valid_q[release_index_q[r]] <= 1'b0;
        release_valid_q[r] <= release_valid[r];
        release_index_q[r] <= release_index[r];
      end
      for (int e = 0; e < Entries; e++) begin
        if (update_valid[e] && entry_valid[e]) payload_q[e] <= update_payload[e];
      end
      // Allocation wins when a registered release and allocation target the
      // same physical slot, replacing the old payload atomically.
      for (int a = 0; a < AllocateWidth; a++) begin
        if (allocate_valid[a] && allocate_ready[a]) begin
          valid_q[allocate_index[a]] <= 1'b1;
          payload_q[allocate_index[a]] <= allocate_payload[a];
        end
      end
    end
  end

  if (!(Entries > 0 && AllocateWidth > 0 && ReleaseWidth > 0 && ReadPorts > 0)) begin : g_bad_size
    $error("Invalid rapt_operand_spill configuration");
  end
  if (!((1 << IndexBits) >= Entries)) begin : g_bad_index
    $error("rapt_operand_spill IndexBits cannot address Entries");
  end
  for (genvar a = 1; a < AllocateWidth; a++) begin : g_allocate_prefix
    `RAPT_SVA_IMPLY(clock, reset || flush, OPERAND_SPILL_ALLOCATE_PREFIX, allocate_valid[a],
                    allocate_valid[a-1])
    `RAPT_SVA_IMPLY(clock, reset || flush, OPERAND_SPILL_ALLOCATE_FIRE_PREFIX,
                    allocate_valid[a] && allocate_ready[a],
                    allocate_valid[a-1] && allocate_ready[a-1])
  end
  for (genvar a = 0; a < AllocateWidth; a++) begin : g_allocate_contract
    for (genvar b = a + 1; b < AllocateWidth; b++) begin : g_unique
      `RAPT_SVA_IMPLY(
          clock, reset || flush, OPERAND_SPILL_ALLOCATE_UNIQUE,
          allocate_valid[a] && allocate_ready[a] && allocate_valid[b] && allocate_ready[b],
          allocate_index[a] != allocate_index[b])
    end
  end
  for (genvar r = 0; r < ReleaseWidth; r++) begin : g_release_contract
    `RAPT_SVA_IMPLY(clock, reset || flush, OPERAND_SPILL_RELEASE_LIVE, release_valid[r],
                    int'(release_index[r]) < Entries && (valid_q[release_index[r]] || allocated_now(
                    release_index[r])))
    for (genvar s = r + 1; s < ReleaseWidth; s++) begin : g_unique
      `RAPT_SVA_IMPLY(clock, reset || flush, OPERAND_SPILL_RELEASE_UNIQUE,
                      release_valid[r] && release_valid[s], release_index[r] != release_index[s])
    end
  end
  for (genvar e = 0; e < Entries; e++) begin : g_update_contract
    `RAPT_SVA_IMPLY(clock, reset || flush, OPERAND_SPILL_UPDATE_LIVE, update_valid[e],
                    entry_valid[e])
  end
endmodule
