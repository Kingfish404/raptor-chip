`include "rapt.svh"

// Control-flow checkpoint lifetime, ancestry, and predictor history. Rename
// stays fenced after a redirect and the precise retirement flush rebuilds
// MAP/free from the committed RAT; no speculative rename snapshot is needed.
//
// Correct resolution clears the released ID from every live ancestry mask.
// That detail makes ID reuse safe: an older checkpoint incarnation cannot make
// a still-live branch look younger than a later reuse of the same numeric ID.
module rapt_rename_checkpoint #(
    parameter int unsigned Entries = rapt_pkg::CoreConfig.branch_checkpoints,
    parameter int unsigned RenameWidth = rapt_pkg::RenameWidth,
    parameter int unsigned ResolvePorts = rapt_pkg::CompletionPorts,
    parameter int unsigned CheckpointBits = rapt_pkg::index_bits(Entries),
    parameter int unsigned GhrBits = 64,
    parameter int unsigned PhrBits = 8
) (
    input logic clock,
    input logic reset,
    input logic flush,

    output logic [Entries-1:0] available,
    input logic allocate_valid[RenameWidth],
    input logic [CheckpointBits-1:0] allocate_id[RenameWidth],
    input logic [GhrBits-1:0] allocate_ghr[RenameWidth] = '{default: '0},
    input logic [PhrBits-1:0] allocate_phr[RenameWidth] = '{default: '0},
    input logic allocate_conditional[RenameWidth] = '{default: 1'b0},

    input logic release_valid[ResolvePorts],
    input logic [CheckpointBits-1:0] release_id[ResolvePorts],
    input logic restore_valid,
    input logic [CheckpointBits-1:0] restore_id,
    output logic restore_hit,
    output logic [GhrBits-1:0] restore_ghr,
    output logic [PhrBits-1:0] restore_phr,
    output logic restore_conditional,
    output logic [Entries-1:0] live
);
  logic [Entries-1:0] valid_q;
  logic [Entries-1:0] older_q[Entries];
  logic [GhrBits-1:0] ghr_q[Entries];
  logic [PhrBits-1:0] phr_q[Entries];
  logic conditional_q[Entries];
  logic [Entries-1:0] release_mask;
  logic [Entries-1:0] allocate_older[RenameWidth];

  if (!(Entries > 0 && RenameWidth > 0 && ResolvePorts > 0)) begin : g_invalid_config_0
    $error("Invalid rapt_rename_checkpoint configuration");
  end
  if (CheckpointBits < rapt_pkg::index_bits(Entries)) begin : g_invalid_index_width
    $error("Invalid rapt_rename_checkpoint configuration: insufficient index width");
  end

  assign available = ~valid_q;
  assign live = valid_q;
  assign restore_hit = restore_valid && int'(restore_id) < Entries && valid_q[restore_id];
  // Decode the restore and allocation targets once into one-hot vectors. The
  // per-entry storage below then keys off a wire bit instead of repeating a
  // full wide compare for every entry, which keeps the entry enable cone flat
  // in `Entries`.
  logic [Entries-1:0] restore_target;
  logic [Entries-1:0] allocate_target[RenameWidth];
  always_comb begin
    restore_target = '0;
    if (restore_valid && int'(restore_id) < Entries) restore_target[restore_id] = 1'b1;
  end
  for (genvar s = 0; s < RenameWidth; s++) begin : g_allocate_decode
    always_comb begin
      allocate_target[s] = '0;
      if (allocate_valid[s] && int'(allocate_id[s]) < Entries)
        allocate_target[s][allocate_id[s]] = 1'b1;
    end
  end

  always_comb begin
    restore_ghr = '0;
    restore_phr = '0;
    restore_conditional = 1'b0;
    if (restore_hit) begin
      restore_ghr = ghr_q[restore_id];
      restore_phr = phr_q[restore_id];
      restore_conditional = conditional_q[restore_id];
    end
  end

  // Decode releases once. Every entry clears the same ancestry bits.
  always_comb begin
    release_mask = '0;
    for (int p = 0; p < ResolvePorts; p++)
    if (release_valid[p] && int'(release_id[p]) < Entries) release_mask[release_id[p]] = 1'b1;
  end
  for (genvar s = 0; s < RenameWidth; s++) begin : g_snapshot_ancestry
    always_comb begin
      allocate_older[s] = valid_q & ~release_mask;
      for (int prior = 0; prior < s; prior++)
      if (allocate_valid[prior]) allocate_older[s][allocate_id[prior]] = 1'b1;
    end
  end

  // Each checkpoint owns its validity, ancestry and snapshot storage.
  // Restore removes its owner and descendants; release also clears ancestry.
  // Allocation retains last-slot priority, though legal IDs are unique.
  for (genvar e = 0; e < Entries; e++) begin : g_entry
    always_ff @(posedge clock) begin
      if (reset || flush) begin
        valid_q[e] <= 1'b0;
        older_q[e] <= '0;
      end else begin
        if ((restore_hit && (restore_target[e] || older_q[e][restore_id])) || release_mask[e])
          valid_q[e] <= 1'b0;
        if (|release_mask) older_q[e] <= older_q[e] & ~release_mask;
        for (int s = 0; s < RenameWidth; s++) begin
          if (allocate_target[s][e]) begin
            valid_q[e] <= 1'b1;
            older_q[e] <= allocate_older[s];
            ghr_q[e] <= allocate_ghr[s];
            phr_q[e] <= allocate_phr[s];
            conditional_q[e] <= allocate_conditional[s];
          end
        end
      end
    end
  end

  for (genvar s = 0; s < RenameWidth; s++) begin : g_allocate_contract
    `RAPT_SVA_IMPLY(clock, reset || flush, RENAME_CHECKPOINT_ALLOC_FREE, allocate_valid[s],
                    int'(allocate_id[s]) < Entries && available[allocate_id[s]])
    for (genvar t = s + 1; t < RenameWidth; t++) begin : g_unique
      `RAPT_SVA_IMPLY(clock, reset || flush, RENAME_CHECKPOINT_ALLOC_UNIQUE,
                      allocate_valid[s] && allocate_valid[t], allocate_id[s] != allocate_id[t])
    end
  end
  `RAPT_SVA_IMPLY(clock, reset || flush, RENAME_CHECKPOINT_RESTORE_INDEX, restore_valid,
                  int'(restore_id) < Entries)
endmodule
