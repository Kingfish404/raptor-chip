task automatic run_drain_handshake_tests;
  for (int kind = 0; kind < 2; kind++) begin
    for (int delayed = 0; delayed < 3; delayed++) begin
      reset_dut();
      memory_idle = delayed != 1;
      raw_writeback_idle = delayed != 2;
      tb_sq_empty = delayed != 0;
      dispatch_one(make_fence_uop(kind == 0), '0, '0, RobW'(0));
      writeback_alu_one(RobW'(0), XLEN'('h80004004));
      check(tb_writeback_drain && !commit_fire && !drain_done,
            "fence bypassed registered request acceptance");
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
      check(cmu_bcast.fence_i == (kind == 0) && cmu_bcast.fence_time == (kind == 1),
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
  $display("PASS: ROU and registered drain fence integration XLEN=%0d 6 delayed completions", XLEN);
endtask
