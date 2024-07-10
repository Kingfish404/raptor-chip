`include "ysyx_macro.v"

`define ysyx_R_TYPE(op1, alu_op, op2)  begin \
  rwen_o = 1; \
  op1_o = op1; \
  op2_o = op2; \
  alu_op_o = alu_op; \
end

`define ysyx_I_TYPE(op1, alu_op, op2)  begin \
  rwen_o = 1; \
  imm_o = `ysyx_SIGN_EXTEND(imm_I, 12, `ysyx_W_WIDTH); \
  op1_o = op1; \
  op2_o = op2; \
  alu_op_o = alu_op; \
end

`define ysyx_S_TYPE(op1, alu_op, op2) begin \
  imm_o = `ysyx_SIGN_EXTEND(imm_S, 12, `ysyx_W_WIDTH); \
  op1_o = op1; \
  op2_o = op2; \
  alu_op_o = alu_op; \
end

`define ysyx_B_TYPE(op1, alu_op, op2) begin \
  imm_o = `ysyx_SIGN_EXTEND(imm_B, 13, `ysyx_W_WIDTH); \
  op1_o = (alu_op == `ysyx_ALU_OP_BGE || alu_op == `ysyx_ALU_OP_BGEU) ? op2 : op1; \
  op2_o = (alu_op == `ysyx_ALU_OP_BGE || alu_op == `ysyx_ALU_OP_BGEU) ? op1 : op2; \
  alu_op_o = ( \
    ({4{(alu_op == `ysyx_ALU_OP_BEQ)}} & `ysyx_ALU_OP_SUB) | \
    ({4{(alu_op == `ysyx_ALU_OP_BNE)}} & `ysyx_ALU_OP_XOR) | \
    ({4{(alu_op == `ysyx_ALU_OP_BLT)}} & `ysyx_ALU_OP_SLT) | \
    ({4{(alu_op == `ysyx_ALU_OP_BLTU)}} & `ysyx_ALU_OP_SLTU) | \
    ({4{(alu_op == `ysyx_ALU_OP_BGE)}} & `ysyx_ALU_OP_SLE) | \
    ({4{(alu_op == `ysyx_ALU_OP_BGEU)}} & `ysyx_ALU_OP_SLEU) | \
    `ysyx_ALU_OP_ADD \
  ); \
end

`define ysyx_U_TYPE(op1, alu_op)  begin \
  rwen_o = 1;    \
  imm_o = `ysyx_SIGN_EXTEND(imm_U, 32, `ysyx_W_WIDTH); \
  op1_o = op1;    \
  op2_o = imm_o;  \
  alu_op_o = alu_op; \
end

`define ysyx_J_TYPE(op1, alu_op, op2)  begin \
  rwen_o = 1; \
  imm_o = `ysyx_SIGN_EXTEND(imm_J, 21, `ysyx_W_WIDTH); \
  op1_o = op1; \
  op2_o = op2; \
  alu_op_o = alu_op; \
end

`define ysyx_I_SYS_TYPE(op1, alu_op, op2)  begin \
  rwen_o = 1; \
  imm_o = `ysyx_SIGN_EXTEND(imm_SYS, 16, `ysyx_W_WIDTH); \
  op1_o = op1; \
  op2_o = op2; \
  alu_op_o = alu_op; \
end
