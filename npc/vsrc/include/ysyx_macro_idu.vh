`include "ysyx_macro.vh"

`define YSYX_R_TYPE(op1, alu_op, op2)  begin \
  op1_o = op1; \
  op2_o = op2; \
  alu_op_o = alu_op; \
  // rd_o = rd; \
end

`define YSYX_I_TYPE(op1, alu_op, op2)  begin \
  imm_o = `YSYX_SIGN_EXTEND(imm_I, 12, `YSYX_W_WIDTH); \
  op1_o = op1; \
  op2_o = op2; \
  alu_op_o = alu_op; \
  // rd_o = rd; \
end

`define YSYX_S_TYPE(op1, alu_op, op2) begin \
  imm_o = `YSYX_SIGN_EXTEND(imm_S, 12, `YSYX_W_WIDTH); \
  op1_o = op1; \
  op2_o = op2; \
  alu_op_o = alu_op; \
end

`define YSYX_B_TYPE(op1, alu_op, op2) begin \
  imm_o = `YSYX_SIGN_EXTEND(imm_B, 13, `YSYX_W_WIDTH); \
  op1_o = (alu_op == `YSYX_ALU_OP_BGE || alu_op == `YSYX_ALU_OP_BGEU) ? op2 : op1; \
  op2_o = (alu_op == `YSYX_ALU_OP_BGE || alu_op == `YSYX_ALU_OP_BGEU) ? op1 : op2; \
  alu_op_o = ( \
    ({4{(alu_op == `YSYX_ALU_OP_BEQ)}} & `YSYX_ALU_OP_SUB) | \
    ({4{(alu_op == `YSYX_ALU_OP_BNE)}} & `YSYX_ALU_OP_XOR) | \
    ({4{(alu_op == `YSYX_ALU_OP_BLT)}} & `YSYX_ALU_OP_SLT) | \
    ({4{(alu_op == `YSYX_ALU_OP_BLTU)}} & `YSYX_ALU_OP_SLTU) | \
    ({4{(alu_op == `YSYX_ALU_OP_BGE)}} & `YSYX_ALU_OP_SLE) | \
    ({4{(alu_op == `YSYX_ALU_OP_BGEU)}} & `YSYX_ALU_OP_SLEU) | \
    `YSYX_ALU_OP_ADD \
  ); \
end

`define YSYX_U_TYPE(op1, alu_op)  begin \
  imm_o = `YSYX_SIGN_EXTEND(imm_U, 32, `YSYX_W_WIDTH); \
  op1_o = op1;    \
  op2_o = imm_o;  \
  alu_op_o = alu_op; \
  // rd_o = rd;      \
end

`define YSYX_J_TYPE(op1, alu_op, op2)  begin \
  imm_o = `YSYX_SIGN_EXTEND(imm_J, 21, `YSYX_W_WIDTH); \
  op1_o = op1; \
  op2_o = op2; \
  alu_op_o = alu_op; \
  // rd_o = rd; \
end

`define YSYX_I_SYS_TYPE(op1, alu_op, op2)  begin \
  imm_o = `YSYX_SIGN_EXTEND(imm_SYS, 16, `YSYX_W_WIDTH); \
  op1_o = op1; \
  op2_o = op2; \
  alu_op_o = alu_op; \
  // rd_o = rd; \
end
