// Independent boundary scoreboard for the registered ROU observer. Allocation
// is sampled at the UOQ->ROB ownership edge; execution-domain steering is a
// later event and must not create a second control-flow identity.
bit cf_identity[`RAPT_ROB_SIZE];
always @(posedge clock) begin
  automatic logic [4:0] expected[`RAPT_ROB_SIZE] = '{default:'0};
  automatic bit head_busy = !reset && dut_rou.rob_entry[dut_rou.h0].busy;
  automatic bit head_waiting = head_busy && dut_rou.rob_entry[dut_rou.h0].state != rapt_pkg::ROB_WB;
  automatic int unsigned head_domain = reset ? 0 : int'(dut_rou.uop_pl[dut_rou.h0].schedule.domain);
  if (reset) cf_identity = '{default:0};
  else begin
    if (!cmu_bcast.flush_pipe) begin
      for (int p = 0; p < rapt_pkg::CompletionPorts; p++)
      if (completion[p].valid && completion[p].updates.control_flow
          && completion_owner.live[completion[p].dest]
          && completion_owner.executing[completion[p].dest]
          && completion[p].generation == completion_owner.generation[completion[p].dest]
          && completion[p].prd == completion_owner.prd[completion[p].dest]
          && completion[p].rd == completion_owner.rd[completion[p].dest]
          && cf_identity[completion[p].dest]) begin
        expected[completion[p].dest] |= 5'(rapt_pkg::CfResolve);
        if (completion[p].mispredict && !completion[p].trap)
          expected[completion[p].dest] |= 5'(rapt_pkg::CfMispredict);
      end
      for (int s = 0; s < rapt_pkg::DispatchWidth; s++)
      if (dut_rou.deq_fire[s]) begin
        automatic int destination = int'(dut_rou.rob_alloc[s]);
        automatic int source = int'(dut_rou.deq_index[s]);
        cf_identity[destination] = dut_rou.uoq_uops[source].execute.branch.conditional
            || dut_rou.uoq_uops[source].execute.branch.jump
            || dut_rou.uoq_uops[source].execute.branch.indirect;
        if (cf_identity[destination]) expected[destination] |= 5'(rapt_pkg::CfAllocate);
      end
    end
    for (int c = 0; c < rapt_pkg::CommitWidth; c++)
    if (rou_cmu.slot[c].valid) begin
      if (rou_cmu.slot[c].ben || rou_cmu.slot[c].jen || rou_cmu.slot[c].jren) begin
        expected[dut_rou.commit_index[c]] |= 5'(rapt_pkg::CfRetire);
        if (rou_cmu.slot[c].trap) expected[dut_rou.commit_index[c]] |= 5'(rapt_pkg::CfTrap);
      end
      cf_identity[dut_rou.commit_index[c]] = 0;
    end
    if (cmu_bcast.flush_pipe) cf_identity = '{default:0};
  end
  #1;
  assert (dut_rou.pmu_cf_head_busy == head_busy && dut_rou.pmu_cf_head_waiting == head_waiting
      && dut_rou.pmu_cf_head_domain == head_domain) else $fatal(1, "ROB head observation lost edge alignment");
  for (int e = 0; e < `RAPT_ROB_SIZE; e++)
    assert (dut_rou.pmu_cf_events[e] == expected[e])
    else $fatal(1, "ROB lifecycle event mismatch at entry %0d: got %0h expected %0h",
                e, dut_rou.pmu_cf_events[e], expected[e]);
end
