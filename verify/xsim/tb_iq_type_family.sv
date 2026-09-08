`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_types.svh"

module tb_iq_type_family;
  import rapt_pkg::*;
  function automatic core_config_t wide_config();
    core_config_t c = CoreConfig;
    c.xlen = 64;
    c.phys_regs = 512;
    c.rob_entries = 128;
    c.completion_ports = 7;
    c.completion_dependencies = 4;
    return c;
  endfunction
  localparam core_config_t Cfg = wide_config();
  typedef logic [63:0] word_t;
  typedef logic [8:0] physical_t;
  typedef logic [6:0] tag_t;
  typedef logic [5:0] generation_t;
  // This queue has never heard of this payload and must not interpret it.
  typedef logic [95:0] opaque_execute_t;
  typedef struct packed {
    execution_domain_t domain;
    logic [2:0] issue_ports;
  } wide_schedule_t;
  `RAPT_UOP_TYPE(wide_uop_t, word_t, arch_reg_t, wide_schedule_t, opaque_execute_t)
  `RAPT_DISPATCH_SLOT_TYPE(wide_slot_t, wide_uop_t, word_t, physical_t, tag_t, generation_t, 4)
  `RAPT_ISSUE_PACKET_TYPE(wide_issue_t, wide_uop_t, word_t, physical_t, tag_t, generation_t)
  `RAPT_COMPLETION_TYPE(wide_completion_t, word_t, physical_t, arch_reg_t, tag_t, generation_t)

  logic clock = 0;
  logic reset = 1;
  always #5 clock = ~clock;
  wide_slot_t dispatch[DispatchWidth];
  wide_completion_t completion[7];
  wide_issue_t iss, iss_b;
  wide_issue_t issue[3];
  logic [2:0] issue_enable = 3'b111;
  assign iss = issue[0];
  assign iss_b = '0;
  cmu_bcast_if cmu_bcast ();
  load_fast_if #(
      .PLEN(9),
      .ROBLEN(7),
      .GENERATION_BITS(6),
      .XLEN(64)
  ) load_fast ();
  dpu_iq_if #(.RS_SIZE(4)) disp ();
  logic [2:0] occupancy;
  int issued_count = 0;
  // Compare the complete new output against the pre-refactor indexed read,
  // including invalid outputs and the fast-confirm identity-qualified bypass.
  always @(negedge clock) begin
    #2;
    for (int p = 0; p < 3; p++) begin
      automatic int idx=0;
      automatic wide_issue_t legacy;
      for (int e = 0; e < 4; e++) if (dut.selected[p][e]) idx |= e;
      legacy.valid=|dut.selected[p];
      legacy.uop=dut.iq_uop[idx];
      legacy.op1=dut.pr1_fast_confirm[idx] ? (
          load_fast.confirmed_prd==dut.iq_pr1[idx] && load_fast.confirmed_dest==dut.iq_pr1_fast_dest[idx]
          && load_fast.confirmed_generation==dut.iq_pr1_fast_generation[idx] ? load_fast.result : '0) : dut.iq_vj[idx];
      legacy.op2=dut.pr2_fast_confirm[idx] ? (
          load_fast.confirmed_prd==dut.iq_pr2[idx] && load_fast.confirmed_dest==dut.iq_pr2_fast_dest[idx]
          && load_fast.confirmed_generation==dut.iq_pr2_fast_generation[idx] ? load_fast.result : '0) : dut.iq_vk[idx];
      legacy.dest=dut.iq_dest[idx];
      legacy.generation=dut.iq_generation[idx];
      legacy.prd=dut.iq_prd[idx];
      assert (issue[p] === legacy)
      else $fatal(1, "stored onehot/indexed output mismatch");
    end
  end
  wide_issue_t issued[16];
  rapt_iq #(
      .Cfg(Cfg),
      .IQ_SIZE(4),
      .NumIssuePorts(3),
      .RebalancePorts(1),
      .ReclaimOnIssue(1),
      .UopT(wide_uop_t),
      .SlotT(wide_slot_t),
      .IssueT(wide_issue_t),
      .CompletionT(wide_completion_t)
  ) dut (
      .cancel_valid(1'b0),
      .cancel_head('0),
      .cancel_owner('0),
      .clock,
      .reset,
      .dispatch,
      .disp,
      .completion,
      .cmu_bcast,
      .load_fast,
      .issue_enable,
      .issue,
      .occ_o(occupancy),
      .pmu_iq_full()
  );
  always @(posedge clock)
    if (!reset) begin
      for (int p = 0; p < 3; p++)
      if (issue[p].valid) begin
        issued[issued_count] = issue[p];
        issued_count++;
      end
    end

  task automatic tick;
    @(negedge clock);
  endtask
  task automatic allocate_a(input physical_t source, input bit early,
                            input logic [2:0] ports = 3'b111);
    dispatch[0] = '0;
    dispatch[0].uop.schedule.issue_ports = ports;
    dispatch[0].uop.execute = 96'hfedc_ba98_7654_3210_0123_4567;
    dispatch[0].uop.pc = 64'hffff_ffff_8000_0000;
    dispatch[0].prd = 9'h101;
    dispatch[0].pr1 = source;
    dispatch[0].op2 = 64'hf000_0000_0000_0007;
    dispatch[0].dest = 7'h62;
    load_fast.valid = early;
    load_fast.prd = source;
    load_fast.dest = 7'h55;
    load_fast.generation = 6'h2a;
    disp.accept[0] = 1;
    tick();
    disp.accept[0] = 0;
    load_fast.valid = 0;
  endtask

  assign disp.rs_idx[0] = disp.free_idx[0];
  initial begin
    cmu_bcast.flush_pipe = 0;
    foreach (dispatch[s]) dispatch[s] = '0;
    foreach (completion[p]) completion[p] = '0;
    disp.accept[0] = 0;
    disp.accept[1] = 0;
    disp.rs_idx[1] = 0;
    load_fast.valid = 0;
    load_fast.prd = 0;
    load_fast.rebusy = 0;
    load_fast.confirmed = 0;
    load_fast.confirmed_prd = 0;
    load_fast.confirmed_dest = 0;
    load_fast.confirmed_generation = 0;
    load_fast.confirmed_rd = 0;
    load_fast.result = 0;
    repeat (3) tick();
    reset = 0;

    // Distinct A/B completion dependencies, including a fourth dependency
    // absent from the production configuration.
    dispatch[0].uop.schedule.issue_ports = '1;
    dispatch[1].uop.schedule.issue_ports = '1;
    dispatch[0].uop.execute = 96'haaaa_bbbb_cccc_dddd_eeee_ffff;
    dispatch[0].dep_valid[0] = 1;
    dispatch[0].dep_tag[0] = 12;
    dispatch[1].uop.execute = 96'h1234_5678_9abc_def0_1234_5678;
    dispatch[1].dep_valid[0] = 1;
    dispatch[1].dep_tag[0] = 33;
    dispatch[1].dep_valid[3] = 1;
    dispatch[1].dep_tag[3] = 77;
    dispatch[1].pr1 = 9'h155;
    dispatch[1].prd = 9'h101;
    dispatch[1].dest = 7'h62;
    disp.rs_idx[1] = disp.free_idx[1];
    disp.accept[0] = 1;
    disp.accept[1] = 1;
    tick();
    disp.accept[0] = 0;
    disp.accept[1] = 0;
    completion[0].valid = 1;
    completion[0].dest = 12;
    tick();
    completion[0].valid = 0;
    repeat (2) tick();
    assert (issued_count == 1 && issued[0].uop.execute == dispatch[0].uop.execute)
    else $fatal(1, "slot A payload/dependency");
    completion[6].valid = 1;
    completion[6].dest = 33;
    completion[6].prd = 9'h155;
    completion[6].result = 64'hfedc_ba98_7654_3210;
    tick();
    completion[6].valid = 0;
    repeat (2) tick();
    assert (issued_count == 1)
    else $fatal(1, "fourth dependency ignored");
    completion[6].valid = 1;
    completion[6].dest = 77;
    completion[6].prd = 0;
    tick();
    completion[6].valid = 0;
    repeat (2) tick();
    assert (issued_count == 2 && issued[1].uop.execute == dispatch[1].uop.execute
            && issued[1].op1 == 64'hfedc_ba98_7654_3210
            && issued[1].prd == 9'h101 && issued[1].dest == 7'h62)
    else $fatal(1, "slot B dependencies/type widths/payload");

    allocate_a(9'h188, 1);
    tick();
    assert (issued_count == 2)
    else $fatal(1, "early wakeup issued without confirmation");
    load_fast.confirmed = 1;
    load_fast.confirmed_prd = 9'h188;
    load_fast.confirmed_dest = 7'h55;
    load_fast.confirmed_generation = 6'h2b;
    load_fast.confirmed_rd = 0;
    load_fast.result = 64'h1234_5678_abcd_ef01;
    tick();
    assert (issued_count == 2)
    else $fatal(1, "stale-generation fast confirmation released operand");
    load_fast.confirmed_generation = 6'h2a;
    load_fast.confirmed_prd = 9'h189;
    tick();
    assert (issued_count == 2)
    else $fatal(1, "wrong-physical-register confirmation released operand");
    load_fast.confirmed_prd = 9'h188;
    load_fast.confirmed_dest = 7'h54;
    tick();
    assert (issued_count == 2)
    else $fatal(1, "wrong-ROB-slot confirmation released operand");
    load_fast.confirmed_dest = 7'h55;
    tick();
    load_fast.confirmed = 0;
    assert (issued_count == 3 && issued[2].op1 == 64'h1234_5678_abcd_ef01)
    else $fatal(1, "early confirmation bypass");

    allocate_a(9'h188, 1);
    load_fast.valid = 1;
    load_fast.rebusy = 1;
    tick();
    load_fast.valid = 0;
    load_fast.rebusy = 0;
    tick();
    assert (issued_count == 3)
    else $fatal(1, "rebusy lost");
    completion[6].valid = 1;
    completion[6].prd = 9'h188;
    completion[6].result = 64'hffff_eeee_dddd_cccc;
    tick();
    completion[6].valid = 0;
    repeat (2) tick();
    assert (issued_count == 4 && issued[3].op1 == 64'hffff_eeee_dddd_cccc)
    else $fatal(1, "ordinary completion after rebusy");

    issue_enable = 3'b011;
    allocate_a(0, 0, 3'b100);
    tick();
    assert (issued_count == 4)
    else $fatal(1, "unsupported/disabled execution port selected");
    issue_enable = 3'b111;
    #1;
    assert (issue[2].valid && !issue[0].valid && !issue[1].valid)
    else $fatal(1, "third execution port capability mask");
    tick();
    issue_enable = 0;
    allocate_a(0, 0);
    allocate_a(0, 0);
    allocate_a(0, 0);
    issue_enable = 3'b111;
    #1;
    assert (issue[0].valid && issue[1].valid && issue[2].valid)
    else $fatal(1, "three-port oldest-ready selection");
    tick();
    assert (issued_count == 8)
    else $fatal(1, "multiport issue count");
    issue_enable = 0;
    allocate_a(0, 0, 3'b011);
    allocate_a(0, 0, 3'b001);
    issue_enable = 3'b011;
    #1;
    assert (issue[0].valid && issue[1].valid
        && issue[0].uop.schedule.issue_ports == 3'b001
        && issue[1].uop.schedule.issue_ports == 3'b011)
    else $fatal(1, "port repair did not preserve restricted/flexible payloads");
    tick();
    assert (issued_count == 10)
    else $fatal(1, "port repair duplicated/lost uop");
    allocate_a(9'h111, 0);
    cmu_bcast.flush_pipe = 1;
    tick();
    cmu_bcast.flush_pipe = 0;
    assert (occupancy == 0)
    else $fatal(1, "flush");
    issue_enable = 0;
    allocate_a(0, 0);
    cmu_bcast.flush_pipe = 1;
    issue_enable = '1;
    #1;
    foreach (issue[p])
    assert (!issue[p].valid)
    else $fatal(1, "ready wrong-path uop escaped flush");
    tick();
    cmu_bcast.flush_pipe = 0;
    assert (occupancy == 0 && issued_count == 10)
    else $fatal(1, "flush issued a cancelled uop");
    issue_enable = 0;
    repeat (4) allocate_a(0, 0, 3'b001);
    #1;
    assert (occupancy == 4 && !disp.free_found[0])
    else $fatal(1, "queue not full before reclaim");
    issue_enable = 3'b001;
    #1;
    assert (disp.free_found[0] && !disp.free_found[1])
    else $fatal(1, "issuing slot not available for reclaim");
    dispatch[0].uop.execute = 96'h0123_4567_89ab_cdef_dead_beef;
    disp.accept[0] = 1;
    tick();
    disp.accept[0] = 0;
    issue_enable = 0;
    #1;
    assert (occupancy == 4)
    else $fatal(1, "issue-clear erased replacement allocation");
    issue_enable = 3'b001;
    repeat (5) tick();
    assert (issued_count == 15 && issued[14].uop.execute == 96'h0123_4567_89ab_cdef_dead_beef)
    else $fatal(1, "reclaimed entry lost payload or became older than residents");
    $display(
        "PASS: independent types, generation-qualified early wakeup, four dependencies, three ports, port repair, flush kill and same-cycle issue-slot reclaim");
    $finish;
  end
  initial begin
    #5000;
    $fatal(1, "type-family test timeout");
  end
endmodule
