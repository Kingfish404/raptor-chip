// Fence maintenance belongs only to successful instruction retirement.
// Invalid payload is allowed to carry arbitrary bits across the rename port.
function automatic rapt_pkg::uop_t make_fence_uop(input int kind);
  rapt_pkg::uop_t u;
  u = '0;
  u.pc = XLEN'('h80004000);

  u.inst = kind == 0 ? 32'h0000100f : kind == 1 ? 32'h0000000f
      : kind == 2 ? 32'h12000073 : 32'h16000073;
  u.execute.sys.kind = kind == 0 ? rapt_pkg::SYS_FENCE_I
      : kind == 1 ? rapt_pkg::SYS_FENCE : rapt_pkg::SYS_TRANSLATION;
  u.imm = kind >= 2 ? 32'd3 : '0;
  u.execute.sys.valid = 1'b1;
  u.execute.sys.fence_i = kind != 1;
  u.execute.sys.fence = kind != 0;
  return u;
endfunction

task automatic run_fence_commit_tests;
  for (int kind = 0; kind < 4; kind++) begin
    reset_dut();
    rnu_rou.slot[0].uop = make_fence_uop(kind);
    rnu_rou.slot[0].pnpc = rnu_rou.slot[0].uop.pc + XLEN'(rnu_rou.slot[0].uop.c ? 2 : 4);
    rnu_rou.valid[0] = 1'b0;
    tick(3);
    check(dut_rou.rob_empty && !(|dut_rou.uoq_valid),
          "invalid fence payload allocated an instruction");
    check(!cmu_bcast.fence_i && !cmu_bcast.fence_time && !cmu_bcast.sfence_valid,
          "idle invalid payload issued cache maintenance");
    clint_timer_trap = 1'b1;
    tick(1);
    check(
        rou_csr.valid && rou_csr.trap && cmu_bcast.time_trap
          && rou_csr.retire_count == 0 && !rou_cmu.slot[0].valid,
        "empty-ROB interrupt did not enter the precise trap path");
    check(!cmu_bcast.fence_i && !cmu_bcast.fence_time && !cmu_bcast.sfence_valid,
          "empty-ROB interrupt used invalid fence metadata");
    clint_timer_trap = 1'b0;
    tick(2);

    reset_dut();
    dispatch_one(make_fence_uop(kind), '0, '0, RobW'(0));
    writeback_alu_one(RobW'(0), XLEN'('h80004004));
    check(
        rou_cmu.slot[0].valid && !rou_cmu.slot[0].trap
          && cmu_bcast.fence_i == (kind == 0 || (kind >= 2 && `RAPT_SFENCE_KEEP_STATE < 2))
          && cmu_bcast.fence_time == (kind != 0),
        "successful fence retirement lost its maintenance signal");
    tick(1);
    check(!cmu_bcast.fence_i && !cmu_bcast.fence_time && !cmu_bcast.sfence_valid,
          "retired fence maintenance repeated after flush");

    reset_dut();
    dispatch_one(make_fence_uop(kind), '0, '0, RobW'(0));
    exu_rou.dest  = RobW'(0);
    exu_rou.npc   = XLEN'('h80004004);
    exu_rou.trap  = 1'b1;
    exu_rou.cause = XLEN'(2);
    exu_rou.tval  = XLEN'('h0000100f);
    exu_rou.valid = 1'b1;
    tick(1);
    clear_writebacks();
    #1;
    check(
        rou_cmu.slot[0].valid && rou_cmu.slot[0].trap
          && rou_csr.valid && rou_csr.trap && rou_csr.retire_count == 0,
        "faulting fence did not enter the precise exception path");
    check(!cmu_bcast.fence_i && !cmu_bcast.fence_time && !cmu_bcast.sfence_valid,
          "faulting fence issued cache maintenance");
    tick(2);
  end
  if (`RAPT_SFENCE_SELECTIVE != 0) begin
    for (int kind = 2; kind < 4; kind++) begin
      for (int r1 = 0; r1 < 2; r1++) begin
        for (int r2 = 0; r2 < 2; r2++) begin
          for (int value_case = 0; value_case < 3; value_case++) begin
            automatic int vpn_bits = XLEN == 64 ? 27 : 20;
            rapt_pkg::uop_t u;
            logic [XLEN-1:0] packed_result;
            logic [26:0] vpn;
            logic [8:0] asid;
            bit noncanonical;
            reset_dut();
            u = make_fence_uop(kind);
            u.inst |= (r1 == 0 ? 0 : 32'(5 << 15)) | (r2 == 0 ? 0 : 32'(6 << 20));
            u.imm[1:0] = {1'(r2 == 0), 1'(r1 == 0)};
            vpn = value_case == 0 ? 0 : 27'h12345;
            asid = value_case == 0 ? 0 : 9'd7;
            noncanonical = XLEN == 64 && value_case == 2;
            packed_result = XLEN'(vpn) | (XLEN'(asid) << vpn_bits)
                | (XLEN'(noncanonical) << (vpn_bits + 9));
            dispatch_one(u, '0, '0, RobW'(0));
            // A rejected generation cannot provide a descriptor or retire.
            force_stale_generation = 1;
            exu_rou.result = ~packed_result;
            writeback_alu_one(RobW'(0), (u.pc + XLEN'(u.c ? 2 : 4)));
            check(!rou_cmu.slot[0].valid && !cmu_bcast.sfence_valid,
                  "stale completion published a fence descriptor");
            force_stale_generation = 0;
            tb_sq_empty = 0;
            tb_writeback_idle = 0;
            exu_rou.result = packed_result;
            writeback_alu_one(RobW'(0), (u.pc + XLEN'(u.c ? 2 : 4)));
            tick(3);
            check(!rou_cmu.slot[0].valid && !cmu_bcast.sfence_valid && tb_writeback_drain,
                  "fence published descriptor before older stores drained");
            tb_sq_empty = 1;
            tick(3);
            check(!rou_cmu.slot[0].valid && !cmu_bcast.sfence_valid && tb_writeback_drain,
                  "fence published descriptor before dirty writeback completed");
            tb_writeback_idle = 1;
            #1;
            check(rou_cmu.slot[0].valid && !rou_cmu.slot[0].trap && cmu_bcast.fence_time,
                  "resolved fence did not retire");
            check(cmu_bcast.sfence_valid == (r1 == 0 || !noncanonical),
                  "noncanonical targeted fence descriptor was not suppressed");
            check(cmu_bcast.sfence_all_vpn == (r1 == 0) && cmu_bcast.sfence_all_asid == (r2 == 0),
                  "zero-valued non-x0 fence operand became an all-address/all-ASID fence");
            check(cmu_bcast.sfence_vpn == vpn && cmu_bcast.sfence_asid == asid,
                  "committed descriptor differs from resolved completion");
            tick(1);
            check(!cmu_bcast.sfence_valid, "fence descriptor repeated after retirement");
          end
        end
      end
    end
  end
  $display(
      "PASS: fence maintenance requires successful retirement; idle IRQ and fault suppression XLEN=%0d",
      XLEN);
endtask
