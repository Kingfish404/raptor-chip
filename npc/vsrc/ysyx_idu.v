`include "ysyx_macro.v"
`include "ysyx_macro_idu.v"
`include "ysyx_macro_dpi_c.v"

module ysyx_IDU (
  input clk, rst,

  input [31:0] inst,
  input [BIT_W-1:0] reg_rdata1, reg_rdata2,
  input [BIT_W-1:0] pc,
  output en_j_o,
  output reg rwen_o, ren_o, wen_o,
  output reg [BIT_W-1:0] op1_o, op2_o,
  output wire [BIT_W-1:0] rwaddr_o, op_j_o,
  output reg [31:0] imm_o,
  output reg [4:0] rs1_o, rs2_o, rd_o,
  output reg [3:0] alu_op_o,
  output [6:0] opcode_o,
  output reg [BIT_W-1:0] pc_o,

  input [16-1:0] rf_table,

  input prev_valid, next_ready,
  output reg valid_o, ready_o
);
  parameter integer BIT_W = 32;

  reg [31:0] inst_idu;
  reg valid, ready;
  wire [4:0] rs1 = inst_idu[19:15], rs2 = inst_idu[24:20], rd = inst_idu[11:7];
  wire [2:0] funct3 = inst_idu[14:12];
  wire [6:0] funct7 = inst_idu[31:25];
  wire [11:0] imm_I = inst_idu[31:20], imm_S = {inst_idu[31:25], inst_idu[11:7]};
  wire [12:0] imm_B = {inst_idu[31], inst_idu[7], inst_idu[30:25], inst_idu[11:8], 1'b0};
  wire [31:0] imm_U = {inst_idu[31:12], 12'b0};
  wire [20:0] imm_J = {inst_idu[31], inst_idu[19:12], inst_idu[20], inst_idu[30:25], inst_idu[24:21], 1'b0};
  wire [15:0] imm_SYS = {{imm_I}, {1'b0, funct3}};
  wire conflict = (rf_table[rs1[4-1:0]] == 1) | (rf_table[rs2[4-1:0]] == 1);
  assign opcode_o = inst_idu[6:0];
  assign valid_o = valid & !conflict;
  assign ready_o = ready & !conflict;

  reg state;
  `ysyx_BUS_FSM()
  always @(posedge clk) begin
    if (rst) begin
      valid <= 0; ready <= 1;
    end
    else begin
      if (state == `ysyx_IDLE) begin
        if (prev_valid) begin inst_idu <= inst; pc_o <= pc; end
        if (prev_valid == 1) begin
          valid <= 1;
          if (conflict) begin
            ready <= 0;
          end
        end
      end
      else if (state == `ysyx_WAIT_READY) begin
        if (next_ready == 1) begin
          ready <= 1;
          if (prev_valid == 0) begin valid <= 0; end
        end
      end
    end
  end

  assign en_j_o = (
    (opcode_o == `ysyx_OP_JAL) | (opcode_o == `ysyx_OP_JALR) |
    (opcode_o == `ysyx_OP_B_TYPE) | (opcode_o == `ysyx_OP_SYSTEM) |
    (0)
  );
  assign rwaddr_o = (
    {BIT_W{opcode_o == `ysyx_OP_IL_TYPE | opcode_o == `ysyx_OP_S_TYPE}} & reg_rdata1 + imm_o |
    (0)
  );
  assign op_j_o = (
    {BIT_W{opcode_o == `ysyx_OP_JAL | opcode_o == `ysyx_OP_B_TYPE}} & pc |
    {BIT_W{opcode_o == `ysyx_OP_JALR | opcode_o == `ysyx_OP_IL_TYPE | opcode_o == `ysyx_OP_S_TYPE}}
      & reg_rdata1 |
    (0)
  );
  assign wen_o = (opcode_o == `ysyx_OP_S_TYPE) & valid_o;
  assign ren_o = (opcode_o == `ysyx_OP_IL_TYPE) & valid_o;
  always @(*) begin
    rwen_o = 0;
    alu_op_o = 0;
    rs1_o = rs1; rs2_o = rs2; rd_o = 0;
    imm_o = 0; op1_o = 0; op2_o = 0;
      case (opcode_o)
        `ysyx_OP_LUI:     begin `ysyx_U_TYPE(0,  `ysyx_ALU_OP_ADD);                              end
        `ysyx_OP_AUIPC:   begin `ysyx_U_TYPE(pc_o, `ysyx_ALU_OP_ADD);                              end
        `ysyx_OP_JAL:     begin `ysyx_J_TYPE(pc_o, `ysyx_ALU_OP_ADD, 4);              end
        `ysyx_OP_JALR:    begin `ysyx_I_TYPE(pc_o, `ysyx_ALU_OP_ADD, 4);           end
        `ysyx_OP_B_TYPE:  begin `ysyx_B_TYPE(reg_rdata1, {1'b0, funct3}, reg_rdata2);   end
        `ysyx_OP_I_TYPE:  begin `ysyx_I_TYPE(reg_rdata1, {(funct3 == 3'b101) ? funct7[5]: 1'b0, funct3}, imm_o);  end
        `ysyx_OP_IL_TYPE: begin `ysyx_I_TYPE(reg_rdata1, {1'b0, funct3}, imm_o);                 end
        `ysyx_OP_S_TYPE:  begin `ysyx_S_TYPE(reg_rdata1, {1'b0, funct3}, reg_rdata2);            end
        `ysyx_OP_R_TYPE:  begin `ysyx_R_TYPE(reg_rdata1, {funct7[5], funct3}, reg_rdata2);       end
        `ysyx_OP_SYSTEM:  begin `ysyx_I_SYS_TYPE(reg_rdata1, {1'b0, funct3}, 0)                  end
        `ysyx_OP_FENCE_I: begin                                                                  end
        default:          begin if (valid_o) begin `ysyx_DPI_C_npc_illegal_inst end              end
      endcase
  end
endmodule // ysyx_IDU
