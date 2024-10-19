`ifndef YSYX_IF
`define YSYX_IF

interface idu_pipe_if;
  logic [31:0] pc;
  logic [31:0] inst;

  logic [31:0] op1;
  logic [31:0] op2;
  logic [31:0] opj;
  logic [3:0] alu_op;

  logic [3:0] rd;
  logic [31:0] imm;

  logic ren;
  logic wen;
  logic jen;
  logic ben;

  logic system;
  logic func3_z;
  logic csr_wen;
  logic ebreak;
  logic ecall;
  logic mret;

  modport in(
      input pc, inst,
      input op1, op2, opj, alu_op,
      input rd, imm, ren, wen, jen, ben,
      input system, func3_z, csr_wen, ebreak, ecall, mret
  );

  modport out(
      output pc, inst,
      output op1, op2, opj, alu_op,
      output rd, imm, ren, wen, jen, ben,
      output system, func3_z, csr_wen, ebreak, ecall, mret
  );
endinterface

`endif
