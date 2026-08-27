// Wrapper exposing the pipelined add/sub DUT with simple top-level ports so
// the C++ host differential testbench can drive it directly.
module rapt_fpu_addsub_tb (
    input  logic        clock,
    input  logic        reset,
    input  logic        flush,
    input  logic        valid,
    input  logic [5:0]  op,
    input  logic [63:0] operand_a,
    input  logic [63:0] operand_b,
    input  logic [2:0]  rounding_mode,
    input  logic        is_double,
    output logic        ready,
    output logic [63:0] dut_result,
    output logic [4:0]  dut_flags,
    output logic        dut_valid
);

  logic        rdy_s, rdy_d;
  logic [63:0] res_s, res_d;
  logic [4:0]  flg_s, flg_d;
  logic        rv_s, rv_d;

  rapt_fpu_addsub #(.TARGET_DOUBLE(1'b0)) dut_s (
      .clock(clock), .reset(reset), .flush(flush),
      .valid(valid && !is_double), .ready(rdy_s),
      .op(op), .operand_a(operand_a), .operand_b(operand_b),
      .rounding_mode(rounding_mode),
      .result(res_s), .flags(flg_s), .result_valid(rv_s));

  rapt_fpu_addsub #(.TARGET_DOUBLE(1'b1)) dut_d (
      .clock(clock), .reset(reset), .flush(flush),
      .valid(valid && is_double), .ready(rdy_d),
      .op(op), .operand_a(operand_a), .operand_b(operand_b),
      .rounding_mode(rounding_mode),
      .result(res_d), .flags(flg_d), .result_valid(rv_d));

  assign ready      = is_double ? rdy_d : rdy_s;
  assign dut_result = is_double ? res_d : res_s;
  assign dut_flags  = is_double ? flg_d : flg_s;
  assign dut_valid  = is_double ? rv_d  : rv_s;

endmodule
