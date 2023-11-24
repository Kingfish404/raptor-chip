`include "npc_common.v"

import "DPI-C" function void npc_exu_ebreak ();

module ysyx_23060087_ALU #(BIT_W = 32) (
    input wire [BIT_W-1:0] alu_op1,
    input wire [BIT_W-1:0] alu_op2,
    input wire [2:0] alu_op,
    output reg [BIT_W-1:0] alu_result_o
);
  always @(*) begin
    case (alu_op)
      `ysyx_23060087_ALU_OP_ADD: begin
          alu_result_o = alu_op1 + alu_op2;
      end
      default: begin
          alu_result_o = alu_op2;
      end
    endcase
  end
endmodule // ysyx_23060087_ALU

module ysyx_23060087_EXU #(BIT_W = 32)(
    input wire clk,
    input wire [BIT_W-1:0] imm,
    input wire [BIT_W-1:0] op1, op2,
    input wire [2:0] alu_op,
    input wire [6:0] opcode,
    output reg [BIT_W-1:0] reg_wdata_o
);
    always @(posedge clk) begin
        if ({opcode} == 7'b11100_11) begin
            npc_exu_ebreak(); // ebreak
        end
    end

    ysyx_23060087_ALU #(BIT_W) alu(
      .alu_op1(op1), .alu_op2(op2), .alu_op(alu_op),
      .alu_result_o(reg_wdata_o)
      );

endmodule // ysyx_23060087_EXU
