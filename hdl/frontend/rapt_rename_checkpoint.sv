`include "rapt.svh"

// Rename checkpoint state.  The caller computes post-slot MAP/free snapshots;
// this module owns allocation lifetime and control-flow ancestry.
//
// Correct resolution clears the released ID from every live ancestry mask.
// That detail makes ID reuse safe: an older checkpoint incarnation cannot make
// a still-live branch look younger than a later reuse of the same numeric ID.
module rapt_rename_checkpoint #(
    parameter int unsigned Entries = rapt_pkg::CoreConfig.branch_checkpoints,
    parameter int unsigned RenameWidth = rapt_pkg::RenameWidth,
    parameter int unsigned ResolvePorts = rapt_pkg::CompletionPorts,
    parameter int unsigned MapEntries = rapt_pkg::CoreConfig.arch_regs,
    parameter int unsigned PhysRegs = rapt_pkg::CoreConfig.phys_regs,
    parameter int unsigned MapBits = rapt_pkg::index_bits(PhysRegs),
    parameter int unsigned CheckpointBits = rapt_pkg::index_bits(Entries)
) (
    input logic clock,
    input logic reset,
    input logic flush,

    output logic [Entries-1:0] available,
    input logic allocate_valid[RenameWidth],
    input logic [CheckpointBits-1:0] allocate_id[RenameWidth],
    input logic [MapBits-1:0] allocate_map[RenameWidth][MapEntries],
    input logic [PhysRegs-1:0] allocate_free[RenameWidth],

    input logic release_valid[ResolvePorts],
    input logic [CheckpointBits-1:0] release_id[ResolvePorts],
    input logic restore_valid,
    input logic [CheckpointBits-1:0] restore_id,
    output logic restore_hit,
    output logic [MapBits-1:0] restore_map[MapEntries],
    output logic [PhysRegs-1:0] restore_free,
    output logic [Entries-1:0] live
);
  logic [Entries-1:0] valid_q;
  logic [Entries-1:0] older_q[Entries];
  logic [MapBits-1:0] map_q[Entries][MapEntries];
  logic [PhysRegs-1:0] free_q[Entries];
  logic [Entries-1:0] release_mask;
  logic [Entries-1:0] allocate_older[RenameWidth];

  if (!(Entries > 0 && RenameWidth > 0 && ResolvePorts > 0)) begin : g_invalid_config_0
    $error("Invalid rapt_rename_checkpoint configuration");
  end
  if (!(MapEntries > 0 && PhysRegs > MapEntries)) begin : g_invalid_config_1
    $error("Invalid rapt_rename_checkpoint configuration");
  end
  if (MapBits < rapt_pkg::index_bits(
          PhysRegs
      ) || CheckpointBits < rapt_pkg::index_bits(
          Entries
      )) begin : g_invalid_index_width
    $error("Invalid rapt_rename_checkpoint configuration: insufficient index width");
  end

  assign available = ~valid_q;
  assign live = valid_q;
  assign restore_hit = restore_valid && int'(restore_id) < Entries && valid_q[restore_id];
  always_comb begin
    restore_free = '0;
    for (int r = 0; r < MapEntries; r++) restore_map[r] = '0;
    if (restore_hit) begin
      restore_free = free_q[restore_id];
      for (int r = 0; r < MapEntries; r++) restore_map[r] = map_q[restore_id][r];
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
        if ((restore_hit && (e == int'(restore_id) || older_q[e][restore_id])) || release_mask[e])
          valid_q[e] <= 1'b0;
        older_q[e] <= older_q[e] & ~release_mask;
        for (int s = 0; s < RenameWidth; s++) begin
          if (allocate_valid[s] && int'(allocate_id[s]) == e) begin
            valid_q[e] <= 1'b1;
            older_q[e] <= allocate_older[s];
            free_q[e] <= allocate_free[s];
            map_q[e] <= allocate_map[s];
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
