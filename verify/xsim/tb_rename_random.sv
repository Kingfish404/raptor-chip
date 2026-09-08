`include "rapt.svh"
`include "rapt_if.svh"
module tb_rename_random;
  import rapt_pkg::*;
  function automatic core_config_t test_config();
    core_config_t c = CoreConfig;
    c.phys_regs=c.arch_regs+6;
    c.rename_entries=7;
    return c;
  endfunction
  localparam core_config_t Cfg = test_config();
  typedef struct packed {
    uop_t uop;
    xlen_t op1,op2;
    phys_reg_t pr1,pr2,prd,prs;
    logic checkpoint_valid;
    branch_checkpoint_t checkpoint;
  } renamed_record_t;
  logic clock = 0, reset = 1, running = 1;
  always #5 clock = ~clock;
  idu_rnu_if idu_rnu ();
  rnu_rou_if rnu_rou ();
  rapt_recovery_if recovery ();
  checkpoint_release_if checkpoint_release ();
  rou_cmu_if commit_bus ();
  cmu_bcast_if cmu_bcast ();
  phys_reg_t map_snapshot[RNUMPkg], rat_snapshot[RNUMPkg];
  rapt_rnu #(
      .Cfg(Cfg),
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
  decoded_slot_t accepted[$], decoded;
  renamed_record_t output_model[$], pending_commit[$], expected, retired;
  phys_reg_t map_model[RNUMPkg], rat_model[RNUMPkg];
  logic [Cfg.phys_regs-1:0] free_model, available;
  logic [31:0] random_state = 32'h176adc05;
  int cycle = 0, sent = 0, renamed = 0, drained = 0, commits = 0, flushes = 0;
  int exhaustion = 0, waw = 0, zero_writes = 0, commit_flush = 0;
  int allocated, count;
  always @(posedge clock)
    if (!reset) begin
      cycle++;
      assert (dut.free_q == free_model)
      else $fatal(1, "free bitmap mismatch cycle=%0d", cycle);
      for (int r = 0; r < RNUMPkg; r++) begin
        assert (map_snapshot[r] == map_model[r])
        else $fatal(1, "MAP mismatch x%0d", r);
        assert (rat_snapshot[r] == rat_model[r])
        else $fatal(1, "RAT mismatch x%0d", r);
      end
      available=free_model; // allocation never reuses this cycle's releases
      count=0;
      for (int c = 0; c < CommitWidth; c++)
      if (commit_bus.slot[c].valid) begin
        count++;
        commits++;
        if (commit_bus.slot[c].rd != 0) begin
          assert (commit_bus.slot[c].prs == rat_model[commit_bus.slot[c].rd])
          else $fatal(1, "stale mapping did not form a WAW chain");
          rat_model[commit_bus.slot[c].rd]=commit_bus.slot[c].prd;
          free_model[commit_bus.slot[c].prs]=1;
        end
      end
      if (cmu_bcast.flush_pipe) begin
        flushes++;
        if (count > 0) commit_flush++;
        accepted.delete();
        output_model.delete();
        pending_commit.delete();
        free_model = '1;
        for (int r = 0; r < RNUMPkg; r++) begin
          map_model[r]=rat_model[r];
          free_model[rat_model[r]]=0;
        end
      end else begin
        for (int s = 0; s < DecodeWidth; s++)
        if (idu_rnu.valid[s] && idu_rnu.ready[s]) begin
          accepted.push_back(idu_rnu.slot[s]);
          sent++;
        end
        for (int s = 0; s < RenameWidth; s++)
        if (rnu_rou.valid[s] && rnu_rou.ready[s]) begin
          assert (output_model.size() > 0)
          else $fatal(1, "unallocated output");
          expected = output_model.pop_front();
          assert (rnu_rou.slot[s].uop==expected.uop
            && rnu_rou.slot[s].op1==expected.op1 && rnu_rou.slot[s].op2==expected.op2
            && rnu_rou.slot[s].pr1==expected.pr1 && rnu_rou.slot[s].pr2==expected.pr2
            && rnu_rou.slot[s].prd==expected.prd && rnu_rou.slot[s].prs==expected.prs
            && rnu_rou.checkpoint_valid[s]==expected.checkpoint_valid
            && rnu_rou.checkpoint[s]==expected.checkpoint)
          else $fatal(1, "renamed output lost/reordered/corrupted");
          pending_commit.push_back(expected);
          drained++;
        end
        if (dut.candidate_valid[0] && !dut.candidate_ready[0] && available == '0) exhaustion++;
        for (int s = 0; s < RenameWidth; s++)
        if (dut.renamed_valid[s]) begin
          assert (accepted.size() > 0)
          else $fatal(1, "rename before input acceptance");
          decoded=accepted.pop_front();
          expected='0;
          expected.uop=decoded.uop;
          expected.op1=decoded.op1;
          expected.op2=decoded.op2;
          expected.pr1=map_model[decoded.rs1];
          expected.pr2=map_model[decoded.rs2];
          expected.prs=map_model[decoded.uop.rd];
          if (decoded.uop.rd != 0) begin
            allocated = -1;
            for (int p = Cfg.phys_regs - 1; p > 0; p--) if (available[p]) allocated = p;
            assert (allocated > 0)
            else $fatal(1, "allocation from empty free set");
            expected.prd=phys_reg_t'(allocated);
            available[allocated]=0;
            free_model[allocated]=0;
            map_model[decoded.uop.rd]=expected.prd;
            for (int older = 0; older < s; older++)
            if (dut.renamed_valid[older] && dut.candidate[older].uop.rd == decoded.uop.rd) waw++;
          end else zero_writes++;
          assert (dut.renamed[s] == expected)
          else $fatal(1, "rename RAW/WAW/tag/value mismatch");
          output_model.push_back(expected);
          renamed++;
        end
      end
    end
  always @(negedge clock)
    if (!reset && running) begin
      random_state={random_state[30:0],random_state[31]^random_state[21]^random_state[1]^random_state[0]};
      cmu_bcast.flush_pipe=cycle%83==82;
      for (int s = 0; s < RenameWidth; s++)
      rnu_rou.ready[s] = s < int'(random_state[7:0]) % (RenameWidth + 1);
      commit_bus.slot = '{default: '0};
      for (int c = 0; c < CommitWidth; c++)
      if (c<int'(random_state[15:8])%(CommitWidth+1) && pending_commit.size()>0 && cycle%19>5) begin
        retired=pending_commit.pop_front();
        commit_bus.slot[c].valid=1;
        commit_bus.slot[c].rd=retired.uop.rd;
        commit_bus.slot[c].prd=retired.prd;
        commit_bus.slot[c].prs=retired.prs;
      end
      for (int s = 0; s < DecodeWidth; s++) begin
        automatic int id = sent + s;
        idu_rnu.valid[s]=1;
        idu_rnu.slot[s]='0;
        idu_rnu.slot[s].uop.pc=xlen_t'(64'h1234567800000000) + xlen_t'(id*4);
        idu_rnu.slot[s].uop.rd=id%9==0 ? '0 : arch_reg_t'(id/2%7+1);
        idu_rnu.slot[s].rs1=arch_reg_t'(id*3%8);
        idu_rnu.slot[s].rs2=arch_reg_t'((id+7)%8);
        // RV64 must transport nontrivial upper halves, not only zero/sign extension.
        idu_rnu.slot[s].op1=xlen_t'(64'ha5c39e1700000000) ^ xlen_t'(id);
        idu_rnu.slot[s].op2=xlen_t'(64'h3e7a82d100000000) ^ xlen_t'(~id);
      end
    end
  initial begin
    void'($value$plusargs("SEED=%d", random_state));
    assert (random_state != 0)
    else $fatal(1, "SEED must be nonzero for the LFSR");
    idu_rnu.valid='{default:0};
    idu_rnu.slot='{default:'0};
    rnu_rou.ready='{default:0};
    commit_bus.slot='{default:'0};
    cmu_bcast.flush_pipe=0;
    recovery.pending=0;
    recovery.redirect_valid=0;
    recovery.owner='0;
    recovery.generation='0;
    recovery.target='0;
    recovery.checkpoint_valid=0;
    recovery.checkpoint='0;
    checkpoint_release.valid='{default:0};
    checkpoint_release.checkpoint='{default:'0};
    free_model='1;
    for (int r = 0; r < RNUMPkg; r++) begin
      map_model[r]=phys_reg_t'(r);
      rat_model[r]=phys_reg_t'(r);
      free_model[r]=0;
    end
    repeat (3) @(negedge clock);
    #1;
    reset = 0;
    repeat (5000) @(negedge clock);
    #1;
    running=0;
    cmu_bcast.flush_pipe=1;
    idu_rnu.valid='{default:0};
    commit_bus.slot='{default:'0};
    @(negedge clock);
    #1;
    assert ($countones(dut.free_q) == 6)
    else $fatal(1, "flush leaked registers");
    assert (renamed>1000 && drained>1000 && commits>1000 && waw>0 && exhaustion>0 && zero_writes>0 && commit_flush>0)
    else $fatal(1, "missing random coverage");
    $display(
        "PASS: XLEN=%0d D/R/C=%0d/%0d/%0d randomized rename %0d uops, %0d commits, %0d WAW, %0d exhaustion cycles, %0d commit+flush",
        $bits(xlen_t), DecodeWidth, RenameWidth, CommitWidth, renamed, commits, waw, exhaustion,
        commit_flush);
    $finish;
  end
  initial begin
    #60000;
    $fatal(1, "random rename timeout");
  end
endmodule
