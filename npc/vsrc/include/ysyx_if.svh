`ifndef YSYX_IF
`define YSYX_IF
`include "ysyx.svh"

interface idu_pipe_if;
  logic [4:0] alu_op;
  logic jen;
  logic ben;
  logic wen;
  logic ren;

  logic system;
  logic ebreak;
  logic fence_i;
  logic ecall;
  logic mret;
  logic [2:0] csr_csw;

  logic [`YSYX_REG_LEN-1:0] rd;
  logic [31:0] imm;
  logic [31:0] op1;
  logic [31:0] op2;
  logic [`YSYX_REG_LEN-1:0] rs1;
  logic [`YSYX_REG_LEN-1:0] rs2;

  logic [31:0] inst;
  logic [31:0] pc;
  modport in(
      input alu_op, jen, ben, wen, ren,
      input system, ebreak, fence_i, ecall, mret, csr_csw,
      input rd, imm, op1, op2, rs1, rs2,
      input inst,
      input pc
  );

  modport out(
      output alu_op, jen, ben, wen, ren,
      output system, ebreak, fence_i, ecall, mret, csr_csw,
      output rd, imm, op1, op2, rs1, rs2,
      output inst,
      output pc
  );
endinterface

typedef struct packed {
  logic [4:0] alu_op;
  logic jen;
  logic ben;
  logic wen;
  logic ren;

  logic system;
  logic ebreak;
  logic fence_i;
  logic ecall;
  logic mret;
  logic [2:0] csr_csw;

  logic [`YSYX_REG_LEN-1:0] rd;
  logic [31:0] imm;
  logic [31:0] op1;
  logic [31:0] op2;
  logic [`YSYX_REG_LEN-1:0] rs1;
  logic [`YSYX_REG_LEN-1:0] rs2;

  logic [31:0] inst;
  logic [31:0] pc;
} micro_op_t;

`endif
