// Actual ROU/FEU composition: renamed operands, out-of-order completion,
// architectural prefix commit, flags and recovery. Integer completion is driven
// by the fixture to hold a precise retirement frontier for the checks below.
integer fp_ooo_pc = 'h80002000;
integer fp_ooo_multi_commit = 0;
logic [4:0] fp_ooo_flags = 0;
always @(posedge clock) if (!reset) begin
  if (rou_csr.valid && rou_csr.fp_flags_valid) fp_ooo_flags <= fp_ooo_flags | rou_csr.fp_flags;
  if (dut_rou.fp_commit_valid[0] && dut_rou.fp_commit_valid[1]
      && dut_rou.rob_fp_writer[dut_rou.commit_index[0]]
      && dut_rou.rob_fp_writer[dut_rou.commit_index[1]])
    fp_ooo_multi_commit <= fp_ooo_multi_commit + 1;
end
function automatic uop_t fp_ooo_uop(input int op, rd, rs1 = 0, rs2 = 0, rs3 = 0);
  uop_t u;
  u = '0;
  u.pc = XLEN'(fp_ooo_pc);
  u.pnpc = u.pc + XLEN'(4);
  u.inst = 32'h02000053;
  u.execute.fp.valid = 1;
  u.execute.fp.op = 6'(op);
  u.execute.fp.rd = 5'(rd);
  u.execute.fp.rs1 = 5'(rs1);
  u.execute.fp.rs2 = 5'(rs2);
  u.execute.fp.rs3 = 5'(rs3);
  u.schedule = rapt_pkg::schedule_uop(u);
  return u;
endfunction
task automatic fp_ooo_enqueue(input uop_t u, input int owner, input logic [XLEN-1:0] gpr = 0);
  rnu_rou.slot[0] = '0;
  rnu_rou.slot[0].uop = u;
  rnu_rou.slot[0].op1 = gpr;
  rnu_rou.checkpoint_valid[0] = 0;
  rnu_rou.valid[0] = 1;
  #1;
  check(rnu_rou.ready[0], "FP OOO UOQ enqueue blocked");
  tick(1);
  rnu_rou.valid[0] = 0;
  #1;
`ifdef RAPT_TEST_REGISTERED_PAYLOAD
  check(!dispatch_valid[0], "FP allocation bypassed the payload register");
  tick(1);
`endif
  check(dispatch_valid[0] && dispatch[0].dest == RobW'(owner),
      "FP serialization or incorrect dispatch owner");
  tick(1);
  fp_ooo_pc = fp_ooo_pc + 4;
endtask
task automatic fp_ooo_empty;
  for (int timeout = 0; timeout < 400 && !dut_rou.rob_empty; timeout++) tick(1);
  check(dut_rou.rob_empty, "FP OOO retirement did not drain");
endtask
task automatic run_fp_ooo;
  reset_dut();
  fp_ooo_enqueue(fp_ooo_uop(`RAPT_FP_OP_FCVT_D_W, 1), 0, 7);
  fp_ooo_empty();
  fp_ooo_enqueue(fp_ooo_uop(`RAPT_FP_OP_FCVT_D_W, 2), 1, 3);
  fp_ooo_empty();
  check(dut_rou.fp_registers.architectural[1] == 64'h401c000000000000
      && dut_rou.fp_registers.architectural[2] == 64'h4008000000000000,
      "FP OOO architectural seeds were not retired");
  dispatch_one(make_alu_uop('h80002100, 32'h00100093, 1), PLEN'(33), '0, RobW'(2));
  fp_ooo_enqueue(fp_ooo_uop(`RAPT_FP_OP_FDIV_D, 0, 1, 2), 3);
  fp_ooo_enqueue(fp_ooo_uop(`RAPT_FP_OP_FADD_D, 3, 2, 2), 4);
  fp_ooo_enqueue(fp_ooo_uop(`RAPT_FP_OP_FMADD_D, 4, 2, 2, 0), 5);
  fp_ooo_enqueue(fp_ooo_uop(`RAPT_FP_OP_FADD_D, 0, 1, 2), 6);
  fp_ooo_enqueue(fp_ooo_uop(`RAPT_FP_OP_FADD_D, 5, 0, 2), 7);
  check(dut_rou.rob_entry[3].state == ROB_EX && dut_rou.rob_entry[4].state == ROB_WB,
      "younger FP ADD did not complete ahead of DIV in the actual ROB");
  tick(180);
  for (int owner = 3; owner <= 7; owner++)
    check(dut_rou.rob_entry[owner].state == ROB_WB, "FP OOO owner did not complete");
  check(dut_rou.fp_registers.architectural[0] == 0
      && dut_rou.fp_registers.architectural[4] == 0 && fp_ooo_flags == 0,
      "speculative FP values or flags escaped retirement");
  check(dut_rou.fp_registers.result_q[5] == 64'h4026aaaaaaaaaaab
      && dut_rou.fp_registers.result_q[7] == 64'h402a000000000000,
      "FMA third-source WAR or younger f0 RAW used wrong version");
  writeback_alu_one(RobW'(2), 'h80002104);
  fp_ooo_empty();
  check(dut_rou.fp_registers.architectural[0] == 64'h4024000000000000
      && dut_rou.fp_registers.architectural[3] == 64'h4018000000000000
      && dut_rou.fp_registers.architectural[4] == 64'h4026aaaaaaaaaaab
      && dut_rou.fp_registers.architectural[5] == 64'h402a000000000000,
      "in-order FP retirement lost renamed results");
  check(fp_ooo_multi_commit > 0 && fp_ooo_flags == 1,
      "FP prefix commit or accrued flags missing");

  reset_dut();
  fp_ooo_flags = 0;
  dispatch_one(make_branch_uop('h80003000, 32'h00000863), '0, '0, RobW'(0));
  fp_ooo_enqueue(fp_ooo_uop(`RAPT_FP_OP_FDIV_D, 2, 0, 0), 1);
  fp_ooo_enqueue(fp_ooo_uop(`RAPT_FP_OP_FCVT_D_W, 3), 2, 17);
  tick(100);
  check(dut_rou.rob_entry[1].state == ROB_WB && dut_rou.rob_entry[2].state == ROB_WB,
      "recovery did not cover already completed FP owners");
  exu_rou.dest = 0;
  exu_rou.npc = XLEN'('h80003100);
  exu_rou.btaken = 1;
  exu_rou.mispredict = 1;
  exu_rou.valid = 1;
  tick(1);
  clear_writebacks();
  check(rou_cmu.flush_pipe, "branch did not establish precise flush");
  tick(4);
  check(dut_rou.rob_empty && fp_ooo_flags == 0
      && dut_rou.fp_registers.architectural[2] == 0
      && dut_rou.fp_registers.architectural[3] == 0,
      "wrong-path completed FP value/flags survived recovery");
  $display("PASS: actual FP ROB/FEU OOO, RAW/WAR/WAW, multi-commit, precise flags and recovery XLEN=%0d", XLEN);
endtask
