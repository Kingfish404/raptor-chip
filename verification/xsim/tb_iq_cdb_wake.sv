`include "rapt.svh"
`include "rapt_if.svh"

// Compare BRQ-style same-cycle wake with ALQ-style registered wake. Both
// consume the producer's CDB value, but only ComboCdbWake may issue before
// the capture edge. A mismatched CDB tag must leave the operand blocked.
module tb_iq_cdb_wake #(
    parameter bit ComboCdbWake = 1'b1,
    parameter int HoldCycles = 1
);
  import rapt_pkg::*;
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  dispatch_slot_t dispatch[DispatchWidth];
  completion_t completion[CompletionPorts];
  issue_packet_t issue[1];
  dpu_iq_if #(.RS_SIZE(4)) disp ();
  cmu_bcast_if cmu_bcast ();
  logic issue_enable;
  logic [2:0] occupancy;
  rapt_iq #(
      .IQ_SIZE(4),
      .NumIssuePorts(1),
      .ComboCdbWake(ComboCdbWake)
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
    completion[0].valid = 1;
    completion[0].prd = phys_reg_t'(6);
    #1;
    if (issue[0].valid) $fatal(1, "wrong CDB tag released operand");

    completion[0].valid = 1;
    completion[0].prd = phys_reg_t'(5);
    completion[0].result = $bits(completion[0].result)'('h1234_5678);
    completion[0].dest = 7;
    completion[0].generation = 1;
    #1;
    if (ComboCdbWake) begin
      if (!issue[0].valid) $fatal(1, "CDB wake did not issue this cycle");
    end else begin
      if (issue[0].valid) $fatal(1, "registered wake issued before the capture edge");
      tick();
      completion[0].valid = 0;
      #1;
      if (!issue[0].valid) $fatal(1, "registered wake did not issue after the capture edge");
    end
    if (issue[0].op1 != $bits(issue[0].op1)'('h1234_5678))
      $fatal(1, "CDB value missing on issue op1");
    if (issue[0].op2 != $bits(issue[0].op2)'('h1111)) $fatal(1, "ready op2 was overwritten");
    if (issue[0].dest != 3) $fatal(1, "issue identity changed");

    tick();
    completion = '{default: '0};
    tick();
    dispatch[0] = '0;
    dispatch[0].uop.schedule.issue_ports = 1;
    dispatch[0].pr1 = phys_reg_t'(11);
    dispatch[0].dest = 10;
    disp.accept[0] = 1;
    tick();
    disp.accept[0] = 0;
    issue_enable = 0;
    completion[0].valid = 1;
    completion[0].prd = phys_reg_t'(11);
    completion[0].result = 'h13572468;
    tick();
    completion[0].valid = 0;
    repeat (HoldCycles) tick();
    issue_enable = 1;
    #1;
    if (!issue[0].valid || issue[0].op1 != `RAPT_XLEN'('h13572468))
      $fatal(1, "unselected consumer lost a one-cycle CDB wake");
    $display("PASS: IQ CDB wake XLEN=%0d combo=%0d hold=%0d", `RAPT_XLEN, ComboCdbWake, HoldCycles);
    $finish;
  end
endmodule
