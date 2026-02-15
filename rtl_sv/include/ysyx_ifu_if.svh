`ifndef YSYX_IF_IF_SVH
`define YSYX_IF_IF_SVH
`include "ysyx.svh"

/* verilator lint_off UNUSEDSIGNAL */
/* verilator lint_off UNUSEDPARAM */

interface ifu_bpu_if #(
    parameter int XLEN = `YSYX_XLEN,
    parameter int PHT_SIZE = `YSYX_PHT_SIZE,
    parameter int BTB_SIZE = `YSYX_BTB_SIZE,
    parameter int RSB_SIZE = `YSYX_RSB_SIZE
);
  logic [XLEN-1:0] pc;

  logic [XLEN-1:0] npc;
  logic taken;

  modport out(output pc, input npc, taken);
  modport in(input pc, output npc, taken);
endinterface

interface ifu_l1i_if #(
    parameter int XLEN = `YSYX_XLEN,
    parameter int L1I_LEN = `YSYX_L1I_LEN,
    parameter int L1I_LINE_LEN = `YSYX_L1I_LINE_LEN
);
  logic [XLEN-1:0] pc;
  logic invalid;

  logic [31:0] inst;
  logic trap;
  logic [XLEN-1:0] cause;
  logic valid;

  modport master(output pc, invalid, input inst, trap, cause, valid);
  modport slave(input pc, invalid, output inst, trap, cause, valid);
endinterface

interface ifu_idu_if #(
    parameter int XLEN = `YSYX_XLEN
);
  logic [31:0] inst;
  logic [XLEN-1:0] pc;
  logic [XLEN-1:0] pnpc;

  logic trap;
  logic [XLEN-1:0] cause;
  logic valid;

  logic ready;

  modport master(output inst, pc, pnpc, trap, cause, valid, input ready);
  modport slave(input inst, pc, pnpc, trap, cause, valid, output ready);
endinterface

/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNUSEDPARAM */

`endif  // YSYX_IF_IF_SVH
