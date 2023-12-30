`include "npc_macro.v"

module ysyx_PC (
  input clk,
  input rst,
  input en_j_o,
  input [BIT_W-1:0] npc_wdata,
  output reg [BIT_W-1:0] pc_o, npc_o
);
  parameter BIT_W = `ysyx_W_WIDTH;
  reg [BIT_W-1:0] npc;
  assign npc = (en_j_o) ? npc_wdata : pc_o + 4;

  always @(posedge clk) begin
    if (rst) begin
      pc_o <= `ysyx_PC_INIT;
      npc_o <= `ysyx_PC_INIT + 4;
    end else begin
      pc_o <= npc;
      npc_o <= npc + 4;
    end
  end
endmodule //ysyx_PC

module ysyx_RegisterFile (
  input clk,
  input rst,
  input reg_write,
  input [ADDR_WIDTH-1:0] waddr,
  input [DATA_WIDTH-1:0] wdata,
  input [ADDR_WIDTH-1:0] s1addr,
  input [ADDR_WIDTH-1:0] s2addr,
  output reg [DATA_WIDTH-1:0] src1_o,
  output reg [DATA_WIDTH-1:0] src2_o
);
  parameter ADDR_WIDTH = 1;
  parameter DATA_WIDTH = 1;
  reg [DATA_WIDTH-1:0] rf [31:0];

  assign src1_o = rf[s1addr];
  assign src2_o = rf[s2addr];

  always @(posedge clk) begin
    if (rst) begin
      rf[0] <= 0;  rf[1] <= 0;  rf[2] <= 0;  rf[3] <= 0;
      rf[4] <= 0;  rf[5] <= 0;  rf[6] <= 0;  rf[7] <= 0;
      rf[8] <= 0;  rf[9] <= 0;  rf[10] <= 0; rf[11] <= 0;
      rf[12] <= 0; rf[13] <= 0; rf[14] <= 0; rf[15] <= 0;
      rf[16] <= 0; rf[17] <= 0; rf[18] <= 0; rf[19] <= 0;
      rf[20] <= 0; rf[21] <= 0; rf[22] <= 0; rf[23] <= 0;
      rf[24] <= 0; rf[25] <= 0; rf[26] <= 0; rf[27] <= 0;
      rf[28] <= 0; rf[29] <= 0; rf[30] <= 0; rf[31] <= 0;
    end
    if (reg_write) begin
      rf[waddr] = wdata;
    end
    rf[0] = 0;
  end
endmodule // ysyx_RegisterFile

module top (
  input rst,
  input clk,
  input [31:0] inst
);
  parameter BIT_W = `ysyx_W_WIDTH;
  // PC unit output
  wire [BIT_W-1:0] pc, npc;

  // REGS output
  wire [BIT_W-1:0] reg_rdata1, reg_rdata2;

  // IFU output
  wire [31:0] inst_reg; 

  // IDU output
  wire [BIT_W-1:0] op1, op2, imm, op_j;
  wire [4:0] rs1, rs2, rd;
  wire [3:0] alu_op;
  wire [6:0] opcode, funct7;
  wire en_wb, ebreak;
  wire en_j;

  // EXU output
  wire [BIT_W-1:0] reg_wdata;
  wire [BIT_W-1:0] npc_wdata;

  ysyx_PC pc_unit(
    .clk(clk), .rst(rst), .en_j_o(en_j), .npc_wdata(npc_wdata),
    .pc_o(pc), .npc_o(npc)
  );

  ysyx_RegisterFile #(5, BIT_W) regs(
    .clk(clk), .rst(rst), .reg_write(en_wb),
    .waddr(rd), .wdata(reg_wdata),
    .s1addr(rs1), .s2addr(rs2),
    .src1_o(reg_rdata1), .src2_o(reg_rdata2)
    );

  // IFU(Instruction Fetch Unit): 负责根据当前PC从存储器中取出一条指令
  ysyx_IFU #(BIT_W, 32) ifu(
    .clk(clk), .pc(pc), 
    .inst(inst),
    .inst_o(inst_reg)
  );

  // IDU(Instruction Decode Unit): 负责对当前指令进行译码, 准备执行阶段需要使用的数据和控制信号
  ysyx_IDU idu(
    .clk(clk), .inst(inst_reg),
    .reg_rdata1(reg_rdata1), .reg_rdata2(reg_rdata2),
    .pc(pc),
    .en_wb_o(en_wb), .en_j_o(en_j),
    .op1_o(op1), .op2_o(op2), .op_j_o(op_j),
    .imm_o(imm),
    .rs1_o(rs1), .rs2_o(rs2), .rd_o(rd),
    .alu_op_o(alu_op), .funct7_o(funct7),
    .opcode_o(opcode)
    );

  // EXU(EXecution Unit): 负责根据控制信号对数据进行执行操作, 并将执行结果写回寄存器或存储器
  ysyx_EXU exu(
    .clk(clk), .rst(rst),
    .imm(imm),
    .op1(op1), .op2(op2), .op_j(op_j),
    .alu_op(alu_op), .funct7(funct7), .opcode(opcode),
    .npc(npc),
    .reg_wdata_o(reg_wdata),
    .npc_wdata_o(npc_wdata)
    );
endmodule // top
