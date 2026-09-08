// ---- tb_rename_checkpoint ----
`include "rapt.svh"

module tb_rename_checkpoint;
  localparam int Entries = 4;
  localparam int Width = 3;
  localparam int Ports = 2;
  localparam int MapEntries = 4;
  localparam int PhysRegs = 8;
  localparam int MapBits = 3;
  localparam int CheckpointBits = 2;

  logic clock = 0, reset = 1, flush = 0;
  always #5 clock = ~clock;
  logic [Entries-1:0] available, live;
  logic allocate_valid[Width];
  logic [CheckpointBits-1:0] allocate_id[Width];
  logic [MapBits-1:0] allocate_map[Width][MapEntries];
  logic [PhysRegs-1:0] allocate_free[Width];
  logic release_valid[Ports];
  logic [CheckpointBits-1:0] release_id[Ports];
  logic restore_valid, restore_hit;
  logic [CheckpointBits-1:0] restore_id;
  logic [MapBits-1:0] restore_map[MapEntries];
  logic [PhysRegs-1:0] restore_free;

  rapt_rename_checkpoint #(
      .Entries(Entries),
      .RenameWidth(Width),
      .ResolvePorts(Ports),
      .MapEntries(MapEntries),
      .PhysRegs(PhysRegs),
      .MapBits(MapBits),
      .CheckpointBits(CheckpointBits)
  ) dut (
      .*
  );

  task automatic idle;
    allocate_valid = '{default: 0};
    allocate_id = '{default: '0};
    allocate_map = '{default: '0};
    allocate_free = '{default: '0};
    release_valid = '{default: 0};
    release_id = '{default: '0};
    restore_valid = 0;
    restore_id = '0;
  endtask

  task automatic set_snapshot(input int slot, input int seed);
    allocate_free[slot] = 8'(8'h80 >> (seed % 4));
    for (int r = 0; r < MapEntries; r++) allocate_map[slot][r] = MapBits'(seed + r);
  endtask

  task automatic tick;
    @(posedge clock);
    #1;
  endtask

  initial begin
    idle();
    tick();
    tick();
    reset = 0;

    // A then B in one rename group: B records A as an ancestor.
    @(negedge clock);
    allocate_valid[0] = 1;
    allocate_id[0] = 0;
    set_snapshot(0, 1);
    allocate_valid[1] = 1;
    allocate_id[1] = 1;
    set_snapshot(1, 2);
    tick();
    assert (live == 4'b0011 && dut.older_q[1][0])
    else $fatal(1, "same-group checkpoint ancestry");

    // A resolves correctly. Clearing its bit from every ancestry mask is what
    // permits safe numeric-ID reuse while B remains unresolved.
    @(negedge clock);
    idle();
    release_valid[0] = 1;
    release_id[0] = 0;
    tick();
    assert (live == 4'b0010 && !dut.older_q[1][0])
    else $fatal(1, "correct resolution did not clear ancestry");

    // C reuses ID 0 and is younger than B. Restoring C must preserve B: the
    // stale A incarnation must not make B appear younger than C.
    @(negedge clock);
    idle();
    allocate_valid[0] = 1;
    allocate_id[0] = 0;
    set_snapshot(0, 5);
    tick();
    assert (live == 4'b0011 && dut.older_q[0][1] && !dut.older_q[1][0])
    else $fatal(1, "checkpoint ID reuse ordering");
    @(negedge clock);
    idle();
    restore_valid = 1;
    restore_id = 0;
    #1;
    assert (restore_hit && restore_free == (8'(8'h80 >> 1)))
    else $fatal(1, "restore snapshot selection");
    for (int r = 0; r < MapEntries; r++)
    assert (restore_map[r] == MapBits'(5 + r))
    else $fatal(1, "restore MAP payload");
    tick();
    assert (live == 4'b0010)
    else $fatal(1, "ABA-safe restore killed older checkpoint");
    // A registered ROU transaction may present the same restore until flush;
    // replay is intentionally idempotent after the checkpoint is consumed.
    assert (!restore_hit)
    else $fatal(1, "consumed restore remained live");
    tick();
    assert (live == 4'b0010)
    else $fatal(1, "restore replay changed live set");

    // D and E are allocated together. E is a descendant of D and both are
    // removed, while the older B checkpoint survives.
    @(negedge clock);
    idle();
    allocate_valid[0] = 1;
    allocate_id[0] = 0;
    set_snapshot(0, 3);
    allocate_valid[1] = 1;
    allocate_id[1] = 2;
    set_snapshot(1, 4);
    tick();
    assert (live == 4'b0111 && dut.older_q[2][0])
    else $fatal(1, "descendant mask");
    @(negedge clock);
    idle();
    restore_valid = 1;
    restore_id = 0;
    tick();
    assert (live == 4'b0010)
    else $fatal(1, "restore did not remove descendants");

    // Fill all remaining entries and prove that capacity is represented as an
    // explicit resource, then verify full-flush lifetime termination.
    @(negedge clock);
    idle();
    allocate_valid = '{default: 1};
    allocate_id[0] = 0;
    allocate_id[1] = 2;
    allocate_id[2] = 3;
    for (int s = 0; s < Width; s++) set_snapshot(s, 1 + s);
    tick();
    assert (live == '1 && available == '0)
    else $fatal(1, "checkpoint capacity accounting");
    @(negedge clock);
    idle();
    flush = 1;
    tick();
    assert (live == '0 && available == '1)
    else $fatal(1, "flush did not clear checkpoints");

    $display(
        "PASS: checkpoint ancestry, ABA-safe reuse, descendant restore, replay, capacity, flush");
    $finish;
  end

  initial begin
    #5000;
    $fatal(1, "rename checkpoint timeout");
  end
endmodule


// ---- tb_rename_checkpoint_pipeline ----
`include "rapt.svh"
`include "rapt_if.svh"

module tb_rename_checkpoint_pipeline;
  import rapt_pkg::*;
  localparam int Width = 2;

  typedef struct packed {
    phys_reg_t prd, prs;
    arch_reg_t rd;
    logic checkpoint_valid;
    branch_checkpoint_t checkpoint;
  } output_t;

  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  idu_rnu_if idu_rnu ();
  rnu_rou_if rnu_rou ();
  rapt_recovery_if recovery ();
  checkpoint_release_if checkpoint_release ();
  rou_cmu_if commit_bus ();
  cmu_bcast_if cmu_bcast ();
  phys_reg_t map_snapshot[RNUMPkg], rat_snapshot[RNUMPkg];
  output_t observed[$];

  rapt_rnu dut (
      .clock,
      .reset,
      .idu_rnu,
      .rnu_rou,
      .recovery,
      .checkpoint_release,
      .rou_cmu(commit_bus),
      .cmu_bcast,
      .map_snapshot,
      .rat_snapshot
  );

  always @(posedge clock)
    if (!reset)
      for (int s = 0; s < Width; s++)
        if (rnu_rou.valid[s] && rnu_rou.ready[s]) begin
          assert (rnu_rou.slot[s].uop.pc ==
                xlen_t'(64'h1234567800000000) + xlen_t'(rnu_rou.slot[s].uop.rd) * 4
                && rnu_rou.slot[s].op1 == xlen_t'(64'ha5c39e1700000000)
                && rnu_rou.slot[s].op2 == xlen_t'(64'h3e7a82d100000000))
          else $fatal(1, "checkpoint pipeline payload truncated/corrupted");
          observed.push_back('{rnu_rou.slot[s].prd, rnu_rou.slot[s].prs, rnu_rou.slot[s].uop.rd,
                             rnu_rou.checkpoint_valid[s], rnu_rou.checkpoint[s]});
        end

  task automatic clear_decode;
    idu_rnu.valid = '{default: 0};
    idu_rnu.slot = '{default: '0};
  endtask

  task automatic send_group(input int count, input arch_reg_t rd0, input logic branch0,
                            input arch_reg_t rd1, input logic branch1);
    @(negedge clock);
    clear_decode();
    idu_rnu.valid[0] = count > 0;
    idu_rnu.slot[0].uop.rd = rd0;
    idu_rnu.slot[0].uop.execute.branch.conditional = branch0;
    idu_rnu.valid[1] = count > 1;
    idu_rnu.slot[1].uop.rd = rd1;
    idu_rnu.slot[1].uop.execute.branch.conditional = branch1;
    for (int s = 0; s < Width; s++) begin
      idu_rnu.slot[s].uop.pc = xlen_t'(64'h1234567800000000)
                             + xlen_t'(idu_rnu.slot[s].uop.rd) * 4;
      idu_rnu.slot[s].op1 = xlen_t'(64'ha5c39e1700000000);
      idu_rnu.slot[s].op2 = xlen_t'(64'h3e7a82d100000000);
    end
    do @(posedge clock); while (!idu_rnu.ready[0] || (count > 1 && !idu_rnu.ready[1]));
    @(negedge clock);
    assert (!rnu_rou.empty)
    else $fatal(1, "accepted decode was hidden from pipeline-empty indication");
    clear_decode();
  endtask

  task automatic wait_observed(input int count);
    while (observed.size() < count) @(negedge clock);
  endtask

  initial begin
    output_t older, branch, younger, reused;
    phys_reg_t queued_prd;
    clear_decode();
    rnu_rou.ready = '{default: 1};
    commit_bus.slot = '{default: '0};
    cmu_bcast.flush_pipe = 0;
    recovery.pending = 0;
    recovery.redirect_valid = 0;
    recovery.owner = '0;
    recovery.generation = '0;
    recovery.target = '0;
    recovery.checkpoint_valid = 0;
    recovery.checkpoint = '0;
    checkpoint_release.valid = '{default: 0};
    checkpoint_release.checkpoint = '{default: '0};
    repeat (3) @(negedge clock);
    reset = 0;

    // An older x3 writer makes architectural p3 stale but not free until that
    // instruction commits after the branch snapshot is taken.
    send_group(1, arch_reg_t'(3), 0, '0, 0);
    wait_observed(1);
    older = observed.pop_front();
    assert (!older.checkpoint_valid && older.prs == phys_reg_t'(3));

    // Slot 0 is the branch and writes x1; slot 1 is younger and writes x2.
    // The branch checkpoint must capture only the post-slot-0 state.
    send_group(2, arch_reg_t'(1), 1, arch_reg_t'(2), 0);
    wait_observed(2);
    branch = observed.pop_front();
    younger = observed.pop_front();
    assert (branch.checkpoint_valid && !younger.checkpoint_valid)
    else $fatal(1, "checkpoint did not follow control-flow slot");
    assert (map_snapshot[1] == branch.prd && map_snapshot[2] == younger.prd);

    // Put additional wrong-path rename work in the output queue. It updates
    // speculative MAP now, but must disappear with the recovery transaction.
    rnu_rou.ready = '{default: 0};
    send_group(1, arch_reg_t'(4), 0, '0, 0);
    wait (rnu_rou.valid[0]);
    queued_prd = map_snapshot[4];
    assert (queued_prd != phys_reg_t'(4));

    @(negedge clock);
    recovery.pending = 1;
    recovery.redirect_valid = 1;
    recovery.checkpoint_valid = 1;
    recovery.checkpoint = branch.checkpoint;
    commit_bus.slot[0].valid = 1;
    commit_bus.slot[0].rd = older.rd;
    commit_bus.slot[0].prd = older.prd;
    commit_bus.slot[0].prs = older.prs;
    @(posedge clock);
    #1;
    assert (dut.pmu_recovery_fence)
    else $fatal(1, "recovery PMU fence probe");
    assert (map_snapshot[1] == branch.prd && map_snapshot[2] == phys_reg_t'(2)
            && map_snapshot[3] == older.prd && map_snapshot[4] == phys_reg_t'(4))
    else $fatal(1, "post-branch MAP restore failed");
    assert (dut.free_q[younger.prd] && dut.free_q[queued_prd]
            && dut.free_q[older.prs] && !dut.free_q[branch.prd])
    else $fatal(1, "restore free-set union failed");
    assert (!rnu_rou.valid[0] && !idu_rnu.ready[0])
    else $fatal(1, "recovery did not flush/fence rename queues");
    assert (rat_snapshot[3] == older.prd)
    else $fatal(1, "same-cycle older commit did not update RAT");

    // Redirect is a pulse; pending must keep fencing both queues afterwards,
    // even when the downstream is ready and the upstream continues offering.
    @(negedge clock);
    recovery.redirect_valid = 0;
    commit_bus.slot = '{default: '0};
    rnu_rou.ready = '{default: 1};
    idu_rnu.valid = '{default: 1};
    for (int s = 0; s < Width; s++) idu_rnu.slot[s].uop.rd = arch_reg_t'(5);
    repeat (4) begin
      @(posedge clock);
      #1;
      for (int s = 0; s < Width; s++) begin
        assert (!idu_rnu.ready[s] && !rnu_rou.valid[s])
        else $fatal(1, "pending fence depended on redirect pulse");
      end
      assert (map_snapshot[1] == branch.prd && map_snapshot[5] == phys_reg_t'(5)
              && observed.size() == 0)
      else $fatal(1, "wrong-path work escaped or mutated MAP while pending");
    end

    // The precise retirement flush still ends this conservative recovery
    // stage and rebuilds MAP from RAT.
    @(negedge clock);
    clear_decode();
    recovery.pending = 0;
    recovery.redirect_valid = 0;
    recovery.checkpoint_valid = 0;
    commit_bus.slot = '{default: '0};
    cmu_bcast.flush_pipe = 1;
    @(posedge clock);
    #1;
    cmu_bcast.flush_pipe = 0;
    assert (map_snapshot[3] == older.prd && map_snapshot[1] == phys_reg_t'(1));

    // Two unresolved branches consume both configured checkpoints. A third is
    // retained at the ordered rename head until one correct resolution frees
    // capacity; it then reuses the released ID without an A/B-specific path.
    rnu_rou.ready = '{default: 1};
    send_group(1, '0, 1, '0, 0);
    send_group(1, '0, 1, '0, 0);
    wait_observed(2);
    branch = observed.pop_front();
    younger = observed.pop_front();
    assert (branch.checkpoint_valid && younger.checkpoint_valid
            && branch.checkpoint != younger.checkpoint);
    send_group(1, '0, 1, '0, 0);
    wait (dut.candidate_valid[0] && !dut.candidate_ready[0]);
    assert (dut.checkpoint_live == '1 && dut.checkpoint_available == '0)
    else $fatal(1, "checkpoint exhaustion did not backpressure rename");
    assert (dut.pmu_checkpoint_full && dut.pmu_checkpoint_stall
            && dut.pmu_checkpoint_occupancy == 2)
    else $fatal(1, "checkpoint PMU pressure probes");
    @(negedge clock);
    checkpoint_release.valid[0] = 1;
    checkpoint_release.checkpoint[0] = branch.checkpoint;
    @(posedge clock);
    #1;
    @(negedge clock);
    checkpoint_release.valid = '{default: 0};
    wait_observed(1);
    reused = observed.pop_front();
    assert (reused.checkpoint_valid && reused.checkpoint == branch.checkpoint)
    else $fatal(1, "released checkpoint was not safely reused");

    $display(
        "PASS: XLEN=%0d RNU checkpoint snapshots, free union, persistent queue fence, payload, capacity backpressure, reuse",
        $bits(xlen_t));
    $finish;
  end

  initial begin
    #10000;
    $fatal(1, "rename checkpoint pipeline timeout");
  end
endmodule
