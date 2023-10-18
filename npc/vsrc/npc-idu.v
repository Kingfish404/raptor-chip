module ysyx_23060087_IDU (
    input clk,
    input [31:0] inst,
    output [11:0] imm_I,
    output [4:0] rs1,
    output [2:0] funct3,
    output [4:0] rd,
    output [6:0] opcode
);
    assign imm_I = inst[31:20];
    assign rs1 = inst[19:15];
    assign funct3 = inst[14:12];
    assign rd = inst[11:7];
    assign opcode = inst[6:0];
endmodule //ysyx_23060087_IDU
