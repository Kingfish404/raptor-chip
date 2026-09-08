`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_types.svh"

// An integration-only execution domain: no changes to rename, ROB, IQ or PRF
// are needed to route its uops, preserve its payload, or consume its results.
module tb_backend_extensibility #(
    parameter bit RecoveryExercise = 0
);
  import rapt_pkg::*;
  localparam int XLEN = CoreConfig.xlen;
  function automatic core_config_t extended_config();
    core_config_t c = CoreConfig;
    c.execution_domains = 6;
    c.completion_ports = 7;
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
  logic issue_enable = 0;
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
  extended_issue_t issue[1];
  assign iss = issue[0];
  assign iss_b = '0;
  dpu_iq_if #(.RS_SIZE(4)) queue ();
  load_fast_if load_fast ();
  exu_prf_if prf_rd ();
  rou_cmu_if rou_cmu ();
  rou_csr_if rou_csr ();
  rou_lsu_if rou_lsu ();
  cmu_bcast_if cmu_bcast ();
  csr_bcast_if csr_bcast ();
  phys_reg_t map_snapshot[RNUMPkg], rat_snapshot[RNUMPkg];
  xlen_t rf[RNUMPkg], rf_map[RNUMPkg];
  logic [2:0] occupancy;

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
      .ValidateCompletionInputs(RecoveryExercise),
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
  rapt_iq #(
      .Cfg(Cfg),
      .IQ_SIZE(4),
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

  `include "tb_core_bcast_defaults.svh"
  extended_issue_t issued[8];
  int issued_count = 0;
  int retired_count = 0;
  always @(posedge clock) begin
    if (!reset) begin
      if (iss.valid) begin
        issued[issued_count] = iss;
        issued_count++;
      end
      if (iss_b.valid) begin
        issued[issued_count] = iss_b;
        issued_count++;
      end
      if (rou_cmu.slot[0].valid) begin
        retired_count++;
        assert (RecoveryExercise || rou_cmu.slot[0].rd == retired_count)
        else $fatal(1, "retirement order A");
      end
      if (rou_cmu.slot[1].valid) begin
        retired_count++;
        assert (RecoveryExercise || rou_cmu.slot[1].rd == retired_count)
        else $fatal(1, "retirement order B");
      end
      assert (RecoveryExercise || !cmu_bcast.flush_pipe)
      else $fatal(1, "unexpected flush");
    end
  end

  function automatic extended_uop_t make_uop(input int rd);
    extended_uop_t u = '0;
    u.schedule.domain = CustomDomain;
    u.schedule.issue_ports = '1;
    u.pc = 'h8000_0000 + xlen_t'(4 * (rd - 1));
    u.pnpc = u.pc + 4;
    u.inst = 32'h0000_0013;
    u.rd = arch_reg_t'(rd);
    if (RecoveryExercise && rd == 2) begin
      u.rd = '0;
      u.inst = 32'h0000_0863;
      u.execute.branch.conditional = 1;
    end
    u.execute.custom_control = 80'hfedc_ba98_7654_3210_0000 | 80'(rd);
    return u;
  endfunction

  task automatic send_one(input int rd, input int rs1, input xlen_t a, input xlen_t b);
    @(negedge clock);
    idu_rnu.slot[0].uop = make_uop(rd);
    idu_rnu.slot[0].rs1 = arch_reg_t'(rs1);
    idu_rnu.slot[0].op1 = a;
    idu_rnu.slot[0].op2 = b;
    idu_rnu.valid[0] = 1;
    do @(posedge clock); while (!idu_rnu.ready[0]);
    @(negedge clock);
    idu_rnu.valid[0] = 0;
  endtask

  task automatic respond(input int port, input int entry);
    completion[port] = '0;
    completion[port].valid = 1;
    completion[port].dest = issued[entry].dest;
    completion[port].generation = issued[entry].generation;
    completion[port].prd = issued[entry].prd;
    completion[port].rd = issued[entry].uop.rd;
    completion[port].result = issued[entry].op1 + issued[entry].op2;
    completion[port].npc = issued[entry].uop.pc + 4;
    completion[port].updates.control_flow = 1;
  endtask

  initial begin
    init_csr_bcast_defaults(`RAPT_PRIV_M, 'h8000_1000, 0);
    rou_lsu.sq_ready = 1;
    rou_lsu.sq_empty = 1;
    load_fast.valid = 0;
    load_fast.rebusy = 0;
    load_fast.prd = 0;
    load_fast.confirmed = 0;
    load_fast.confirmed_prd = 0;
    load_fast.confirmed_rd = 0;
    load_fast.result = 0;
    foreach (completion[p]) completion[p] = '0;
    foreach (idu_rnu.slot[s]) begin
      idu_rnu.slot[s] = '0;
      idu_rnu.valid[s] = 0;
    end
    repeat (3) @(negedge clock);
    reset = 0;
    if (RecoveryExercise) begin
      issue_enable = 1;
      send_one(1, 0, 30, 3);
      wait (issued_count == 1);
      @(negedge clock);
      issue_enable = 0;
      send_one(2, 0, 0, 0);
      send_one(3, 0, 40, 4);
      wait (occupancy == 2);
      @(negedge clock);
      issue_enable = 1;
      wait (issued_count == 2);
      @(negedge clock);
      issue_enable = 0;
      assert (occupancy == 1)
      else $fatal(1, "young resident setup failed");
      respond(6, 1);
      completion[6].mispredict = 1;
      completion[6].npc = 'h8000_1000;
      completion[6].generation = issued[1].generation - rob_generation_t'(1);
      @(negedge clock);
      assert (!recovery.pending && occupancy == 1)
      else $fatal(1, "stale recovery changed IQ ownership");
      completion[6].generation = issued[1].generation;
      @(negedge clock);
      completion[6].valid = 0;
      assert (recovery.redirect_valid && recovery.owner == issued[1].dest
          && recovery.generation == issued[1].generation)
      else $fatal(1, "valid branch did not publish current recovery identity");
      issue_enable = 1;
      #1;
      assert (!iss.valid)
      else $fatal(1, "young IQ resident issued on real ROU redirect");
      repeat (3) @(negedge clock);
      assert (occupancy == 0 && issued_count == 2 && recovery.pending)
      else $fatal(1, "early cancellation lost pending fence or retained younger work");
      respond(5, 0);
      @(negedge clock);
      completion[5].valid = 0;
      wait (retired_count == 2);
      @(negedge clock);
      assert (!recovery.pending && rf[1] == 33 && issued_count == 2)
      else $fatal(1, "older retirement or precise cleanup failed after cancellation");
      $display(
          "PASS: RNU/ROU/IQ/PRF recovery: stale rejected, younger cancelled, older retired XLEN=%0d",
          XLEN);
      $finish;
    end
    send_one(1, 0, 'h1200, 'h34);
    send_one(2, 1, 0, 7);
    wait (occupancy == 2);
    @(negedge clock);
    issue_enable = 1;
    wait (issued_count == 1);
    repeat (3) @(negedge clock);
    assert (issued_count == 1)
    else $fatal(1, "dependent uop issued before completion");
    // Port 6 is beyond every production completion source.
    respond(6, 0);
    @(negedge clock);
    completion[6].valid = 0;
    wait (issued_count == 2);
    @(negedge clock);
    assert (issued[1].op1 == 'h1234)
    else $fatal(1, "new completion port did not wake IQ");
    respond(5, 1);
    @(negedge clock);
    completion[5].valid = 0;
    wait (retired_count == 2);
    @(negedge clock);
    assert (rf[1] == 'h1234 && rf[2] == 'h123b)
    else $fatal(1, "new ports did not write PRF");

    send_one(3, 0, 30, 3);
    send_one(4, 0, 40, 4);
    wait (issued_count == 4);
    @(negedge clock);
    respond(5, 2);
    respond(6, 3);
    @(negedge clock);
    completion[5].valid = 0;
    completion[6].valid = 0;
    wait (retired_count == 4);
    @(negedge clock);
    assert (rf[3] == 33 && rf[4] == 44)
    else $fatal(1, "simultaneous completion lost");
    for (int i = 0; i < 4; i++)
    assert (issued[i].uop.execute.custom_control == (80'hfedc_ba98_7654_3210_0000 | 80'(i + 1)))
    else $fatal(1, "extended payload lost in rename/dispatch/IQ");
    $display(
        "PASS: extra execution domain, extended uop, seven completion ports, IQ/ROB/PRF integration");
    $finish;
  end
  initial begin
    #20000;
    $fatal(1, "backend extension timeout: issued=%0d retired=%0d occupancy=%0d", issued_count,
           retired_count, occupancy);
  end
endmodule
