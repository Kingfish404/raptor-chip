task automatic run_drain_handshake_tests;
  rapt_pkg::uop_t u;
  for (int kind = 0; kind < 5; kind++) begin
    for (int delayed = 0; delayed < 3; delayed++) begin
      reset_dut();
      memory_idle = delayed != 1;
      raw_writeback_idle = delayed != 2;
      tb_sq_empty = delayed != 0;
      u = make_fence_uop(kind == 0 ? 0 : 1);
      if (kind == 2) u.inst = 32'h8330000f;  // FENCE.TSO
      if (kind == 2 || kind == 3) u.execute.sys.kind = rapt_pkg::SYS_FENCE;
      if (kind == 3) u.inst = 32'h0100000f;  // PAUSE
      if (kind == 4) begin
        u.inst = 32'h12000073; // SFENCE.VMA carries both legacy decoder flags.
        u.execute.sys.kind = rapt_pkg::SYS_TRANSLATION;
        u.imm = 3;
        u.execute.sys.fence_i = 1;
      end
      dispatch_one(u, '0, '0, RobW'(0));
      writeback_alu_one(RobW'(0), XLEN'('h80004004));
      check(tb_writeback_drain && !commit_fire && !drain_done,
            "fence bypassed registered request acceptance");
      check(tb_writeback_clean == (kind == 0) && !tb_writeback_cbo,
            "ordering fence requested the wrong cache maintenance");
      repeat (8) begin
        tick(1);
        check(drain_active && !drain_done && !commit_fire,
              "fence ignored pending store, refill or write response");
        check(!cmu_bcast.fence_i && !cmu_bcast.fence_time,
              "cache maintenance preceded drain completion");
      end
      memory_idle = 1;
      raw_writeback_idle = 1;
      tb_sq_empty = 1;
      #1;
      check(!commit_fire && !drain_done, "raw idle fed through to retirement");
      tick(1);
      check(commit_fire && drain_done && !drain_active,
            "quiescent drain did not complete and retire");
      check(
          cmu_bcast.fence_i == (kind == 0 || (kind == 4 && `RAPT_SFENCE_KEEP_STATE < 2))
                && cmu_bcast.fence_time == (kind != 0),
          "successful fence lost its maintenance event");
      // Quiescence is a completed ordering point. Later independent activity
      // must not withdraw its registered completion before the retirement edge.
      memory_idle = 0;
      raw_writeback_idle = 0;
      #1;
      check(commit_fire && drain_done, "completed ordering point became live idle again");
      tick(1);
      check(!commit_fire && !tb_writeback_drain,
            "fence did not release its drain request after retirement");
      tick(1);
      check(!drain_done && !drain_active, "completion leaked into the next transaction");
    end
  end
  $display("PASS: ROU and registered drain fence integration XLEN=%0d 15 delayed completions",
           XLEN);
endtask
