`include "rapt.svh"
`include "rapt_if.svh"

// Ordered rename: incoming decode groups are flattened by RNQ. The rename
// group sees a program-order fold of MAP, including RAW and stale-destination
// WAW bypass. Free registers are selected once per actual destination writer.
module rapt_rnu #(
    parameter rapt_pkg::core_config_t Cfg = rapt_pkg::CoreConfig,
    parameter type UopT = rapt_pkg::uop_t,
    parameter int DecodeWidth = Cfg.decode_width,
    parameter int RenameWidth = Cfg.rename_width,
    parameter int CommitWidth = Cfg.commit_width,
    parameter unsigned RIQ_SIZE = Cfg.rename_entries,
    parameter unsigned RNUM = Cfg.arch_regs,
    parameter unsigned RLEN = rapt_pkg::index_bits(Cfg.arch_regs),
    parameter unsigned PNUM = Cfg.phys_regs,
    parameter unsigned PLEN = rapt_pkg::index_bits(Cfg.phys_regs),
    parameter unsigned CheckpointEntries = Cfg.branch_checkpoints,
    parameter unsigned CheckpointBits = rapt_pkg::index_bits(CheckpointEntries),
    parameter unsigned ResolvePorts = Cfg.completion_ports,
    parameter unsigned XLEN = Cfg.xlen
) (
    input logic clock,
    reset,
    rou_cmu_if.in rou_cmu,
    cmu_bcast_if.in cmu_bcast,
    idu_rnu_if.slave idu_rnu,
    rnu_rou_if.master rnu_rou,
    rapt_recovery_if.sink recovery,
    checkpoint_release_if.sink checkpoint_release,
    output logic [PLEN-1:0] map_snapshot[RNUM],
    output logic [PLEN-1:0] rat_snapshot[RNUM]
);
  localparam int CheckpointOccupancyBits = rapt_pkg::index_bits(CheckpointEntries + 1);

  typedef struct packed {
    UopT uop;
    logic [XLEN-1:0] op1, op2;
    logic [RLEN-1:0] rs1, rs2;
  } decoded_t;
  typedef struct packed {
    UopT uop;
    logic [XLEN-1:0] op1, op2;
    logic [PLEN-1:0] pr1, pr2, prd, prs;
    logic checkpoint_valid;
    logic [CheckpointBits-1:0] checkpoint;
  } renamed_t;
  logic [rapt_pkg::index_bits(RIQ_SIZE+1)-1:0] decoded_count;
  logic [rapt_pkg::index_bits(2*RenameWidth+1)-1:0] renamed_count;
  assign rnu_rou.empty = decoded_count == 0 && renamed_count == 0;
  decoded_t decoded[DecodeWidth], candidate[RenameWidth];
  logic candidate_valid[RenameWidth], candidate_ready[RenameWidth];
  renamed_t renamed[RenameWidth], buffered[RenameWidth];
  logic renamed_valid[RenameWidth], renamed_ready[RenameWidth];
  logic [PLEN-1:0] map_q[RNUM], rat_q[RNUM], map_next[RNUM], rat_next[RNUM];
  logic [PNUM-1:0] free_q, free_next, free_after_commit;
  logic allocation_found[RenameWidth];
  logic [PLEN-1:0] allocation_index[RenameWidth];
  logic [CheckpointEntries-1:0] checkpoint_available, checkpoint_live;
  logic checkpoint_found[RenameWidth], checkpoint_allocate_valid[RenameWidth];
  logic [CheckpointBits-1:0] checkpoint_index[RenameWidth], checkpoint_allocate_id[RenameWidth];
  logic [PLEN-1:0] checkpoint_allocate_map[RenameWidth][RNUM];
  logic [PNUM-1:0] checkpoint_allocate_free[RenameWidth];
  logic checkpoint_restore_hit;
  logic [PLEN-1:0] checkpoint_restore_map[RNUM];
  logic [PNUM-1:0] checkpoint_restore_free;
  int allocation_rank;
  int checkpoint_rank;
  logic destination_needed[RenameWidth], checkpoint_needed[RenameWidth];
  int chosen;
  int checkpoint_chosen;
  logic pmu_pending;
  logic pmu_checkpoint_full /* verilator public_flat_rd */;
  logic pmu_checkpoint_stall /* verilator public_flat_rd */;
  logic pmu_recovery_fence /* verilator public_flat_rd */;
  logic [rapt_pkg::index_bits(CheckpointEntries+1)-1:0]
      pmu_checkpoint_occupancy /* verilator public_flat_rd */;
  // Match the ROU enqueue-ready probe: work already renamed, not RNQ input.
  assign pmu_pending = rnu_rou.valid[0];
  assign pmu_checkpoint_full = &checkpoint_live;
  assign pmu_recovery_fence = recovery.pending;
  assign pmu_checkpoint_occupancy = CheckpointOccupancyBits'(
      $countones(checkpoint_live));
  rapt_rank_select #(
      .Entries  (PNUM),
      .NumSelect(RenameWidth),
      .IndexBits(PLEN)
  ) allocator (
      .available(free_q),
      .found(allocation_found),
      .index(allocation_index)
  );
  rapt_rank_select #(
      .Entries  (CheckpointEntries),
      .NumSelect(RenameWidth),
      .IndexBits(CheckpointBits)
  ) checkpoint_allocator (
      .available(checkpoint_available),
      .found(checkpoint_found),
      .index(checkpoint_index)
  );
  rapt_rename_checkpoint #(
      .Entries(CheckpointEntries),
      .RenameWidth(RenameWidth),
      .ResolvePorts(ResolvePorts),
      .MapEntries(RNUM),
      .PhysRegs(PNUM),
      .MapBits(PLEN),
      .CheckpointBits(CheckpointBits)
  ) checkpoints (
      .clock(clock),
      .reset(reset),
      .flush(cmu_bcast.flush_pipe),
      .available(checkpoint_available),
      .allocate_valid(checkpoint_allocate_valid),
      .allocate_id(checkpoint_allocate_id),
      .allocate_map(checkpoint_allocate_map),
      .allocate_free(checkpoint_allocate_free),
      .release_valid(checkpoint_release.valid),
      .release_id(checkpoint_release.checkpoint),
      .restore_valid(recovery.redirect_valid && recovery.checkpoint_valid),
      .restore_id(recovery.checkpoint),
      .restore_hit(checkpoint_restore_hit),
      .restore_map(checkpoint_restore_map),
      .restore_free(checkpoint_restore_free),
      .live(checkpoint_live)
  );
  if (!(idu_rnu.Width == DecodeWidth && rnu_rou.Width == RenameWidth)) begin : g_invalid_config_0
    $error("Invalid rapt_rnu configuration");
  end
  if (!(rou_cmu.Width == CommitWidth)) begin : g_invalid_config_1
    $error("Invalid rapt_rnu configuration");
  end
  if (!(PNUM > RNUM && RenameWidth > 0 && CheckpointEntries > 0)) begin : g_invalid_config_2
    $error("Invalid rapt_rnu configuration");
  end
  if (!(checkpoint_release.Ports == ResolvePorts)) begin : g_invalid_config_3
    $error("Invalid rapt_rnu configuration");
  end
  if (!(rnu_rou.CheckpointBits == CheckpointBits)) begin : g_invalid_config_4
    $error("Invalid rapt_rnu configuration");
  end
  if (!(recovery.CheckpointBits == CheckpointBits)) begin : g_invalid_config_5
    $error("Invalid rapt_rnu configuration");
  end
  for (genvar s = 0; s < DecodeWidth; s++) assign decoded[s] = idu_rnu.slot[s];
  rapt_stream_queue #(
      .ItemT(decoded_t),
      .Depth(RIQ_SIZE),
      .InWidth(DecodeWidth),
      .OutWidth(RenameWidth)
  ) rnq (
      .clock(clock),
      .reset(reset),
      .flush(cmu_bcast.flush_pipe || recovery.pending),
      .in_data(decoded),
      .in_valid(idu_rnu.valid),
      .in_ready(idu_rnu.ready),
      .out_data(candidate),
      .out_valid(candidate_valid),
      .out_ready(candidate_ready),
      .occupancy(decoded_count)
  );
  rapt_stream_queue #(
      .ItemT(renamed_t),
      .Depth(2 * RenameWidth),
      .InWidth(RenameWidth),
      .OutWidth(RenameWidth)
  ) rename_pipe (
      .clock(clock),
      .reset(reset),
      .flush(cmu_bcast.flush_pipe || recovery.pending),
      .in_data(renamed),
      .in_valid(renamed_valid),
      .in_ready(renamed_ready),
      .out_data(buffered),
      .out_valid(rnu_rou.valid),
      .out_ready(rnu_rou.ready),
      .occupancy(renamed_count)
  );
  for (genvar s = 0; s < RenameWidth; s++) begin
    always_comb begin
      rnu_rou.slot[s] = '0;
      rnu_rou.slot[s].uop = buffered[s].uop;
      rnu_rou.slot[s].op1 = buffered[s].op1;
      rnu_rou.slot[s].op2 = buffered[s].op2;
      rnu_rou.slot[s].pr1 = buffered[s].pr1;
      rnu_rou.slot[s].pr2 = buffered[s].pr2;
      rnu_rou.slot[s].prd = buffered[s].prd;
      rnu_rou.slot[s].prs = buffered[s].prs;
    end
    assign rnu_rou.checkpoint_valid[s] = buffered[s].checkpoint_valid;
    assign rnu_rou.checkpoint[s] = buffered[s].checkpoint;
  end

  function automatic logic control_flow(input UopT u);
    return u.execute.branch.conditional || u.execute.branch.jump || u.execute.branch.indirect;
  endfunction

  for (genvar s = 0; s < RenameWidth; s++) begin : g_resource_demand
    assign destination_needed[s] = candidate[s].uop.rd != 0;
    assign checkpoint_needed[s] = control_flow(candidate[s].uop);
  end
  rapt_rename_admit #(
      .Width(RenameWidth)
  ) admission (
      .enable(!reset && !cmu_bcast.flush_pipe && !recovery.pending),
      .valid(candidate_valid),
      .downstream_ready(renamed_ready),
      .destination_needed(destination_needed),
      .checkpoint_needed(checkpoint_needed),
      .physical_found(allocation_found),
      .checkpoint_found(checkpoint_found),
      .ready(candidate_ready),
      .fire(renamed_valid),
      .checkpoint_stall(pmu_checkpoint_stall)
  );

  // Shared retirement view for next-state and every checkpoint snapshot.
  // Allocation still reads free_q, never these same-cycle releases.
  always_comb begin
    free_after_commit = free_q;
    for (int c = 0; c < CommitWidth; c++)
    if (rou_cmu.slot[c].valid && rou_cmu.slot[c].rd != 0)
      free_after_commit[rou_cmu.slot[c].prs] = 1'b1;
  end
  // Snapshots depend on accepted rename tags, not on another slot's snapshot.
  // Each generated map entry has one owner and youngest-accepted-writer priority.
  for (genvar s = 0; s < RenameWidth; s++) begin : g_checkpoint_snapshot
    always_comb begin
      checkpoint_allocate_free[s] = free_after_commit;
      for (int prior = 0; prior <= s; prior++)
      if (renamed_valid[prior] && candidate[prior].uop.rd != 0)
        checkpoint_allocate_free[s][renamed[prior].prd] = 1'b0;
      checkpoint_allocate_free[s][0] = 1'b0;
    end
    for (genvar r = 0; r < RNUM; r++) begin : g_map_entry
      if (r == 0) begin : g_zero
        assign checkpoint_allocate_map[s][r] = '0;
      end else begin : g_mapping
        always_comb begin
          checkpoint_allocate_map[s][r] = map_q[r];
          for (int prior = 0; prior <= s; prior++)
          if (renamed_valid[prior] && candidate[prior].uop.rd != 0
                && int'(candidate[prior].uop.rd) == r)
            checkpoint_allocate_map[s][r] = renamed[prior].prd;
        end
      end
    end
  end

  always_comb begin
    for (int r = 0; r < RNUM; r++) begin
      rat_next[r] = rat_q[r];
      map_next[r] = map_q[r];
      // Explicit per-entry youngest-writer priority, not addressed NBA writes.
      for (int c = 0; c < CommitWidth; c++)
      if (rou_cmu.slot[c].valid && rou_cmu.slot[c].rd != 0 && int'(rou_cmu.slot[c].rd) == r)
        rat_next[r] = rou_cmu.slot[c].prd;
    end
    free_next = free_after_commit;
    // Deliberately no same-cycle commit-to-allocation reuse: PRF retirement
    // and writeback arbitration must never race a newly allocated identity.
    allocation_rank = 0;
    checkpoint_rank = 0;
    chosen = 0;
    checkpoint_chosen = 0;
    for (int s = 0; s < RenameWidth; s++) begin
      chosen = int'(allocation_index[allocation_rank]);
      checkpoint_chosen = int'(checkpoint_index[checkpoint_rank]);
      renamed[s] = '0;
      renamed[s].uop = candidate[s].uop;
      renamed[s].op1 = candidate[s].op1;
      renamed[s].op2 = candidate[s].op2;
      // Read the cycle-start MAP once, then bypass only older slot tags.
      // Do not cascade a full RNUM-entry updated MAP through every slot.
      renamed[s].pr1 = map_q[candidate[s].rs1];
      renamed[s].pr2 = map_q[candidate[s].rs2];
      renamed[s].prs = map_q[candidate[s].uop.rd];
      for (int older = 0; older < s; older++) begin
        if (renamed_valid[older] && candidate[older].uop.rd != 0) begin
          if (candidate[s].rs1 == candidate[older].uop.rd) renamed[s].pr1 = renamed[older].prd;
          if (candidate[s].rs2 == candidate[older].uop.rd) renamed[s].pr2 = renamed[older].prd;
          if (candidate[s].uop.rd == candidate[older].uop.rd) renamed[s].prs = renamed[older].prd;
        end
      end
      if (renamed_valid[s] && candidate[s].uop.rd != 0) begin
        renamed[s].prd = PLEN'(chosen);
        allocation_rank++;
        free_next[chosen] = 1'b0;
        map_next[candidate[s].uop.rd] = PLEN'(chosen);
      end
      renamed[s].checkpoint_valid = renamed_valid[s] && control_flow(candidate[s].uop);
      renamed[s].checkpoint = CheckpointBits'(checkpoint_chosen);
      checkpoint_allocate_valid[s] = renamed[s].checkpoint_valid;
      checkpoint_allocate_id[s] = renamed[s].checkpoint;
      if (renamed[s].checkpoint_valid) checkpoint_rank++;

    end
    if (checkpoint_restore_hit) begin
      // Registers allocated after the branch become free; registers released
      // meanwhile by older retirement remain free as well.
      free_next = checkpoint_restore_free | free_next;
      for (int r = 0; r < RNUM; r++) map_next[r] = checkpoint_restore_map[r];
    end
    if (cmu_bcast.flush_pipe) begin
      // All speculative identities, including those buffered before ROB,
      // are discarded. Rebuild from the post-commit architectural map.
      free_next = '1;
      for (int r = 0; r < RNUM; r++) begin
        map_next[r] = rat_next[r];
        free_next[rat_next[r]] = 1'b0;
      end
    end
    free_next[0] = 1'b0;
    map_next[0]  = '0;
    rat_next[0]  = '0;
  end
  always_ff @(posedge clock) begin
    if (reset) begin
      free_q <= {PNUM{1'b1}} << RNUM;
      for (int r = 0; r < RNUM; r++) begin
        map_q[r] <= PLEN'(r);
        rat_q[r] <= PLEN'(r);
      end
    end else begin
      free_q <= free_next;
      for (int r = 0; r < RNUM; r++) begin
        map_q[r] <= map_next[r];
        rat_q[r] <= rat_next[r];
      end
    end
  end
  for (genvar r = 0; r < RNUM; r++) begin : g_snapshot
    assign map_snapshot[r] = map_q[r];
    assign rat_snapshot[r] = rat_q[r];
    `RAPT_SVA(clock, reset, RENAME_MAP_ALLOCATED, !free_q[map_q[r]])
  end
  `RAPT_SVA_IMPLY(clock, reset || cmu_bcast.flush_pipe, RENAME_RECOVERY_FENCES_ACCEPT,
                  recovery.pending, !candidate_valid[0] || !candidate_ready[0])
endmodule
