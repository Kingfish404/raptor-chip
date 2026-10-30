// verilog_syntax: parse-as-module-body
// Routing fixture around the actual FPQ/FEU, renamed FPR retirement and owner guard.
// Completion uses the producer's unchanged identity, without fixture enrichment.
completion_t fp_irq_wb;
logic fp_irq_accept, fp_irq_issue_enable;
dpu_iq_if #(.RS_SIZE(CoreConfig.iq_entries)) fp_irq_queue ();
integer fp_irq_writes = 0;
integer fp_irq_retired = 0;
integer fp_irq_enqueued = 0;
integer fp_irq_captured = 0;
integer fp_irq_flush_offers = 0;
for (genvar fq = 0; fq < DispatchWidth; fq++) begin
  assign fp_irq_queue.accept[fq] = dispatch_valid[fq] && dispatch_ready[fq]
      && dispatch[fq].uop.execute.fp.valid;
  assign fp_irq_queue.rs_idx[fq] = fp_irq_queue.free_idx[fq];
  always @(posedge clock)
    if (!reset && fp_irq_queue.accept[fq])
      check(fp_irq_queue.free_found[fq], "FP route accepted without queue capacity");
end
// JOB N: reuse the fixture RF for both dispatch and late operand reads.
logic [1:0][PLEN-1:0] n1_dispatch_int[DispatchWidth];
logic [PLEN-1:0] n1_int_address;
for (genvar s = 0; s < DispatchWidth; s++) begin : g_n1_dispatch
  assign n1_dispatch_int[s] = {exu_prf.pr2[s], exu_prf.pr1[s]};
end
rapt_feu fp_irq_feu (
    .int_source_regs(n1_dispatch_int),
    .fp_dispatch_tag(n1_dispatch_tag),
    .fp_dispatch_generation(n1_dispatch_generation),
    .fp_retire_valid(n1_commit_valid),
    .fp_retire_value(n1_commit_value),
    .fp_retire_owner(n1_commit_owner),
    .fp_retire_generation(n1_commit_generation),
    .fp_queue_read_uop(n1_read_uop),
    .fp_queue_read_tag(n1_read_tag),
    .operand_read_value(n1_read_value),
    .fp_queue_ready_tag(n1_ready_tag),
    .fp_queue_read_generation(n1_read_generation),
    .int_operand_address(n1_int_address),
    .int_operand_value(n1_gpr[n1_int_address]),
    .int_operand_valid(1'b1),
    .early_completion(completion),
    // end JOB N
    .completion(completion),
    .clock(clock),
    .reset(reset),
    .cancel_valid(recovery.redirect_valid),
    .cancel_head(recovery.head),
    .cancel_owner(recovery.owner),
    .cmu_bcast(cmu_bcast),
    .csr_bcast(csr_bcast),
    .dispatch(dispatch),
    .disp_fpq(fp_irq_queue),
    .wb_fpu(fp_irq_wb),
    .wb_accept(fp_irq_accept),
    .issue_enable(fp_irq_issue_enable)
);
rapt_completion_guard #(
    .Entries(`RAPT_ROB_SIZE),
    .IndexBits(RobW),
    .GenerationBits(CoreConfig.rob_generation_bits),
    .PhysBits(PLEN),
    .ArchBits(RLEN),
    .EnforcePayload(0)
) fp_irq_guard (
    .candidate_valid(fp_irq_wb.valid),
    .candidate_index(fp_irq_wb.dest),
    .candidate_generation(fp_irq_wb.generation),
    .candidate_prd(fp_irq_wb.prd),
    .candidate_rd(fp_irq_wb.rd),
    .live(completion_owner.live),
    .executing(completion_owner.executing),
    .owner_generation(completion_owner.generation),
    .owner_prd(completion_owner.prd),
    .owner_rd(completion_owner.rd),
    .accept(fp_irq_accept),
    .identity_match(),
    .payload_match()
);
always @(posedge clock)
  if (!reset) begin
    if (fp_irq_queue.accept[0]) begin
      fp_irq_enqueued <= fp_irq_enqueued + 1;
      if (cmu_bcast.flush_pipe) fp_irq_flush_offers <= fp_irq_flush_offers + 1;
      else fp_irq_captured <= fp_irq_captured + 1;
    end
    if (commit_fire && dut_rou.rob_fp_writer[dut_rou.rob_head]) fp_irq_writes <= fp_irq_writes + 1;
    if (commit_fire && dut_rou.rob_fp_valid[dut_rou.rob_head]) fp_irq_retired <= fp_irq_retired + 1;
    if (cmu_bcast.flush_pipe)
      check(!fp_irq_feu.iss.valid && !fp_irq_wb.valid,
            "FP issue/completion/FPR write escaped interrupt flush");
  end
task automatic fp_irq_seed;
  check(dut_rou.fp_registers.architectural[2] == 0,
        "reset did not initialize committed FPR sentinel");
endtask
task automatic fp_irq_positive_control;
  uop_t control_uop;
  $display("FP cancellation: offered=%0d captured=%0d flush_offers=%0d", fp_irq_enqueued,
           fp_irq_captured, fp_irq_flush_offers);
  check(fp_irq_enqueued == 6, "ready cancellation cases did not offer each FP owner once");
`ifdef RAPT_TEST_REGISTERED_PAYLOAD
  check(fp_irq_captured == 0 && fp_irq_flush_offers == 6,
        "FP offer was not canceled by flush at the payload boundary");
`endif
  reset_dut();
  fp_irq_seed();
  control_uop = '0;
  control_uop.pc = XLEN'(`RAPT_PC_INIT);

  control_uop.inst = 32'hf4000153;
  control_uop.imm = 32'hf4000153;
  control_uop.execute.fp.valid = 1;
  control_uop.execute.fp.op = `RAPT_FP_OP_ZFHMIN;
  control_uop.execute.fp.rd = 2;
  control_uop.schedule = rapt_pkg::schedule_uop(control_uop);
  dispatch_one(control_uop, '0, '0, RobW'(0));
  tick(12);
  $display(
      "FP control: queued=%0d writes=%0d retired=%0d data=%h owner=%b executing=%b wb=%b accepted=%b issue=%b",
      fp_irq_enqueued, fp_irq_writes, fp_irq_retired, dut_rou.fp_registers.architectural[2],
      completion_owner.live[0], completion_owner.executing[0], fp_irq_wb.valid, fp_irq_accept,
      fp_irq_feu.iss.valid);
  check(fp_irq_enqueued == 7, "positive control did not enter actual FPQ");
`ifdef RAPT_TEST_REGISTERED_PAYLOAD
  check(fp_irq_captured == 1 && fp_irq_flush_offers == 6,
        "uncanceled FP control was not captured exactly once");
`endif
  check(fp_irq_writes == 1 && fp_irq_retired == 1,
        "uncanceled FP control did not write and retire exactly once");
  check(dut_rou.fp_registers.architectural[2] == 64'hffffffffffff0000,
        "uncanceled FMV.H.X control did not update boxed FPR");
  $display("PASS: actual FPQ/FEU/guard/FPR cancellation and positive control XLEN=%0d", XLEN);
endtask
