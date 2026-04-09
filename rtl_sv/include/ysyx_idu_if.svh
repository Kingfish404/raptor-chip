`ifndef YSYX_PIPE_IF_SVH
`define YSYX_PIPE_IF_SVH
`include "ysyx.svh"
import ysyx_pkg::*;

interface idu_rnu_if #(
    parameter unsigned RLEN = `YSYX_REG_LEN,
    parameter int XLEN = `YSYX_XLEN
);
  // Slot A (always present)
  ysyx_pkg::uop_t uop_a;

  logic [XLEN-1:0] op1_a;
  logic [XLEN-1:0] op2_a;
  logic [RLEN-1:0] rs1_a;
  logic [RLEN-1:0] rs2_a;
  logic valid_a;

`ifdef YSYX_DUAL_ISSUE
  // Slot B (dual issue — younger instruction)
  ysyx_pkg::uop_t uop_b;

  logic [XLEN-1:0] op1_b;
  logic [XLEN-1:0] op2_b;
  logic [RLEN-1:0] rs1_b;
  logic [RLEN-1:0] rs2_b;
  logic valid_b;
`endif

  logic ready;

  modport master(
      output uop_a, op1_a, op2_a, rs1_a, rs2_a, valid_a,
`ifdef YSYX_DUAL_ISSUE
      output uop_b, op1_b, op2_b, rs1_b, rs2_b, valid_b,
`endif
      input ready
  );
  modport slave(
      input uop_a, op1_a, op2_a, rs1_a, rs2_a, valid_a,
`ifdef YSYX_DUAL_ISSUE
      input uop_b, op1_b, op2_b, rs1_b, rs2_b, valid_b,
`endif
      output ready
  );
endinterface

`endif
