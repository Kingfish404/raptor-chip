module rapt_fpu_mul_tb (
    input  logic        clock,
    input  logic        reset,
    input  logic        flush,
    input  logic        valid,
    input  logic        is_double,
    input  logic [63:0] operand_a,
    input  logic [63:0] operand_b,
    input  logic [2:0]  rounding_mode,
    output logic        ready,
    output logic [63:0] dut_result,
    output logic [4:0]  dut_flags,
    output logic        dut_valid
);
  logic ready_s, ready_d;
  logic [63:0] result_s, result_d;
  logic [4:0] flags_s, flags_d;
  logic valid_s, valid_d;

  rapt_fpu_mul #(.TARGET_DOUBLE(1'b0)) dut_s (
      .clock(clock), .reset(reset), .flush(flush),
      .valid(valid && !is_double), .ready(ready_s),
      .operand_a(operand_a), .operand_b(operand_b),
      .rounding_mode(rounding_mode),
      .result(result_s), .flags(flags_s), .result_valid(valid_s));

  rapt_fpu_mul #(.TARGET_DOUBLE(1'b1)) dut_d (
      .clock(clock), .reset(reset), .flush(flush),
      .valid(valid && is_double), .ready(ready_d),
      .operand_a(operand_a), .operand_b(operand_b),
      .rounding_mode(rounding_mode),
      .result(result_d), .flags(flags_d), .result_valid(valid_d));

  assign ready = is_double ? ready_d : ready_s;
  assign dut_result = is_double ? result_d : result_s;
  assign dut_flags = is_double ? flags_d : flags_s;
  assign dut_valid = is_double ? valid_d : valid_s;
endmodule