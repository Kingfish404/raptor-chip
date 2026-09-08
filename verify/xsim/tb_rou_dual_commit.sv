`include "rapt.svh"
`include "rapt_if.svh"

module tb_rou_dual_commit #(
    parameter bit CheckOperandIndependence = 0
);
  localparam int CandidateBits = rapt_pkg::index_bits(rapt_pkg::DispatchWidth);

  import rapt_pkg::*;

  localparam int XLEN = `RAPT_XLEN;
  localparam int RobW = $clog2(`RAPT_ROB_SIZE);
  localparam int PLEN = `RAPT_PHY_LEN;
  localparam int RLEN = `RAPT_REG_LEN;

  logic clock = 1'b0;
  logic reset = 1'b1;

  logic clint_timer_trap;
  logic clint_sw_trap;
  logic clint_ext_trap;
  logic s_int_pending;
  logic [XLEN-1:0] s_int_cause;

  logic dm_haltreq;
  logic halted;
  logic [XLEN-1:0] halt_pc;
  logic commit_fire;
  logic pmu_rob_full;

  rnu_rou_if rnu_rou ();
  rapt_recovery_if recovery ();
  checkpoint_release_if checkpoint_release ();
  exu_prf_if exu_prf ();
  rapt_pkg::dispatch_slot_t dispatch[rapt_pkg::DispatchWidth];
  logic dispatch_valid[rapt_pkg::DispatchWidth];
  logic dispatch_ready[rapt_pkg::DispatchWidth];
  rapt_pkg::execution_domain_t candidate_domain[rapt_pkg::DispatchWidth];
  logic selected_valid[rapt_pkg::DispatchWidth];
  logic [rapt_pkg::index_bits(rapt_pkg::DispatchWidth)-1:0]
      selected_candidate[rapt_pkg::DispatchWidth];
  for (genvar s = 0; s < rapt_pkg::DispatchWidth; s++) begin : g_select_identity
    assign selected_valid[s] = dispatch_valid[s];
    assign selected_candidate[s] = CandidateBits'(s);
  end
  rapt_pkg::completion_t exu_rou;
  rapt_pkg::completion_t exu_rou_b;
  rapt_pkg::completion_t exu_rou_c;
  rapt_pkg::completion_t exu_ioq_bcast;
  rapt_pkg::completion_t exu_wb_mul;
  rapt_pkg::completion_t completion[rapt_pkg::CompletionPorts];
  rapt_pkg::completion_t completion_stimulus[rapt_pkg::CompletionPorts];
  rob_completion_owner_if completion_owner ();
  logic force_stale_generation;
  assign completion_stimulus[0] = exu_rou;
  assign completion_stimulus[1] = exu_rou_b;
  assign completion_stimulus[2] = exu_rou_c;
  assign completion_stimulus[3] = exu_ioq_bcast;
  assign completion_stimulus[4] = exu_wb_mul;
  // One-way construction: never read a packed record to drive another field
  // of that same record. Identity enrichment is fixture convenience, not a
  // model of an execution unit retaining its own allocation token.
  for (genvar p = 0; p < rapt_pkg::CompletionPorts; p++) begin : g_completion_input
    if (p >= 5) assign completion_stimulus[p] = '0;
    always_comb begin
      completion[p] = completion_stimulus[p];
      completion[p].generation = completion_owner.generation[completion_stimulus[p].dest]
          - rapt_pkg::rob_generation_t'(p == 0 && force_stale_generation);
      completion[p].prd = completion_owner.prd[completion_stimulus[p].dest];
      completion[p].rd = completion_owner.rd[completion_stimulus[p].dest];
`ifdef RAPT_TEST_FP_IRQ_COMPOSE
      if (p == 4) begin
        completion[p] = fp_irq_wb;
        completion[p].valid = fp_irq_wb.valid && fp_irq_accept;
      end
`endif
    end
  end

  csr_bcast_if csr_bcast ();
  rou_cmu_if rou_cmu ();
  rou_csr_if rou_csr ();
  rou_lsu_if rou_lsu ();
  logic tb_sq_ready, tb_sq_empty;
`ifndef RAPT_TEST_ATOMIC_REPLAY
  assign rou_lsu.sq_ready = tb_sq_ready;
  assign rou_lsu.sq_empty = tb_sq_empty;
`endif
  cmu_bcast_if cmu_bcast ();

  rapt_rou #(
      .ScanEntries(rapt_pkg::DispatchWidth),
      .ValidateCompletionInputs(1'b1)
  ) dut_rou (
      .completion(completion),
      .completion_owner(completion_owner),
      .clock(clock),
      .rnu_rou(rnu_rou),
      .recovery(recovery),
      .checkpoint_release(checkpoint_release),
      .exu_prf(exu_prf),
      .dispatch(dispatch),
      .candidate_domain(candidate_domain),
      .candidate_valid(dispatch_valid),
      .candidate_ready(dispatch_ready),
      .selected_valid(selected_valid),
      .selected_candidate(selected_candidate),

      .csr_bcast(csr_bcast),
      .clint_timer_trap(clint_timer_trap),
      .clint_sw_trap(clint_sw_trap),
      .clint_ext_trap(clint_ext_trap),
      .s_int_pending(s_int_pending),
      .s_int_cause(s_int_cause),
      .rou_cmu(rou_cmu),
      .rou_csr(rou_csr),
      .rou_lsu(rou_lsu),
      .dm_haltreq_i(dm_haltreq),
      .halted_o(halted),
      .halt_pc_o(halt_pc),
      .commit_fire_o(commit_fire),
      .pmu_rob_full(pmu_rob_full),
      .reset(reset)
  );

  `include "tb_rou_operand_pair.svh"

rapt_cmu dut_cmu (
      .clock(clock),
      .rou_cmu(rou_cmu),
      .cmu_bcast(cmu_bcast),
      .reset(reset)
  );

  always #5 clock = ~clock;

  `include "tb_common.svh"
  `include "tb_core_bcast_defaults.svh"
  `include "tb_rou_recovery_events.svh"

  assign exu_rou.updates = '{control_flow:1'b1, system_state:1'b1, exception:1'b1, default:'0};
  assign exu_rou_b.updates = '{control_flow:1'b1, default:'0};
  assign exu_rou_c.updates = '{control_flow:1'b1, default:'0};
  assign exu_ioq_bcast.updates = '{memory:1'b1, exception:1'b1, default:'0};
  assign exu_wb_mul.updates = '{control_flow:1'b1, default:'0};
`ifdef RAPT_TEST_ATOMIC_REPLAY
  `include "tb_rou_atomic_replay.svh"
