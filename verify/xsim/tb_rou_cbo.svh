// Exercise real ROU/CMU retirement: CBO metadata may only cause maintenance
// after a successful, current-generation completion and older SQ drain.
task automatic expect_cbo_maintenance;
  rapt_pkg::uop_t u, branch_u;
  logic [XLEN-1:0] va;
  for (int op = 0; op < 3; op++) begin
    for (int fault = 0; fault < 2; fault++) begin
      reset_dut();
      va = XLEN'('h45678abd);
      u = make_alu_uop(XLEN'('h80002000), (32'(op) << 20) | 32'h0000a00f, '0);
      u.execute.sys.fence = 1;
      dispatch_one(u, '0, '0, RobW'(0));
      tb_sq_empty = 0;
      // Rejected old generation must neither complete nor replace the VA.
      force_stale_generation = 1;
      exu_rou.dest = 0; exu_rou.npc = u.pnpc;
      exu_rou.tval = ~va; exu_rou.valid = 1;
      tick(1); clear_writebacks(); force_stale_generation = 0;
      check(!commit_fire && !cmu_bcast.cbo_inval && !cmu_bcast.fence_time,
            "stale CBO completion caused maintenance");
      exu_ioq_bcast.dest = 0; exu_ioq_bcast.npc = u.pnpc;
      exu_ioq_bcast.tval = va; exu_ioq_bcast.wen = 0;
      exu_ioq_bcast.trap = 1'(fault);
      exu_ioq_bcast.cause = XLEN'(`RAPT_CAUSE_STORE_PAGE_FAULT);
      exu_ioq_bcast.valid = 1;
      tick(1); clear_writebacks();
      // Check actual fault retirement, not only the stalled ROB entry.
      if (fault != 0) begin
        tb_sq_empty = 1; #1;
        check(commit_fire && rou_cmu.slot[0].trap && rou_cmu.flush_pipe,
              "faulting CBO did not reach trap retirement");
        check(!cmu_bcast.cbo_inval && !cmu_bcast.fence_time,
              "faulting CBO caused maintenance");
      end else begin
        repeat (3) begin
          check(!commit_fire && !cmu_bcast.cbo_inval && !cmu_bcast.fence_time,
                "CBO bypassed older SQ entries");
          tick(1);
        end
        tb_sq_empty = 1; #1;
        check(commit_fire && rou_cmu.flush_pipe, "CBO failed to retire after SQ drain");
        check(!cmu_bcast.fence_time && !cmu_bcast.fence_i, "CBO flushed cache/TLB globally");
        check(cmu_bcast.cbo_inval == (op != 1), "INVAL/FLUSH/CLEAN maintenance kind wrong");
        if (op != 1)
          check(cmu_bcast.cbo_block == va[11:6], "CBO lost accepted completion VA");
      end
      tick(1); tick(3);
      check(!cmu_bcast.cbo_inval && !cmu_bcast.fence_time, "CBO maintenance repeated after retirement");
    end
  end
  reset_dut();
  branch_u = make_branch_uop(XLEN'('h80003000), 32'h00000863);
  u = make_alu_uop(XLEN'('h80003004), 32'h0020a00f, '0);
  u.execute.sys.fence = 1;
  dispatch_one(branch_u, '0, '0, RobW'(0));
  // A serializing CBO stays queued until the older branch resolves. It
  // must be discarded by mispredict recovery before it can execute.
  rnu_rou.slot[0].uop = u;
  rnu_rou.checkpoint_valid[0] = 0;
  rnu_rou.valid[0] = 1;
  #1; check(rnu_rou.ready[0], "wrong-path CBO could not enter rename queue");
  tick(1); rnu_rou.valid[0] = 0; tick(1);
  check(!dispatch_valid[0] && !commit_fire && !cmu_bcast.cbo_inval,
        "younger CBO executed before unresolved branch");
  exu_rou.dest = 0; exu_rou.npc = XLEN'('h80003100);
  exu_rou.mispredict = 1; exu_rou.btaken = 1; exu_rou.valid = 1;
  tick(1); clear_writebacks();
  check(commit_fire && rou_cmu.flush_pipe && !cmu_bcast.cbo_inval,
        "wrong-path CBO initiated maintenance on branch retirement");
  tick(1); tick(4);
  check(!cmu_bcast.cbo_inval && !commit_fire, "wrong-path CBO survived flush");
  $display("PASS: CBO retirement RV%0d INVAL/CLEAN/FLUSH, SQ drain, fault, wrong path and stale generation", XLEN);
endtask
