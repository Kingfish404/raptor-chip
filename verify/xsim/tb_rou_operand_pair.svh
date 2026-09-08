// Two production ROU instances: only integer payload values differ.
// Shared completion control-flow/trap/CSR fields are public fixture inputs;
// this does not model execution-unit computation of those fields.
int paired_dispatches = 0, paired_commits = 0, paired_ready_operands = 0;
if (CheckOperandIndependence) begin : g_operand_pair
  rnu_rou_if shadow_rnu_rou();
  rapt_recovery_if shadow_recovery();
  checkpoint_release_if shadow_checkpoint_release();
  exu_prf_if shadow_exu_prf();
  rob_completion_owner_if shadow_completion_owner();
  rou_cmu_if shadow_rou_cmu();
  rou_csr_if shadow_rou_csr();
  rou_lsu_if shadow_rou_lsu();
  completion_t shadow_completion[CompletionPorts];
  dispatch_slot_t shadow_dispatch[DispatchWidth];
  execution_domain_t shadow_candidate_domain[DispatchWidth];
  logic shadow_dispatch_valid[DispatchWidth];
  logic shadow_halted, shadow_commit_fire, shadow_pmu_rob_full;
  logic [XLEN-1:0] shadow_halt_pc;
  assign shadow_rnu_rou.empty = rnu_rou.empty;
  assign shadow_rou_lsu.sq_ready = rou_lsu.sq_ready;
  assign shadow_rou_lsu.sq_empty = rou_lsu.sq_empty;
  for (genvar s = 0; s < RenameWidth; s++) begin
    assign shadow_rnu_rou.valid[s] = rnu_rou.valid[s];
    assign shadow_rnu_rou.checkpoint_valid[s] = rnu_rou.checkpoint_valid[s];
    assign shadow_rnu_rou.checkpoint[s] = rnu_rou.checkpoint[s];
    always_comb begin
      shadow_rnu_rou.slot[s] = rnu_rou.slot[s];
      shadow_rnu_rou.slot[s].op1 = ~rnu_rou.slot[s].op1;
      shadow_rnu_rou.slot[s].op2 = ~rnu_rou.slot[s].op2;
    end
    assign shadow_exu_prf.pv1[s] = ~exu_prf.pv1[s];
    assign shadow_exu_prf.pv2[s] = ~exu_prf.pv2[s];
    assign shadow_exu_prf.pv1_valid[s] = exu_prf.pv1_valid[s];
    assign shadow_exu_prf.pv2_valid[s] = exu_prf.pv2_valid[s];
  end
  for (genvar p = 0; p < CompletionPorts; p++) always_comb begin
    shadow_completion[p] = completion[p];
    shadow_completion[p].result = ~completion[p].result;
  end
  rapt_rou #(
      .ScanEntries(rapt_pkg::DispatchWidth),
      .ValidateCompletionInputs(1'b1)
  ) shadow (
      .completion(shadow_completion),
      .completion_owner(shadow_completion_owner),
      .clock(clock),
      .rnu_rou(shadow_rnu_rou),
      .recovery(shadow_recovery),
      .checkpoint_release(shadow_checkpoint_release),
      .exu_prf(shadow_exu_prf),
      .dispatch(shadow_dispatch),
      .candidate_domain(shadow_candidate_domain),
      .candidate_valid(shadow_dispatch_valid),
      .candidate_ready(dispatch_ready),
      .selected_valid(selected_valid),
      .selected_candidate(selected_candidate),

      .csr_bcast(csr_bcast),
      .clint_timer_trap(clint_timer_trap),
      .clint_sw_trap(clint_sw_trap),
      .clint_ext_trap(clint_ext_trap),
      .s_int_pending(s_int_pending),
      .s_int_cause(s_int_cause),
      .rou_cmu(shadow_rou_cmu),
      .rou_csr(shadow_rou_csr),
      .rou_lsu(shadow_rou_lsu),
      .dm_haltreq_i(dm_haltreq),
      .halted_o(shadow_halted),
      .halt_pc_o(shadow_halt_pc),
      .commit_fire_o(shadow_commit_fire),
      .pmu_rob_full(shadow_pmu_rob_full),
      .reset(reset)
  );

  always @(posedge clock) if (!reset) begin
    assert ({commit_fire, halted, halt_pc, pmu_rob_full} ==
        {shadow_commit_fire, shadow_halted, shadow_halt_pc, shadow_pmu_rob_full})
      else $fatal(1, "operand-dependent ROU commit/halt/capacity");
    for (int s = 0; s < RenameWidth; s++) begin
      assert (rnu_rou.ready[s] == shadow_rnu_rou.ready[s]
          && exu_prf.pr1[s] == shadow_exu_prf.pr1[s]
          && exu_prf.pr2[s] == shadow_exu_prf.pr2[s])
        else $fatal(1, "operand-dependent ROU rename admission/read address");
    end
    for (int s = 0; s < DispatchWidth; s++) begin
      assert (dispatch_valid[s] == shadow_dispatch_valid[s]
          && candidate_domain[s] == shadow_candidate_domain[s])
        else $fatal(1, "operand-dependent ROU dispatch eligibility");
      if (dispatch_valid[s]) begin
        automatic dispatch_slot_t a = dispatch[s], b = shadow_dispatch[s];
        // A nonzero pr tag denotes an unavailable operand. Allocation may
        // legally supply a zero placeholder until its producer completes.
        if (a.pr1 == '0) begin
          assert (a.op1 == ~b.op1) else $fatal(1, "paired ROU ready op1 variation lost");
          paired_ready_operands++;
        end
        if (a.pr2 == '0) begin
          assert (a.op2 == ~b.op2) else $fatal(1, "paired ROU ready op2 variation lost");
          paired_ready_operands++;
        end
        a.op1 = '0; a.op2 = '0; b.op1 = '0; b.op2 = '0;
        assert (a == b) else $fatal(1, "operand-dependent ROU dispatch identity");
        if (dispatch_ready[s]) paired_dispatches++;
      end
    end
    for (int c = 0; c < CommitWidth; c++) begin
      assert (rou_cmu.slot[c].valid == shadow_rou_cmu.slot[c].valid)
        else $fatal(1, "operand-dependent ROU retirement timing");
      if (rou_cmu.slot[c].valid) begin
        assert (rou_cmu.slot[c] == shadow_rou_cmu.slot[c])
          else $fatal(1, "operand-dependent ROU retirement identity");
        paired_commits++;
      end
    end
    assert ({rou_csr.pc, rou_csr.csr_wen, rou_csr.csr_wdata, rou_csr.csr_addr, rou_csr.fp_flags_valid, rou_csr.fp_flags, rou_csr.fp_dirty, rou_csr.ecall, rou_csr.ebreak, rou_csr.mret, rou_csr.sret, rou_csr.trap, rou_csr.tval, rou_csr.cause, rou_csr.valid, rou_csr.retire_count} == {shadow_rou_csr.pc, shadow_rou_csr.csr_wen, shadow_rou_csr.csr_wdata, shadow_rou_csr.csr_addr, shadow_rou_csr.fp_flags_valid, shadow_rou_csr.fp_flags, shadow_rou_csr.fp_dirty, shadow_rou_csr.ecall, shadow_rou_csr.ebreak, shadow_rou_csr.mret, shadow_rou_csr.sret, shadow_rou_csr.trap, shadow_rou_csr.tval, shadow_rou_csr.cause, shadow_rou_csr.valid, shadow_rou_csr.retire_count})
      else $fatal(1, "operand-dependent ROU rou_csr");
    assert ({rou_lsu.store, rou_lsu.dest, rou_lsu.sq_vaddr, rou_lsu.pc, rou_lsu.valid} == {shadow_rou_lsu.store, shadow_rou_lsu.dest, shadow_rou_lsu.sq_vaddr, shadow_rou_lsu.pc, shadow_rou_lsu.valid})
      else $fatal(1, "operand-dependent ROU rou_lsu");
    assert ({rou_cmu.next_pc, rou_cmu.redirect_pc, rou_cmu.btaken, rou_cmu.ben, rou_cmu.jen, rou_cmu.jren, rou_cmu.atomic_sc, rou_cmu.fence_time, rou_cmu.fence_i, rou_cmu.flush_pipe, rou_cmu.flush_redirect, rou_cmu.sys_resume, rou_cmu.time_trap, rou_cmu.rob_head} == {shadow_rou_cmu.next_pc, shadow_rou_cmu.redirect_pc, shadow_rou_cmu.btaken, shadow_rou_cmu.ben, shadow_rou_cmu.jen, shadow_rou_cmu.jren, shadow_rou_cmu.atomic_sc, shadow_rou_cmu.fence_time, shadow_rou_cmu.fence_i, shadow_rou_cmu.flush_pipe, shadow_rou_cmu.flush_redirect, shadow_rou_cmu.sys_resume, shadow_rou_cmu.time_trap, shadow_rou_cmu.rob_head})
      else $fatal(1, "operand-dependent ROU rou_cmu");
    assert ({recovery.pending, recovery.redirect_valid, recovery.owner, recovery.head, recovery.generation, recovery.target, recovery.checkpoint_valid, recovery.checkpoint} == {shadow_recovery.pending, shadow_recovery.redirect_valid, shadow_recovery.owner, shadow_recovery.head, shadow_recovery.generation, shadow_recovery.target, shadow_recovery.checkpoint_valid, shadow_recovery.checkpoint})
      else $fatal(1, "operand-dependent ROU recovery");
    assert (completion_owner.live == shadow_completion_owner.live
        && completion_owner.executing == shadow_completion_owner.executing)
      else $fatal(1, "operand-dependent ROU owner lifecycle");
    for (int e = 0; e < `RAPT_ROB_SIZE; e++) if (completion_owner.live[e])
      assert ({completion_owner.generation[e], completion_owner.prd[e], completion_owner.rd[e]}
          == {shadow_completion_owner.generation[e], shadow_completion_owner.prd[e], shadow_completion_owner.rd[e]})
        else $fatal(1, "operand-dependent ROU live owner identity");
    for (int p = 0; p < CompletionPorts; p++) begin
      assert (checkpoint_release.valid[p] == shadow_checkpoint_release.valid[p])
        else $fatal(1, "operand-dependent checkpoint release timing");
      if (checkpoint_release.valid[p]) assert (checkpoint_release.checkpoint[p] == shadow_checkpoint_release.checkpoint[p])
        else $fatal(1, "operand-dependent checkpoint release identity");
    end
  end
end
