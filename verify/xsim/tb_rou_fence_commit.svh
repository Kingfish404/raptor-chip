// Fence maintenance belongs only to successful instruction retirement.
// Invalid payload is allowed to carry arbitrary bits across the rename port.
function automatic rapt_pkg::uop_t make_fence_uop(input bit instruction_fence);
  rapt_pkg::uop_t u;
  u = '0;
  u.pc = XLEN'('h80004000);
  u.pnpc = u.pc + XLEN'(4);
  u.inst = instruction_fence ? 32'h0000100f : 32'h0000000f;
  u.execute.sys.valid = 1'b1;
  u.execute.sys.fence_i = instruction_fence;
  u.execute.sys.fence = !instruction_fence;
  return u;
endfunction

task automatic run_fence_commit_tests;
  for (int kind = 0; kind < 2; kind++) begin
    reset_dut();
    rnu_rou.slot[0].uop = make_fence_uop(kind == 0);
    rnu_rou.valid[0] = 1'b0;
    tick(3);
    check(dut_rou.rob_empty && !(|dut_rou.uoq_valid),
          "invalid fence payload allocated an instruction");
    check(!cmu_bcast.fence_i && !cmu_bcast.fence_time,
          "idle invalid payload issued cache maintenance");
    clint_timer_trap = 1'b1;
    tick(1);
    check(
        rou_csr.valid && rou_csr.trap && cmu_bcast.time_trap
          && rou_csr.retire_count == 0 && !rou_cmu.slot[0].valid,
        "empty-ROB interrupt did not enter the precise trap path");
    check(!cmu_bcast.fence_i && !cmu_bcast.fence_time,
          "empty-ROB interrupt used invalid fence metadata");
    clint_timer_trap = 1'b0;
    tick(2);

    reset_dut();
    dispatch_one(make_fence_uop(kind == 0), '0, '0, RobW'(0));
    writeback_alu_one(RobW'(0), XLEN'('h80004004));
    check(
        rou_cmu.slot[0].valid && !rou_cmu.slot[0].trap
          && cmu_bcast.fence_i == (kind == 0)
          && cmu_bcast.fence_time == (kind == 1),
        "successful fence retirement lost its maintenance signal");
    tick(1);
    check(!cmu_bcast.fence_i && !cmu_bcast.fence_time,
          "retired fence maintenance repeated after flush");

    reset_dut();
    dispatch_one(make_fence_uop(kind == 0), '0, '0, RobW'(0));
    exu_rou.dest = RobW'(0);
    exu_rou.npc = XLEN'('h80004004);
    exu_rou.trap = 1'b1;
    exu_rou.cause = XLEN'(2);
    exu_rou.tval = XLEN'('h0000100f);
    exu_rou.valid = 1'b1;
    tick(1);
    clear_writebacks();
    #1;
    check(
        rou_cmu.slot[0].valid && rou_cmu.slot[0].trap
          && rou_csr.valid && rou_csr.trap && rou_csr.retire_count == 0,
        "faulting fence did not enter the precise exception path");
    check(!cmu_bcast.fence_i && !cmu_bcast.fence_time, "faulting fence issued cache maintenance");
    tick(2);
  end
  $display(
      "PASS: fence maintenance requires successful retirement; idle IRQ and fault suppression XLEN=%0d",
      XLEN);
endtask
