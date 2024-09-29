interface idu_pipe_if (
    input logic clk
);
  logic [3:0] rd;
  logic [31:0] imm;

  logic [31:0] op1;
  logic [31:0] op2;

  logic ren;
  logic wen;

  logic system;
  logic [2:0] system_func3;
  logic csr_wen;
  logic ebreak;
endinterface
