`ifndef YSYX_PIPE_IF_SVH
`define YSYX_PIPE_IF_SVH
`include "ysyx.svh"
import ysyx_pkg::*;

interface idu_rnu_if #(
    parameter unsigned RLEN = `YSYX_REG_LEN,
    parameter int XLEN = `YSYX_XLEN
);
  ysyx_pkg::uop_t uop;

  logic [XLEN-1:0] op1;
  logic [XLEN-1:0] op2;
  logic [RLEN-1:0] rs1;
  logic [RLEN-1:0] rs2;

  logic valid;
  logic ready;

  modport master(output uop, op1, op2, rs1, rs2, output valid, input ready);
  modport slave(input uop, op1, op2, rs1, rs2, input valid, output ready);
endinterface

`endif
