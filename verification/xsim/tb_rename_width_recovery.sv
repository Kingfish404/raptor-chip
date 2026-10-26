`include "rapt.svh"
`include "rapt_if.svh"
module tb_rename_width_recovery;
  import rapt_pkg::*;
  function automatic core_config_t test_config();
    core_config_t c = CoreConfig;
    c.phys_regs = c.arch_regs + 6;
    return c;
  endfunction
  localparam core_config_t Cfg = test_config();
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  idu_rnu_if idu_rnu ();
  rnu_rou_if rnu_rou ();
  rapt_recovery_if recovery ();
  checkpoint_release_if checkpoint_release ();
  rou_cmu_if commit_bus ();
  cmu_bcast_if cmu_bcast ();
  phys_reg_t map_snapshot[RNUMPkg], rat_snapshot[RNUMPkg];
  rapt_rnu #(
      .Cfg (Cfg),
      .PLEN($bits(phys_reg_t))
  ) dut (
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
  typedef struct packed {
    phys_reg_t prd, prs;
    arch_reg_t rd;
  } record_t;
  record_t observed[$], retired_record;
  phys_reg_t model_map[RNUMPkg], model_rat[RNUMPkg];
  int renamed = 0, drained = 0, sent = 0;
  logic exhausted = 0;
  always @(posedge clock)
    if (!reset) begin
      for (int c = 0; c < CommitWidth; c++)
      if (commit_bus.slot[c].valid) model_rat[commit_bus.slot[c].rd] = commit_bus.slot[c].prd;
      if (cmu_bcast.flush_pipe) begin
        for (int r = 0; r < RNUMPkg; r++) model_map[r] = model_rat[r];
        observed.delete();
      end else begin
        for (int s = 0; s < RenameWidth; s++)
        if (dut.renamed_valid[s]) begin
          assert (dut.renamed[s].pr1 == model_map[1] && dut.renamed[s].pr2 == 0)
          else $fatal(1, "intra-group RAW bypass");
          if (dut.renamed[s].uop.rd != 0) begin
            assert (dut.renamed[s].prs == model_map[1] && dut.renamed[s].prd != 0)
            else $fatal(1, "intra-group WAW stale destination");
            model_map[1] = dut.renamed[s].prd;
          end else
            assert (dut.renamed[s].prd == 0)
            else $fatal(1, "x0 allocated");
          renamed++;
        end
        for (int s = 0; s < RenameWidth; s++)
        if (rnu_rou.valid[s] && rnu_rou.ready[s]) begin
          observed.push_back('{rnu_rou.slot[s].prd, rnu_rou.slot[s].prs, rnu_rou.slot[s].uop.rd});
          drained++;
        end
      end
      if (dut.candidate_valid[0] && !dut.candidate_ready[0] && $countones(dut.free_q) == 0)
        exhausted = 1;
    end
  initial begin
    idu_rnu.valid = '{default: 0};
    idu_rnu.slot = '{default: '0};
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
    for (int r = 0; r < RNUMPkg; r++) begin
      model_map[r] = phys_reg_t'(r);
      model_rat[r] = phys_reg_t'(r);
    end
    repeat (3) @(negedge clock);
    reset = 0;
    // Four x1 read-modify-writes in one group. All resources are consumed
    // without any commit; the next writer must stall, never get tag zero.
    while (sent < 12) begin
      for (int s = 0; s < DecodeWidth; s++) begin
        idu_rnu.valid[s] = sent + s < 12;
        idu_rnu.slot[s] = '0;
        idu_rnu.slot[s].rs1 = 1;
        idu_rnu.slot[s].uop.rd = 1;
      end
      @(posedge clock);
      for (int s = 0; s < DecodeWidth; s++) if (idu_rnu.valid[s] && idu_rnu.ready[s]) sent++;
      @(negedge clock);
    end
    idu_rnu.valid = '{default: 0};
    wait (exhausted && observed.size() == 6);
    @(negedge clock);
    // Several same-register commits and flush on the SAME edge. The youngest
    // committed physical identity is retained; buffered speculative ones free.
    for (int c = 0; c < CommitWidth; c++) begin
      retired_record = observed.pop_front();
      commit_bus.slot[c].valid = 1;
      commit_bus.slot[c].rd = retired_record.rd;
      commit_bus.slot[c].prd = retired_record.prd;
      commit_bus.slot[c].prs = retired_record.prs;
    end
    cmu_bcast.flush_pipe = 1;
    @(negedge clock);
    cmu_bcast.flush_pipe = 0;
    commit_bus.slot = '{default: '0};
    assert ($countones(dut.free_q) == 6)
    else $fatal(1, "flush leaked allocated identities");
    for (int r = 0; r < RNUMPkg; r++)
    assert (map_snapshot[r] == model_rat[r] && rat_snapshot[r] == model_rat[r])
    else $fatal(1, "post-commit recovery priority");
    repeat (3) @(negedge clock);
    assert (renamed == 6 && drained == 6)
    else $fatal(1, "squashed work escaped");
    // x0 destinations use no physical register, but still see the restored x1.
    for (int s = 0; s < DecodeWidth; s++) begin
      idu_rnu.valid[s] = 1;
      idu_rnu.slot[s].uop.rd = 0;
    end
    @(negedge clock);
    idu_rnu.valid = '{default: 0};
    wait (drained == 6 + DecodeWidth);
    @(negedge clock);
    assert ($countones(dut.free_q) == 6 && map_snapshot[0] == 0)
    else $fatal(1, "x0 changed allocator state");
    $display("PASS: four-slot RAW/WAW, exhaustion, flush+multi-commit recovery, x0");
    $finish;
  end
  initial begin
    #10000;
    $fatal(1, "rename timeout sent=%0d renamed=%0d drained=%0d", sent, renamed, drained);
  end
endmodule
