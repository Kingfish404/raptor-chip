`include "ysyx.svh"

module ysyx_exu_alu (
    input [XLEN-1:0] alu_src1,
    input [XLEN-1:0] alu_src2,
    input [3:0] alu_op,
    output reg [XLEN-1:0] out_alu_res
);
  parameter bit [7:0] XLEN = `YSYX_XLEN;

  always_comb begin
    // $display("alu_op: %h, alu_src1: %h, alu_src2: %h", alu_op, alu_src1, alu_src2);
    unique case (alu_op)
      `YSYX_ALU_OP_ADD: begin
        out_alu_res = alu_src1 + alu_src2;
      end
      `YSYX_ALU_OP_SUB: begin
        out_alu_res = alu_src1 - alu_src2;
      end
      `YSYX_ALU_OP_SLT: begin
        out_alu_res = (($signed(alu_src1)) < ($signed(alu_src2))) ? 1 : 0;
      end
      `YSYX_ALU_OP_SLE: begin
        out_alu_res = (($signed(alu_src1)) <= ($signed(alu_src2))) ? 1 : 0;
      end
      `YSYX_ALU_OP_SLTU: begin
        out_alu_res = (alu_src1 < alu_src2) ? 1 : 0;
      end
      `YSYX_ALU_OP_SLEU: begin
        out_alu_res = (alu_src1 <= alu_src2) ? 1 : 0;
      end
      `YSYX_ALU_OP_XOR: begin
        out_alu_res = alu_src1 ^ alu_src2;
      end
      `YSYX_ALU_OP_OR: begin
        out_alu_res = alu_src1 | alu_src2;
      end
      `YSYX_ALU_OP_AND: begin
        out_alu_res = alu_src1 & alu_src2;
      end
      `YSYX_ALU_OP_SLL: begin
        out_alu_res = alu_src1 << (alu_src2 & 'h1f);
      end
      `YSYX_ALU_OP_SRL: begin
        out_alu_res = ($unsigned(alu_src1)) >> (alu_src2 & 'h1f);
      end
      `YSYX_ALU_OP_SRA: begin
        out_alu_res = ($signed(alu_src1)) >>> (alu_src2 & 'h1f);
      end
      default: begin
        out_alu_res = alu_src2;
      end
    endcase
    // $display("out_alu_res: %h", out_alu_res);
  end
endmodule  // ysyx_ALU
