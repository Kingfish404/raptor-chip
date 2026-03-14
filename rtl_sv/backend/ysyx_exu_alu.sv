`include "ysyx.svh"

module ysyx_exu_alu #(
    parameter bit [7:0] XLEN = `YSYX_XLEN
) (
    input [XLEN-1:0] s1,
    input [XLEN-1:0] s2,
    input [4:0] op,
    input word,       // RV64 W-variant: operate on lower 32 bits, sign-extend result
    output logic [XLEN-1:0] out_r
);
  // Shift amount mask: 5-bit for RV32 or W-variants, 6-bit for RV64 base
  localparam int SHAMT_MASK = XLEN - 1;  // 31 for RV32, 63 for RV64
  localparam int SHAMT_W = $clog2(XLEN); // 5 for RV32, 6 for RV64
  logic [XLEN-1:0] alu_r;

  always_comb begin
    unique case (op)
      // verilog_format: off
      `YSYX_ALU_ADD_: begin alu_r = s1 + s2; end
      `YSYX_ALU_SUB_: begin alu_r = s1 - s2; end
      `YSYX_ALU_EQ__: begin alu_r = (s1 == s2) ? 'h1 : 0; end
      `YSYX_ALU_SLT_: begin alu_r = (($signed(s1)) < ($signed(s2))) ? 'h1 : 0;  end
      `YSYX_ALU_SLE_: begin alu_r = (($signed(s1)) <= ($signed(s2))) ? 'h1 : 0; end
      `YSYX_ALU_SGE_: begin alu_r = (($signed(s1)) >= ($signed(s2))) ? 'h1 : 0; end
      `YSYX_ALU_SLTU: begin alu_r = (s1 < s2) ? 'h1 : 0;  end
      `YSYX_ALU_SLEU: begin alu_r = (s1 <= s2) ? 'h1 : 0; end
      `YSYX_ALU_SGEU: begin alu_r = (s1 >= s2) ? 'h1 : 0; end
      `YSYX_ALU_XOR_: begin alu_r = s1 ^ s2; end
      `YSYX_ALU_OR__: begin alu_r = s1 | s2; end
      `YSYX_ALU_AND_: begin alu_r = s1 & s2; end
      `YSYX_ALU_SLL_: begin alu_r = word ? s1 << s2[4:0] : s1 << s2[SHAMT_W-1:0]; end
      `YSYX_ALU_SRL_: begin alu_r = word ? {{XLEN-32{1'b0}}, s1[31:0]} >> s2[4:0] : s1 >> s2[SHAMT_W-1:0]; end
      `YSYX_ALU_SRA_: begin alu_r = word ? $signed({{XLEN-32{s1[31]}}, s1[31:0]}) >>> s2[4:0] : $signed(s1) >>> s2[SHAMT_W-1:0]; end
      // verilog_format: on
      default: begin
        alu_r = 'h0;
      end
    endcase
  end

  // W-variant: sign-extend lower 32-bit result to XLEN
  generate
    if (XLEN > 32) begin : gen_word_ext
      assign out_r = word ? {{XLEN-32{alu_r[31]}}, alu_r[31:0]} : alu_r;
    end else begin : gen_no_word
      assign out_r = alu_r;
    end
  endgenerate
endmodule
