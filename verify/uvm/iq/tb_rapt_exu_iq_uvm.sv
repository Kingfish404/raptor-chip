`timescale 1ns/1ps
`include "rapt.svh"
`include "rapt_if.svh"

module tb_rapt_exu_iq_uvm;
  import uvm_pkg::*;
  import rapt_pkg::*;
  import rapt_iq_uvm_pkg::*;

  logic clock = 1'b0;
  always #5 clock = ~clock;

  rapt_iq_uvm_if tb_if (clock);

  cmu_bcast_if cmu_bcast();
  rou_exu_if rou_exu();
  exu_disp_rs_if #(.RS_SIZE(8)) disp();
  exu_wb_if exu_rou();
  exu_wb_if exu_rou_b();
  exu_wb_if exu_ioq_bcast();
  exu_wb_if exu_wb_mul();
  exu_load_fast_if load_fast();
  exu_iq_iss_if iss();
  exu_iq_iss_if iss_b();

  rapt_exu_iq #(
      .IQ_SIZE(8),
      .HAS_ISS_B(1'b1)
  ) dut (
      .clock,
      .reset(tb_if.reset),
      .cmu_bcast,
      .rou_exu,
      .disp,
      .exu_rou,
      .exu_rou_b,
      .exu_ioq_bcast,
      .exu_wb_mul,
      .load_fast,
      .iss,
      .iss_b,
      .occ_o(tb_if.occ),
      .pmu_iq_full(tb_if.pmu_iq_full)
  );

  always_comb begin
    cmu_bcast.flush_pipe = tb_if.flush_pipe;

    disp.accept_a = tb_if.accept_a;
    disp.accept_b = tb_if.accept_b;
    disp.b_rs_idx = tb_if.b_rs_idx;
    disp.iss_b_block_a = tb_if.iss_b_block_a;
    disp.iss_b_block_b = tb_if.iss_b_block_b;
    tb_if.free_found_a = disp.free_found_a;
    tb_if.free_found_b = disp.free_found_b;
    tb_if.free_idx_a = disp.free_idx_a;
    tb_if.free_idx_b = disp.free_idx_b;

    rou_exu.uop = '0;
    rou_exu.uop.pc = tb_if.pc_a;
    rou_exu.uop.rd = tb_if.rd_a;
    rou_exu.op1 = tb_if.op1_a;
    rou_exu.op2 = tb_if.op2_a;
    rou_exu.pr1 = tb_if.pr1_a;
    rou_exu.pr2 = tb_if.pr2_a;
    rou_exu.prd = tb_if.prd_a;
    rou_exu.dest = tb_if.dest_a;
    rou_exu.valid = tb_if.accept_a;
    rou_exu.uop_b = '0;
    rou_exu.uop_b.pc = tb_if.pc_b;
    rou_exu.uop_b.rd = tb_if.rd_b;
    rou_exu.op1_b = tb_if.op1_b;
    rou_exu.op2_b = tb_if.op2_b;
    rou_exu.pr1_b = tb_if.pr1_b;
    rou_exu.pr2_b = tb_if.pr2_b;
    rou_exu.prd_b = tb_if.prd_b;
    rou_exu.dest_b = tb_if.dest_b;
    rou_exu.valid_b = tb_if.accept_b;

    exu_ioq_bcast.valid = tb_if.wb_valid[0];
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
    tb_if.iss_pc = iss.pc;
    tb_if.iss_op1 = iss.op1;
    tb_if.iss_op2 = iss.op2;
    tb_if.iss_prd = iss.prd;
    tb_if.iss_rd = iss.rd;
    tb_if.iss_dest = iss.dest;
    tb_if.iss_b_valid = iss_b.valid;
    tb_if.iss_b_pc = iss_b.pc;
    tb_if.iss_b_op1 = iss_b.op1;
    tb_if.iss_b_op2 = iss_b.op2;
    tb_if.iss_b_prd = iss_b.prd;
    tb_if.iss_b_rd = iss_b.rd;
    tb_if.iss_b_dest = iss_b.dest;
  end

  initial begin
    uvm_config_db#(iq_vif_t)::set(null, "uvm_test_top.env.agent.*", "vif", tb_if);
    run_test("iq_uvm_test");
  end

  initial begin
    #2ms;
    $fatal(1, "UVM issue queue test timed out");
  end
endmodule
