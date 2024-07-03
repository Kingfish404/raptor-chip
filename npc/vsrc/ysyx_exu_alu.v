`include "ysyx_macro.v"

module ysyx_ALU (
  input [BIT_W-1:0] alu_src1,
  input [BIT_W-1:0] alu_src2,
  input [3:0] alu_op,
  output reg [BIT_W-1:0] alu_res_o
);
  parameter integer BIT_W = `ysyx_W_WIDTH;

  always @(*) begin
    // $display("alu_op: %h, alu_src1: %h, alu_src2: %h", alu_op, alu_src1, alu_src2);
    unique case (alu_op)
      `ysyx_ALU_OP_ADD:  begin alu_res_o = alu_src1 + alu_src2;  end
      `ysyx_ALU_OP_SUB:  begin alu_res_o = alu_src1 - alu_src2;  end
      `ysyx_ALU_OP_SLT:  begin alu_res_o = (($signed(alu_src1)) <  ($signed(alu_src2))) ? 1 : 0;  end
      `ysyx_ALU_OP_SLE:  begin alu_res_o = (($signed(alu_src1)) <= ($signed(alu_src2))) ? 1 : 0; end
      `ysyx_ALU_OP_SLTU: begin alu_res_o = (alu_src1 < alu_src2) ? 1 : 0;  end
      `ysyx_ALU_OP_SLEU: begin alu_res_o = (alu_src1 <= alu_src2) ? 1 : 0; end
      `ysyx_ALU_OP_XOR:  begin alu_res_o = alu_src1 ^ alu_src2;  end
      `ysyx_ALU_OP_OR:   begin alu_res_o = alu_src1 | alu_src2;  end
      `ysyx_ALU_OP_AND:  begin alu_res_o = alu_src1 & alu_src2;  end
      `ysyx_ALU_OP_SLL:  begin alu_res_o = alu_src1 << (alu_src2[4:0]); end
      `ysyx_ALU_OP_SRL:  begin alu_res_o = ($unsigned(alu_src1)) >> (alu_src2 & 'h1f); end
      `ysyx_ALU_OP_SRA:  begin alu_res_o = ($signed(alu_src1)) >>> (alu_src2 & 'h1f); end
      default: begin  alu_res_o = alu_src2;
      end
    endcase
    // $display("alu_res_o: %h", alu_res_o);
  end
endmodule // ysyx_ALU
