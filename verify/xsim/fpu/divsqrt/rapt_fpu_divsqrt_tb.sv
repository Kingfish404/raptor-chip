// Wrapper exposing the iterative DUT and the combinational reference side by
// side. The reference computes combinationally from the launch operands; the
// testbench latches its outputs when the DUT completes.
module rapt_fpu_divsqrt_tb (
    input  logic        clock,
    input  logic        reset,
    input  logic [63:0] operand_a,
    input  logic [63:0] operand_b,
    input  logic [2:0]  rounding_mode,
    input  logic        src_is_double,
    input  logic        dst_is_double,
    input  logic        divide,
    input  logic        sqrt,
    input  logic        flush,
    input  logic        valid,
    output logic        ready,
    output logic [63:0] dut_result,
    output logic [4:0]  dut_flags,
    output logic        dut_valid,
    output logic [63:0] ref_result,
    output logic [4:0]  ref_flags
);

  // Iterative unit under test
  rapt_fpu_divsqrt dut (
      .clock(clock), .reset(reset),
      .operand_a(operand_a), .operand_b(operand_b),
      .rounding_mode(rounding_mode),
      .src_is_double(src_is_double), .dst_is_double(dst_is_double),
      .divide(divide), .sqrt(sqrt), .flush(flush),
      .valid(valid), .ready(ready),
      .result(dut_result), .flags(dut_flags), .result_valid(dut_valid)
  );

  // Combinational reference (original implementation)
  logic        ref_ready;
  logic [63:0] ref_res_c;
  logic [4:0]  ref_flg_c;
  logic        ref_valid_c;
  rapt_fpu_divsqrt_ref ref_i (
      .clock(clock), .reset(reset),
      .operand_a(operand_a), .operand_b(operand_b),
      .rounding_mode(rounding_mode),
      .src_is_double(src_is_double), .dst_is_double(dst_is_double),
      .divide(divide), .sqrt(sqrt), .flush(flush),
      .valid(valid), .ready(ref_ready),
      .result(ref_res_c), .flags(ref_flg_c), .result_valid(ref_valid_c)
  );

  // Latch reference outputs at launch (its result_valid is 1 cycle later)
  logic [63:0] a_q, b_q;
  logic [2:0]  rm_q;
  logic        dbl_q, div_q;
  always_ff @(posedge clock) begin
    if (valid) begin
      a_q <= operand_a; b_q <= operand_b;
      rm_q <= rounding_mode; dbl_q <= src_is_double; div_q <= divide;
    end
  end

  // The reference registers its result internally; capture on its valid.
  // The reference registers its result internally on the valid edge; its
  // result_valid (busy_q) is high for the following single cycle. Because of
  // non-blocking sampling we must capture the cycle AFTER result_valid rises.
  logic [63:0] ref_res_q;
  logic [4:0]  ref_flg_q;
  logic        ref_valid_d;
  always_ff @(posedge clock) begin
    ref_valid_d <= ref_valid_c;
    if (ref_valid_d) begin
      ref_res_q <= ref_res_c;
      ref_flg_q <= ref_flg_c;
    end
  end
  assign ref_result = ref_res_q;
  assign ref_flags  = ref_flg_q;

endmodule
