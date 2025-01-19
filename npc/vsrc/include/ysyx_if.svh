`ifndef YSYX_IF
`define YSYX_IF
`include "ysyx.svh"

interface idu_pipe_if;
  logic [31:0] pc;
  logic [31:0] inst;

  logic [31:0] imm;
  logic [31:0] op1;
  logic [31:0] op2;
  logic [4:0] alu_op;

  logic [`YSYX_REG_LEN-1:0] rd;

  logic ren;
  logic wen;
  logic jen;
  logic ben;

  logic system;
  logic [2:0] csr_csw;
  logic ebreak;
  logic ecall;
  logic mret;

  modport in(
      input pc, inst,
      input imm, alu_op, op1, op2,
      input rd, ren, wen, jen, ben,
      input system, csr_csw, ebreak, ecall, mret
  );

  modport out(
      output pc, inst,
      output imm, alu_op, op1, op2,
      output rd, ren, wen, jen, ben,
      output system, csr_csw, ebreak, ecall, mret
  );
endinterface

typedef struct packed {
  logic [31:0] pc;
  logic [31:0] inst;

  logic [31:0] imm;
  logic [4:0]  alu_op;
  logic [31:0] op1;
  logic [31:0] op2;

  logic [`YSYX_REG_LEN-1:0] rd;

  logic ren;
  logic wen;
  logic jen;
  logic ben;

  logic system;
  logic [2:0] csr_csw;
  logic ebreak;
  logic ecall;
  logic mret;
} micro_op_t;

`endif
