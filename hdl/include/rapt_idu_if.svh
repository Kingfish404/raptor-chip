/* verilator lint_off DECLFILENAME */
`ifndef RAPT_PIPE_IF_SVH
`define RAPT_PIPE_IF_SVH
`include "rapt.svh"

interface idu_rnu_if #(
    parameter unsigned RLEN = `RAPT_REG_LEN,
    parameter int XLEN = `RAPT_XLEN
);
  // Slot A (always present)
  rapt_pkg::uop_t uop_a;

  logic [XLEN-1:0] op1_a;
  logic [XLEN-1:0] op2_a;
  logic [RLEN-1:0] rs1_a;
  logic [RLEN-1:0] rs2_a;
  logic valid_a;

`ifdef RAPT_DUAL_ISSUE
  // Slot B (dual issue: younger instruction)
  rapt_pkg::uop_t uop_b;

  logic [XLEN-1:0] op1_b;
  logic [XLEN-1:0] op2_b;
  logic [RLEN-1:0] rs1_b;
  logic [RLEN-1:0] rs2_b;
  logic valid_b;
`endif

  logic ready;

`ifdef RAPT_DUAL_ISSUE
  modport master(
      output uop_a, op1_a, op2_a, rs1_a, rs2_a, valid_a,
      output uop_b, op1_b, op2_b, rs1_b, rs2_b, valid_b,
      input ready
  );
  modport slave(
      input uop_a, op1_a, op2_a, rs1_a, rs2_a, valid_a,
      input uop_b, op1_b, op2_b, rs1_b, rs2_b, valid_b,
      output ready
  );
`else
  modport master(output uop_a, op1_a, op2_a, rs1_a, rs2_a, valid_a, input ready);
  modport slave(input uop_a, op1_a, op2_a, rs1_a, rs2_a, valid_a, output ready);
`endif
endinterface

`endif
