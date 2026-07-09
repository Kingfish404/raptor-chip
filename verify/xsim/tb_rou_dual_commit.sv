`include "rapt.svh"
`include "rapt_if.svh"

module tb_rou_dual_commit;
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

  rnu_rou_if rnu_rou();
  exu_prf_if exu_prf();
  rou_exu_if rou_exu();
  exu_wb_if exu_rou();
  exu_wb_if exu_rou_b();
  exu_wb_if exu_rou_c();
  exu_wb_if exu_ioq_bcast();
  csr_bcast_if csr_bcast();
  rou_cmu_if rou_cmu();
  rou_csr_if rou_csr();
  rou_lsu_if rou_lsu();
  cmu_bcast_if cmu_bcast();

  rapt_pkg::uop_payload_t uop_pl[`RAPT_ROB_SIZE];

  rapt_rou dut_rou (
      .clock(clock),
      .rnu_rou(rnu_rou),
      .exu_prf(exu_prf),
      .rou_exu(rou_exu),
      .exu_rou(exu_rou),
      .exu_rou_b(exu_rou_b),
      .exu_rou_c(exu_rou_c),
      .exu_ioq_bcast(exu_ioq_bcast),
      .csr_bcast(csr_bcast),
      .clint_timer_trap(clint_timer_trap),
      .clint_sw_trap(clint_sw_trap),
      .clint_ext_trap(clint_ext_trap),
      .s_int_pending(s_int_pending),
      .s_int_cause(s_int_cause),
      .rou_cmu(rou_cmu),
      .rou_csr(rou_csr),
      .rou_lsu(rou_lsu),
      .uop_pl(uop_pl),
      .dm_haltreq_i(dm_haltreq),
      .halted_o(halted),
      .halt_pc_o(halt_pc),
      .commit_fire_o(commit_fire),
      .pmu_rob_full(pmu_rob_full),
      .reset(reset)
  );

  rapt_cmu dut_cmu (
      .clock(clock),
      .rou_cmu(rou_cmu),
      .cmu_bcast(cmu_bcast),
      .reset(reset)
  );

  always #5 clock = ~clock;

  `include "tb_common.svh"
  `include "tb_core_bcast_defaults.svh"

  task automatic clear_writebacks;
    begin
      exu_rou.valid = 1'b0;
      exu_rou_b.valid = 1'b0;
      exu_rou_c.valid = 1'b0;
      exu_ioq_bcast.valid = 1'b0;
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

      rnu_rou.uop_a = '0;
      rnu_rou.pr1_a = '0;
      rnu_rou.pr2_a = '0;
      rnu_rou.prd_a = '0;
      rnu_rou.prs_a = '0;
      rnu_rou.op1_a = '0;
      rnu_rou.op2_a = '0;
      rnu_rou.valid_a = 1'b0;
`ifdef RAPT_DUAL_ISSUE
      rnu_rou.uop_b = '0;
      rnu_rou.pr1_b = '0;
      rnu_rou.pr2_b = '0;
      rnu_rou.prd_b = '0;
      rnu_rou.prs_b = '0;
      rnu_rou.op1_b = '0;
      rnu_rou.op2_b = '0;
      rnu_rou.valid_b = 1'b0;
`endif

      exu_prf.pv1_a = '0;
      exu_prf.pv2_a = '0;
      exu_prf.pv1_a_valid = 1'b1;
      exu_prf.pv2_a_valid = 1'b1;
`ifdef RAPT_DUAL_ISSUE
      exu_prf.pv1_b = '0;
      exu_prf.pv2_b = '0;
      exu_prf.pv1_b_valid = 1'b1;
      exu_prf.pv2_b_valid = 1'b1;
`endif

      rou_exu.ready = 1'b1;
`ifdef RAPT_DUAL_ISSUE
      rou_exu.ready_b = 1'b1;
`endif

      exu_rou.pc = '0;
      exu_rou.npc = '0;
      exu_rou.btaken = 1'b0;
      exu_rou.mispredict = 1'b0;
      exu_rou.dest = '0;
      exu_rou.result = '0;
      exu_rou.prd = '0;
      exu_rou.rd = '0;
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
      exu_rou_b.dest = '0;
      exu_rou_b.result = '0;
      exu_rou_b.prd = '0;
      exu_rou_b.rd = '0;
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
      exu_ioq_bcast.prd = '0;
      exu_ioq_bcast.rd = '0;
      exu_ioq_bcast.wen = 1'b0;
      exu_ioq_bcast.alu = '0;
      exu_ioq_bcast.sq_waddr = '0;
      exu_ioq_bcast.sq_wdata = '0;
      exu_ioq_bcast.trap = 1'b0;
      exu_ioq_bcast.tval = '0;
      exu_ioq_bcast.cause = '0;
      exu_ioq_bcast.difftest_skip = 1'b0;

      clear_writebacks();

      init_csr_bcast_defaults(`RAPT_PRIV_M, 32'h2000_0000, 1'b1);

      rou_lsu.sq_ready = 1'b1;
      rou_lsu.sq_empty = 1'b1;
    end
  endtask

  function automatic rapt_pkg::uop_t make_alu_uop(
      input logic [XLEN-1:0] pc,
      input logic [31:0] inst,
      input logic [RLEN-1:0] rd
  );
    rapt_pkg::uop_t u;
    begin
      u = '0;
      u.pc = pc;
      u.pnpc = pc + XLEN'(4);
      u.inst = inst;
      u.rd = rd;
      u.alu = `RAPT_ALU_ADD_;
      return u;
    end
  endfunction

  function automatic rapt_pkg::uop_t make_store_uop(
      input logic [XLEN-1:0] pc,
      input logic [31:0] inst
  );
    rapt_pkg::uop_t u;
    begin
      u = '0;
      u.pc = pc;
      u.pnpc = pc + XLEN'(4);
      u.inst = inst;
      u.wen = 1'b1;
      u.alu = `RAPT_ALU_SW__;
      return u;
    end
  endfunction

  function automatic rapt_pkg::uop_t make_branch_uop(
      input logic [XLEN-1:0] pc,
      input logic [31:0] inst
  );
    rapt_pkg::uop_t u;
    begin
      u = '0;
      u.pc = pc;
      u.pnpc = pc + XLEN'(4);
      u.inst = inst;
      u.ben = 1'b1;
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
      check(rnu_rou.ready, "ROU not ready after reset");
      check(!rou_cmu.valid_a, "ROU reports commit after reset");
      check(!cmu_bcast.flush_pipe, "CMU reports flush after reset");
    end
  endtask

  task automatic dispatch_one(
      input rapt_pkg::uop_t u,
      input logic [PLEN-1:0] prd,
      input logic [PLEN-1:0] prs,
      input logic [RobW-1:0] expected_dest
  );
    begin
      rnu_rou.uop_a = u;
      rnu_rou.pr1_a = '0;
      rnu_rou.pr2_a = '0;
      rnu_rou.prd_a = prd;
      rnu_rou.prs_a = prs;
      rnu_rou.op1_a = '0;
      rnu_rou.op2_a = '0;
      rnu_rou.valid_a = 1'b1;
      #1;
      check(rnu_rou.ready, "ROU rejected enqueue unexpectedly");
      tick(1);
      rnu_rou.valid_a = 1'b0;
      #1;
      check(rou_exu.valid, "ROU did not present dispatch after enqueue");
      check(rou_exu.dest == expected_dest, "ROU dispatch dest mismatch");
      tick(1);
      #1;
      check(!rou_exu.valid, "ROU dispatch valid did not drop after accept");
    end
  endtask

  task automatic writeback_alu_pair(
      input logic [XLEN-1:0] npc0,
      input logic [XLEN-1:0] npc1,
      input bit slot1_mispredict
  );
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

  task automatic expect_basic_dual_commit;
    begin
      reset_dut();
      dispatch_one(make_alu_uop(32'h8000_0000, 32'h0010_0093, 5'd1), 6'd33, 6'd1, RobW'(0));
      dispatch_one(make_alu_uop(32'h8000_0004, 32'h0020_0113, 5'd2), 6'd34, 6'd2, RobW'(1));
      writeback_alu_pair(32'h8000_0004, 32'h8000_0008, 1'b0);

      check(commit_fire, "basic pair did not assert commit_fire");
      check(rou_cmu.valid_a, "basic pair missing slot0 commit");
      check(rou_cmu.valid_b, "basic pair missing slot1 commit");
      check(!rou_cmu.flush_pipe, "basic pair unexpectedly flushed");
      check(rou_cmu.rd_a == 5'd1, "basic pair slot0 rd mismatch");
      check(rou_cmu.rd_b == 5'd2, "basic pair slot1 rd mismatch");
      check(rou_cmu.prd_a == 6'd33, "basic pair slot0 prd mismatch");
      check(rou_cmu.prs_b == 6'd2, "basic pair slot1 prs mismatch");
      check(rou_cmu.pc_a == 32'h8000_0000, "basic pair slot0 pc mismatch");
      check(rou_cmu.pc_b == 32'h8000_0004, "basic pair slot1 pc mismatch");
      check(rou_cmu.npc_b == 32'h8000_0008, "basic pair slot1 npc mismatch");
      check(cmu_bcast.valid_b, "CMU broadcast missing valid_b for dual commit");
      check(cmu_bcast.rpc == 32'h8000_0004, "CMU broadcast did not select slot1 rpc");
      check(cmu_bcast.cpc == 32'h8000_0008, "CMU broadcast did not select slot1 cpc");

      tick(1);
      check(rou_cmu.rob_head == RobW'(2), "ROB head did not advance by 2 after dual commit");
      check(!rou_cmu.valid_a, "basic pair still commits after retiring");
    end
  endtask

  task automatic expect_slot0_store_blocks_dual;
    begin
      reset_dut();
      dispatch_one(make_store_uop(32'h8000_1000, 32'h0020_a023), '0, '0, RobW'(0));
      dispatch_one(make_alu_uop(32'h8000_1004, 32'h0030_0193, 5'd3), 6'd35, 6'd3, RobW'(1));
      writeback_store0_alu1();

      check(commit_fire, "slot0 store did not assert commit_fire");
      check(rou_cmu.valid_a, "slot0 store missing slot0 commit");
      check(!rou_cmu.valid_b, "slot0 store incorrectly dual committed");
      check(rou_lsu.valid, "slot0 store did not drive LSU commit valid");
      check(rou_lsu.store, "slot0 store did not drive LSU store");
      check(rou_lsu.sq_waddr == 32'h8000_2000, "slot0 store address mismatch");

      tick(1);
      check(rou_cmu.rob_head == RobW'(1), "ROB head did not advance by 1 for slot0 store");
      check(rou_cmu.valid_a, "slot1 should commit after slot0 store retires");
      check(!rou_cmu.valid_b, "single remaining slot unexpectedly dual committed");
      tick(1);
      check(rou_cmu.rob_head == RobW'(2), "ROB head did not retire slot1 after store");
    end
  endtask

  task automatic expect_slot1_branch_flush;
    begin
      reset_dut();
      dispatch_one(make_alu_uop(32'h8000_2000, 32'h0040_0213, 5'd4), 6'd36, 6'd4, RobW'(0));
      dispatch_one(make_branch_uop(32'h8000_2004, 32'h0002_0863), '0, '0, RobW'(1));
      writeback_alu_pair(32'h8000_2004, 32'h8000_2080, 1'b1);

      check(commit_fire, "slot1 branch pair did not assert commit_fire");
      check(rou_cmu.valid_a, "slot1 branch pair missing slot0 commit");
      check(rou_cmu.valid_b, "slot1 branch pair missing slot1 commit");
      check(rou_cmu.flush_pipe, "slot1 branch mispredict did not flush");
      check(rou_cmu.ben, "slot1 branch did not drive branch metadata");
      check(rou_cmu.btaken, "slot1 branch did not drive taken metadata");
      check(rou_cmu.pc_b == 32'h8000_2004, "slot1 branch pc mismatch");
      check(rou_cmu.npc_b == 32'h8000_2080, "slot1 branch target mismatch");
      check(cmu_bcast.flush_pipe, "CMU broadcast missing slot1 branch flush");
      check(cmu_bcast.rpc == 32'h8000_2004, "CMU broadcast did not select branch slot rpc");
      check(cmu_bcast.cpc == 32'h8000_2080, "CMU broadcast did not select branch target");

      tick(1);
      check(rou_cmu.rob_head == RobW'(0), "flush did not reset ROB head");
      check(!rou_cmu.valid_a, "ROU still reports commit after slot1 branch flush");
      check(!cmu_bcast.flush_pipe, "CMU flush did not clear after one cycle");
    end
  endtask

  initial begin
`ifndef RAPT_DUAL_COMMIT
    fail("tb_rou_dual_commit requires RAPT_DUAL_COMMIT enabled");
`endif

    init_inputs();
    expect_basic_dual_commit();
    expect_slot0_store_blocks_dual();
    expect_slot1_branch_flush();

    $display("PASS: ROU dual-commit xsim checks passed");
    $finish;
  end
endmodule
