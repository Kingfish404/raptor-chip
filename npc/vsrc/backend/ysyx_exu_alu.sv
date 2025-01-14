`include "ysyx.svh"

module ysyx_exu_alu (
    input [XLEN-1:0] s1,
    input [XLEN-1:0] s2,
    input [4:0] op,
    output logic [XLEN-1:0] out_r
);
  parameter bit [7:0] XLEN = `YSYX_XLEN;

  always_comb begin
    // $display("op: %h, s1: %h, s2: %h", op, s1, s2);
    unique case (op)
      // RV32I
      // verilog_format: off
      `YSYX_ALU_ADD_: begin out_r = s1 + s2; end
      `YSYX_ALU_SUB_: begin out_r = s1 - s2; end
      `YSYX_ALU_SLT_: begin out_r = (($signed(s1)) < ($signed(s2))) ? 1 : 0;  end
      `YSYX_ALU_SLE_: begin out_r = (($signed(s1)) <= ($signed(s2))) ? 1 : 0; end
      `YSYX_ALU_SLTU: begin out_r = (s1 < s2) ? 1 : 0;  end
      `YSYX_ALU_SLEU: begin out_r = (s1 <= s2) ? 1 : 0; end
      `YSYX_ALU_XOR_: begin out_r = s1 ^ s2; end
      `YSYX_ALU_OR__: begin out_r = s1 | s2; end
      `YSYX_ALU_AND_: begin out_r = s1 & s2; end
      `YSYX_ALU_SLL_: begin out_r = s1 << (s2 & 'h1f);  end
      `YSYX_ALU_SRL_: begin out_r = ($unsigned(s1)) >> (s2 & 'h1f); end
      `YSYX_ALU_SRA_: begin out_r = ($signed(s1)) >>> (s2 & 'h1f);  end
      // verilog_format: on
      default: begin
        out_r = 0;
      end
    endcase
    // $display("out_r: %h", out_r);
  end
endmodule  // ysyx_exu_alu
