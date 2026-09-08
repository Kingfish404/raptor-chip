// Actual ROU/CMU boundary test; execution endpoints are modeled. This does
// not establish FEU/FPR cancellation or external interrupt-controller behavior.
integer fp_irq_boundary_cases = 0;
always @(posedge clock)
  if (!reset && dut_rou.rob_empty && dut_rou.deq_fire[0]
      && dut_rou.allocation[0].uop.execute.fp.valid && dut_rou.async_trap_pending)
    fp_irq_boundary_cases <= fp_irq_boundary_cases + 1;
task automatic run_fp_irq_boundary;
  uop_t u;
  logic [XLEN-1:0] resume_pc;
  for (int prior = 0; prior < 2; prior++)
    for (int ready = 0; ready < 2; ready++)
      for (int irq = 0; irq < 3; irq++) begin
        reset_dut();
`ifdef RAPT_TEST_FP_IRQ_COMPOSE
        fp_irq_seed();
`endif
        resume_pc = XLEN'(`RAPT_PC_INIT);
        if (prior != 0) begin
          dispatch_one(make_alu_uop('h80001200,32'h00100093,RLEN'(1)),PLEN'(32),'0,RobW'(0));
          writeback_alu_one(RobW'(0),'h80001204);
          check(commit_fire, "prior instruction did not reach retirement");
          tick(1);
          resume_pc = XLEN'('h80001204);
        end
        u = '0;
        u.pc = resume_pc;
        u.pnpc = resume_pc + XLEN'(4);
        u.inst = 32'hf4000153; // FMV.H.X f2,x0
        u.execute.fp.valid = 1;
        u.execute.fp.op = `RAPT_FP_OP_ZFHMIN;
        u.execute.fp.rd = 2;
        u.schedule = rapt_pkg::schedule_uop(u);
        dispatch_ready[0] = 1'(ready);
        rnu_rou.slot[0] = '0;
        rnu_rou.slot[0].uop = u;
        rnu_rou.valid[0] = 1;
        #1;
        check(rnu_rou.ready[0], "FP enqueue not accepted");
        tick(1);
        rnu_rou.valid[0] = 0;
        clint_timer_trap = irq == 0;
        clint_sw_trap = irq == 1;
        clint_ext_trap = irq == 2;
        #1;
        check(dut_rou.rob_empty && dut_rou.deq_fire[0]
            && dut_rou.allocation[0].uop.execute.fp.valid,
            "missing empty-ROB FP allocation / IRQ coincidence");
        tick(1);
        check(cmu_bcast.flush_pipe && rou_csr.valid && rou_csr.trap,
            "coincident IRQ did not flush and report trap");
        check(rou_csr.pc == resume_pc && rou_csr.tval == 0,
            "IRQ lost precise FP restart PC");
        check(rou_csr.cause == ((XLEN'(1) << (XLEN-1))
            | XLEN'(irq == 0 ? 7 : irq == 1 ? 3 : 11)),
            "wrong interrupt cause");
        check(!commit_fire && !rou_csr.fp_flags_valid,
            "canceled FP retired or published flags");
        clint_timer_trap = 0;
        clint_sw_trap = 0;
        clint_ext_trap = 0;
        tick(1);
        check(dut_rou.rob_empty, "flush retained FP ROB owner");
        repeat (3) begin
          check(!commit_fire && !dispatch_valid[0] && !rou_csr.valid,
              "canceled FP produced late dispatch/retirement/CSR event");
          tick(1);
        end
`ifdef RAPT_TEST_FP_IRQ_COMPOSE
        check(fp_irq_writes == 0 && fp_irq_fpr.ioq_rdata == 64'h0123456789abcdef,
            "canceled FP modified actual FPR storage");
`endif
      end
  check(fp_irq_boundary_cases == 12, "FP IRQ scenario count mismatch");
`ifdef RAPT_TEST_FP_IRQ_COMPOSE
  fp_irq_positive_control();
`endif
  $display("PASS: FP allocation / IRQ boundary cases=%0d XLEN=%0d", fp_irq_boundary_cases, XLEN);
endtask