`endif
  task automatic clear_writebacks;
    begin
      exu_rou.valid = 1'b0;
      exu_rou_b.valid = 1'b0;
      exu_rou_c.valid = 1'b0;
      exu_ioq_bcast.valid = 1'b0;
      exu_wb_mul.valid = 1'b0;
    end
  endtask

  task automatic init_inputs;
    begin
      clint_timer_trap = 1'b0;
      clint_sw_trap = 1'b0;
      clint_ext_trap = 1'b0;
      s_int_pending = 1'b0;
      s_int_cause = '0;
      dm_haltreq = 1'b0;
      force_stale_generation = 1'b0;

      rnu_rou.slot[0].uop = '0;
      rnu_rou.slot[0].pr1 = '0;
      rnu_rou.slot[0].pr2 = '0;
      rnu_rou.slot[0].prd = '0;
      rnu_rou.slot[0].prs = '0;
      rnu_rou.slot[0].op1 = '0;
      rnu_rou.slot[0].op2 = '0;
      rnu_rou.valid[0] = 1'b0;
      rnu_rou.checkpoint_valid[0] = 1'b0;
      rnu_rou.checkpoint[0] = '0;
`ifdef RAPT_DUAL_ISSUE
      rnu_rou.slot[1].uop = '0;
      rnu_rou.slot[1].pr1 = '0;
      rnu_rou.slot[1].pr2 = '0;
      rnu_rou.slot[1].prd = '0;
      rnu_rou.slot[1].prs = '0;
      rnu_rou.slot[1].op1 = '0;
      rnu_rou.slot[1].op2 = '0;
      rnu_rou.valid[1] = 1'b0;
      rnu_rou.checkpoint_valid[1] = 1'b0;
      rnu_rou.checkpoint[1] = '0;
`endif

      exu_prf.pv1[0] = '0;
      exu_prf.pv2[0] = '0;
      exu_prf.pv1_valid[0] = 1'b1;
      exu_prf.pv2_valid[0] = 1'b1;
`ifdef RAPT_DUAL_ISSUE
      exu_prf.pv1[1] = '0;
      exu_prf.pv2[1] = '0;
      exu_prf.pv1_valid[1] = 1'b1;
      exu_prf.pv2_valid[1] = 1'b1;
`endif

      dispatch_ready[0] = 1'b1;
`ifdef RAPT_DUAL_ISSUE
      dispatch_ready[1] = 1'b1;
