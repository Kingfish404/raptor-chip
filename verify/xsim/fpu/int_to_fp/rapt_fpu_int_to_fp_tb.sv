module rapt_fpu_int_to_fp_tb (
    input logic clock, reset, flush, valid,
    input logic target_double, int64_input, unsigned_input,
    input logic [63:0] operand,
    input logic [2:0] rounding_mode,
    output logic ready,
    output logic [63:0] dut_result,
    output logic [4:0] dut_flags,
    output logic dut_valid
);
  logic [3:0] unit_ready, unit_valid;
  logic [63:0] unit_result[4];
  logic [4:0] unit_flags[4];
  logic [1:0] select;

  assign select = {target_double, int64_input};

  rapt_fpu_int_to_fp #(.TARGET_DOUBLE(0), .INT64_INPUT(0)) u_sw (
      .clock, .reset, .flush, .valid(valid && select == 0), .ready(unit_ready[0]),
      .operand, .unsigned_input, .rounding_mode, .result(unit_result[0]),
      .flags(unit_flags[0]), .result_valid(unit_valid[0]));
  rapt_fpu_int_to_fp #(.TARGET_DOUBLE(0), .INT64_INPUT(1)) u_sl (
      .clock, .reset, .flush, .valid(valid && select == 1), .ready(unit_ready[1]),
      .operand, .unsigned_input, .rounding_mode, .result(unit_result[1]),
      .flags(unit_flags[1]), .result_valid(unit_valid[1]));
  rapt_fpu_int_to_fp #(.TARGET_DOUBLE(1), .INT64_INPUT(0)) u_dw (
      .clock, .reset, .flush, .valid(valid && select == 2), .ready(unit_ready[2]),
      .operand, .unsigned_input, .rounding_mode, .result(unit_result[2]),
      .flags(unit_flags[2]), .result_valid(unit_valid[2]));
  rapt_fpu_int_to_fp #(.TARGET_DOUBLE(1), .INT64_INPUT(1)) u_dl (
      .clock, .reset, .flush, .valid(valid && select == 3), .ready(unit_ready[3]),
      .operand, .unsigned_input, .rounding_mode, .result(unit_result[3]),
      .flags(unit_flags[3]), .result_valid(unit_valid[3]));

  always_comb begin
    ready = unit_ready[select];
    dut_result = unit_result[select];
    dut_flags = unit_flags[select];
    dut_valid = unit_valid[select];
  end
endmodule
