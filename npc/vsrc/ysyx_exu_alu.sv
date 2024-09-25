`include "ysyx_macro.vh"

module ysyx_exu_alu (
    input [BIT_W-1:0] alu_src1,
    input [BIT_W-1:0] alu_src2,
    input [3:0] alu_op,
    output reg [BIT_W-1:0] alu_res_o
);
  parameter bit [7:0] BIT_W = `YSYX_W_WIDTH;

  always_comb begin
    // $display("alu_op: %h, alu_src1: %h, alu_src2: %h", alu_op, alu_src1, alu_src2);
    unique case (alu_op)
      `YSYX_ALU_OP_ADD: begin
        alu_res_o = alu_src1 + alu_src2;
      end
      `YSYX_ALU_OP_SUB: begin
        alu_res_o = alu_src1 - alu_src2;
      end
      `YSYX_ALU_OP_SLT: begin
        alu_res_o = (($signed(alu_src1)) < ($signed(alu_src2))) ? 1 : 0;
      end
      `YSYX_ALU_OP_SLE: begin
        alu_res_o = (($signed(alu_src1)) <= ($signed(alu_src2))) ? 1 : 0;
      end
      `YSYX_ALU_OP_SLTU: begin
        alu_res_o = (alu_src1 < alu_src2) ? 1 : 0;
      end
      `YSYX_ALU_OP_SLEU: begin
        alu_res_o = (alu_src1 <= alu_src2) ? 1 : 0;
      end
      `YSYX_ALU_OP_XOR: begin
        alu_res_o = alu_src1 ^ alu_src2;
      end
      `YSYX_ALU_OP_OR: begin
        alu_res_o = alu_src1 | alu_src2;
      end
      `YSYX_ALU_OP_AND: begin
        alu_res_o = alu_src1 & alu_src2;
      end
      `YSYX_ALU_OP_SLL: begin
        alu_res_o = alu_src1 << (alu_src2 & 'h1f);
      end
      `YSYX_ALU_OP_SRL: begin
        alu_res_o = ($unsigned(alu_src1)) >> (alu_src2 & 'h1f);
      end
      `YSYX_ALU_OP_SRA: begin
        alu_res_o = ($signed(alu_src1)) >>> (alu_src2 & 'h1f);
      end
      default: begin
        alu_res_o = alu_src2;
      end
    endcase
    // $display("alu_res_o: %h", alu_res_o);
  end
endmodule  // ysyx_ALU
