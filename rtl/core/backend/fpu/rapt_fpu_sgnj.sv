`include "rapt.svh"

module rapt_fpu_sgnj (
    input  logic [5:0]  op,
    input  logic [63:0] operand_a,
    input  logic [63:0] operand_b,
    output logic [63:0] result
);
  logic [31:0] operand_a_s;
  logic [31:0] operand_b_s;

  assign operand_a_s = operand_a[63:32] == '1
    ? operand_a[31:0] : 32'h7fc0_0000;
  assign operand_b_s = operand_b[63:32] == '1
    ? operand_b[31:0] : 32'h7fc0_0000;

  always_comb begin
    unique case (op)
      `RAPT_FP_OP_FSGNJ_S:
        result = {32'hffff_ffff, operand_b_s[31], operand_a_s[30:0]};
      `RAPT_FP_OP_FSGNJN_S:
        result = {32'hffff_ffff, ~operand_b_s[31], operand_a_s[30:0]};
      `RAPT_FP_OP_FSGNJX_S:
        result = {32'hffff_ffff,
                  operand_a_s[31] ^ operand_b_s[31], operand_a_s[30:0]};
      `RAPT_FP_OP_FSGNJ_D:
        result = {operand_b[63], operand_a[62:0]};
      `RAPT_FP_OP_FSGNJN_D:
        result = {~operand_b[63], operand_a[62:0]};
      `RAPT_FP_OP_FSGNJX_D:
        result = {operand_a[63] ^ operand_b[63], operand_a[62:0]};
      default:
        result = '0;
    endcase
  end
endmodule
