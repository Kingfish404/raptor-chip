// Independent transition-system miter for rename checkpoint lifetime,
// ancestry clearing, snapshots, and restore selection.
module formal_rename_checkpoint #(
    parameter int Entries = 4,
    parameter int RenameWidth = 2,
    parameter int ResolvePorts = 2,
    parameter int MapEntries = 4,
    parameter int PhysRegs = 8,
    parameter int MapBits = PhysRegs > 1 ? $clog2(PhysRegs) : 1,
    parameter int CheckpointBits = Entries > 1 ? $clog2(Entries) : 1
) (
    input logic clock,
    reset,
    flush,
    input logic allocate_valid[RenameWidth],
    input logic [CheckpointBits-1:0] allocate_id[RenameWidth],
    input logic [MapBits-1:0] allocate_map[RenameWidth][MapEntries],
    input logic [PhysRegs-1:0] allocate_free[RenameWidth],
    input logic release_valid[ResolvePorts],
    input logic [CheckpointBits-1:0] release_id[ResolvePorts],
    input logic restore_valid,
    input logic [CheckpointBits-1:0] restore_id,
    output logic correct
);
  logic [Entries-1:0] available, live;
  logic restore_hit;
  logic [MapBits-1:0] restore_map[MapEntries];
  logic [PhysRegs-1:0] restore_free;
  rapt_rename_checkpoint #(
      .Entries(Entries),
      .RenameWidth(RenameWidth),
      .ResolvePorts(ResolvePorts),
      .MapEntries(MapEntries),
      .PhysRegs(PhysRegs),
      .MapBits(MapBits),
      .CheckpointBits(CheckpointBits)
  ) dut (
      .*
  );

  logic [Entries-1:0] ref_valid, next_valid;
  logic [Entries-1:0] ref_older[Entries], next_older[Entries];
  logic [MapBits-1:0] ref_map[Entries][MapEntries], next_map[Entries][MapEntries];
  logic [PhysRegs-1:0] ref_free[Entries], next_free[Entries];

  always_comb begin
    next_valid = ref_valid;
    for (int e = 0; e < Entries; e++) begin
      next_older[e] = ref_older[e];
      next_free[e] = ref_free[e];
      for (int r = 0; r < MapEntries; r++) next_map[e][r] = ref_map[e][r];
    end
    if (restore_valid) begin
      for (int e = 0; e < Entries; e++)
      if (e == int'(restore_id) || ref_older[e][restore_id]) next_valid[e] = 0;
    end
    for (int p = 0; p < ResolvePorts; p++)
    if (release_valid[p]) begin
      next_valid[release_id[p]] = 0;
      for (int e = 0; e < Entries; e++) next_older[e][release_id[p]] = 0;
    end
    for (int s = 0; s < RenameWidth; s++)
    if (allocate_valid[s]) begin
      next_valid[allocate_id[s]] = 1;
      next_older[allocate_id[s]] = ref_valid;
      for (int p = 0; p < ResolvePorts; p++)
      if (release_valid[p]) next_older[allocate_id[s]][release_id[p]] = 0;
      for (int prior = 0; prior < s; prior++)
      if (allocate_valid[prior]) next_older[allocate_id[s]][allocate_id[prior]] = 1;
      next_free[allocate_id[s]] = allocate_free[s];
      for (int r = 0; r < MapEntries; r++) next_map[allocate_id[s]][r] = allocate_map[s][r];
    end
    if (reset || flush) begin
      next_valid = '0;
      for (int e = 0; e < Entries; e++) next_older[e] = '0;
    end
  end

  always_ff @(posedge clock) begin
    ref_valid <= next_valid;
    for (int e = 0; e < Entries; e++) begin
      ref_older[e] <= next_older[e];
      ref_free[e] <= next_free[e];
      for (int r = 0; r < MapEntries; r++) ref_map[e][r] <= next_map[e][r];
    end
  end

  always_comb begin
    correct = live == ref_valid && available == ~ref_valid;
    for (int e = 0; e < Entries; e++) begin
      correct &= dut.older_q[e] == ref_older[e];
      if (ref_valid[e]) begin
        correct &= dut.free_q[e] == ref_free[e];
        for (int r = 0; r < MapEntries; r++) correct &= dut.map_q[e][r] == ref_map[e][r];
      end
    end
    correct &= restore_hit == (restore_valid && ref_valid[restore_id]);
    if (restore_valid && ref_valid[restore_id]) begin
      correct &= restore_free == ref_free[restore_id];
      for (int r = 0; r < MapEntries; r++) correct &= restore_map[r] == ref_map[restore_id][r];
    end
  end

`ifdef FORMAL
  always_comb begin
    assume (int'(restore_id) < Entries);
    if (restore_valid) assume (ref_valid[restore_id]);
    for (int s = 0; s < RenameWidth; s++)
    if (allocate_valid[s]) begin
      assume (int'(allocate_id[s]) < Entries && !ref_valid[allocate_id[s]]);
      assume (!restore_valid);
      for (int prior = 0; prior < s; prior++)
      if (allocate_valid[prior]) assume (allocate_id[s] != allocate_id[prior]);
    end
    for (int p = 0; p < ResolvePorts; p++)
    if (release_valid[p]) begin
      assume (int'(release_id[p]) < Entries && ref_valid[release_id[p]]);
      if (restore_valid) assume (release_id[p] != restore_id);
      for (int q = 0; q < p; q++) if (release_valid[q]) assume (release_id[p] != release_id[q]);
      for (int s = 0; s < RenameWidth; s++)
      if (allocate_valid[s]) assume (release_id[p] != allocate_id[s]);
    end
  end
`endif
endmodule
