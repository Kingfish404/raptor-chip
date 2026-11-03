// Compatibility interface for fixed-format users outside the FEU.
module rapt_fpu_addsub #(
    parameter bit TARGET_DOUBLE = 1'b0
) (
    input logic clock,
    reset,
    flush,
    valid,
    output logic ready,
    input logic [5:0] op,
    input logic [63:0] operand_a,
    operand_b,
    input logic [2:0] rounding_mode,
    output logic [63:0] result,
    output logic [4:0] flags,
    output logic result_valid
);
  rapt_fpu_fp_addsub #(
      .TARGET_DOUBLE(TARGET_DOUBLE),
      .MULTI_FORMAT(1'b0)
  ) u_shared (
      .clock(clock),
      .reset(reset),
      .flush(flush),
      .valid(valid),
      .ready(ready),
      .op(op),
      .target_double(TARGET_DOUBLE),
      .operand_a(operand_a),
      .operand_b(operand_b),
      .rounding_mode(rounding_mode),
      .result(result),
      .flags(flags),
      .result_valid(result_valid)
  );
endmodule
