// Compatibility interface for fixed-format users outside the FEU.
module rapt_fpu_int_to_fp #(
    parameter bit TARGET_DOUBLE = 1'b0,
    parameter bit INT64_INPUT = 1'b0
) (
    input logic clock,
    reset,
    flush,
    valid,
    output logic ready,
    input logic [63:0] operand,
    input logic unsigned_input,
    input logic [2:0] rounding_mode,
    output logic [63:0] result,
    output logic [4:0] flags,
    output logic result_valid
);
  rapt_fpu_integer_to_fp #(
      .TARGET_DOUBLE(TARGET_DOUBLE),
      .INT64_INPUT(INT64_INPUT),
      .MULTI_FORMAT(1'b0)
  ) u_shared (
      .clock(clock),
      .reset(reset),
      .flush(flush),
      .valid(valid),
      .ready(ready),
      .operand(operand),
      .target_double(TARGET_DOUBLE),
      .int64_input(INT64_INPUT),
      .unsigned_input(unsigned_input),
      .rounding_mode(rounding_mode),
      .result(result),
      .flags(flags),
      .result_valid(result_valid)
  );
endmodule
