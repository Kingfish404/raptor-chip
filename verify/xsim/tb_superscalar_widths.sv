`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_types.svh"

// An integration-only execution domain: no changes to rename, ROB, IQ or PRF
// are needed to route its uops, preserve its payload, or consume its results.
module tb_superscalar_widths;
  import rapt_pkg::*;
  localparam int XLEN = CoreConfig.xlen;
  function automatic core_config_t extended_config();
    core_config_t c = CoreConfig;
    c.execution_domains = 6;
    c.completion_ports  = 7;
`ifdef RAPT_TEST_ODD_DEPTHS
    c.rename_entries = 7;
    c.dispatch_entries = 7;
    c.rob_entries = 47;
`endif
    return c;
  endfunction
  localparam core_config_t Cfg = extended_config();
  localparam execution_domain_t CustomDomain = execution_domain_t'(5);

  typedef struct packed {
    int_op_uop_t int_op;
    branch_uop_t branch;
    memory_uop_t memory;
    fp_uop_t fp;
    sys_uop_t sys;
    logic [79:0] custom_control;
  } extended_execute_t;
  `RAPT_UOP_TYPE(extended_uop_t, xlen_t, arch_reg_t, scheduling_t, extended_execute_t)
  `RAPT_DISPATCH_SLOT_TYPE(extended_slot_t, extended_uop_t, xlen_t, phys_reg_t, rob_index_t,
                           rob_generation_t, CoreConfig.completion_dependencies)
  `RAPT_ISSUE_PACKET_TYPE(extended_issue_t, extended_uop_t, xlen_t, phys_reg_t, rob_index_t,
                          rob_generation_t)

  logic clock = 0;
  logic reset = 1;
  always #5 clock = ~clock;
  logic [1:0] issue_enable;
  idu_rnu_if #(.UopT(extended_uop_t)) idu_rnu ();
  rnu_rou_if #(.UopT(extended_uop_t)) rnu_rou ();
  rapt_recovery_if #(.RobEntries(Cfg.rob_entries)) recovery ();
  checkpoint_release_if #(.Ports(Cfg.completion_ports)) checkpoint_release ();
  execution_domain_t dispatch_candidate_domain[Cfg.steer_scan_entries];
  logic dispatch_candidate_valid[Cfg.steer_scan_entries];
  logic dispatch_candidate_ready[Cfg.steer_scan_entries];
  logic [index_bits(Cfg.steer_scan_entries)-1:0] dispatch_selected_candidate[DispatchWidth];
  extended_slot_t dispatch[DispatchWidth];
  logic dispatch_valid[rapt_pkg::DispatchWidth];
  completion_t completion[Cfg.completion_ports];
  rob_completion_owner_if #(.ENTRIES(Cfg.rob_entries)) completion_owner ();
  dispatch_capacity_t capacity[Cfg.execution_domains];
  dispatch_grant_t grant[Cfg.execution_domains];
  extended_issue_t iss, iss_b;
  extended_issue_t issue[2];
  assign iss   = issue[0];
  assign iss_b = issue[1];
  dpu_iq_if #(.RS_SIZE(8)) queue ();
  load_fast_if load_fast ();
  exu_prf_if prf_rd ();
  rou_cmu_if rou_cmu ();
  rou_csr_if rou_csr ();
  rou_lsu_if rou_lsu ();
  cmu_bcast_if cmu_bcast ();
  csr_bcast_if csr_bcast ();
  phys_reg_t map_snapshot[RNUMPkg], rat_snapshot[RNUMPkg];
  xlen_t rf[RNUMPkg], rf_map[RNUMPkg];
  logic [3:0] occupancy;

  rapt_rnu #(
      .Cfg (Cfg),
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
      .Cfg  (Cfg),
      .UopT (extended_uop_t),
      .SlotT(extended_slot_t),
      .ScanEntries(Cfg.steer_scan_entries)
  ) rob (
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
      .Cfg  (Cfg),
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
  rapt_iq #(
      .Cfg(Cfg),
      .IQ_SIZE(8),
      .NumIssuePorts(2),
      .UopT(extended_uop_t),
      .SlotT(extended_slot_t),
      .IssueT(extended_issue_t)
  ) iq (
      .cancel_valid(recovery.redirect_valid),
      .cancel_head(recovery.head),
      .cancel_owner(recovery.owner),
      .clock,
      .reset,
      .cmu_bcast,
      .dispatch,
      .disp(queue),
      .completion,
      .load_fast,
      .issue_enable,
      .issue,
      .occ_o(occupancy),
      .pmu_iq_full()
  );

  // Compare registered observations with real pre-edge handshakes, not with
  // post-edge queue state.  The dispatch PMU observes ordered UOQ-to-ROB
  // allocation; endpoint acceptance is intentionally a separate, potentially
  // sparse handshake in buffered mode.
  always @(posedge clock)
    if (!reset) begin
      automatic int allocation_count = 0;
      automatic int stopped_domain = 0;
      automatic dispatch_stop_t reason_before = rob.dispatch_stop;
      for (int s = 0; s < DispatchWidth; s++) allocation_count += int'(rob.deq_fire[s]);
      if (reason_before == DispatchStopEndpoint)
        stopped_domain = int'(rob.uoq_uops[rob.deq_index[allocation_count]].schedule.domain);
      #1;
      assert (rob.pmu_dispatch_count == allocation_count && rob.pmu_dispatch_reason == reason_before)
      else $fatal(1, "dispatch PMU sampled the wrong handshake edge");
      if (reason_before == DispatchStopEndpoint)
        assert (rob.pmu_dispatch_stop_domain == stopped_domain)
        else $fatal(1, "dispatch PMU used the wrong stopped-slot domain");
    end

  `include "tb_core_bcast_defaults.svh"
  localparam int Instructions = 192;
  int cycle = 0, sent = 0, retired = 0, issued_total = 0;
  int max_rename = 0, max_dispatch = 0, max_commit = 0;
  extended_issue_t pending  [$];
  extended_issue_t returned;
  always @(posedge clock)
    if (!reset) begin
      automatic int count;
      cycle++;
      for (int p = 0; p < 2; p++)
      if (issue[p].valid) begin
        automatic int id = int'((issue[p].uop.pc - 'h8000_0000) >> 2);
        assert (issue[p].op1 + issue[p].op2 == xlen_t'(2 + id / 7))
        else
          $fatal(
              1,
              "RAW/WAW value id=%0d got=%0d expected=%0d",
              id,
              issue[p].op1 + issue[p].op2,
              2 + id / 7
          );
        assert (issue[p].uop.execute.custom_control == 80'(id))
        else $fatal(1, "payload reordered");
        pending.push_back(issue[p]);
        issued_total++;
      end
      count = 0;
      for (int s = 0; s < RenameWidth; s++) count += int'(rnu_rou.valid[s] && rnu_rou.ready[s]);
      if (count > max_rename) max_rename = count;
      count = 0;
      for (int s = 0; s < DispatchWidth; s++) count += int'(dispatch_valid[s]);
      if (count > max_dispatch) max_dispatch = count;
      count = 0;
      for (int c = 0; c < CommitWidth; c++)
      if (rou_cmu.slot[c].valid) begin
        assert (rou_cmu.slot[c].pc == xlen_t'('h8000_0000 + 4 * retired))
        else $fatal(1, "retirement lost/duplicated/reordered at %0d", retired);
        retired++;
        count++;
      end
      if (count > max_commit) max_commit = count;
      assert (!cmu_bcast.flush_pipe)
      else $fatal(1, "unexpected flush");
    end
  // Finite bursts force completed instructions to accumulate for wide commit;
  // periodic issue pauses force partial dispatch and queue full/reclaim cases.
  always @(negedge clock) begin
    issue_enable = cycle % 11 < 4 ? 2'b00 : 2'b11;
    for (int p = 0; p < Cfg.completion_ports; p++) completion[p] = '0;
    if (!reset && cycle % 5 == 0) begin
      for (int p = 0; p < Cfg.completion_ports; p++)
      if (pending.size() != 0) begin
        returned = pending.pop_front();
        completion[p].valid = 1'b1;
        completion[p].dest = returned.dest;
        completion[p].generation = returned.generation;
        completion[p].prd = returned.prd;
        completion[p].rd = returned.uop.rd;
        completion[p].result = returned.op1 + returned.op2;
        completion[p].npc = returned.uop.pc + 4;
      end
    end
  end
  initial begin
    init_csr_bcast_defaults(2'b11, 'h8000_1000, 1'b0);
    rou_lsu.sq_ready = 1;
    rou_lsu.sq_empty = 1;
    load_fast.valid = 0;
    load_fast.rebusy = 0;
    load_fast.prd = 0;
    load_fast.confirmed = 0;
    load_fast.confirmed_prd = 0;
    load_fast.confirmed_rd = 0;
    load_fast.result = 0;
    idu_rnu.valid = '{default: 0};
    idu_rnu.slot = '{default: '0};
    repeat (4) @(negedge clock);
    reset = 0;
    while (sent < Instructions) begin
      @(negedge clock);
      for (int s = 0; s < DecodeWidth; s++) begin
        automatic int id = sent + s;
        idu_rnu.slot[s] = '0;
        idu_rnu.valid[s] = id < Instructions;
        idu_rnu.slot[s].uop.schedule.domain = CustomDomain;
        idu_rnu.slot[s].uop.schedule.issue_ports = '1;
        idu_rnu.slot[s].uop.pc = xlen_t'('h8000_0000 + 4 * id);
        idu_rnu.slot[s].uop.pnpc = idu_rnu.slot[s].uop.pc + 4;
        idu_rnu.slot[s].uop.inst = 32'h00000013;
        idu_rnu.slot[s].uop.rd = arch_reg_t'(1 + id % 7);
        idu_rnu.slot[s].uop.execute.custom_control = 80'(id);
        idu_rnu.slot[s].rs1 = id < 7 ? '0 : arch_reg_t'(1 + id % 7);
        idu_rnu.slot[s].op1 = id < 7 ? 1 : 0;
        idu_rnu.slot[s].op2 = 1;
      end
      @(posedge clock);
      for (int s = 0; s < DecodeWidth; s++) if (idu_rnu.valid[s] && idu_rnu.ready[s]) sent++;
    end
    @(negedge clock);
    idu_rnu.valid = '{default: 0};
    wait (retired == Instructions);
    repeat (3) @(negedge clock);
    assert (issued_total == Instructions)
    else $fatal(1, "issue count");
    for (int r = 1; r <= 7; r++)
    assert (rf[r] == xlen_t'(2 + (Instructions - r) / 7))
    else $fatal(1, "architectural value x%0d", r);
    assert ($countones(rename.free_q) == CoreConfig.phys_regs - CoreConfig.arch_regs)
    else $fatal(1, "physical register leak after WAW retirement");
    if (RenameWidth > 1)
      assert (max_rename > 1)
      else $fatal(1, "rename never multi-slot");
    if (DispatchWidth > 1)
      assert (max_dispatch > 1)
      else $fatal(1, "dispatch never multi-slot");
    if (CommitWidth > 1)
      assert (max_commit > 1)
      else $fatal(1, "commit never multi-slot");
    $display(
        "PASS: widths decode=%0d rename=%0d dispatch=%0d commit=%0d; max=%0d/%0d/%0d; %0d uops",
        DecodeWidth, RenameWidth, DispatchWidth, CommitWidth, max_rename, max_dispatch, max_commit,
        retired);
    $finish;
  end
  initial begin
    #200000;
    $fatal(1, "width test timeout sent=%0d issued=%0d retired=%0d", sent, issued_total, retired);
  end
endmodule
