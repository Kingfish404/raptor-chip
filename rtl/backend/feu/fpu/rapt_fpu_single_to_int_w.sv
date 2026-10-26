// Compatibility interface for fixed-format users outside the FEU.
module rapt_fpu_single_to_int_w #(
    parameter bit SOURCE_DOUBLE = 1'b0
) (
    input logic clock,
    reset,
    flush,
    valid,
    output logic ready,
    input logic [63:0] operand,
    input logic unsigned_result,
    int64_target,
    input logic [2:0] rounding_mode,
    output logic [63:0] result,
    output logic [4:0] flags,
    output logic result_valid
);
  rapt_fpu_fp_to_int #(
      .SOURCE_DOUBLE(SOURCE_DOUBLE),
      .MULTI_FORMAT(1'b0)
  ) u_shared (
      .clock(clock),
      .reset(reset),
      .flush(flush),
      .valid(valid),
      .ready(ready),
      .operand(operand),
      .source_double(SOURCE_DOUBLE),
      .unsigned_result(unsigned_result),
      .int64_target(int64_target),
      .rounding_mode(rounding_mode),
      .result(result),
      .flags(flags),
      .result_valid(result_valid)
  );
endmodule
