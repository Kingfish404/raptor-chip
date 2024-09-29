interface idu_pipe_if (
    input logic clk
);
  logic [3:0] rd;
  logic [31:0] imm;

  logic [31:0] op1;
  logic [31:0] op2;
  logic [31:0] opj;
  logic [3:0] alu_op;

  logic ren;
  logic wen;
  logic jen;

  logic system;
  logic system_func3;
  logic csr_wen;
  logic ebreak;
endinterface
