`include "rapt.svh"

interface rapt_iq_uvm_if (input logic clock);
  localparam int IQSize = 8;
  localparam int XLEN = `RAPT_XLEN;
  localparam int PLEN = `RAPT_PHY_LEN;
  localparam int RLEN = `RAPT_REG_LEN;
  localparam int ROBSize = `RAPT_ROB_SIZE;
  localparam int IQLEN = $clog2(IQSize);
  localparam int ROBLEN = $clog2(ROBSize);

  logic reset;
  logic flush_pipe;

  logic accept_a;
  logic accept_b;
  logic [IQLEN-1:0] b_rs_idx;
  logic iss_b_block_a;
  logic iss_b_block_b;

  logic [XLEN-1:0] pc_a;
  logic [XLEN-1:0] op1_a;
  logic [XLEN-1:0] op2_a;
  logic [PLEN-1:0] pr1_a;
  logic [PLEN-1:0] pr2_a;
  logic [PLEN-1:0] prd_a;
  logic [RLEN-1:0] rd_a;
  logic [ROBLEN-1:0] dest_a;

  logic [XLEN-1:0] pc_b;
  logic [XLEN-1:0] op1_b;
  logic [XLEN-1:0] op2_b;
  logic [PLEN-1:0] pr1_b;
  logic [PLEN-1:0] pr2_b;
  logic [PLEN-1:0] prd_b;
  logic [RLEN-1:0] rd_b;
  logic [ROBLEN-1:0] dest_b;

  logic [3:0] wb_valid;
  logic [PLEN-1:0] wb_prd_0;
  logic [PLEN-1:0] wb_prd_1;
  logic [PLEN-1:0] wb_prd_2;
  logic [PLEN-1:0] wb_prd_3;
  logic [XLEN-1:0] wb_result_0;
  logic [XLEN-1:0] wb_result_1;
  logic [XLEN-1:0] wb_result_2;
  logic [XLEN-1:0] wb_result_3;
  logic load_fast_valid;
  logic load_fast_rebusy;
  logic [PLEN-1:0] load_fast_prd;

  logic free_found_a;
  logic free_found_b;
  logic [IQLEN-1:0] free_idx_a;
  logic [IQLEN-1:0] free_idx_b;
  logic [IQLEN:0] occ;
  logic pmu_iq_full;

  logic iss_valid;
  logic [XLEN-1:0] iss_pc;
  logic [XLEN-1:0] iss_op1;
  logic [XLEN-1:0] iss_op2;
  logic [PLEN-1:0] iss_prd;
  logic [RLEN-1:0] iss_rd;
  logic [ROBLEN-1:0] iss_dest;

  logic iss_b_valid;
  logic [XLEN-1:0] iss_b_pc;
  logic [XLEN-1:0] iss_b_op1;
  logic [XLEN-1:0] iss_b_op2;
  logic [PLEN-1:0] iss_b_prd;
  logic [RLEN-1:0] iss_b_rd;
  logic [ROBLEN-1:0] iss_b_dest;

  initial begin
    reset = 1'b1;
    flush_pipe = 1'b0;
    accept_a = 1'b0;
    accept_b = 1'b0;
    b_rs_idx = '0;
    iss_b_block_a = 1'b0;
    iss_b_block_b = 1'b0;
    pc_a = '0;
    op1_a = '0;
    op2_a = '0;
    pr1_a = '0;
    pr2_a = '0;
    prd_a = '0;
    rd_a = '0;
    dest_a = '0;
    pc_b = '0;
    op1_b = '0;
    op2_b = '0;
    pr1_b = '0;
    pr2_b = '0;
    prd_b = '0;
    rd_b = '0;
    dest_b = '0;
    wb_valid = '0;
    wb_prd_0 = '0;
    wb_prd_1 = '0;
    wb_prd_2 = '0;
    wb_prd_3 = '0;
    wb_result_0 = '0;
    wb_result_1 = '0;
    wb_result_2 = '0;
    wb_result_3 = '0;
    load_fast_valid = 1'b0;
    load_fast_rebusy = 1'b0;
    load_fast_prd = '0;
  end

  clocking drv_cb @(negedge clock);
    default input #1step output #0;
    output reset, flush_pipe, accept_a, accept_b, b_rs_idx;
    output iss_b_block_a, iss_b_block_b;
    output pc_a, op1_a, op2_a, pr1_a, pr2_a, prd_a, rd_a, dest_a;
    output pc_b, op1_b, op2_b, pr1_b, pr2_b, prd_b, rd_b, dest_b;
    output wb_valid, wb_prd_0, wb_prd_1, wb_prd_2, wb_prd_3;
    output wb_result_0, wb_result_1, wb_result_2, wb_result_3;
    output load_fast_valid, load_fast_rebusy, load_fast_prd;
    input free_found_a, free_found_b, free_idx_a, free_idx_b;
  endclocking

  clocking mon_cb @(posedge clock);
    default input #1step;
    input reset, flush_pipe, accept_a, accept_b, b_rs_idx;
    input iss_b_block_a, iss_b_block_b;
    input pc_a, op1_a, op2_a, pr1_a, pr2_a, prd_a, rd_a, dest_a;
    input pc_b, op1_b, op2_b, pr1_b, pr2_b, prd_b, rd_b, dest_b;
    input wb_valid, wb_prd_0, wb_prd_1, wb_prd_2, wb_prd_3;
    input wb_result_0, wb_result_1, wb_result_2, wb_result_3;
    input load_fast_valid, load_fast_rebusy, load_fast_prd;
    input free_found_a, free_found_b, free_idx_a, free_idx_b;
    input occ, pmu_iq_full;
    input iss_valid, iss_pc, iss_op1, iss_op2, iss_prd, iss_rd, iss_dest;
    input iss_b_valid, iss_b_pc, iss_b_op1, iss_b_op2, iss_b_prd, iss_b_rd, iss_b_dest;
  endclocking
endinterface
