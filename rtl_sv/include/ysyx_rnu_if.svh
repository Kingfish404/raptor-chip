`ifndef YSYX_RN_IF_SVH
`define YSYX_RN_IF_SVH
`include "ysyx.svh"
import ysyx_pkg::*;

interface rnu_rou_if #(
    parameter unsigned PLEN = `YSYX_PHY_LEN,
    parameter unsigned RLEN = `YSYX_REG_LEN,
    parameter unsigned XLEN = `YSYX_XLEN
);
  ysyx_pkg::uop_t uop;

  logic [PLEN-1:0] pr1;
  logic [PLEN-1:0] pr2;
  logic [PLEN-1:0] prd;
  logic [PLEN-1:0] prs;

  logic [XLEN-1:0] op1;
  logic [XLEN-1:0] op2;

  logic valid;
  logic ready;

  modport master(output uop, output op1, op2, output pr1, pr2, prd, prs, output valid, input ready);
  modport slave(input uop, input op1, op2, input pr1, pr2, prd, prs, input valid, output ready);
endinterface


`endif
