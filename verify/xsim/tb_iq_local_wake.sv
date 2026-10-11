`include "rapt.svh"
`include "rapt_if.svh"

// A local producer is seen by resident data registers one edge before the
// global broadcast. New allocations and completion dependencies use the latter.
module tb_iq_local_wake;
  import rapt_pkg::*;
`ifdef RAPT_TEST_LOCAL_MEMORY_WAKE
  localparam int LocalWakePort = IntegerIssuePorts + 1;
`else
  localparam int LocalWakePort = 0;
`endif

  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  dispatch_slot_t dispatch[DispatchWidth];
  completion_t accepted[CompletionPorts], completion[CompletionPorts];
  completion_t local_operand_wake[CompletionPorts];
  issue_packet_t issue[1];
  dpu_iq_if #(.RS_SIZE(4)) disp ();
  cmu_bcast_if cmu_bcast ();
  load_fast_if load_fast ();
  logic issue_enable = 0;
  logic [2:0] occupancy;
  for (genvar p = 0; p < CompletionPorts; p++) begin : g_completion
    rapt_completion_stage stage (
        .clock,
        .reset,
        .flush(cmu_bcast.flush_pipe),
        .accepted(accepted[p]),
        .completion(completion[p])
    );
    assign local_operand_wake[p] = (p < IntegerIssuePorts || p == LocalWakePort) ? accepted[p] : '0;
  end
  for (genvar s = 0; s < DispatchWidth; s++) assign disp.rs_idx[s] = disp.free_idx[s];
  rapt_iq #(
      .IQ_SIZE(4),
      .NumIssuePorts(1),
      .ComboCdbWake(1'b0),
      .LocalOperandWake(1'b1)
  ) dut (
      .clock,
      .reset,
      .completion,
      .local_operand_wake,
      .dispatch,
      .disp,
      .cmu_bcast,
      .cancel_valid(1'b0),
      .cancel_head('0),
      .cancel_owner('0),
      .combo_source(completion),
      .load_fast,
      .issue_enable,
      .issue,
      .occ_o(occupancy),
      .pmu_iq_full()
  );
  task automatic tick;
    @(negedge clock);
  endtask
  task automatic offer(input int tag1, input int tag2, input int owner);
    dispatch[0] = '0;
    dispatch[0].uop.schedule.issue_ports = 1;
    dispatch[0].dest = $bits(dispatch[0].dest)'(owner);
    dispatch[0].generation = 1;
    dispatch[0].pr1 = phys_reg_t'(tag1);
    dispatch[0].pr2 = phys_reg_t'(tag2);
    dispatch[0].op1 = 'h55;
    dispatch[0].op2 = 'h66;
    disp.accept[0] = 1;
    #1;
    if (!disp.free_found[0]) $fatal(1, "local-wake fixture exhausted queue");
  endtask
  task automatic producer(input int port_id, input int tag, input logic [`RAPT_XLEN-1:0] value,
                          input int owner = 12);
    accepted[port_id] = '0;
    accepted[port_id].valid = 1;
    accepted[port_id].prd = phys_reg_t'(tag);
    accepted[port_id].rd = arch_reg_t'(tag == 0 ? 0 : 1);
    accepted[port_id].result = value;
    accepted[port_id].dest = $bits(dispatch[0].dest)'(owner);
    accepted[port_id].generation = 1;
  endtask
  task automatic stop_offer;
    disp.accept = '{default: 0};
    dispatch = '{default: '0};
  endtask
  task automatic expect_issue(input int owner, input logic [`RAPT_XLEN-1:0] op1,
                              input logic [`RAPT_XLEN-1:0] op2);
    #1;
    if (!issue[0].valid || issue[0].dest != $bits(
            dispatch[0].dest
        )'(owner) || issue[0].op1 != op1 || issue[0].op2 != op2)
      $fatal(
          1,
          "incorrect issue owner/data: valid=%b owner=%0d op1=%h op2=%h",
          issue[0].valid,
          issue[0].dest,
          issue[0].op1,
          issue[0].op2
      );
  endtask
  task automatic retire_and_empty;
    tick();
    tick();
    #1;
    if (occupancy != 0 || issue[0].valid) $fatal(1, "late global copy resurrected owner");
    issue_enable = 0;
  endtask
  initial begin
    stop_offer();
    accepted = '{default: '0};
    cmu_bcast.flush_pipe = 0;
    load_fast.valid = 0;
    load_fast.rebusy = 0;
    load_fast.confirmed = 0;
    load_fast.prd = 0;
    load_fast.result = 0;
    repeat (3) tick();
    reset = 0;

    offer(5, 0, 3);
    tick();
    stop_offer();
    issue_enable = 1;
    producer(LocalWakePort, 5, 'h12345678);
    #1;
    if (issue[0].valid) $fatal(1, "local wake entered combinational issue selection");
    tick();
    accepted = '{default: '0};
    expect_issue(3, 'h12345678, 'h66);
    retire_and_empty();

    // An allocation coinciding with an early packet must consume its later
    // global copy. The incoming owner cannot depend on a past local event.
    offer(6, 0, 4);
    producer(LocalWakePort, 6, 'habcdef01);
    issue_enable = 1;
    tick();
    stop_offer();
    accepted = '{default: '0};
    #1;
    if (issue[0].valid) $fatal(1, "allocation unexpectedly consumed resident local bypass");
    tick();
    expect_issue(4, 'habcdef01, 'h66);
    retire_and_empty();

    offer(7, 8, 5);
    tick();
    stop_offer();
    producer(LocalWakePort, 7, 'h7777);
    tick();
    accepted = '{default: '0};
    producer(1, 8, 'h8888);
    tick();
    accepted = '{default: '0};
    repeat (2) tick();
    issue_enable = 1;
    expect_issue(5, 'h7777, 'h8888);
    retire_and_empty();

    offer(9, 0, 6);
    tick();
    stop_offer();
    producer(LocalWakePort, 9, 'hdead);
    cmu_bcast.flush_pipe = 1;
    tick();
    accepted = '{default: '0};
    cmu_bcast.flush_pipe = 0;
    issue_enable = 1;
    repeat (2) tick();
    #1;
    if (occupancy != 0 || issue[0].valid || completion[LocalWakePort].valid)
      $fatal(1, "flush retained local/global completion or queue owner");
    issue_enable = 0;
    offer(9, 0, 7);
    tick();
    stop_offer();
    producer(LocalWakePort, 9, 'hbeef);
    tick();
    accepted = '{default: '0};
    issue_enable = 1;
    expect_issue(7, 'hbeef, 'h66);
    retire_and_empty();

    offer(10, 0, 8);
    dispatch[0].dep_valid[0] = 1;
    dispatch[0].dep_tag[0] = $bits(dispatch[0].dest)'(11);
    dispatch[0].dep_generation[0] = 1;
    tick();
    stop_offer();
    producer(LocalWakePort, 10, 'h1010, 11);
    issue_enable = 1;
    tick();
    accepted = '{default: '0};
    #1;
    if (issue[0].valid) $fatal(1, "local data wake bypassed global completion dependency");
    tick();
    expect_issue(8, 'h1010, 'h66);
    retire_and_empty();

    offer(0, 0, 9);
    tick();
    stop_offer();
    producer(LocalWakePort, 0, 'hbad);
    tick();
    accepted = '{default: '0};
    issue_enable = 1;
    expect_issue(9, 'h55, 'h66);
    retire_and_empty();
    $display(
        "PASS: resident local wake, allocation handoff, duplicate global packet, backpressure, flush/reuse, control dependency and zero tag XLEN=%0d",
        `RAPT_XLEN);
    $finish;
  end
endmodule
