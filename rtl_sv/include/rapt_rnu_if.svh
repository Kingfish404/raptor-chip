`ifndef RAPT_RN_IF_SVH
`define RAPT_RN_IF_SVH
`include "rapt.svh"
import rapt_pkg::*;

/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */

interface rnu_rou_if #(
    parameter unsigned PLEN = `RAPT_PHY_LEN,
    parameter unsigned RLEN = `RAPT_REG_LEN,
    parameter unsigned XLEN = `RAPT_XLEN
);
  // Slot A (always present)
  rapt_pkg::uop_t uop_a;

  logic [PLEN-1:0] pr1_a;
  logic [PLEN-1:0] pr2_a;
  logic [PLEN-1:0] prd_a;
  logic [PLEN-1:0] prs_a;

  logic [XLEN-1:0] op1_a;
  logic [XLEN-1:0] op2_a;

  logic valid_a;

`ifdef RAPT_DUAL_ISSUE
  // Slot B (dual issue: younger instruction)
  rapt_pkg::uop_t uop_b;

  logic [PLEN-1:0] pr1_b;
  logic [PLEN-1:0] pr2_b;
  logic [PLEN-1:0] prd_b;
  logic [PLEN-1:0] prs_b;

  logic [XLEN-1:0] op1_b;
  logic [XLEN-1:0] op2_b;

  logic valid_b;
`endif

  logic ready;

  modport master(
      output uop_a, op1_a, op2_a, pr1_a, pr2_a, prd_a, prs_a, valid_a,
`ifdef RAPT_DUAL_ISSUE
      output uop_b, op1_b, op2_b, pr1_b, pr2_b, prd_b, prs_b, valid_b,
`endif
      input ready
  );
  modport slave(
      input uop_a, op1_a, op2_a, pr1_a, pr2_a, prd_a, prs_a, valid_a,
`ifdef RAPT_DUAL_ISSUE
      input uop_b, op1_b, op2_b, pr1_b, pr2_b, prd_b, prs_b, valid_b,
`endif
      output ready
  );
endinterface

/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNUSEDPARAM */

`endif
