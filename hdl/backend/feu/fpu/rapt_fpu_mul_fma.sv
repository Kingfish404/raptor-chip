`include "rapt.svh"

// One-at-a-time FMUL/FMA endpoint with one shared significand multiplier.
// FMUL captures the product in stage 2; FMA captures it in stage 1. Their
// original four/six-cycle pipelines, rounding and flags remain independent.
// No arbitration/retry latency: a request is accepted only when both are idle.
module rapt_fpu_mul_fma #(
    parameter bit TARGET_DOUBLE = 1'b0
) (
    input logic clock,
    reset,
    flush,
    valid,
    is_fma,
    output logic ready,
    input logic [5:0] op,
    input logic [63:0] operand_a,
    operand_b,
    operand_c,
    input logic [2:0] rounding_mode,
    output logic [63:0] result,
    output logic [4:0] flags,
    output logic result_valid
);
  localparam int MantBits = TARGET_DOUBLE ? 53 : 24;
  logic mul_ready, fma_ready, mul_valid, fma_valid;
  logic mul_product_valid, fma_product_valid;
  logic [MantBits-1:0] mul_a, mul_b, fma_a, fma_b, selected_a, selected_b;
  logic [2*MantBits-1:0] product;
  logic [63:0] mul_result, fma_result;
  logic [4:0] mul_flags, fma_flags;
  logic mul_result_valid, fma_result_valid;

  assign ready = mul_ready && fma_ready;
  assign mul_valid = valid && ready && !is_fma;
  assign fma_valid = valid && ready && is_fma;
  // Registered MUL stage-1 ownership selects the resource. With no MUL owner,
  // pre-read the FMA operands without putting valid/reset on its data path.
  assign selected_a = mul_product_valid ? mul_a : fma_a;
  assign selected_b = mul_product_valid ? mul_b : fma_b;
  assign product = selected_a * selected_b;

  rapt_fpu_mul_pipeline #(
      .TARGET_DOUBLE(TARGET_DOUBLE)
  ) u_mul (
      .clock(clock),
      .reset(reset),
      .flush(flush),
      .valid(mul_valid),
      .ready(mul_ready),
      .operand_a(operand_a),
      .operand_b(operand_b),
      .rounding_mode(rounding_mode),
      .result(mul_result),
      .flags(mul_flags),
      .result_valid(mul_result_valid),
      .product_a(mul_a),
      .product_b(mul_b),
      .product_valid(mul_product_valid),
      .product(product)
  );
  rapt_fpu_fma_pipeline #(
      .TARGET_DOUBLE(TARGET_DOUBLE)
  ) u_fma (
      .clock(clock),
      .reset(reset),
      .flush(flush),
      .valid(fma_valid),
      .ready(fma_ready),
      .op(op),
      .operand_a(operand_a),
      .operand_b(operand_b),
      .operand_c(operand_c),
      .rounding_mode(rounding_mode),
      .result(fma_result),
      .flags(fma_flags),
      .result_valid(fma_result_valid),
      .product_a(fma_a),
      .product_b(fma_b),
      .product_valid(fma_product_valid),
      .product(product)
  );
  assign result_valid = mul_result_valid || fma_result_valid;
  assign result = mul_result_valid ? mul_result : fma_result;
  assign flags = mul_result_valid ? mul_flags : fma_flags;

  `RAPT_SVA(clock, reset || flush, FP_PRODUCT_ONE_OWNER, !(mul_product_valid && fma_product_valid))
  `RAPT_SVA(clock, reset || flush, FP_PRODUCT_ONE_RESULT, !(mul_result_valid && fma_result_valid))
endmodule
