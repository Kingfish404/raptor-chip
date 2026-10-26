`include "rapt.svh"
module tb (
    input logic is_double,
    input logic [2:0] choice,
    input logic [63:0] a,
    b,
    output logic [63:0] cmp,
    sgnj,
    output logic [4:0] flags,
    output logic [9:0] classification
);
  logic [5:0] cop, sop;
  always_comb begin
    case (choice)
      0:cop=is_double?`RAPT_FP_OP_FEQ_D:`RAPT_FP_OP_FEQ_S;
      1:cop=is_double?`RAPT_FP_OP_FLT_D:`RAPT_FP_OP_FLT_S;
      2:cop=is_double?`RAPT_FP_OP_FLE_D:`RAPT_FP_OP_FLE_S;
      3:cop=is_double?`RAPT_FP_OP_FMIN_D:`RAPT_FP_OP_FMIN_S;
      default:cop=is_double?`RAPT_FP_OP_FMAX_D:`RAPT_FP_OP_FMAX_S;
    endcase
    case (choice)
      0:sop=is_double?`RAPT_FP_OP_FSGNJ_D:`RAPT_FP_OP_FSGNJ_S;
      1:sop=is_double?`RAPT_FP_OP_FSGNJN_D:`RAPT_FP_OP_FSGNJN_S;
      default:sop=is_double?`RAPT_FP_OP_FSGNJX_D:`RAPT_FP_OP_FSGNJX_S;
    endcase
  end
  rapt_fpu_compare c (
      .op(cop),
      .operand_a(a),
      .operand_b(b),
      .result(cmp),
      .flags
  );
  rapt_fpu_sgnj s (
      .op(sop),
      .operand_a(a),
      .operand_b(b),
      .result(sgnj)
  );
  rapt_fpu_classify f (
      .is_double,
      .operand(a),
      .result(classification)
  );
endmodule
