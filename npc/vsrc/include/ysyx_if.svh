interface idu_pipe_if (
    input logic clk
);
  logic [31:0] pc;
  logic [31:0] inst;
  logic speculation;

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

  modport out(
      input clk,
      output pc,
      output inst,
      output speculation,
      output op1,
      output op2,
      output opj,
      output alu_op,
      output rd,
      output imm,
      output ren,
      output wen,
      output jen,
      output ben,
      output system,
      output func3_z,
      output csr_wen,
      output ebreak,
      output ecall,
      output mret
  );
  modport in(
      input clk,
      input pc,
      input inst,
      input speculation,
      input op1,
      input op2,
      input opj,
      input alu_op,
      input rd,
      input imm,
      input ren,
      input wen,
      input jen,
      input ben,
      input system,
      input func3_z,
      input csr_wen,
      input ebreak,
      input ecall,
      input mret
  );
endinterface
