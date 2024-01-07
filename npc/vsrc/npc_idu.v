`include "npc_macro.v"
`include "npc_macro_idu.v"

module ysyx_IDU (
  input wire clk, rst,

  input wire prev_valid, next_ready,
  output reg valid_o, ready_o,

  input wire [31:0] inst_in,
  input wire [BIT_W-1:0] reg_rdata1, reg_rdata2,
  input wire [BIT_W-1:0] pc,
  output reg en_wb_o, en_j_o, ren_o, wen_o,
  output reg [BIT_W-1:0] op1_o, op2_o, op_j_o,
  output reg [31:0] imm_o,
  output reg [4:0] rs1_o, rs2_o, rd_o,
  output reg [3:0] alu_op_o,
  output reg [6:0] funct7_o,
  output reg [6:0] opcode_o
);
  parameter BIT_W = `ysyx_W_WIDTH;

  wire [4:0] rs1 = inst[19:15], rs2 = inst[24:20], rd = inst[11:7];
  wire [2:0] funct3 = inst[14:12];
  wire [6:0] funct7 = inst[31:25];
  wire [11:0] imm_I = inst[31:20], imm_S = {inst[31:25], inst[11:7]};
  wire [12:0] imm_B = {inst[31], inst[7], inst[30:25], inst[11:8], 1'b0};
  wire [31:0] imm_U = {inst[31:12], 12'b0};
  wire [20:0] imm_J = {inst[31], inst[19:12], inst[20], inst[30:25], inst[24:21], 1'b0};
  assign opcode_o = inst[6:0];

  reg [31:0] inst;
  reg state;
  `ysyx_BUS_FSM();
  always @(posedge clk) begin
    if (rst) begin
      valid_o <= 0; ready_o <= 1;
    end
    else begin 
      `ysyx_BUS();
      if (state == `ysyx_IDLE) begin
        if (prev_valid == 1) begin inst <= inst_in; valid_o <= 1; ready_o <= 0; end
      end
    end
  end

  always @(*) begin
    en_wb_o = 0; en_j_o = 0; ren_o = 0; wen_o = 0;
    alu_op_o = 0;
    rs1_o = rs1; rs2_o = rs2; rd_o = 0;
    imm_o = 0;
    op1_o = 0; op2_o = 0; op_j_o = 0;
    funct7_o = funct7;
    case (opcode_o)
      `ysyx_OP_LUI:     begin `ysyx_U_TYPE(0,  `ysyx_ALU_OP_ADD);                                       end
      `ysyx_OP_AUIPC:   begin `ysyx_U_TYPE(pc, `ysyx_ALU_OP_ADD);                                       end
      `ysyx_OP_JAL:     begin `ysyx_J_TYPE(pc, `ysyx_ALU_OP_ADD, 4); op_j_o = pc;                       end
      `ysyx_OP_JALR:    begin `ysyx_I_TYPE(pc, `ysyx_ALU_OP_ADD, 4); en_j_o = 1; op_j_o = reg_rdata1;   end
      `ysyx_OP_B_TYPE:  begin `ysyx_B_TYPE(reg_rdata1, {1'b0, funct3}, reg_rdata2); en_j_o = 1; op_j_o = pc;    end
      `ysyx_OP_I_TYPE:  begin `ysyx_I_TYPE(reg_rdata1, {(funct3 == 3'b101) ? funct7[5]: 1'b0, funct3}, imm_o);  end
      `ysyx_OP_IL_TYPE: begin `ysyx_I_TYPE(reg_rdata1, {1'b0, funct3}, imm_o); op_j_o = reg_rdata1; ren_o = 1;      end
      `ysyx_OP_S_TYPE:  begin `ysyx_S_TYPE(reg_rdata1, {1'b0, funct3}, reg_rdata2); op_j_o = reg_rdata1; wen_o = 1; end
      `ysyx_OP_R_TYPE:  begin `ysyx_R_TYPE(reg_rdata1, {funct7[5], funct3}, reg_rdata2);                end
      `ysyx_OP_SYSTEM:  begin `ysyx_I_SYS_TYPE(reg_rdata1, {1'b0, funct3}, 0)                           end
      default: begin
        if (valid_o == 1) begin
          npc_illegal_inst();
        end
      end
    endcase
  end
endmodule // ysyx_IDU
