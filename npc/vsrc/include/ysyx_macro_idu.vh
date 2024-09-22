`include "ysyx_macro.vh"

`define YSYX_B_TYPE(op1, alu_op, op2) begin \
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
