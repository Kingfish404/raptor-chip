`include "npc_common.v"

module ysyx_23060087_PC #(BIT_W = `ysyx_23060087_W_WIDTH)(
    input clk,
    input rst,
    input en_jal_o,
    input [BIT_W-1:0] imm,
    output reg [BIT_W-1:0] pc_o
);
    reg [BIT_W-1:0] npc;

    always @(*) begin
        if (en_jal_o) begin
            npc = imm;
        end else begin
            npc = pc_o + 4;
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            pc_o <= `ysyx_23060087_PC_INIT;
        end else begin
            pc_o <= npc;
        end
    end
endmodule //ysyx_23060087_PC

module ysyx_23060087_RegisterFile #(ADDR_WIDTH = 1, DATA_WIDTH = 1) (
  input wire clk,
  input wire reg_write,
  input wire [ADDR_WIDTH-1:0] waddr,
  input wire [DATA_WIDTH-1:0] wdata,
  input wire [ADDR_WIDTH-1:0] s1addr,
  input wire [ADDR_WIDTH-1:0] s2addr,
  output reg [DATA_WIDTH-1:0] src1_o,
  output reg [DATA_WIDTH-1:0] src2_o
);
  reg [DATA_WIDTH-1:0] rf [31:0];

  assign src1_o = rf[s1addr];
  assign src2_o = rf[s2addr];
  assign rf[0] = 0;

  always @(posedge clk) begin
    if (reg_write) begin
      rf[waddr] = wdata;
    end
  end
endmodule // ysyx_23060087_RegisterFile


module top #(BIT_W = `ysyx_23060087_W_WIDTH) (
    input rst,
    input clk,
    input [31:0] inst
);
    // PC unit output
    wire [BIT_W-1:0] pc;

    // REGS output
    wire [BIT_W-1:0] reg_rdata1, reg_rdata2;

    // IFU output
    wire [31:0] inst_reg = inst;

    // IDU output
    wire [BIT_W-1:0] op1, op2;
    wire [31:0] imm;
    wire [4:0] rs1, rs2, rd;
    wire [2:0] alu_op;
    wire [6:0] opcode;
    wire en_wb, ebreak;
    wire en_jal;

    // EXU output
    wire [BIT_W-1:0] reg_wdata;

    ysyx_23060087_PC pc_unit(
        .clk(clk), .rst(rst), .en_jal_o(en_jal),  .imm(imm),
        .pc_o(pc)
    );

    ysyx_23060087_RegisterFile #(5, BIT_W) regs(
      .clk(clk), .reg_write(en_wb),
      .waddr(rd), .wdata(reg_wdata),
      .s1addr(rs1), .s2addr(rs2),
      .src1_o(reg_rdata1), .src2_o(reg_rdata2)
      );

    // // IFU(Instruction Fetch Unit): 负责根据当前PC从存储器中取出一条指令
    // ysyx_23060087_IFU #(BIT_W, 32) ifu(
    //   .clk(clk), .pc(pc), 
    //   .inst(inst),
    //   .inst_o(inst_reg)
    // );

    // IDU(Instruction Decode Unit): 负责对当前指令进行译码, 准备执行阶段需要使用的数据和控制信号
    ysyx_23060087_IDU idu(
        .clk(clk), .inst(inst_reg),
        .reg_rdata1(reg_rdata1), .reg_rdata2(reg_rdata2),
        .pc(pc),
        .en_wb_o(en_wb), .en_jal_o(en_jal),
        .op1_o(op1), .op2_o(op2),
        .imm_o(imm),
        .rs1_o(rs1), .rs2_o(rs2), .rd_o(rd),
        .alu_op_o(alu_op), .opcode_o(opcode)
        );

    // EXU(EXecution Unit): 负责根据控制信号对数据进行执行操作, 并将执行结果写回寄存器或存储器
    ysyx_23060087_EXU exu(
        .clk(clk),
        .imm(imm),
        .op1(op1), .op2(op2),
        .alu_op(alu_op),
        .opcode(opcode),
        .reg_wdata_o(reg_wdata)
        );
endmodule // top
