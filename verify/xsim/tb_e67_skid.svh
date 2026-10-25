// Admission scoreboard follows accepted rename slots, independently of skid state.
typedef rnu_rou.slot_t E67RenameSlotT;
E67RenameSlotT e67_expected[256];
int e67_put, e67_get;
always @(posedge clock) begin
  if (reset || cmu_bcast.flush_pipe) begin
    e67_put = 0;
    e67_get = 0;
  end else begin
    for (int s = 0; s < rapt_pkg::RenameWidth; s++) begin
      if (rnu_rou.valid[s] && rnu_rou.ready[s]) begin
        e67_expected[e67_put%256] = rnu_rou.slot[s];
        e67_put++;
      end
    end
    for (int s = 0; s < rapt_pkg::DispatchWidth; s++) begin
      if (dut_rou.deq_fire[s]) begin
        check(e67_get < e67_put, "allocation without accepted rename owner");
        check(dut_rou.allocation[s].uop.pc == e67_expected[e67_get%256].uop.pc,
              "skid changed rename order or PC");
        check(
            dut_rou.allocation[s].pr1 == e67_expected[e67_get % 256].pr1
                  && dut_rou.allocation[s].pr2 == e67_expected[e67_get % 256].pr2
                  && dut_rou.allocation[s].prd == e67_expected[e67_get % 256].prd
                  && dut_rou.allocation[s].prs == e67_expected[e67_get % 256].prs
                  && dut_rou.allocation[s].op1 == e67_expected[e67_get % 256].op1
                  && dut_rou.allocation[s].op2 == e67_expected[e67_get % 256].op2,
            "skid changed immutable source descriptors");
        e67_get++;
      end
    end
  end
end

task automatic e67_send(input int first, input int count);
  for (int s = 0; s < rapt_pkg::RenameWidth; s++) begin
    rnu_rou.slot[s] = '0;
    rnu_rou.slot[s].uop = make_alu_uop(XLEN'(32'h80200000 + 4 * (first + s)),
                                     32'h00100013, '0);
    rnu_rou.slot[s].pnpc = rnu_rou.slot[s].uop.pc + XLEN'(rnu_rou.slot[s].uop.c ? 2 : 4);
    rnu_rou.slot[s].pr1 = PLEN'(s + 1);
    rnu_rou.slot[s].pr2 = PLEN'(s + 9);
    rnu_rou.slot[s].op1 = XLEN'(32'h12340000 + first + s);
    rnu_rou.slot[s].op2 = XLEN'(32'h56780000 + first + s);
    rnu_rou.valid[s] = s < count;
    rnu_rou.checkpoint_valid[s] = 0;
    rnu_rou.checkpoint[s] = '0;
  end
  #1;
  for (int s = 0; s < count; s++) check(rnu_rou.ready[s], "skid rejected empty admission");
  tick(1);
  for (int s = 0; s < rapt_pkg::RenameWidth; s++) rnu_rou.valid[s] = 0;
  #1;
endtask

