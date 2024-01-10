`include "npc_macro.v"

module top (
  input clock, reset
);
  parameter BIT_W = `ysyx_W_WIDTH;
  // PC unit output
  wire [BIT_W-1:0] pc, npc;

  // REGS output
  wire [BIT_W-1:0] reg_rdata1, reg_rdata2;

  // IFU output
  wire [31:0] inst;
  wire ifu_valid, ifu_ready;
  // IFU bus wire
  wire [BIT_W-1:0] ifu_araddr_o;
  wire ifu_arvalid_o, ifu_rready_o;
  wire [1:0] ifu_rresp;
  wire ifu_arready, ifu_rvalid;
  wire [BIT_W-1:0] ifu_rdata;

  // IDU output
  wire [BIT_W-1:0] op1, op2, imm, op_j;
  wire [4:0] rs1, rs2, rd;
  wire [3:0] alu_op;
  wire [6:0] opcode, funct7;
  wire rwen, en_j, ren, wen;
  wire ebreak;
  wire idu_valid, idu_ready;

  // EXU output
  wire [BIT_W-1:0] reg_wdata;
  wire [BIT_W-1:0] npc_wdata;
  wire exu_valid, exu_ready;
  wire wben;

  ysyx_PC pc_unit(
    .clk(clock), .rst(reset), 
    .exu_valid(exu_valid),

    .en_j_o(en_j), 
    .npc_wdata(npc_wdata), .pc_o(pc), .npc_o(npc)
  );

  ysyx_RegisterFile #(5, BIT_W) regs(
    .clk(clock), .rst(reset),
    .exu_valid(exu_valid),
    
    .reg_write_en(rwen),
    .waddr(rd), .wdata(reg_wdata),
    .s1addr(rs1), .s2addr(rs2),
    .src1_o(reg_rdata1), .src2_o(reg_rdata2)
    );

  ysyx_BUS_ARBITER bus(
    .clk(clock), .rst(reset),

    .ifu_araddr(ifu_araddr_o),
    .ifu_arvalid(ifu_arvalid_o), .ifu_rready(ifu_rready_o),
    .ifu_rresp_o(ifu_rresp),
    .ifu_arready_o(ifu_arready), .ifu_rvalid_o(ifu_rvalid),
    .ifu_rdata_o(ifu_rdata)
  );

  // IFU(Instruction Fetch Unit): 负责根据当前PC从存储器中取出一条指令
  ysyx_IFU #(.ADDR_W(BIT_W), .DATA_W(32)) ifu(
    .clk(clock), .rst(reset),

    .prev_valid(exu_valid), .next_ready(idu_ready),
    .valid_o(ifu_valid), .ready_o(ifu_ready),

    .ifu_araddr_o(ifu_araddr_o),
    .ifu_arvalid_o(ifu_arvalid_o), .ifu_rready_o(ifu_rready_o),
    .ifu_rresp(ifu_rresp),
    .ifu_arready(ifu_arready), .ifu_rvalid(ifu_rvalid),
    .ifu_rdata(ifu_rdata),

    .pc(pc), .npc(npc),
    .inst_o(inst)
  );

  // IDU(Instruction Decode Unit): 负责对当前指令进行译码, 准备执行阶段需要使用的数据和控制信号
  ysyx_IDU idu(
    .clk(clock), .rst(reset),

    .prev_valid(ifu_valid), .next_ready(exu_ready),
    .valid_o(idu_valid), .ready_o(idu_ready),

    .inst(inst),
    .reg_rdata1(reg_rdata1), .reg_rdata2(reg_rdata2),
    .pc(pc),
    .rwen_o(rwen), .en_j_o(en_j), .ren_o(ren), .wen_o(wen),
    .op1_o(op1), .op2_o(op2), .op_j_o(op_j),
    .imm_o(imm),
    .rs1_o(rs1), .rs2_o(rs2), .rd_o(rd),
    .alu_op_o(alu_op), .funct7_o(funct7),
    .opcode_o(opcode)
    );

  // EXU(EXecution Unit): 负责根据控制信号对数据进行执行操作, 并将执行结果写回寄存器或存储器
  ysyx_EXU exu(
    .clk(clock), .rst(reset),

    .prev_valid(idu_valid), .next_ready(ifu_ready),
    .valid_o(exu_valid), .ready_o(exu_ready),
  
    .ren(ren), .wen(wen),
    .imm(imm),
    .op1(op1), .op2(op2), .op_j(op_j),
    .alu_op(alu_op), .funct7(funct7), .opcode(opcode),
    .pc(pc),
    .reg_wdata_o(reg_wdata),
    .npc_wdata_o(npc_wdata),
    .wben_o(wben)
    );

  

endmodule // top

module ysyx_PC (
  input clk, rst,
  input exu_valid,
  input en_j_o,
  input [BIT_W-1:0] npc_wdata,
  output reg [BIT_W-1:0] pc_o, npc_o
);
  parameter BIT_W = `ysyx_W_WIDTH;
  // assign npc_o = npc_wdata;

  always @(posedge clk) begin
    if (rst) begin
      pc_o <= `ysyx_PC_INIT;
      npc_o <= `ysyx_PC_INIT;
    end
    else begin
      npc_o <= npc_wdata;
      if (exu_valid) begin
        pc_o <= npc_o;
      end
    end
  end
endmodule //ysyx_PC

module ysyx_RegisterFile (
  input clk, rst,
  input exu_valid,
  input reg_write_en,
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
    else begin
      if (reg_write_en && exu_valid) begin
        rf[waddr] <= wdata;
      end
      rf[0] <= 0;
    end
  end
endmodule // ysyx_RegisterFile
