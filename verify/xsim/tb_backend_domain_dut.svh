  // Shared rename/ROB/commit/PRF/router wiring for the custom execution domain.
  // The caller supplies Cfg, extended uop/slot types, interfaces and its IQ.
  // Optional completion validation is consumed here; no include guard.
  rapt_rnu #(
      .Cfg(Cfg),
      .UopT(extended_uop_t)
  ) rename (
      .clock,
      .reset,
      .idu_rnu,
      .rnu_rou,
      .recovery,
      .checkpoint_release,
      .rou_cmu,
      .cmu_bcast,
      .map_snapshot,
      .rat_snapshot
  );
  rapt_rou #(
      .Cfg(Cfg),
      .UopT(extended_uop_t),
      .SlotT(extended_slot_t),
`ifdef TB_BACKEND_VALIDATE_COMPLETIONS
      .ValidateCompletionInputs(`TB_BACKEND_VALIDATE_COMPLETIONS),
`endif
      .ScanEntries(Cfg.steer_scan_entries)
  ) rob (
      .writeback_clean(),
      .writeback_cbo(),
      .writeback_cbo_invalidate(),
      .writeback_block(),
      .clock,
      .reset,
      .rnu_rou,
      .recovery,
      .checkpoint_release,
      .exu_prf(prf_rd),
      .dispatch,
      .candidate_domain(dispatch_candidate_domain),
      .candidate_valid(dispatch_candidate_valid),
      .candidate_ready(dispatch_candidate_ready),
      .selected_valid(dispatch_valid),
      .selected_candidate(dispatch_selected_candidate),
      .completion,
      .completion_owner(completion_owner),
      .csr_bcast,
      .clint_timer_trap(1'b0),
      .clint_sw_trap(1'b0),
      .clint_ext_trap(1'b0),
      .s_int_pending(1'b0),
      .s_int_cause('0),
      .rou_cmu,
      .rou_csr,
      .rou_lsu,
      .dm_haltreq_i(1'b0),
      .halted_o(),
      .halt_pc_o(),
      .commit_fire_o(),
      .pmu_rob_full()
  );
  rapt_cmu commit_unit (
      .clock,
      .reset,
      .rou_cmu,
      .cmu_bcast
  );
  rapt_prf #(
      .Cfg(Cfg)
  ) prf (
      .clock,
      .reset,
      .prf_rd,
      .completion,
      .rou_cmu,
      .cmu_bcast,
      .map_snapshot,
      .rat_snapshot,
      .rf,
      .rf_map,
      .dbg_we_i(1'b0),
      .dbg_addr_i('0),
      .dbg_wdata_i('0),
      .dbg_rdata_o()
  );
  rapt_dpu #(
      .Cfg(Cfg),
      .NumCandidates(Cfg.steer_scan_entries)
  ) router (
      .clock,
      .reset,
      .candidate_domain(dispatch_candidate_domain),
      .candidate_valid(dispatch_candidate_valid),
      .candidate_ready(dispatch_candidate_ready),
      .selected_valid(dispatch_valid),
      .selected_candidate(dispatch_selected_candidate),
      .capacity,
      .grant
  );
  for (genvar d = 0; d < 5; d++) assign capacity[d] = '0;
  rapt_dispatch_iq_adapter endpoint (
      .queue,
      .capacity(capacity[5]),
      .grant(grant[5])
  );
  `undef TB_BACKEND_VALIDATE_COMPLETIONS
