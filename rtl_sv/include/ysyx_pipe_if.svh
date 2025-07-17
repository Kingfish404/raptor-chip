`ifndef YSYX_PIPE_IF_SVH
`define YSYX_PIPE_IF_SVH
`include "ysyx.svh"

interface idu_pipe_if #(
    parameter int XLEN = `YSYX_XLEN
);
  logic c;
  logic [4:0] alu;
  logic jen;
  logic ben;
  logic wen;
  logic ren;
  logic atom;

  logic system;
  logic ecall;
  logic ebreak;
  logic fence_i;
  logic fence_time;
  logic mret;
  logic [2:0] csr_csw;

  logic trap;
  logic [`YSYX_XLEN-1:0] tval;
  logic [`YSYX_XLEN-1:0] cause;

  logic [4:0] rd;
  logic [XLEN-1:0] imm;
  logic [XLEN-1:0] op1;
  logic [XLEN-1:0] op2;
  logic [4:0] rs1;
  logic [4:0] rs2;

  logic [$clog2(`YSYX_ROB_SIZE):0] qj;
  logic [$clog2(`YSYX_ROB_SIZE):0] qk;
  logic [$clog2(`YSYX_ROB_SIZE):0] dest;

  logic [XLEN-1:0] pnpc;

  logic [31:0] inst;
  logic [XLEN-1:0] pc;

  modport in(
      input c,
      input alu, jen, ben, wen, ren, atom,
      input system, ecall, ebreak, mret, csr_csw,
      input trap, tval, cause,
      input fence_i, fence_time,
      input rd, imm, op1, op2, rs1, rs2,
      input qj, qk, dest,
      input pnpc,
      input inst,
      input pc
  );
  modport out(
      output c,
      output alu, jen, ben, wen, ren, atom,
      output system, ecall, ebreak, mret, csr_csw,
      output trap, tval, cause,
      output fence_i, fence_time,
      output rd, imm, op1, op2, rs1, rs2,
      output qj, qk, dest,
      output pnpc,
      output inst,
      output pc
  );
endinterface

interface wbu_pipe_if #(
    parameter int XLEN = `YSYX_XLEN
);
  logic [XLEN-1:0] pc;
  logic [XLEN-1:0] npc;

  logic sys_retire;
  logic jen;
  logic ben;

  logic fence_time;
  logic fence_i;

  logic flush_pipe;

  modport in(input pc, npc, sys_retire, jen, ben, fence_time, fence_i, flush_pipe);
  modport out(output pc, npc, sys_retire, jen, ben, fence_time, fence_i, flush_pipe);
endinterface

`endif
