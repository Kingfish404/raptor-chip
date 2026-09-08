/* verilator lint_off DECLFILENAME */
`ifndef RAPT_IDU_IF_SVH
`define RAPT_IDU_IF_SVH
`include "rapt.svh"
interface idu_rnu_if #(
    parameter int Width = rapt_pkg::DecodeWidth,
    parameter type UopT = rapt_pkg::uop_t,
    parameter int XLEN = `RAPT_XLEN,
    parameter int RLEN = `RAPT_REG_LEN
);
  typedef struct packed {
    UopT uop;
    logic [XLEN-1:0] op1;
    logic [XLEN-1:0] op2;
    logic [RLEN-1:0] rs1;
    logic [RLEN-1:0] rs2;
  } slot_t;
  slot_t slot[Width];
  logic valid[Width];
  logic ready[Width];
  modport master(output slot, valid, input ready);
  modport slave(input slot, valid, output ready);
endinterface
`endif
