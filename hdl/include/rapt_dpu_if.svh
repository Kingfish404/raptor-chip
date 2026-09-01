/* verilator lint_off DECLFILENAME */
`ifndef RAPT_DPU_IF_SVH
`define RAPT_DPU_IF_SVH
`include "rapt.svh"

/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */

interface iq_iss_if #(
    parameter unsigned PLEN = `RAPT_PHY_LEN,
    parameter unsigned RLEN = `RAPT_REG_LEN,
    parameter int XLEN = `RAPT_XLEN
);
  /* verilator lint_off UNUSEDSIGNAL */
  logic valid;
  logic [XLEN-1:0] op1;
  logic [XLEN-1:0] op2;
  logic [5:0] alu;
  logic [XLEN-1:0] pc;
  logic c;
  logic word;
  logic [XLEN-1:0] imm;
  logic [XLEN-1:0] pnpc;
  logic jen;
  logic jren;
  logic trap;
  logic [XLEN-1:0] tval;
  logic [XLEN-1:0] cause;
  logic [$clog2(`RAPT_ROB_SIZE)-1:0] dest;
  logic [PLEN-1:0] prd;
  logic [RLEN-1:0] rd;
  logic fp_valid;
  logic [5:0] fp_op;
  logic [2:0] fp_rm;
  logic [4:0] fp_rs1;
  logic [4:0] fp_rs2;
  logic [4:0] fp_rs3;
  logic [4:0] fp_rd;
  logic fp_dep1_valid;
  logic fp_dep2_valid;
  logic fp_dep3_valid;
  logic [$clog2(`RAPT_ROB_SIZE)-1:0] fp_dep1;
  logic [$clog2(`RAPT_ROB_SIZE)-1:0] fp_dep2;
  logic [$clog2(`RAPT_ROB_SIZE)-1:0] fp_dep3;
  /* verilator lint_on UNUSEDSIGNAL */

  modport iq(
      output valid, op1, op2, alu, pc, c, word, imm, pnpc, jen, jren,
      output trap, tval, cause, dest, prd, rd,
      output fp_valid, fp_op, fp_rm, fp_rs1, fp_rs2, fp_rs3, fp_rd,
      output fp_dep1_valid, fp_dep2_valid, fp_dep3_valid, fp_dep1, fp_dep2, fp_dep3
  );
  modport fu(
      input valid, op1, op2, alu, pc, c, word, imm, pnpc, jen, jren,
      input trap, tval, cause, dest, prd, rd,
      input fp_valid, fp_op, fp_rm, fp_rs1, fp_rs2, fp_rs3, fp_rd,
      input fp_dep1_valid, fp_dep2_valid, fp_dep3_valid, fp_dep1, fp_dep2, fp_dep3
  );
endinterface

interface dpu_iq_if #(
    parameter unsigned RS_SIZE = `RAPT_RS_SIZE
);
  logic free_found_a;
  logic free_found_b;
  logic [$clog2(RS_SIZE)-1:0] free_idx_a;
  logic [$clog2(RS_SIZE)-1:0] free_idx_b;
  logic accept_a;
  logic accept_b;
  logic [$clog2(RS_SIZE)-1:0] b_rs_idx;
  logic iss_b_block_a;
  logic iss_b_block_b;

  modport top(
      input free_found_a, free_found_b, free_idx_a, free_idx_b,
      output accept_a, accept_b, b_rs_idx, iss_b_block_a, iss_b_block_b
  );
  modport rs(
      output free_found_a, free_found_b, free_idx_a, free_idx_b,
      input accept_a, accept_b, b_rs_idx, iss_b_block_a, iss_b_block_b
  );
endinterface

interface dpu_ioq_if #(
    parameter unsigned IOQ_SIZE = `RAPT_IOQ_SIZE
);
  logic ready;
  logic ready_b;
  logic accept_a;
  logic accept_b_paired;
  logic accept_b_alone;

  modport top(input ready, ready_b, output accept_a, accept_b_paired, accept_b_alone);
  modport ioq(output ready, ready_b, input accept_a, accept_b_paired, accept_b_alone);

  /* verilator lint_off UNUSEDSIGNAL */
  logic [$clog2(IOQ_SIZE)-1:0] _ioq_size_pad;
  /* verilator lint_on UNUSEDSIGNAL */
endinterface

/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNUSEDPARAM */

`endif  // RAPT_DPU_IF_SVH
