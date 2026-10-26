`include "rapt.svh"

// One 53x53 product resource for the S and D MUL/FMA streams. Each operation
// keeps its original format-specific finishing stages and eight-cycle slot.
module rapt_fpu_fp_product (
    input logic clock,
    reset,
    flush,
    valid,
    is_fma,
    target_double,
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
  logic [23:0] mul_a_s, mul_b_s, fma_a_s, fma_b_s;
  logic [52:0] mul_a_d, mul_b_d, fma_a_d, fma_b_d;
  logic mul_product_s, fma_product_s, mul_product_d, fma_product_d;
  logic [52:0] product_a, product_b;
  logic [105:0] product;
  logic [3:0] mul_delay_valid_s, mul_delay_valid_d;
  logic [63:0] mul_delay_result_s[4], mul_delay_result_d[4];
  logic [4:0] mul_delay_flags_s[4], mul_delay_flags_d[4];
  logic [63:0] mul_result_s, mul_result_d, fma_result_s, fma_result_d;
  logic [4:0] mul_flags_s, mul_flags_d, fma_flags_s, fma_flags_d;
  logic mul_valid_s, mul_valid_d, fma_valid_s, fma_valid_d;
  logic mul_ready_s, mul_ready_d, fma_ready_s, fma_ready_d;
  logic mul_result_valid_s, mul_result_valid_d, fma_result_valid_s, fma_result_valid_d;

  assign ready = mul_ready_s && mul_ready_d && fma_ready_s && fma_ready_d;
  assign mul_valid_s = valid && ready && !is_fma && !target_double;
  assign mul_valid_d = valid && ready && !is_fma && target_double;
  assign fma_valid_s = valid && ready && is_fma && !target_double;
  assign fma_valid_d = valid && ready && is_fma && target_double;
  always_comb begin
    product_a = '0;
    product_b = '0;
    if (mul_product_s) begin
      product_a = {29'b0, mul_a_s};
      product_b = {29'b0, mul_b_s};
    end else if (fma_product_s) begin
      product_a = {29'b0, fma_a_s};
      product_b = {29'b0, fma_b_s};
    end else if (mul_product_d) begin
      product_a = mul_a_d;
      product_b = mul_b_d;
    end else if (fma_product_d) begin
      product_a = fma_a_d;
      product_b = fma_b_d;
    end
  end
  assign product = product_a * product_b;

  rapt_fpu_mul_pipeline #(
      .TARGET_DOUBLE(1'b0)
  ) u_mul_s (
      .clock,
      .reset,
      .flush,
      .valid(mul_valid_s),
      .ready(mul_ready_s),
      .operand_a,
      .operand_b,
      .rounding_mode,
      .result(mul_result_s),
      .flags(mul_flags_s),
      .result_valid(mul_result_valid_s),
      .product_a(mul_a_s),
      .product_b(mul_b_s),
      .product_valid(mul_product_s),
      .product(product[47:0])
  );
  rapt_fpu_fma_pipeline #(
      .TARGET_DOUBLE(1'b0)
  ) u_fma_s (
      .clock,
      .reset,
      .flush,
      .valid(fma_valid_s),
      .ready(fma_ready_s),
      .op,
      .operand_a,
      .operand_b,
      .operand_c,
      .rounding_mode,
      .result(fma_result_s),
      .flags(fma_flags_s),
      .result_valid(fma_result_valid_s),
      .product_a(fma_a_s),
      .product_b(fma_b_s),
      .product_valid(fma_product_s),
      .product(product[47:0])
  );
  rapt_fpu_mul_pipeline #(
      .TARGET_DOUBLE(1'b1)
  ) u_mul_d (
      .clock,
      .reset,
      .flush,
      .valid(mul_valid_d),
      .ready(mul_ready_d),
      .operand_a,
      .operand_b,
      .rounding_mode,
      .result(mul_result_d),
      .flags(mul_flags_d),
      .result_valid(mul_result_valid_d),
      .product_a(mul_a_d),
      .product_b(mul_b_d),
      .product_valid(mul_product_d),
      .product(product)
  );
  rapt_fpu_fma_pipeline #(
      .TARGET_DOUBLE(1'b1)
  ) u_fma_d (
      .clock,
      .reset,
      .flush,
      .valid(fma_valid_d),
      .ready(fma_ready_d),
      .op,
      .operand_a,
      .operand_b,
      .operand_c,
      .rounding_mode,
      .result(fma_result_d),
      .flags(fma_flags_d),
      .result_valid(fma_result_valid_d),
      .product_a(fma_a_d),
      .product_b(fma_b_d),
      .product_valid(fma_product_d),
      .product(product)
  );

  always_ff @(posedge clock) begin
    // Payload is observed only with its valid/state owner. Clear control last.
    mul_delay_valid_s <= {mul_delay_valid_s[2:0], mul_result_valid_s};
    mul_delay_valid_d <= {mul_delay_valid_d[2:0], mul_result_valid_d};
    if (mul_result_valid_s) begin
      mul_delay_result_s[0] <= mul_result_s;
      mul_delay_flags_s[0] <= mul_flags_s;
    end
    if (mul_result_valid_d) begin
      mul_delay_result_d[0] <= mul_result_d;
      mul_delay_flags_d[0] <= mul_flags_d;
    end
    for (int stage = 1; stage < 4; stage++) begin
      if (mul_delay_valid_s[stage-1]) begin
        mul_delay_result_s[stage] <= mul_delay_result_s[stage-1];
        mul_delay_flags_s[stage] <= mul_delay_flags_s[stage-1];
      end
      if (mul_delay_valid_d[stage-1]) begin
        mul_delay_result_d[stage] <= mul_delay_result_d[stage-1];
        mul_delay_flags_d[stage] <= mul_delay_flags_d[stage-1];
      end
    end
    if (reset || flush) begin
      mul_delay_valid_s <= '0;
      mul_delay_valid_d <= '0;
    end
  end
  always_comb begin
    result_valid = mul_delay_valid_s[3] || mul_delay_valid_d[3]
        || fma_result_valid_s || fma_result_valid_d;
    result = fma_result_d;
    flags = fma_flags_d;
    if (mul_delay_valid_s[3]) begin
      result = mul_delay_result_s[3];
      flags = mul_delay_flags_s[3];
    end else if (mul_delay_valid_d[3]) begin
      result = mul_delay_result_d[3];
      flags = mul_delay_flags_d[3];
    end else if (fma_result_valid_s) begin
      result = fma_result_s;
      flags = fma_flags_s;
    end
  end
  `RAPT_SVA(clock, reset || flush, FP_MULTI_PRODUCT_ONE_OWNER,
            $onehot0({mul_product_s, fma_product_s, mul_product_d, fma_product_d}))
  `RAPT_SVA(clock, reset || flush, FP_MULTI_PRODUCT_ONE_RESULT,
            $onehot0({mul_delay_valid_s[3], mul_delay_valid_d[3], fma_result_valid_s,
                      fma_result_valid_d}))
endmodule
