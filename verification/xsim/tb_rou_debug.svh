// A non-clean fence's held DONE must not acknowledge the subsequent debug clean.
task automatic expect_debug_halt_orders_clean;
  rapt_pkg::uop_t u;
  reset_dut();
  debug.enable = 1;
  u = make_alu_uop('h8000_4000, 'h0ff0_000f, 5'd0);
  u.execute.sys.fence = 1;
  dispatch_one(u, '0, '0, RobW'(0));
  writeback_alu_one(RobW'(0), 'h8000_4004);
  check(tb_writeback_drain && !tb_writeback_clean, "ordinary fence requested a clean");
  dm_haltreq = 1;
  tick(1);
  check(cmu_bcast.flush_redirect && !tb_writeback_drain && !halted,
        "debug clean reused the retiring fence's held DONE");
  tb_writeback_idle = 0;
  tick(1);
  check(tb_writeback_drain && tb_writeback_clean && !halted,
        "debug halt did not start a fresh clean transaction");
  tick(3);
  check(!halted, "debug halt ignored a stalled clean transaction");
  tb_writeback_idle = 1;
  tick(1);
  check(halted && halt_pc == 'h8000_4004, "debug clean lost the fence successor PC");
endtask

// Exercise the production ROU admission token and its redirect handshake.
task automatic expect_precise_debug;
  rapt_pkg::uop_t u;
  reset_dut();
  debug.enable = 1;
  debug.step = 1;
  clint_timer_trap = 1;
  for (int s = 0; s < 2; s++) begin
    rnu_rou.slot[s] = '0;
    rnu_rou.slot[s].uop = make_alu_uop('h8000_1000 + XLEN'(4*s), 'h0010_0093, 5'd1);
    rnu_rou.slot[s].pnpc = 'h8000_1004 + XLEN'(4*s);
    rnu_rou.slot[s].prd = PLEN'(33+s);
    rnu_rou.slot[s].prs = PLEN'(1+s);
    rnu_rou.valid[s] = 1;
  end
  #1;
  check(rnu_rou.ready[0] && !rnu_rou.ready[1], "step admitted a second rename lane");
  tick(1);
  check(!rnu_rou.ready[0] && dut_rou.skid_count == 1, "step token was not consumed");
  tick(8);
  check($countones(dut_rou.rob_entry_busy) == 1 && !dut_rou.recieved_trap,
        "step admitted younger work or failed to mask an interrupt");
  writeback_alu_one(RobW'(0), 'h8000_1004);
  check(dut_rou.commit_count == 1 && rou_cmu.next_pc == 'h8000_1004,
        "step completion count or next PC incorrect");
  tick(3);
  check(halted && halt_pc == 'h8000_1004 && debug.cause == 4,
        "step did not halt at its architectural successor");
  foreach (rnu_rou.valid[s]) rnu_rou.valid[s] = 0;
  tick(3);
  check(!dut_rou.recieved_trap && !commit_fire, "halted step took a pending interrupt");
  debug.resume_pc = 'h8000_2000;
  debug.resume_valid = 1;
  #1;
  check(recovery.redirect_valid && recovery.target == 'h8000_2000,
        "DPC resume did not publish a recovery redirect");
  tick(1);
  check(debug.resume_ack && cmu_bcast.flush_redirect && cmu_bcast.redirect_pc == 'h8000_2000
        && halt_pc == 'h8000_2000, "resume acknowledged before redirect applied");
  debug.resume_valid = 0;
  debug.stepie = 1;
  tick(1);
  check(dut_rou.recieved_trap && rou_csr.valid && rou_csr.trap,
        "stepie did not allow an interrupt before instruction execution");
  tick(3);
  check(halted && debug.cause == 4 && halt_pc == 'h2000_0000,
        "interrupt step did not halt at trap entry");

  // EBREAK is serialized by normal admission. It is removed without an
  // exception or architectural retirement, and its PC remains restartable.
  for (int p = 0; p < 3; p++) begin
    reset_dut();
    debug.enable = 1;
    debug.ebreak = 3'b111;
    csr_bcast.priv = p == 2 ? 2'd3 : 2'(p);
    u = make_ecall_uop('h8000_3000);
    u.execute.sys.ecall = 0;
    u.execute.sys.ebreak = 1;
    u.inst = 'h0010_0073;
    dispatch_one(u, '0, '0, RobW'(0));
    writeback_alu_one(RobW'(0), 'h8000_3004);
    check(!rou_csr.valid && !rou_cmu.slot[0].valid && rou_cmu.next_pc == 'h8000_3000,
          "debug ebreak raised an exception or retired");
    tick(3);
    check(halted && halt_pc == 'h8000_3000 && debug.cause == 1,
          "privilege-qualified ebreak did not halt at the ebreak");
  end
  $display("PASS: precise ROU step token, interrupt mask, DPC redirect and M/S/U ebreak");
endtask
