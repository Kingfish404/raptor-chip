`include "npc_common.v"

module ysyx_23060087_IDU #(BIT_W = 32) (
    input wire clk,
    input wire [31:0] inst,
    input wire [BIT_W-1:0] reg_rdata1, reg_rdata2,
    input wire [BIT_W-1:0] pc,
    output reg en_wb_o, output reg en_jal_o,
    output reg [`ysyx_23060087_W_WIDTH-1:0] op1_o, op2_o,
    output reg [31:0] imm_o,
    output reg [4:0] rs1_o, rs2_o, rd_o,
    output reg [2:0] alu_op_o,
    output reg [6:0] opcode_o
);
    wire [4:0] rs1 = inst[19:15], rs2 = inst[24:20], rd = inst[11:7];
    wire [2:0] funct3 = inst[14:12];
    wire [11:0] imm_I = inst[31:20], imm_S = {inst[31:25], inst[11:7]};
    wire [12:0] imm_B = {inst[31], inst[7], inst[30:25], inst[11:8], 1'b0};
    wire [31:0] imm_U = {inst[31:12], 12'b0};
    wire [20:0] imm_J = {inst[31], inst[19:12], inst[20], inst[30:25], inst[24:21], 1'b0};
    assign opcode_o = inst[6:0];

    always @(*) begin
        en_wb_o = 0;
        en_jal_o = 0;
        alu_op_o = 0;
        rs1_o = rs1;
        rs2_o = rs2;
        rd_o = 0;
        case (opcode_o)
            `ysyx_23060087_OP_R_TYPE:begin
                en_wb_o = 1;
                imm_o = 0;
                op1_o = reg_rdata1;
                op2_o = reg_rdata2;
                rd_o = rd;
            end
            `ysyx_23060087_OP_I_TYPE:begin
                en_wb_o = 1;
                case (funct3)
                    3'b000: begin
                        imm_o = `ysyx_23060087_SIGN_EXTEND(imm_I, 12, `ysyx_23060087_W_WIDTH);
                    end
                    default: begin
                        imm_o = 0;
                    end
                endcase
                op1_o = reg_rdata1;
                op2_o = imm_o;
                alu_op_o = `ysyx_23060087_ALU_OP_ADD;
                rd_o = rd;
            end
            `ysyx_23060087_OP_S_TYPE:begin
                imm_o = `ysyx_23060087_SIGN_EXTEND(imm_S, 12, `ysyx_23060087_W_WIDTH);
                op1_o = reg_rdata1;
                op2_o = imm_o;
            end
            `ysyx_23060087_OP_B_TYPE:begin
                imm_o = `ysyx_23060087_SIGN_EXTEND(imm_B, 13, `ysyx_23060087_W_WIDTH);
                op1_o = reg_rdata1;
                op2_o = reg_rdata2;
            end
            `ysyx_23060087_OP_LUI:begin
                en_wb_o = 1;
                imm_o = `ysyx_23060087_SIGN_EXTEND(imm_U, 32, `ysyx_23060087_W_WIDTH);
                op1_o = imm_o;
                op2_o = 0;
                rd_o = rd;
            end
            `ysyx_23060087_OP_AUIPC:begin
                en_wb_o = 1;
                imm_o = `ysyx_23060087_SIGN_EXTEND(imm_U, 32, `ysyx_23060087_W_WIDTH);
                op1_o = pc;
                op2_o = imm_o;
                alu_op_o = `ysyx_23060087_ALU_OP_ADD;
                rd_o = rd;
            end
            `ysyx_23060087_OP_JAL:begin
                en_wb_o = 1;
                imm_o = pc + `ysyx_23060087_SIGN_EXTEND(imm_J, 21, `ysyx_23060087_W_WIDTH);
                op1_o = pc;
                op2_o = 4;
                en_jal_o = 1;
                alu_op_o = `ysyx_23060087_ALU_OP_ADD;
                rd_o = rd;
            end
            `ysyx_23060087_OP_JALR:begin
                en_wb_o = 1;
                imm_o = (reg_rdata1 + `ysyx_23060087_SIGN_EXTEND(imm_I, 12, `ysyx_23060087_W_WIDTH));
                op1_o = pc;
                op2_o = 4;
                en_jal_o = 1;
                alu_op_o = `ysyx_23060087_ALU_OP_ADD;
                rd_o = rd;
            end
            default: begin
                imm_o = 0;
                op1_o = 0;
                op2_o = 0;
            end
        endcase
    end
endmodule // ysyx_23060087_IDU
