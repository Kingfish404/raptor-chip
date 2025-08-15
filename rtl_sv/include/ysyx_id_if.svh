`ifndef YSYX_PIPE_IF_SVH
`define YSYX_PIPE_IF_SVH
`include "ysyx.svh"

interface idu_rnu_if #(
    parameter unsigned RLEN = `YSYX_REG_LEN,
    parameter int XLEN = `YSYX_XLEN
);
  logic c;
  logic [4:0] alu;
  logic ben;
  logic jen;
  logic jren;
  logic wen;
  logic ren;
  logic atom;

  logic system;
  logic ecall;
  logic ebreak;
  logic f_i;
  logic f_time;
  logic mret;
  logic [2:0] csr_csw;

  logic trap;
  logic [`YSYX_XLEN-1:0] tval;
  logic [`YSYX_XLEN-1:0] cause;

  logic [RLEN-1:0] rd;
  logic [XLEN-1:0] imm;
  logic [XLEN-1:0] op1;
  logic [XLEN-1:0] op2;
  logic [RLEN-1:0] rs1;
  logic [RLEN-1:0] rs2;

  logic [$clog2(`YSYX_ROB_SIZE):0] qj;
  logic [$clog2(`YSYX_ROB_SIZE):0] qk;
  logic [$clog2(`YSYX_ROB_SIZE):0] dest;

  logic [XLEN-1:0] pnpc;
  logic [31:0] inst;
  logic [XLEN-1:0] pc;

  logic valid;
  logic ready;

  modport master(
      output c,
      output alu, ben, jen, jren, wen, ren, atom,
      output system, ecall, ebreak, mret, csr_csw,
      output trap, tval, cause,
      output f_i, f_time,
      output rd, imm, op1, op2, rs1, rs2,
      output qj, qk, dest,

      output pnpc,
      output inst,
      output pc,
      output valid,
      input ready
  );
  modport slave(
      input c,
      input alu, ben, jen, jren, wen, ren, atom,
      input system, ecall, ebreak, mret, csr_csw,
      input trap, tval, cause,
      input f_i, f_time,
      input rd, imm, op1, op2, rs1, rs2,
      input qj, qk, dest,

      input pnpc,
      input inst,
      input pc,
      input valid,
      output ready
  );
endinterface

`endif