`endif

      exu_rou.pc = '0;
      exu_rou.npc = '0;
      exu_rou.btaken = 1'b0;
      exu_rou.mispredict = 1'b0;
      exu_rou.dest = '0;
      exu_rou.result = '0;
      exu_rou.csr_wen = 1'b0;
      exu_rou.csr_wdata = '0;
      exu_rou.trap = 1'b0;
      exu_rou.tval = '0;
      exu_rou.cause = '0;
      exu_rou.difftest_skip = 1'b0;

      exu_rou_b.pc = '0;
      exu_rou_b.npc = '0;
      exu_rou_b.btaken = 1'b0;
      exu_rou_b.mispredict = 1'b0;
      exu_rou_b.trap = 1'b0;
      exu_rou_b.dest = '0;
      exu_rou_b.result = '0;
      exu_rou_b.difftest_skip = 1'b0;

      exu_rou_c.pc = '0;
      exu_rou_c.npc = '0;
      exu_rou_c.btaken = 1'b0;
      exu_rou_c.mispredict = 1'b0;
      exu_rou_c.dest = '0;
      exu_rou_c.difftest_skip = 1'b0;

      exu_ioq_bcast.pc = '0;
      exu_ioq_bcast.npc = '0;
      exu_ioq_bcast.result = '0;
      exu_ioq_bcast.dest = '0;
      exu_ioq_bcast.wen = 1'b0;
      exu_ioq_bcast.alu = '0;
      exu_ioq_bcast.sq_waddr = '0;
      exu_ioq_bcast.sq_wdata = '0;
      exu_ioq_bcast.sq_wdata64 = '0;
      exu_ioq_bcast.sq_fp64 = 1'b0;
      exu_ioq_bcast.trap = 1'b0;
      exu_ioq_bcast.tval = '0;
      exu_ioq_bcast.cause = '0;
      exu_ioq_bcast.difftest_skip = 1'b0;

      clear_writebacks();

      init_csr_bcast_defaults(`RAPT_PRIV_M, 32'h2000_0000, 1'b1);

      tb_sq_ready = 1'b1;
      tb_sq_empty = 1'b1;
    end
  endtask

  task automatic expect_stale_generation_is_rejected;
    begin
      reset_dut();

      // Allocate generation 0, resolve a branch and let its precise recovery
      // flush reset the ROB pointers without resetting the generation counter.
      dispatch_one(make_branch_uop(32'h8007_0000, 32'h0000_0863), '0, '0, RobW'(0));
      exu_rou.dest = RobW'(0);
      exu_rou.npc = 32'h8007_0100;
      exu_rou.btaken = 1'b1;
      exu_rou.mispredict = 1'b1;
      exu_rou.valid = 1'b1;
      tick(1);
      clear_writebacks();
      exu_rou.btaken = 1'b0;
      exu_rou.mispredict = 1'b0;
      #1;
      check(rou_cmu.flush_pipe, "generation seed branch did not flush");
      tick(2);

      dispatch_one(make_alu_uop(32'h8007_0100, 32'h0010_0093, 5'd1), 6'd33, 6'd1, RobW'(0));
      check(dut_rou.rob_entry[0].generation == rapt_pkg::rob_generation_t'(1),
            "ROB generation did not survive flush and advance on reuse");

      // Same slot and immutable payload, but the previous generation: the
      // local ROB guard must leave the current owner executing.
      force_stale_generation = 1'b1;
      exu_rou.dest = RobW'(0);
      exu_rou.npc = 32'h8007_0104;
      exu_rou.valid = 1'b1;
      #1;
      check(!dut_rou.completion_valid[0], "stale generation passed the ROB guard");
      tick(1);
      clear_writebacks();
      force_stale_generation = 1'b0;
      #1;
      check(dut_rou.rob_entry[0].state == ROB_EX && !commit_fire,
            "stale generation changed the current ROB owner");

      writeback_alu_one(RobW'(0), 32'h8007_0104);
      check(commit_fire, "current generation was rejected after stale completion");
      tick(1);
    end
  endtask

  function automatic rapt_pkg::uop_t make_alu_uop(
      input logic [XLEN-1:0] pc, input logic [31:0] inst, input logic [RLEN-1:0] rd);
    rapt_pkg::uop_t u;
    begin
      u = '0;
      u.pc = pc;
      u.pnpc = pc + XLEN'(4);
      u.inst = inst;
      u.rd = rd;
      u.execute.int_op.alu = `RAPT_ALU_ADD_;
      return u;
    end
  endfunction

  function automatic rapt_pkg::uop_t make_store_uop(input logic [XLEN-1:0] pc,
                                                    input logic [31:0] inst);
    rapt_pkg::uop_t u;
    begin
      u = '0;
      u.pc = pc;
      u.pnpc = pc + XLEN'(4);
      u.inst = inst;
      u.execute.memory.store = 1'b1;
      u.execute.int_op.alu = `RAPT_ALU_SW__;
      return u;
    end
  endfunction

  function automatic rapt_pkg::uop_t make_branch_uop(input logic [XLEN-1:0] pc,
                                                     input logic [31:0] inst);
    rapt_pkg::uop_t u;
    begin
      u = '0;
      u.pc = pc;
      u.pnpc = pc + XLEN'(4);
      u.inst = inst;
      u.execute.branch.conditional = 1'b1;
      return u;
    end
  endfunction

  function automatic rapt_pkg::uop_t make_sret_uop(input logic [XLEN-1:0] pc);
    rapt_pkg::uop_t u;
    begin
      u = '0;
      u.pc = pc;
      u.pnpc = pc + XLEN'(4);
      u.inst = 32'h1020_0073;
      u.execute.sys.valid = 1'b1;
      u.execute.sys.sret = 1'b1;
      return u;
    end
  endfunction

  function automatic rapt_pkg::uop_t make_ecall_uop(input logic [XLEN-1:0] pc);
    rapt_pkg::uop_t u;
    begin
      u = '0;
      u.pc = pc;
      u.pnpc = pc + XLEN'(4);
      u.inst = 32'h0000_0073;
      u.execute.sys.valid = 1'b1;
      u.execute.sys.ecall = 1'b1;
      return u;
    end
  endfunction

  function automatic rapt_pkg::uop_t make_fp_load_uop(input logic [XLEN-1:0] pc,
                                                      input logic [11:0] immediate);
    rapt_pkg::uop_t u;
    begin
      u = '0;
      u.pc = pc;
      u.pnpc = pc + XLEN'(4);
      u.inst = 32'h1001_3087;
      u.execute.fp.valid = 1'b1;
      u.execute.fp.op = `RAPT_FP_OP_FLD;
      u.execute.fp.rd = 5'd1;
      u.imm = XLEN'(immediate);
      return u;
    end
  endfunction

  task automatic reset_dut;
    begin
      reset = 1'b1;
      init_inputs();
      tick(4);
      reset = 1'b0;
      tick(1);
      check(rnu_rou.ready[0], "ROU not ready after reset");
      check(!rou_cmu.slot[0].valid, "ROU reports commit after reset");
      check(!cmu_bcast.flush_pipe, "CMU reports flush after reset");
    end
  endtask

  task automatic dispatch_one(input rapt_pkg::uop_t u, input logic [PLEN-1:0] prd,
                              input logic [PLEN-1:0] prs, input logic [RobW-1:0] expected_dest);
    begin
      rnu_rou.slot[0].uop = u;
      rnu_rou.slot[0].pr1 = '0;
      rnu_rou.slot[0].pr2 = '0;
      rnu_rou.slot[0].prd = prd;
      rnu_rou.slot[0].prs = prs;
      rnu_rou.slot[0].op1 = '0;
      rnu_rou.slot[0].op2 = '0;
      rnu_rou.checkpoint_valid[0] = u.execute.branch.conditional
          || u.execute.branch.jump || u.execute.branch.indirect;
      rnu_rou.checkpoint[0] = rapt_pkg::branch_checkpoint_t'(expected_dest);
      rnu_rou.valid[0] = 1'b1;
      #1;
      check(rnu_rou.ready[0], "ROU rejected enqueue unexpectedly");
      tick(1);
      rnu_rou.valid[0] = 1'b0;
      #1;
      check(dispatch_valid[0], "ROU did not present dispatch after enqueue");
      check(dispatch[0].dest == expected_dest, "ROU dispatch dest mismatch");
      tick(1);
      #1;
      check(!dispatch_valid[0], "ROU dispatch valid did not drop after accept");
    end
  endtask

  task automatic buffer_one(input rapt_pkg::uop_t u, input logic [PLEN-1:0] prd,
                            input logic [PLEN-1:0] prs, input logic [RobW-1:0] expected_dest);
    begin
      rnu_rou.slot[0] = '0;
      rnu_rou.slot[0].uop = u;
      rnu_rou.slot[0].prd = prd;
      rnu_rou.slot[0].prs = prs;
      rnu_rou.checkpoint_valid[0] = u.execute.branch.conditional
          || u.execute.branch.jump || u.execute.branch.indirect;
      rnu_rou.checkpoint[0] = rapt_pkg::branch_checkpoint_t'(expected_dest);
      rnu_rou.valid[0] = 1'b1;
      #1;
      check(rnu_rou.ready[0], "ROU rejected buffered allocation input");
      tick(1);
      rnu_rou.valid[0] = 1'b0;
      tick(1);
      #1;
      check(
          dut_rou.rob_entry[expected_dest].busy && dut_rou.rob_entry[expected_dest].state == ROB_DP,
          "uop did not enter ROB-backed dispatch buffer");
    end
  endtask

  task automatic expect_cross_domain_dispatch_bypass;
    begin
      reset_dut();
      dispatch_ready[0] = 1'b0;
      dispatch_ready[1] = 1'b0;
      buffer_one(make_branch_uop(32'h8009_0000, 32'h0000_0063), '0, '0, RobW'(0));
      buffer_one(make_alu_uop(32'h8009_0004, 32'h0010_0093, 5'd1), 6'd33, 6'd1, RobW'(1));

      dispatch_ready[1] = 1'b1;
      #1;
      check(dispatch_valid[0] && dispatch[0].dest == RobW'(0),
            "oldest blocked branch was not first steering candidate");
      check(dispatch_valid[1] && dispatch[1].dest == RobW'(1),
            "younger integer uop was not exposed as a steering candidate");
      check(!dut_rou.endpoint_fire[0] && dut_rou.endpoint_fire[1],
            "ready younger domain did not bypass blocked older domain");
      tick(1);
      #1;
      check(dut_rou.rob_entry[0].state == ROB_DP && dut_rou.rob_entry[1].state == ROB_EX,
            "cross-domain bypass changed the wrong ROB owner state");
      check(dut_rou.pmu_steer_bypass == 1, "cross-domain bypass event was not measured");

      dispatch_ready[0] = 1'b1;
      #1;
      check(dispatch_valid[0] && dispatch[0].dest == RobW'(0),
            "previously blocked oldest owner disappeared");
      tick(1);
      #1;
      check(dut_rou.rob_entry[0].state == ROB_EX,
            "previously blocked oldest owner did not dispatch when ready");
    end
  endtask

  task automatic expect_dispatch_edge_writeback_merge;
    begin
      reset_dut();
      dispatch_one(make_alu_uop(32'h800a_0000, 32'h0010_0093, 5'd1), 6'd33, 6'd1, RobW'(0));

      // Keep a dependent consumer resident in ROB_DP.  Its producer completes
      // on the exact edge on which the execution-domain endpoint accepts it.
      // The dispatch boundary must expose the value and clear the tag in this
      // cycle; a registered-only resident snoop would lose the one-shot CDB.
      dispatch_ready[0] = 1'b0;
      dispatch_ready[1] = 1'b0;
      rnu_rou.slot[0] = '0;
      rnu_rou.slot[0].uop = make_alu_uop(32'h800a_0004, 32'h0010_0113, 5'd2);
      rnu_rou.slot[0].pr1 = 6'd33;
      rnu_rou.slot[0].prd = 6'd34;
      rnu_rou.slot[0].prs = 6'd2;
      exu_prf.pv1_valid[0] = 1'b0;
      rnu_rou.valid[0] = 1'b1;
      #1;
      check(rnu_rou.ready[0], "ROU rejected dependent merge-test input");
      tick(1);
      rnu_rou.valid[0] = 1'b0;
      tick(1);
      #1;
      check(dut_rou.rob_entry[1].state == ROB_DP,
            "dependent merge-test uop did not wait in ROB_DP");

      exu_rou.dest = RobW'(0);
      exu_rou.npc = 32'h800a_0004;
      exu_rou.result = 32'hcafe_babe;
      exu_rou.valid = 1'b1;
      dispatch_ready[0] = 1'b1;
      #1;
      check(dispatch_valid[0] && dispatch[0].dest == RobW'(1),
            "dependent merge-test uop was not presented to its endpoint");
      check(dispatch[0].pr1 == '0 && dispatch[0].op1 == 32'hcafe_babe,
            "same-cycle completion was not merged at ROB dispatch output");
      tick(1);
      clear_writebacks();
      exu_prf.pv1_valid[0] = 1'b1;
      #1;
      check(dut_rou.rob_entry[0].state == ROB_WB && dut_rou.rob_entry[1].state == ROB_EX,
            "merge edge changed the wrong ROB lifecycle state");
    end
  endtask

  task automatic writeback_alu_pair(input logic [XLEN-1:0] npc0, input logic [XLEN-1:0] npc1,
                                    input bit slot1_mispredict);
    begin
      exu_rou.dest = RobW'(0);
      exu_rou.npc = npc0;
      exu_rou.btaken = 1'b0;
      exu_rou.mispredict = 1'b0;
      exu_rou.trap = 1'b0;
      exu_rou.difftest_skip = 1'b0;
      exu_rou.valid = 1'b1;

      exu_rou_b.dest = RobW'(1);
      exu_rou_b.npc = npc1;
      exu_rou_b.btaken = slot1_mispredict;
      exu_rou_b.mispredict = slot1_mispredict;
      exu_rou_b.difftest_skip = 1'b0;
      exu_rou_b.valid = 1'b1;

      tick(1);
      clear_writebacks();
      #1;
    end
  endtask

  task automatic writeback_store0_alu1;
    begin
      exu_ioq_bcast.dest = RobW'(0);
      exu_ioq_bcast.npc = 32'h8000_1004;
      exu_ioq_bcast.wen = 1'b1;
      exu_ioq_bcast.alu = `RAPT_ALU_SW__;
      exu_ioq_bcast.sq_waddr = 32'h8000_2000;
      exu_ioq_bcast.sq_wdata = 32'h1234_5678;
      exu_ioq_bcast.trap = 1'b0;
      exu_ioq_bcast.difftest_skip = 1'b0;
      exu_ioq_bcast.valid = 1'b1;

      exu_rou_b.dest = RobW'(1);
      exu_rou_b.npc = 32'h8000_1008;
      exu_rou_b.btaken = 1'b0;
      exu_rou_b.mispredict = 1'b0;
      exu_rou_b.difftest_skip = 1'b0;
      exu_rou_b.valid = 1'b1;

      tick(1);
      clear_writebacks();
      exu_ioq_bcast.wen = 1'b0;
      #1;
    end
  endtask

  task automatic writeback_alu_one(input logic [RobW-1:0] dest, input logic [XLEN-1:0] npc);
    begin
      exu_rou.dest = dest;
      exu_rou.npc = npc;
      exu_rou.btaken = 1'b0;
      exu_rou.mispredict = 1'b0;
      exu_rou.trap = 1'b0;
      exu_rou.difftest_skip = 1'b0;
      exu_rou.valid = 1'b1;
      tick(1);
      clear_writebacks();
      #1;
    end
  endtask

  task automatic expect_basic_dual_commit;
    begin
      reset_dut();
      dispatch_one(make_alu_uop(32'h8000_0000, 32'h0010_0093, 5'd1), 6'd33, 6'd1, RobW'(0));
      dispatch_one(make_alu_uop(32'h8000_0004, 32'h0020_0113, 5'd2), 6'd34, 6'd2, RobW'(1));
      writeback_alu_pair(32'h8000_0004, 32'h8000_0008, 1'b0);

      check(commit_fire, "basic pair did not assert commit_fire");
      check(rou_cmu.slot[0].valid, "basic pair missing slot0 commit");
      check(rou_cmu.slot[1].valid, "basic pair missing slot1 commit");
      check(!rou_cmu.flush_pipe, "basic pair unexpectedly flushed");
      check(rou_cmu.slot[0].rd == 5'd1, "basic pair slot0 rd mismatch");
      check(rou_cmu.slot[1].rd == 5'd2, "basic pair slot1 rd mismatch");
      check(rou_cmu.slot[0].prd == 6'd33, "basic pair slot0 prd mismatch");
      check(rou_cmu.slot[1].prs == 6'd2, "basic pair slot1 prs mismatch");
      check(rou_cmu.slot[0].pc == 32'h8000_0000, "basic pair slot0 pc mismatch");
      check(rou_cmu.slot[1].pc == 32'h8000_0004, "basic pair slot1 pc mismatch");
      check(rou_cmu.slot[1].npc == 32'h8000_0008, "basic pair slot1 npc mismatch");
      check(dut_cmu.count == 2, "CMU did not observe both retiring instructions");
      check(rou_csr.retire_count == 2, "minstret count lost a normal dual retirement");
      check(cmu_bcast.rpc == 32'h8000_0004, "CMU broadcast did not select slot1 rpc");
      check(cmu_bcast.cpc == 32'h8000_0008, "CMU broadcast did not select slot1 cpc");

      tick(1);
      check(rou_cmu.rob_head == RobW'(2), "ROB head did not advance by 2 after dual commit");
      check(!rou_cmu.slot[0].valid, "basic pair still commits after retiring");
    end
  endtask

  task automatic expect_slot0_store_blocks_dual;
    begin
      reset_dut();
      dispatch_one(make_store_uop(32'h8000_1000, 32'h0020_a023), '0, '0, RobW'(0));
      dispatch_one(make_alu_uop(32'h8000_1004, 32'h0030_0193, 5'd3), 6'd35, 6'd3, RobW'(1));
      writeback_store0_alu1();

      check(commit_fire, "slot0 store did not assert commit_fire");
      check(rou_cmu.slot[0].valid, "slot0 store missing slot0 commit");
      check(!rou_cmu.slot[1].valid, "slot0 store incorrectly dual committed");
      check(rou_lsu.valid, "slot0 store did not drive LSU commit valid");
      check(rou_lsu.store, "slot0 store did not drive LSU store");
      check(rou_lsu.dest == RobW'(0), "slot0 store owner mismatch");

      tick(1);
      check(rou_cmu.rob_head == RobW'(1), "ROB head did not advance by 1 for slot0 store");
      check(rou_cmu.slot[0].valid, "slot1 should commit after slot0 store retires");
      check(!rou_cmu.slot[1].valid, "single remaining slot unexpectedly dual committed");
      tick(1);
      check(rou_cmu.rob_head == RobW'(2), "ROB head did not retire slot1 after store");
    end
  endtask

  task automatic expect_slot1_branch_serializes_flush;
    begin
      reset_dut();
      dispatch_one(make_alu_uop(32'h8000_2000, 32'h0040_0213, 5'd4), 6'd36, 6'd4, RobW'(0));
      dispatch_one(make_branch_uop(32'h8000_2004, 32'h0002_0863), '0, '0, RobW'(1));
      writeback_alu_pair(32'h8000_2004, 32'h8000_2080, 1'b1);

      check(commit_fire, "slot0 did not commit before serializing slot1 branch");
      check(rou_cmu.slot[0].valid, "serialized branch pair missing slot0 commit");
      check(!rou_cmu.slot[1].valid, "mispredicting slot1 branch incorrectly dual committed");
      check(!rou_cmu.flush_pipe, "slot1 branch flushed before reaching ROB head");

      tick(1);
      check(rou_cmu.rob_head == RobW'(1), "ROB head did not advance to serialized branch");
      check(commit_fire && rou_cmu.slot[0].valid, "serialized branch did not commit at ROB head");
      check(!rou_cmu.slot[1].valid, "serialized branch unexpectedly used slot1 commit");
      check(rou_cmu.flush_pipe, "serialized branch mispredict did not flush");
      check(rou_cmu.ben, "serialized branch did not drive branch metadata");
      check(rou_cmu.btaken, "serialized branch did not drive taken metadata");
      check(rou_cmu.slot[0].pc == 32'h8000_2004, "serialized branch pc mismatch");
      check(rou_cmu.slot[0].npc == 32'h8000_2080, "serialized branch target mismatch");
      check(cmu_bcast.flush_pipe, "CMU broadcast missing serialized branch flush");
      check(cmu_bcast.rpc == 32'h8000_2004, "CMU broadcast selected wrong branch rpc");
      check(cmu_bcast.cpc == 32'h8000_2080, "CMU broadcast selected wrong branch target");

      tick(1);
      check(rou_cmu.rob_head == RobW'(0), "flush did not reset ROB head");
      check(!rou_cmu.slot[0].valid, "ROU still reports commit after serialized branch flush");
      check(!cmu_bcast.flush_pipe, "CMU flush did not clear after one cycle");
    end
  endtask

  task automatic expect_rob_wrap_reuse_and_sret;
    localparam int WrapIterations = 4 * `RAPT_ROB_SIZE;
    logic [XLEN-1:0] pc;
    logic [RobW-1:0] dest;
    begin
      reset_dut();

      pc = 32'h8000_0400;
      dispatch_one(make_ecall_uop(pc), '0, '0, RobW'(0));
      check(
          dut_rou.uop_pl[0].execute.sys.ecall && !dut_rou.uop_pl[0].execute.sys.ebreak
          && !dut_rou.uop_pl[0].execute.sys.mret && !dut_rou.uop_pl[0].execute.sys.sret,
          "ECALL payload classification was not exclusive");
      writeback_alu_one(RobW'(0), csr_bcast.mtvec);
      check(commit_fire && rou_cmu.slot[0].valid, "seed ECALL did not commit");
      check(rou_cmu.flush_pipe, "seed ECALL did not flush");
      check(rou_cmu.slot[0].npc == csr_bcast.mtvec, "seed ECALL did not select mtvec");
      tick(1);
      check(!rou_cmu.slot[0].valid && !rou_csr.valid,
            "flushed ECALL remained architecturally visible");

      for (int iteration = 0; iteration < WrapIterations; iteration++) begin
        pc = 32'h8001_0000 + XLEN'(iteration * 4);
        dest = RobW'(iteration);
        dispatch_one(make_alu_uop(pc, 32'h0010_0093, 5'd1), PLEN'(33), PLEN'(1), dest);
        writeback_alu_one(dest, pc + XLEN'(4));

        check(commit_fire && rou_cmu.slot[0].valid, "ROB wrap entry did not become committable");
        check(!rou_cmu.slot[1].valid, "ROB wrap entry unexpectedly dual committed");
        check(rou_cmu.slot[0].pc == pc, "ROB wrap reused stale PC payload");
        check(rou_cmu.slot[0].npc == pc + XLEN'(4), "ROB wrap reused stale NPC payload");
        tick(1);
        check(rou_cmu.rob_head == RobW'(iteration + 1), "ROB head mismatch across wrap/reuse");
      end

      pc = 32'h8002_0000;
      dest = RobW'(WrapIterations);
      dispatch_one(make_sret_uop(pc), '0, '0, dest);
      check(
          dut_rou.uop_pl[dest].execute.sys.sret && !dut_rou.uop_pl[dest].execute.sys.ecall
          && !dut_rou.uop_pl[dest].execute.sys.ebreak && !dut_rou.uop_pl[dest].execute.sys.mret,
          "SRET reused stale ECALL/EBREAK/MRET payload");
      writeback_alu_one(dest, 32'h0001_2340);

      check(commit_fire && rou_cmu.slot[0].valid, "post-wrap SRET did not commit");
      check(rou_csr.valid && rou_csr.sret, "post-wrap SRET metadata was corrupted");
      check(rou_cmu.flush_pipe, "post-wrap SRET did not flush");
      check(rou_cmu.slot[0].npc == 32'h0001_2340, "post-wrap SRET used a stale redirect target");
      check(rou_cmu.slot[0].npc != csr_bcast.mtvec,
            "post-wrap SRET was contaminated by the old ECALL mtvec target");
      tick(1);
      check(rou_cmu.flush_redirect, "post-wrap SRET redirect was not registered");
      check(rou_cmu.redirect_pc == 32'h0001_2340,
            "post-wrap SRET registered the wrong redirect target");
      tick(1);
      check(!rou_cmu.flush_redirect, "post-wrap SRET redirect did not clear");
    end
  endtask

  task automatic expect_stale_csr_wen_is_not_exposed;
    begin
      reset_dut();

      // Seed csr_wen in slot 1, then flush it as the younger instruction
      // behind a mispredicted branch. Flush intentionally only resets ROB
      // validity/state, so the hot csr_wen field remains stale.
      dispatch_one(make_branch_uop(32'h8003_0000, 32'h0000_0863), '0, '0, RobW'(0));
      dispatch_one(make_alu_uop(32'h8003_0004, 32'h0000_0013, 5'd0), '0, '0, RobW'(1));

      exu_rou.dest = RobW'(1);
      exu_rou.npc = 32'h8003_0008;
      exu_rou.csr_wen = 1'b1;
      exu_rou.csr_wdata = '0;
      exu_rou.valid = 1'b1;
      tick(1);
      clear_writebacks();
      exu_rou.csr_wen = 1'b0;

      exu_rou.dest = RobW'(0);
      exu_rou.npc = 32'h8003_0100;
      exu_rou.btaken = 1'b1;
      exu_rou.mispredict = 1'b1;
      exu_rou.valid = 1'b1;
      tick(1);
      clear_writebacks();
      exu_rou.btaken = 1'b0;
      exu_rou.mispredict = 1'b0;
      check(rou_cmu.flush_pipe, "seed branch did not request a flush");
      tick(1);
      check(dut_rou.rob_entry[1].csr_wen, "test setup did not preserve stale csr_wen across flush");
      tick(1);

      // Reuse slot 1 for a non-system FP load whose immediate aliases
      // sstatus.  Its FP-dirty retirement must not expose the stale CSR write.
      dispatch_one(make_alu_uop(32'h8003_1000, 32'h0000_0013, 5'd0), '0, '0, RobW'(0));
      writeback_alu_one(RobW'(0), 32'h8003_1004);
      check(commit_fire, "leading ALU did not commit before reused FP slot");
      tick(1);
      dispatch_one(make_fp_load_uop(32'h8003_1004, 12'h100), '0, '0, RobW'(1));

      exu_ioq_bcast.dest = RobW'(1);
      exu_ioq_bcast.npc = 32'h8003_1008;
      exu_ioq_bcast.wen = 1'b0;
      exu_ioq_bcast.trap = 1'b0;
      exu_ioq_bcast.valid = 1'b1;
      tick(1);
      clear_writebacks();
      #1;

      check(commit_fire && rou_csr.valid, "reused FP load did not produce an FP-dirty commit");
      check(rou_csr.fp_dirty, "reused FP load did not mark FS dirty");
      check(rou_csr.csr_addr == 12'h100,
            "reused FP load did not retain the sstatus-aliasing immediate");
      check(!rou_csr.csr_wen, "non-system FP load exposed stale csr_wen at retirement");
      tick(1);
    end
  endtask

  task automatic expect_registered_recovery_fence;
    begin
      // A resolved younger branch must stop new UOQ->ROB allocation while
      // older useful work can still complete and retire. Work already in the
      // ROB-backed dispatch buffer is age-gated and removed by precise flush.
      reset_dut();
      dispatch_one(make_alu_uop(32'h8004_0000, 32'h0010_0093, 5'd1), 6'd33, 6'd1, RobW'(0));
      dispatch_one(make_branch_uop(32'h8004_0004, 32'h0000_0863), '0, '0, RobW'(1));

      dispatch_ready[0] = 1'b0;
      dispatch_ready[1] = 1'b0;
      rnu_rou.slot[0].uop = make_alu_uop(32'h8004_0008, 32'h0020_0113, 5'd2);
      rnu_rou.slot[0].prd = 6'd34;
      rnu_rou.slot[0].prs = 6'd2;
      rnu_rou.checkpoint_valid[0] = 1'b0;
      rnu_rou.checkpoint[0] = '0;
      rnu_rou.valid[0] = 1'b1;
      #1;
      check(rnu_rou.ready[0], "wrong-path setup could not enter UOQ");
      tick(1);
      rnu_rou.valid[0] = 1'b0;
      tick(1);
      #1;
      check(dispatch_valid[0], "wrong-path setup did not reach dispatch endpoint");
      check(dut_rou.rob_entry[2].state == ROB_DP,
            "wrong-path setup was not retained in the ROB dispatch buffer");

      exu_rou_b.dest = RobW'(1);
      exu_rou_b.npc = 32'h8004_0100;
      exu_rou_b.btaken = 1'b1;
      exu_rou_b.mispredict = 1'b1;
      exu_rou_b.trap = 1'b0;
      exu_rou_b.valid = 1'b1;
      tick(1);
      clear_writebacks();
      #1;
      check(dut_rou.recovery_pending, "mispredict did not register recovery request");
      check(
          recovery.pending && recovery.redirect_valid && recovery.checkpoint_valid
            && recovery.checkpoint == rapt_pkg::branch_checkpoint_t'(1)
            && recovery.owner == RobW'(1)
            && recovery.target == 32'h8004_0100,
          "mispredict did not publish its rename checkpoint");
      check(dut_rou.recovery_owner == RobW'(1), "recovery request saved wrong owner");
      check(dut_rou.recovery_target == 32'h8004_0100, "recovery request saved wrong target");
      check(dut_rou.dispatch_stop == DispatchStopRecovery,
            "registered recovery did not own dispatch stop reason");

      dispatch_ready[0] = 1'b1;
      dispatch_ready[1] = 1'b1;
      #1;
      check(!dispatch_valid[0] && dut_rou.dispatch_count == 0,
            "registered recovery allowed wrong-path dispatch or new allocation");
      check(dut_rou.rob_tail == RobW'(3), "recovery fence changed ROB tail");

      writeback_alu_one(RobW'(0), 32'h8004_0004);
      check(commit_fire && rou_cmu.slot[0].valid, "recovery fence stopped older useful retirement");
      check(recovery.pending && !recovery.redirect_valid,
            "unchanged recovery owner repeated its redirect event");
      check(dut_rou.recovery_pending && !dispatch_valid[0],
            "recovery fence dropped before owner reached the head");
      check(dut_rou.rob_entry[2].state == ROB_DP,
            "recovery fence discarded pending ROB state before flush");

      tick(1);
      check(rou_cmu.flush_pipe && rou_cmu.slot[0].valid,
            "pending branch did not flush at precise retirement boundary");
      check(rou_cmu.slot[0].pc == 32'h8004_0004, "pending branch retired from the wrong ROB entry");
      tick(1);
      check(!dut_rou.recovery_pending, "full flush did not clear recovery request");
      check(!dut_rou.rob_entry[2].busy, "full flush did not clear pending wrong-path uop");
      check(dut_rou.rob_tail == '0 && dut_rou.rob_head == '0,
            "full flush did not reopen the base ROB identity");

      dispatch_one(make_alu_uop(32'h8004_0100, 32'h0030_0193, 5'd3), 6'd35, 6'd3, RobW'(0));
      writeback_alu_one(RobW'(0), 32'h8004_0104);
      check(commit_fire, "dispatch did not reopen after recovery flush");
      tick(1);

      // If a younger branch resolves first, a later older request must replace
      // it according to ROB ring age. The precise flush still occurs at head.
      reset_dut();
      dispatch_one(make_branch_uop(32'h8005_0000, 32'h0000_0863), '0, '0, RobW'(0));
      dispatch_one(make_branch_uop(32'h8005_0004, 32'h0000_0863), '0, '0, RobW'(1));
      exu_rou_b.dest = RobW'(1);
      exu_rou_b.npc = 32'h8005_0200;
      exu_rou_b.btaken = 1'b1;
      exu_rou_b.mispredict = 1'b1;
      exu_rou_b.trap = 1'b0;
      exu_rou_b.valid = 1'b1;
      tick(1);
      clear_writebacks();
      #1;
      check(dut_rou.recovery_pending && dut_rou.recovery_owner == RobW'(1),
            "younger recovery request setup failed");

      exu_rou.dest = RobW'(0);
      exu_rou.npc = 32'h8005_0100;
      exu_rou.btaken = 1'b1;
      exu_rou.mispredict = 1'b1;
      exu_rou.trap = 1'b0;
      exu_rou.valid = 1'b1;
      tick(1);
      clear_writebacks();
      #1;
      check(dut_rou.recovery_pending && dut_rou.recovery_owner == RobW'(0),
            "older late recovery request did not supersede younger owner");
      check(
          recovery.redirect_valid && recovery.checkpoint_valid
            && recovery.checkpoint == rapt_pkg::branch_checkpoint_t'(0)
            && recovery.owner == RobW'(0) && recovery.target == 32'h8005_0100,
          "older recovery did not replace rename checkpoint owner");
      check(dut_rou.recovery_target == 32'h8005_0100,
            "older late recovery request did not replace target");
      check(rou_cmu.flush_pipe, "older head recovery did not request precise flush");
      tick(1);
      check(!dut_rou.recovery_pending, "older recovery flush did not clear transaction");

      // Faulting control-flow completion is an exception transaction, not a
      // branch-recovery transaction; flush priority remains with retirement.
      reset_dut();
      dispatch_one(make_branch_uop(32'h8006_0000, 32'h0000_0863), '0, '0, RobW'(0));
      exu_rou.dest = RobW'(0);
      exu_rou.npc = 32'h8006_0100;
      exu_rou.btaken = 1'b1;
      exu_rou.mispredict = 1'b1;
      exu_rou.trap = 1'b1;
      exu_rou.cause = XLEN'(`RAPT_CAUSE_INSTR_PAGE_FAULT);
      exu_rou.valid = 1'b1;
      tick(1);
      clear_writebacks();
      exu_rou.trap = 1'b0;
      exu_rou.mispredict = 1'b0;
      #1;
      check(!dut_rou.recovery_pending,
            "faulting control-flow completion incorrectly created recovery request");
      check(rou_cmu.flush_pipe && rou_cmu.slot[0].trap,
            "faulting control flow did not retain exception flush priority");
      tick(1);
    end
  endtask

  task automatic expect_recovery_identity_reuse;
    rapt_pkg::rob_generation_t expected_generation;
    begin
      reset_dut();
      // Real flush/reallocation, no forced internal state. Keep slot and target
      // identical so only generation distinguishes these three transactions.
      for (int epoch = 0; epoch < 3; epoch++) begin
        dispatch_one(make_branch_uop(XLEN'('h8009_0000), 32'h0000_0863), '0, '0, RobW'(0));
        expected_generation = rapt_pkg::rob_generation_t'(epoch);
        check(completion_owner.generation[0] == expected_generation,
              "recovery reuse did not advance allocation generation");
        exu_rou.dest = RobW'(0);
        exu_rou.npc = XLEN'('h8009_0100);
        exu_rou.btaken = 1'b1;
        exu_rou.mispredict = 1'b1;
        exu_rou.valid = 1'b1;
        if (epoch != 0) begin
          force_stale_generation = 1'b1;
          tick(1);
          check(!recovery.pending && !recovery.redirect_valid && !commit_fire,
                "stale branch completion opened recovery or retired reused slot");
          check(dut_rou.rob_entry[0].state == ROB_EX,
                "stale branch completion changed reused execution state");
          force_stale_generation = 1'b0;
        end
        tick(1);
        clear_writebacks();
        // The producer bus is free to change after the accepted completion.
        exu_rou.npc = XLEN'('hdead_0000);
        #1;
        check(
            recovery.pending && recovery.redirect_valid && recovery.owner == RobW'(0)
              && recovery.generation == expected_generation
              && recovery.target == XLEN'('h8009_0100) && recovery.checkpoint_valid,
            "recovery publication lost held generation/target after slot reuse");
        check(rou_cmu.flush_pipe, "reused head branch failed precise recovery");
        tick(2);
        check(!recovery.pending && !recovery.redirect_valid,
              "precise flush left an announced recovery transaction alive");
      end
      $display("PASS: recovery identity reuse: 3 generations, 2 stale branches rejected");
    end
  endtask

  task automatic expect_correct_branch_releases_checkpoint;
    begin
      reset_dut();
      dispatch_one(make_branch_uop(32'h8008_0000, 32'h0000_0063), '0, '0, RobW'(0));
      exu_rou.dest = RobW'(0);
      exu_rou.npc = 32'h8008_0004;
      exu_rou.btaken = 1'b0;
      exu_rou.mispredict = 1'b0;
      exu_rou.trap = 1'b0;
      exu_rou.valid = 1'b1;
      #1;
      check(
          checkpoint_release.valid[0]
            && checkpoint_release.checkpoint[0] == rapt_pkg::branch_checkpoint_t'(0),
          "correct branch did not publish checkpoint release");
      check(!recovery.pending && !recovery.redirect_valid,
            "correct branch incorrectly opened recovery transaction");
      tick(1);
      clear_writebacks();
      check(commit_fire && !rou_cmu.flush_pipe,
            "correct branch did not retire without recovery flush");
      tick(1);
    end
  endtask

  task automatic expect_cbo_zero_commit_with_resident_sq;
    rapt_pkg::uop_t u;
    begin
      reset_dut();
      u = make_store_uop(XLEN'('h8000_2000), 32'h0040_a00f);
      u.execute.sys.fence = 1'b1;
      dispatch_one(u, '0, '0, RobW'(0));
      // CBO.ZERO has already allocated its speculative SQ resident at WB.
      // That resident cannot drain until the ROB marks it committed.
      tb_sq_empty = 1'b0;
      exu_ioq_bcast.dest = RobW'(0);
      exu_ioq_bcast.npc = u.pnpc;
      exu_ioq_bcast.wen = 1'b1;
      exu_ioq_bcast.valid = 1'b1;
      tick(1);
      clear_writebacks();
      #1;
      check(commit_fire && rou_lsu.valid && rou_lsu.store,
            "CBO.ZERO waits for its own uncommitted SQ resident to drain");
      check(rou_cmu.flush_pipe && !rou_cmu.slot[1].valid,
            "CBO.ZERO must still retire alone and resume fetch through recovery");
      tick(1);

      // A real fence does not own an SQ resident and must still drain stores.
      reset_dut();
      u = make_alu_uop(XLEN'('h8000_2004), 32'h0ff0_000f, '0);
      u.execute.sys.fence = 1'b1;
      dispatch_one(u, '0, '0, RobW'(0));
      tb_sq_empty = 1'b0;
      writeback_alu_one(RobW'(0), u.pnpc);
      check(!commit_fire, "FENCE retired while older stores remain in SQ");
      tick(3);
      check(!commit_fire, "FENCE stopped waiting for the SQ to drain");
      tb_sq_empty = 1'b1;
      #1;
      check(commit_fire && rou_cmu.flush_pipe, "FENCE did not retire after SQ drain");
      tick(1);
    end
  endtask

  task automatic expect_full_width_retirement;
    localparam logic [XLEN-1:0] Pc = XLEN'(64'h1234_5678_8009_0000);
    localparam logic [XLEN-1:0] NextPc = Pc + XLEN'(4);
    localparam logic [XLEN-1:0] Address = XLEN'(64'h89ab_cdef_800a_0000);
    localparam logic [XLEN-1:0] Data = XLEN'(64'hfedc_ba98_7654_3210);
    localparam logic [63:0] FpData = 64'hd00d_beef_1357_2468;
    begin
      reset_dut();
      dispatch_one(make_alu_uop(Pc, 32'h0010_0093, 5'd1), PLEN'(33), PLEN'(1), RobW'(0));
      writeback_alu_one(RobW'(0), NextPc);
      // The completion bus may immediately serve another owner. Retirement
      // must use persistent metadata, including the upper half in RV64.
      exu_rou.npc = ~NextPc;
      #1;
      check(commit_fire && rou_cmu.slot[0].pc == Pc && rou_cmu.slot[0].npc == NextPc,
            "full-width PC/NPC metadata was truncated or bypassed");
      tick(1);
      check(halt_pc == NextPc, "full-width architectural next PC was not retained");

      reset_dut();
      dispatch_one(make_store_uop(Pc, 32'h0020_a023), '0, '0, RobW'(0));
      tb_sq_ready = 1'b0;
      exu_ioq_bcast.dest = RobW'(0);
      exu_ioq_bcast.npc = NextPc;
      exu_ioq_bcast.wen = 1'b1;
      exu_ioq_bcast.sq_waddr = Address;
      exu_ioq_bcast.tval = Address;
      exu_ioq_bcast.sq_wdata = Data;
      exu_ioq_bcast.sq_wdata64 = FpData;
      exu_ioq_bcast.sq_fp64 = 1'b1;
      exu_ioq_bcast.valid = 1'b1;
      tick(1);
      clear_writebacks();
      exu_ioq_bcast.sq_waddr = ~Address;
      exu_ioq_bcast.tval = ~Address;
      exu_ioq_bcast.sq_wdata = ~Data;
      exu_ioq_bcast.sq_wdata64 = ~FpData;
      exu_ioq_bcast.sq_fp64 = 1'b0;
      tick(2);
      check(!commit_fire, "store retired despite SQ backpressure");
      tb_sq_ready = 1'b1;
      #1;
      check(commit_fire && rou_lsu.valid && rou_lsu.store,
            "held store did not retire after SQ backpressure cleared");
      check(rou_lsu.dest == RobW'(0) && rou_lsu.sq_vaddr == Address,
            "store retirement identity/address witness was truncated or transient");
`ifdef RAPT_RVFI
      check(rou_cmu.slot[0].rvfi_sq_waddr == Address && rou_cmu.slot[0].rvfi_sq_wdata == Data,
            "dedicated RVFI memory trace did not retain the completion payload");
`endif
      tick(1);
    end
  endtask

  task automatic expect_bus_error_interrupt;
    begin
      reset_dut();
      csr_bcast.bus_error_int=1;
      clint_ext_trap=1;
      clint_sw_trap=1;
      clint_timer_trap=1;
      s_int_pending=1;
      s_int_cause=(XLEN'(1)<<(XLEN-1))|9;
      tick(1);
      check(
          rou_csr.valid && rou_csr.trap && rou_csr.tval==0
          && rou_csr.cause==((XLEN'(1)<<(XLEN-1))|16),
          "empty ROB did not prioritize platform bus error interrupt");
      reset_dut();
      dispatch_one(make_alu_uop('h80001200, 32'h00100093, RLEN'(1)), PLEN'(32), '0, RobW'(0));
      writeback_alu_one(RobW'(0), 'h80001204);
      csr_bcast.bus_error_int = 1;
      tick(1);
      check(
          rou_csr.valid && rou_csr.trap && rou_csr.pc=='h80001204
          && rou_csr.cause==((XLEN'(1)<<(XLEN-1))|16),
          "bus error did not preserve post-retirement interrupt PC");
      csr_bcast.bus_error_int = 0;
      tick(3);
    end
  endtask

`ifdef RAPT_TEST_RETIRE_COUNT
  `include "tb_rou_retire_count.svh"
`endif
`ifdef RAPT_TEST_FP_IRQ_BOUNDARY
`ifdef RAPT_TEST_FP_IRQ_COMPOSE
  `include "tb_rou_fp_irq_compose.svh"
`endif
  `include "tb_rou_fp_irq_boundary.svh"
`endif

`ifdef RAPT_TEST_EXCEPTION_RD
  `include "tb_rou_exception_rd.svh"
`endif

  initial begin
`ifndef RAPT_DUAL_COMMIT
    fail("tb_rou_dual_commit requires RAPT_DUAL_COMMIT enabled");
`endif

`ifdef RAPT_TEST_EXCEPTION_RD
    run_exception_rd();
    $finish;
`elsif RAPT_TEST_FP_IRQ_BOUNDARY
    run_fp_irq_boundary();
    $finish;
`elsif RAPT_TEST_RETIRE_COUNT
    run_retire_count_tests();
    $finish;
`elsif RAPT_TEST_ATOMIC_REPLAY
    run_atomic_replay();
    $finish;
`else
    init_inputs();
    expect_basic_dual_commit();
    expect_slot0_store_blocks_dual();
    expect_slot1_branch_serializes_flush();
    expect_correct_branch_releases_checkpoint();
    expect_cross_domain_dispatch_bypass();
    expect_dispatch_edge_writeback_merge();
    expect_registered_recovery_fence();
    expect_recovery_identity_reuse();
    expect_stale_generation_is_rejected();
    expect_rob_wrap_reuse_and_sret();
    expect_stale_csr_wen_is_not_exposed();
    expect_full_width_retirement();
    expect_cbo_zero_commit_with_resident_sq();
    expect_bus_error_interrupt();

    if (CheckOperandIndependence) begin
      check(paired_dispatches > 100 && paired_commits > 100 && paired_ready_operands > 100,
            "insufficient paired ROU lifecycle coverage");
      $display("PASS: paired ROU dispatches=%0d commits=%0d ready_operands=%0d XLEN=%0d",
               paired_dispatches, paired_commits, paired_ready_operands, XLEN);
    end
    $display(
        "PASS: ROU buffered dispatch bypass/edge merge, dual commit, recovery fence, generation guard, wrap/reuse, CSR gating, SRET, and full-width persistent metadata (XLEN=%0d)",
        XLEN);
    $finish;
`endif
  end
endmodule