task automatic run_e67_skid;
  int held;
  reset_dut();
  e67_send(0, rapt_pkg::RenameWidth);
  check(int'(dut_rou.skid_count) == rapt_pkg::RenameWidth && $countones(dut_rou.rob_entry_busy
        ) == 0, "registered skid bypassed the rename capture edge");
  tick(1);
  check(dut_rou.skid_count == 0 && $countones(dut_rou.rob_entry_busy) == rapt_pkg::RenameWidth,
        "registered skid did not allocate on the next edge");
  $display("E67_LATENCY rename_to_allocation_edges=2 width=%0d XLEN=%0d", rapt_pkg::RenameWidth,
           XLEN);
  tick(2);

  // Block every dispatch domain, fill the spill, and retain the next group.
  reset_dut();
  for (int s = 0; s < rapt_pkg::DispatchWidth; s++) dispatch_ready[s] = 0;
  for (int i = 0; i < rapt_pkg::CoreConfig.operand_spill_entries; i++) e67_send(i, 1);
  e67_send(100, rapt_pkg::RenameWidth);
  check(int'(dut_rou.skid_count) == rapt_pkg::RenameWidth, "spill-full group was not held");
  tick(4);
  check(!rnu_rou.ready[0] && int'(dut_rou.skid_count) == rapt_pkg::RenameWidth,
        "blocked domains overwrote the skid");
  for (int s = 0; s < rapt_pkg::DispatchWidth; s++) dispatch_ready[s] = 1;
  tick(8);
  check(dut_rou.skid_count == 0 && e67_get == e67_put, "spill release did not drain skid");

  // Fill the ROB with dispatched, incomplete owners; release its oldest owner.
  reset_dut();
  for (int i = 0; i < `RAPT_ROB_SIZE; i++) e67_send(i, 1);
  e67_send(100, rapt_pkg::RenameWidth);
  check(int'(dut_rou.skid_count) == rapt_pkg::RenameWidth, "ROB-full group was not held");
  tick(3);
  writeback_alu_one(RobW'(0), XLEN'('h80200004));
  tick(3);
  check(int'(dut_rou.skid_count) == rapt_pkg::RenameWidth - 1,
        "single ROB credit did not admit exactly one held lane");
  for (int i = 1; i < rapt_pkg::RenameWidth; i++) begin
    writeback_alu_one(RobW'(i), XLEN'(32'h80200004 + 4 * i));
    tick(3);
  end
  check(dut_rou.skid_count == 0 && e67_get == e67_put, "partial group did not drain in order");

  // A younger branch announces recovery while an older owner delays precise flush.
  reset_dut();
  dispatch_one(make_alu_uop(XLEN'(32'h80040000), 32'h00100013, '0), '0, '0, RobW'(0));
  dispatch_one(make_branch_uop(XLEN'(32'h80040004), 32'h00000863), '0, '0, RobW'(1));
  for (int i = 2; i < `RAPT_ROB_SIZE; i++) e67_send(i, 1);
  e67_send(100, rapt_pkg::RenameWidth);
  held = int'(dut_rou.skid_count);
  check(held == rapt_pkg::RenameWidth, "recovery setup lacked held group");
  exu_rou_b.dest = RobW'(1);
  exu_rou_b.npc = XLEN'('h80040100);
  exu_rou_b.btaken = 1;
  exu_rou_b.mispredict = 1;
  exu_rou_b.valid = 1;
  tick(1);
  clear_writebacks();
  tick(3);
  check(recovery.pending && !rnu_rou.ready[0] && int'(dut_rou.skid_count) == held,
        "recovery announcement consumed or dropped held group");
  writeback_alu_one(RobW'(0), XLEN'('h80040004));
  tick(1);
  check(cmu_bcast.flush_pipe, "recovery did not reach precise flush");
  tick(2);
  check(dut_rou.skid_count == 0 && dut_rou.rob_empty, "precise flush retained held wrong path");
  e67_send(200, rapt_pkg::RenameWidth);
  tick(1);
  check(dut_rou.skid_count == 0, "post-flush group did not allocate after capture");

  // A fence waits in the skid, then allocates alone and flushes its suffix.
  for (int kind = 0; kind < 2; kind++) begin
    reset_dut();
    dispatch_one(make_alu_uop(XLEN'(32'h80040000), 32'h00100013, '0), '0, '0, RobW'(0));
    for (int s = 0; s < rapt_pkg::RenameWidth; s++) begin
      rnu_rou.slot[s] = '0;
      rnu_rou.slot[s].uop = s == 0 ? make_fence_uop(kind == 0)
          : make_alu_uop(XLEN'(32'h80040004 + 4 * s), 32'h00100013, '0);
      rnu_rou.slot[s].pnpc = rnu_rou.slot[s].uop.pc + XLEN'(rnu_rou.slot[s].uop.c ? 2 : 4);
      rnu_rou.checkpoint_valid[s] = 0;
      rnu_rou.valid[s] = 1;
    end
    tick(1);
    for (int s = 0; s < rapt_pkg::RenameWidth; s++) rnu_rou.valid[s] = 0;
    check(int'(dut_rou.skid_count) == rapt_pkg::RenameWidth, "fence bypassed older ROB owner");
    writeback_alu_one(RobW'(0), XLEN'('h80040004));
    tick(4);
    check(int'(dut_rou.skid_count) == rapt_pkg::RenameWidth - 1 && dut_rou.serialize_in_flight,
          "fence did not allocate alone from skid");
    writeback_alu_one(RobW'(1), XLEN'('h80004004));
    tick(2);
    check(dut_rou.skid_count == 0 && dut_rou.rob_empty, "fence flush retained its held suffix");
  end
  $display(
      "PASS: E67 registered skid, ROB/spill full, partial groups, recovery hold/flush, fences W%0d RV%0d",
      rapt_pkg::RenameWidth, XLEN);
endtask
