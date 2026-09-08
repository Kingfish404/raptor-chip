`timescale 1ns / 1ps
`include "rapt.svh"
`include "rapt_if.svh"

module tb_rapt_iq_uvm;
  import uvm_pkg::*;
  import rapt_pkg::*;
  import rapt_iq_uvm_pkg::*;

  logic clock = 1'b0;
  always #5 clock = ~clock;

  rapt_iq_uvm_if tb_if (clock);

  cmu_bcast_if cmu_bcast ();
  rapt_pkg::dispatch_slot_t dispatch[rapt_pkg::DispatchWidth];
  logic dispatch_ready[rapt_pkg::DispatchWidth];
  dpu_iq_if #(.RS_SIZE(8)) disp ();
  rapt_pkg::completion_t exu_rou;
  rapt_pkg::completion_t exu_rou_b;
  rapt_pkg::completion_t exu_ioq_bcast;
  rapt_pkg::completion_t exu_wb_mul;
  rapt_pkg::completion_t completion[rapt_pkg::CompletionPorts];
  assign completion[0] = exu_rou;
  assign completion[1] = exu_rou_b;
  assign completion[2] = '0;
  assign completion[3] = exu_ioq_bcast;
  assign completion[4] = exu_wb_mul;

  load_fast_if load_fast ();
  rapt_pkg::issue_packet_t iss;
  rapt_pkg::issue_packet_t iss_b;
  rapt_pkg::issue_packet_t issue[2];
  assign iss = issue[0];
  assign iss_b = issue[1];

  rapt_iq #(
      .IQ_SIZE(8),
      .NumIssuePorts(2)
  ) dut (
      .cancel_valid(1'b0),
      .cancel_head('0),
      .cancel_owner('0),
      .completion(completion),
      .clock,
      .reset(tb_if.reset),
      .cmu_bcast,
      .dispatch(dispatch),
      .disp,

      .load_fast,
      .issue,
      .issue_enable(2'b11),
      .occ_o(tb_if.occ),
      .pmu_iq_full(tb_if.pmu_iq_full)
  );

  always_comb begin
    cmu_bcast.flush_pipe = tb_if.flush_pipe;

    disp.accept[0] = tb_if.accept_a;
    disp.accept[1] = tb_if.accept_b;
    disp.rs_idx[1] = tb_if.b_rs_idx;
    tb_if.free_found_a = disp.free_found[0];
    tb_if.free_found_b = disp.free_found[1];
    tb_if.free_idx_a = disp.free_idx[0];
    tb_if.free_idx_b = disp.free_idx[1];

    dispatch[0].uop = '0;
    dispatch[0].uop.schedule.issue_ports = {~tb_if.iss_b_block_a, 1'b1};
    dispatch[0].uop.pc = tb_if.pc_a;
    dispatch[0].uop.rd = tb_if.rd_a;
    dispatch[0].op1 = tb_if.op1_a;
    dispatch[0].op2 = tb_if.op2_a;
    dispatch[0].pr1 = tb_if.pr1_a;
    dispatch[0].pr2 = tb_if.pr2_a;
    dispatch[0].prd = tb_if.prd_a;
    dispatch[0].dest = tb_if.dest_a;

    dispatch[1].uop = '0;
    dispatch[1].uop.schedule.issue_ports = {~tb_if.iss_b_block_b, 1'b1};
    dispatch[1].uop.pc = tb_if.pc_b;
    dispatch[1].uop.rd = tb_if.rd_b;
    dispatch[1].op1 = tb_if.op1_b;
    dispatch[1].op2 = tb_if.op2_b;
    dispatch[1].pr1 = tb_if.pr1_b;
    dispatch[1].pr2 = tb_if.pr2_b;
    dispatch[1].prd = tb_if.prd_b;
    dispatch[1].dest = tb_if.dest_b;


    exu_ioq_bcast.valid = tb_if.wb_valid[0];
    load_fast.confirmed = exu_ioq_bcast.valid;
    load_fast.confirmed_prd = exu_ioq_bcast.prd;
    load_fast.confirmed_rd = exu_ioq_bcast.rd;
    load_fast.result = exu_ioq_bcast.result;
    exu_ioq_bcast.prd = tb_if.wb_prd_0;
    exu_ioq_bcast.result = tb_if.wb_result_0;
    exu_rou.valid = tb_if.wb_valid[1];
    exu_rou.prd = tb_if.wb_prd_1;
    exu_rou.result = tb_if.wb_result_1;
    exu_rou_b.valid = tb_if.wb_valid[2];
    exu_rou_b.prd = tb_if.wb_prd_2;
    exu_rou_b.result = tb_if.wb_result_2;
    exu_wb_mul.valid = tb_if.wb_valid[3];
    exu_wb_mul.prd = tb_if.wb_prd_3;
    exu_wb_mul.result = tb_if.wb_result_3;
    load_fast.valid = tb_if.load_fast_valid;
    load_fast.rebusy = tb_if.load_fast_rebusy;
    load_fast.prd = tb_if.load_fast_prd;

    tb_if.iss_valid = iss.valid;
    tb_if.iss_pc = iss.uop.pc;
    tb_if.iss_op1 = iss.op1;
    tb_if.iss_op2 = iss.op2;
    tb_if.iss_prd = iss.prd;
    tb_if.iss_rd = iss.uop.rd;
    tb_if.iss_dest = iss.dest;
    tb_if.iss_b_valid = iss_b.valid;
    tb_if.iss_b_pc = iss_b.uop.pc;
    tb_if.iss_b_op1 = iss_b.op1;
    tb_if.iss_b_op2 = iss_b.op2;
    tb_if.iss_b_prd = iss_b.prd;
    tb_if.iss_b_rd = iss_b.uop.rd;
    tb_if.iss_b_dest = iss_b.dest;
  end

  assign disp.rs_idx[0] = disp.free_idx[0];
  initial begin
    uvm_config_db#(iq_vif_t)::set(null, "uvm_test_top.env.agent.*", "vif", tb_if);
    run_test("iq_uvm_test");
  end

  initial begin
    #2ms;
    $fatal(1, "UVM issue queue test timed out");
  end
endmodule
