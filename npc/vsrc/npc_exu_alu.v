`include "npc_common.v"

module ysyx_ALU (
  input wire [BIT_W-1:0] alu_op1,
  input wire [BIT_W-1:0] alu_op2,
  input wire [3:0] alu_op,
  output reg [BIT_W-1:0] alu_res_o
);
  parameter BIT_W = `ysyx_W_WIDTH;
    
  always @(*) begin
    // $display("alu_op1: %h, alu_op2: %h, alu_op: %h", alu_op1, alu_op2, alu_op);
    unique case (alu_op)
      `ysyx_ALU_OP_ADD:  begin alu_res_o = alu_op1 + alu_op2;  end
      `ysyx_ALU_OP_SUB:  begin alu_res_o = alu_op1 - alu_op2;  end
      `ysyx_ALU_OP_SLT:  begin alu_res_o = ((signed'(alu_op1)) <  (signed'(alu_op2))) ? 1 : 0;  end
      `ysyx_ALU_OP_SLE:  begin alu_res_o = ((signed'(alu_op1)) <= (signed'(alu_op2))) ? 1 : 0; end
      `ysyx_ALU_OP_SLTU: begin alu_res_o = (alu_op1 < alu_op2) ? 1 : 0;  end
      `ysyx_ALU_OP_SLEU: begin alu_res_o = (alu_op1 <= alu_op2) ? 1 : 0; end
      `ysyx_ALU_OP_XOR:  begin alu_res_o = alu_op1 ^ alu_op2;  end
      `ysyx_ALU_OP_OR:   begin alu_res_o = alu_op1 | alu_op2;  end
      `ysyx_ALU_OP_AND:  begin alu_res_o = alu_op1 & alu_op2;  end
      `ysyx_ALU_OP_SLL:  begin alu_res_o = alu_op1 << alu_op2; end
      `ysyx_ALU_OP_SRL:  begin alu_res_o = alu_op1 >> alu_op2; end
      `ysyx_ALU_OP_SRA:  begin alu_res_o = (signed'(alu_op1)) >>> (alu_op2 & 'h1f); end
      default: begin  alu_res_o = alu_op2;
      end
    endcase
  end
endmodule // ysyx_ALU
