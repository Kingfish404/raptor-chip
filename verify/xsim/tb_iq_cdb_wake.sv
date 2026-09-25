`include "rapt.svh"
`include "rapt_if.svh"

// BRQ-style queue: a waiting operand must issue the cycle its producer
// appears on CDB, with the CDB value on op1. Tag-only fast-wake without a
// matching CDB packet still must not issue.
module tb_iq_cdb_wake;
  import rapt_pkg::*;
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  dispatch_slot_t dispatch[DispatchWidth];
  completion_t completion[CompletionPorts];
  issue_packet_t issue[1];
  dpu_iq_if #(.RS_SIZE(4)) disp ();
  cmu_bcast_if cmu_bcast ();
  load_fast_if load_fast ();
  logic issue_enable;
  logic [2:0] occupancy;
  rapt_iq #(
      .IQ_SIZE(4),
      .NumIssuePorts(1),
      .ComboCdbWake(1'b1)
  ) dut (
      .cancel_valid(1'b0),
      .cancel_head('0),
      .cancel_owner('0),
      .clock,
      .reset,
      .dispatch,
      .completion,
      .disp,
      .cmu_bcast,
      .combo_source(completion),
      .load_fast,
      .issue_enable,
      .issue,
      .occ_o(occupancy),
      .pmu_iq_full()
  );
  assign disp.rs_idx[0] = disp.free_idx[0];
  assign disp.rs_idx[1] = disp.free_idx[1];
  task automatic tick;
    @(negedge clock);
  endtask
  initial begin
    disp.accept = '{default: 0};
    dispatch = '{default: '0};
    completion = '{default: '0};
    issue_enable = 1;
    cmu_bcast.flush_pipe = 0;
    load_fast.valid = 0;
    load_fast.rebusy = 0;
    load_fast.confirmed = 0;
    load_fast.prd = 0;
    load_fast.result = 0;
    repeat (3) tick();
    reset = 0;

    dispatch[0] = '0;
    dispatch[0].uop.schedule.issue_ports = 1;
    dispatch[0].pr1 = phys_reg_t'(5);
    dispatch[0].pr2 = '0;
    dispatch[0].op1 = '0;
    dispatch[0].op2 = $bits(dispatch[0].op2)'('h1111);
    dispatch[0].prd = '0;
    dispatch[0].dest = 3;
    dispatch[0].generation = 1;
    disp.accept[0] = 1;
    tick();
    disp.accept[0] = 0;
    dispatch[0] = '0;
    tick();
    #1;
    if (issue[0].valid) $fatal(1, "issued before producer CDB");

    load_fast.valid = 1;
    load_fast.prd = phys_reg_t'(5);
    load_fast.dest = 4;
    load_fast.generation = 2;
    #1;
    if (issue[0].valid) $fatal(1, "tag-only fast-wake issued without CDB");
    load_fast.valid = 0;

    completion[0].valid = 1;
    completion[0].prd = phys_reg_t'(5);
    completion[0].result = $bits(completion[0].result)'('h1234_5678);
    completion[0].dest = 7;
    completion[0].generation = 1;
    #1;
    if (!issue[0].valid) $fatal(1, "CDB wake did not issue this cycle");
    if (issue[0].op1 != $bits(issue[0].op1)'('h1234_5678))
      $fatal(1, "CDB value missing on issue op1");
    if (issue[0].op2 != $bits(issue[0].op2)'('h1111)) $fatal(1, "ready op2 was overwritten");
    if (issue[0].dest != 3) $fatal(1, "issue identity changed");

    $display("PASS: IQ ComboCdbWake same-cycle CDB operand XLEN=%0d", `RAPT_XLEN);
    $finish;
  end
endmodule
