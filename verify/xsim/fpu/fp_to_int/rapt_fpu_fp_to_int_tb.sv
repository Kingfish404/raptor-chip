module rapt_fpu_fp_to_int_tb (
    input logic clock, reset, flush, valid,
    input logic source_double, unsigned_result, int64_target,
    input logic [63:0] operand,
    input logic [2:0] rounding_mode,
    output logic ready,
    output logic [63:0] dut_result,
    output logic [4:0] dut_flags,
    output logic dut_valid
);
  logic ready_s, ready_d, valid_s, valid_d;
  logic [63:0] result_s, result_d;
  logic [4:0] flags_s, flags_d;

  rapt_fpu_single_to_int_w #(.SOURCE_DOUBLE(0)) dut_s (
      .clock, .reset, .flush, .valid(valid && !source_double), .ready(ready_s),
      .operand, .unsigned_result, .int64_target, .rounding_mode,
      .result(result_s), .flags(flags_s), .result_valid(valid_s));
  rapt_fpu_single_to_int_w #(.SOURCE_DOUBLE(1)) dut_d (
      .clock, .reset, .flush, .valid(valid && source_double), .ready(ready_d),
      .operand, .unsigned_result, .int64_target, .rounding_mode,
      .result(result_d), .flags(flags_d), .result_valid(valid_d));

  assign ready = source_double ? ready_d : ready_s;
  assign dut_result = source_double ? result_d : result_s;
  assign dut_flags = source_double ? flags_d : flags_s;
  assign dut_valid = source_double ? valid_d : valid_s;
endmodule
