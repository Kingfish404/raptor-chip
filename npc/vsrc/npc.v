// `define ysyx_23060087_USE_MODULE
`define ysyx_23060087_PC_INIT 64'h80000000
`define ysyx_23060087_ADDR_WIDTH 64

module top #(BIT_W = 64) (
    input rst,
    input clk,
    input [31:0] inst,
    output reg [BIT_W-1:0] pc,
    output reg [BIT_W-1:0] rfout [31:0]
);
    reg [BIT_W-1:0] npc = 0;
    reg [31:0] inst_c = 0;

    assign npc = pc + 4;
    // IFU(Instruction Fetch Unit): 负责根据当前PC从存储器中取出一条指令
    ysyx_23060087_IFU #(BIT_W, 32) ifu(.clk(clk), .pc(pc), .inst_in(inst), .inst(inst_c));

    reg [11:0] imm_I;
    reg [4:0] rs1;
    reg [2:0] funct3;
    reg [4:0] rd;
    reg [6:0] opcode;

    // IDU(Instruction Decode Unit): 负责对当前指令进行译码, 准备执行阶段需要使用的数据和控制信号
    ysyx_23060087_IDU idu(
        .clk(clk), .inst(inst_c),
        .imm_I(imm_I), .rs1(rs1), .funct3(funct3), .rd(rd), .opcode(opcode));

    // EXU(EXecution Unit): 负责根据控制信号对数据进行执行操作, 并将执行结果写回寄存器或存储器
    ysyx_23060087_EXU exu(
        .clk(clk), .imm_I(imm_I), .rs1(rs1), .funct3(funct3), .rd(rd), .opcode(opcode), .rfout(rfout));

    `ifdef ysyx_23060087_USE_MODULE
    Reg #(BIT_W, `ysyx_23060087_PC_INIT) r_pc(clk, rst, npc, pc, 1'b1);
    `else
    always @(posedge clk) begin
        if (rst) begin
            pc <= `ysyx_23060087_PC_INIT;
        end else begin
            $display(
                "v> inst: 0x%08x, pc: 0x%08x, npc: 0x%08x imm_I: 0x%03x, rs1: 0x%2x, funct3: 0x%02x, rd: 0x%02x, opcode: 0x%02x",
                 inst_c, pc, npc, imm_I, rs1, funct3, rd, opcode);
            pc <= npc;
        end
    end
    `endif
endmodule //top
