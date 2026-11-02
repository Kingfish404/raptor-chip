`include "rapt.svh"

// Four-stage, one-operation-at-a-time IEEE-754 multiplier.
//
// Stage 1: decode/classify and normalize input significands.
// Stage 2: calculate the full-precision significand product.
// Stage 3: normalize the product and form guard/round/sticky bits.
// Stage 4: round, pack, and raise flags.
// Standalone compatibility wrapper: the pipeline's product resource is local.
module rapt_fpu_mul #(
    parameter bit TARGET_DOUBLE = 1'b0
) (
    input logic clock,
    reset,
    flush,
    valid,
    output logic ready,
    input logic [63:0] operand_a,
    operand_b,
    input logic [2:0] rounding_mode,
    output logic [63:0] result,
    output logic [4:0] flags,
    output logic result_valid
);
  localparam int MantBits = TARGET_DOUBLE ? 53 : 24;
  logic [MantBits-1:0] product_a, product_b;
  logic unused_product_valid;
  logic [2*MantBits-1:0] product;
  assign product = product_a * product_b;
  rapt_fpu_mul_pipeline #(
      .TARGET_DOUBLE(TARGET_DOUBLE)
  ) u_pipeline (
      .clock(clock),
      .reset(reset),
      .flush(flush),
      .valid(valid),
      .target_double(TARGET_DOUBLE),
      .ready(ready),
      .operand_a(operand_a),
      .operand_b(operand_b),
      .rounding_mode(rounding_mode),
      .result(result),
      .flags(flags),
      .result_valid(result_valid),
      .product_a(product_a),
      .product_b(product_b),
      .product(product),
      .product_valid(unused_product_valid)
  );
endmodule

// Product is consumed in the original second pipeline stage.
module rapt_fpu_mul_pipeline #(
    parameter bit TARGET_DOUBLE = 1'b0,
    parameter bit MultiFormat = 1'b0
) (
    input  logic        clock,
    input  logic        reset,
    input  logic        flush,
    input  logic        valid,
    input  logic        target_double,
    output logic        ready,
    input  logic [63:0] operand_a,
    input  logic [63:0] operand_b,
    input  logic [2:0]  rounding_mode,
    output logic [63:0] result,
    output logic [4:0]  flags,
    output logic        result_valid,
    output logic [((TARGET_DOUBLE || MultiFormat) ? 53 : 24)-1:0] product_a,
    product_b,
    output logic product_valid,
    input logic [2*((TARGET_DOUBLE || MultiFormat) ? 53 : 24)-1:0] product
);
  localparam int FracBits = (TARGET_DOUBLE || MultiFormat) ? 52 : 23;
  localparam int SinglePad = FracBits - 23;
  localparam int MantBits = FracBits + 1;
  localparam int ProductBits = 2 * MantBits;
  localparam int ExtBits = (TARGET_DOUBLE || MultiFormat) ? 59 : 27;
  localparam int RoundBits = ExtBits - MantBits;
  // Normalized finite exponents: D [-1074, 1023], S [-149, 127].
  // Their sum plus normalization/rounding is within [-2148, 2048].
  logic format_double_c, s1_double_q, s2_double_q, s3_double_q;
  logic signed [13:0] input_bias_c, input_min_exp_c;
  logic signed [13:0] normalize_min_exp_c, round_min_exp_c, round_max_exp_c, round_bias_c;
  logic [10:0] input_inf_exp_c;
  logic [MantBits-1:0] precision_retained_c;
  logic [ExtBits-1:0] round_mant_c;
  assign format_double_c = MultiFormat ? target_double : TARGET_DOUBLE;
  assign input_bias_c = format_double_c ? 14'sd1023 : 14'sd127;
  assign input_min_exp_c = format_double_c ? -14'sd1022 : -14'sd126;
  assign input_inf_exp_c = format_double_c ? 11'h7ff : 11'h0ff;
  assign normalize_min_exp_c = s2_double_q ? -14'sd1022 : -14'sd126;
  assign round_min_exp_c = s3_double_q ? -14'sd1022 : -14'sd126;
  assign round_max_exp_c = s3_double_q ? 14'sd1023 : 14'sd127;
  assign round_bias_c = s3_double_q ? 14'sd1023 : 14'sd127;

  logic s1_valid_q, s2_valid_q, s3_valid_q, s4_valid_q;

  logic [MantBits-1:0] s1_mant_a_q, s1_mant_b_q;
  logic signed [13:0] s1_exp_a_q, s1_exp_b_q;
  logic s1_result_sign_q, s1_special_q;
  logic [63:0] s1_special_result_q;
  logic [4:0] s1_special_flags_q;
  logic [2:0] s1_rounding_mode_q;

  logic [ProductBits-1:0] s2_product_q;
  logic signed [13:0] s2_exp_sum_q;
  logic s2_result_sign_q, s2_special_q;
  logic [63:0] s2_special_result_q;
  logic [4:0] s2_special_flags_q;
  logic [2:0] s2_rounding_mode_q;

  logic [ExtBits-1:0] s3_mant_q;
  logic signed [13:0] s3_exponent_q;
  logic s3_result_sign_q, s3_special_q;
  logic s3_tiny_q;
  logic [63:0] s3_special_result_q;
  logic [4:0] s3_special_flags_q;
  logic [2:0] s3_rounding_mode_q;

  logic [63:0] result_q;
  logic [4:0] flags_q;

  logic sign_a_c, sign_b_c;
  logic [10:0] exp_a_c, exp_b_c;
  logic [51:0] frac_a_c, frac_b_c;
  logic a_nan_c, b_nan_c, a_snan_c, b_snan_c;
  logic a_inf_c, b_inf_c, a_zero_c, b_zero_c;
  logic [MantBits-1:0] mant_a_c, mant_b_c;
  logic signed [13:0] exponent_a_c, exponent_b_c;
  logic special_c;
  logic [63:0] special_result_c;
  logic [4:0] special_flags_c;

  logic [ProductBits-1:0] product_c;
  logic signed [13:0] exponent_sum_c;

  logic [ExtBits-1:0] stage3_mant_c;
  logic signed [13:0] stage3_exponent_c;
  integer subnormal_shift_c;
  logic stage3_tiny_c, precision_guard_c, precision_sticky_c, precision_up_c;

  logic [63:0] stage4_result_c;
  logic [4:0] stage4_flags_c;
  logic guard_4, sticky_4, inexact_4, round_up_4, hidden_4;
  logic [MantBits:0] rounded_4;
  logic [52:0] significand_4;
  logic signed [13:0] exponent_4;

  function automatic logic [MantBits-1:0] normalize_subnormal(
      input logic [FracBits-1:0] fraction, input logic signed [13:0] min_exponent,
      output logic signed [13:0] exponent_value);
    logic [MantBits-1:0] normalized;
    logic [$clog2(MantBits)-1:0] shift_count;
    begin
      // Keep normalization logarithmic when both formats use the wide window.
      normalized = {1'b0, fraction};
      shift_count = '0;
      for (int stage = $clog2(MantBits) - 1; stage >= 0; stage--) begin
        if ((normalized >> (MantBits - (1 << stage))) == '0) begin
          normalized = normalized << (1 << stage);
          shift_count[stage] = 1'b1;
        end
      end
      exponent_value = fraction == '0 ? min_exponent : min_exponent - $signed(14'(shift_count));
      normalize_subnormal = normalized;
    end
  endfunction

  function automatic logic [ExtBits-1:0] shift_sticky(input logic [ExtBits-1:0] value,
                                                      input integer amount);
    logic [ExtBits-1:0] shifted;
    integer index;
    begin
      shifted = '0;
      if (amount == 0) shifted = value;
      else if (amount >= ExtBits) shifted[0] = |value;
      else begin
        shifted = value >> amount;
        for (index = 0; index < ExtBits; index = index + 1)
        if (index < amount) shifted[0] = shifted[0] | value[index];
      end
      shift_sticky = shifted;
    end
  endfunction

  always_comb begin
    sign_a_c = format_double_c ? operand_a[63] : operand_a[31];
    sign_b_c = format_double_c ? operand_b[63] : operand_b[31];
    if (format_double_c) begin
      exp_a_c = operand_a[62:52];
      exp_b_c = operand_b[62:52];
      frac_a_c = operand_a[51:0];
      frac_b_c = operand_b[51:0];
    end else begin
      exp_a_c = operand_a[63:32] == '1 ? {3'b0, operand_a[30:23]} : 11'h0ff;
      exp_b_c = operand_b[63:32] == '1 ? {3'b0, operand_b[30:23]} : 11'h0ff;
      frac_a_c = operand_a[63:32] == '1
          ? 52'({operand_a[22:0], {SinglePad{1'b0}}}) : 52'({23'h40_0000, {SinglePad{1'b0}}});
      frac_b_c = operand_b[63:32] == '1
          ? 52'({operand_b[22:0], {SinglePad{1'b0}}}) : 52'({23'h40_0000, {SinglePad{1'b0}}});
    end

    a_nan_c = exp_a_c == input_inf_exp_c && frac_a_c[FracBits-1:0] != '0;
    b_nan_c = exp_b_c == input_inf_exp_c && frac_b_c[FracBits-1:0] != '0;
    a_snan_c = a_nan_c && !frac_a_c[FracBits-1];
    b_snan_c = b_nan_c && !frac_b_c[FracBits-1];
    a_inf_c = exp_a_c == input_inf_exp_c && frac_a_c[FracBits-1:0] == '0;
    b_inf_c = exp_b_c == input_inf_exp_c && frac_b_c[FracBits-1:0] == '0;
    a_zero_c = exp_a_c == '0 && frac_a_c[FracBits-1:0] == '0;
    b_zero_c = exp_b_c == '0 && frac_b_c[FracBits-1:0] == '0;

    mant_a_c = '0;
    mant_b_c = '0;
    exponent_a_c = 0;
    exponent_b_c = 0;
    if (exp_a_c == '0) begin
      mant_a_c = normalize_subnormal(frac_a_c[FracBits-1:0], input_min_exp_c, exponent_a_c);
    end else begin
      mant_a_c = {1'b1, frac_a_c[FracBits-1:0]};
      exponent_a_c = $signed({3'b0, exp_a_c}) - input_bias_c;
    end
    if (exp_b_c == '0) begin
      mant_b_c = normalize_subnormal(frac_b_c[FracBits-1:0], input_min_exp_c, exponent_b_c);
    end else begin
      mant_b_c = {1'b1, frac_b_c[FracBits-1:0]};
      exponent_b_c = $signed({3'b0, exp_b_c}) - input_bias_c;
    end

    special_c = 1'b0;
    special_result_c = format_double_c ? 64'h7ff8_0000_0000_0000
        : 64'hffff_ffff_7fc0_0000;
    special_flags_c = '0;
    if (a_nan_c || b_nan_c) begin
      special_c = 1'b1;
      special_flags_c[4] = a_snan_c || b_snan_c;
    end else if ((a_inf_c && b_zero_c) || (b_inf_c && a_zero_c)) begin
      special_c = 1'b1;
      special_flags_c[4] = 1'b1;
    end else if (a_inf_c || b_inf_c) begin
      special_c = 1'b1;
      special_result_c = format_double_c
          ? {sign_a_c ^ sign_b_c, 11'h7ff, 52'b0}
          : {32'hffff_ffff, sign_a_c ^ sign_b_c, 8'hff, 23'b0};
    end else if (a_zero_c || b_zero_c) begin
      special_c = 1'b1;
      special_result_c = format_double_c
          ? {sign_a_c ^ sign_b_c, 63'b0}
          : {32'hffff_ffff, sign_a_c ^ sign_b_c, 31'b0};
    end
  end

  assign product_a = s1_mant_a_q;
  assign product_b = s1_mant_b_q;
  assign product_valid = s1_valid_q;
  assign product_c = product;
  assign exponent_sum_c = s1_exp_a_q + s1_exp_b_q;

  always_comb begin
    stage3_mant_c = '0;
    stage3_exponent_c = s2_exp_sum_q;
    subnormal_shift_c = 0;
    stage3_tiny_c = 1'b0;
    precision_guard_c = 1'b0;
    precision_sticky_c = 1'b0;
    precision_up_c = 1'b0;
    if (s2_product_q[ProductBits-1]) begin
      stage3_mant_c = ExtBits'(s2_product_q >> (ProductBits - ExtBits));
      stage3_mant_c[0] = stage3_mant_c[0]
          | (|s2_product_q[ProductBits-ExtBits-1:0]);
      stage3_exponent_c = s2_exp_sum_q + 1;
    end else begin
      stage3_mant_c = ExtBits'(s2_product_q >> (ProductBits - ExtBits - 1));
      stage3_mant_c[0] = stage3_mant_c[0]
          | (|s2_product_q[ProductBits-ExtBits-2:0]);
    end
    // Detect tininess at target precision with an unbounded exponent,
    // before the subnormal shift reduces available precision.
    round_mant_c = stage3_mant_c;
    if (MultiFormat && !s2_double_q) begin
      round_mant_c = stage3_mant_c >> SinglePad;
      round_mant_c[0] |= |(stage3_mant_c & ExtBits'((64'b1 << SinglePad) - 1));
    end
    precision_retained_c = MantBits'(round_mant_c >> RoundBits);
    precision_guard_c = round_mant_c[RoundBits-1];
    precision_sticky_c = |round_mant_c[RoundBits-2:0];
    case (s2_rounding_mode_q)
      3'b000: precision_up_c = precision_guard_c
          && (precision_sticky_c || round_mant_c[RoundBits]);
      3'b001: precision_up_c = 1'b0;
      3'b010: precision_up_c = (precision_guard_c || precision_sticky_c) && s2_result_sign_q;
      3'b011: precision_up_c = (precision_guard_c || precision_sticky_c) && !s2_result_sign_q;
      3'b100: precision_up_c = precision_guard_c;
      default: precision_up_c = 1'b0;
    endcase
    stage3_tiny_c = (stage3_exponent_c < normalize_min_exp_c)
        && !((stage3_exponent_c == normalize_min_exp_c - 14'sd1) && precision_up_c
             && (s2_double_q ? (&precision_retained_c) : (&precision_retained_c[23:0])));
    stage3_mant_c = round_mant_c;
    if (stage3_exponent_c < normalize_min_exp_c) begin
      subnormal_shift_c = int'(normalize_min_exp_c) - int'(stage3_exponent_c);
      stage3_mant_c = shift_sticky(stage3_mant_c, subnormal_shift_c);
      stage3_exponent_c = normalize_min_exp_c;
    end
  end

  always_comb begin
    stage4_result_c = s3_special_result_q;
    stage4_flags_c = s3_special_flags_q;
    guard_4 = 1'b0;
    sticky_4 = 1'b0;
    inexact_4 = 1'b0;
    round_up_4 = 1'b0;
    rounded_4 = '0;
    significand_4 = '0;
    exponent_4 = s3_exponent_q;
    hidden_4 = 1'b0;

    if (!s3_special_q) begin
      stage4_flags_c = '0;
      guard_4 = s3_mant_q[RoundBits-1];
      sticky_4 = |s3_mant_q[RoundBits-2:0];
      inexact_4 = guard_4 | sticky_4;
      case (s3_rounding_mode_q)
        3'b000: round_up_4 = guard_4
            && (sticky_4 || s3_mant_q[RoundBits]);
        3'b001: round_up_4 = 1'b0;
        3'b010: round_up_4 = inexact_4 && s3_result_sign_q;
        3'b011: round_up_4 = inexact_4 && !s3_result_sign_q;
        3'b100: round_up_4 = guard_4;
        default: round_up_4 = 1'b0;
      endcase
      rounded_4 = {1'b0, s3_mant_q[ExtBits-1-:MantBits]} + round_up_4;
      if (s3_double_q ? rounded_4[MantBits] : rounded_4[24]) begin
        significand_4[MantBits-1:0] = rounded_4[MantBits:1];
        exponent_4 = s3_exponent_q + 1;
      end else begin
        significand_4[MantBits-1:0] = rounded_4[MantBits-1:0];
      end

      hidden_4 = s3_double_q ? significand_4[MantBits-1] : significand_4[23];
      if (exponent_4 > round_max_exp_c) begin
        inexact_4 = 1'b1;
        stage4_flags_c[2] = 1'b1;
        if (s3_rounding_mode_q == 3'b001
            || (s3_rounding_mode_q == 3'b010 && !s3_result_sign_q)
            || (s3_rounding_mode_q == 3'b011 && s3_result_sign_q)) begin
          stage4_result_c = s3_double_q
              ? {s3_result_sign_q, 11'h7fe, 52'hf_ffff_ffff_ffff}
              : {32'hffff_ffff, s3_result_sign_q, 8'hfe, 23'h7f_ffff};
        end else begin
          stage4_result_c = s3_double_q
              ? {s3_result_sign_q, 11'h7ff, 52'b0}
              : {32'hffff_ffff, s3_result_sign_q, 8'hff, 23'b0};
        end
      end else if (exponent_4 == round_min_exp_c && !hidden_4) begin
        stage4_result_c = s3_double_q
            ? {s3_result_sign_q, 11'b0, significand_4[51:0]}
            : {32'hffff_ffff, s3_result_sign_q, 8'b0, significand_4[22:0]};
        stage4_flags_c[1] = inexact_4 && s3_tiny_q;
      end else begin
        stage4_result_c = s3_double_q
            ? {s3_result_sign_q, 11'(exponent_4 + round_bias_c), significand_4[51:0]}
            : {32'hffff_ffff, s3_result_sign_q, 8'(exponent_4 + round_bias_c),
               significand_4[22:0]};
      end
      stage4_flags_c[1] = inexact_4 && s3_tiny_q;
      stage4_flags_c[0] = inexact_4;
    end
  end

  assign ready = !reset && !flush;
  assign result = result_q;
  assign flags = flags_q;
  assign result_valid = s4_valid_q;

  always_ff @(posedge clock) begin
    // Payload is observed only with its valid/state owner. Clear control last.
    s4_valid_q <= s3_valid_q;
    s3_valid_q <= s2_valid_q;
    s2_valid_q <= s1_valid_q;
    s1_valid_q <= valid && ready;
    s1_double_q <= format_double_c;
    s2_double_q <= s1_double_q;
    s3_double_q <= s2_double_q;
    begin
      s1_mant_a_q <= mant_a_c;
      s1_mant_b_q <= mant_b_c;
      s1_exp_a_q <= exponent_a_c;
      s1_exp_b_q <= exponent_b_c;
      s1_result_sign_q <= sign_a_c ^ sign_b_c;
      s1_special_q <= special_c;
      s1_special_result_q <= special_result_c;
      s1_special_flags_q <= special_flags_c;
      s1_rounding_mode_q <= rounding_mode;
    end
    if (s1_valid_q) begin
      s2_product_q <= product_c;
      s2_exp_sum_q <= exponent_sum_c;
      s2_result_sign_q <= s1_result_sign_q;
      s2_special_q <= s1_special_q;
      s2_special_result_q <= s1_special_result_q;
      s2_special_flags_q <= s1_special_flags_q;
      s2_rounding_mode_q <= s1_rounding_mode_q;
    end
    if (s2_valid_q) begin
      s3_mant_q <= stage3_mant_c;
      s3_tiny_q <= stage3_tiny_c;
      s3_exponent_q <= stage3_exponent_c;
      s3_result_sign_q <= s2_result_sign_q;
      s3_special_q <= s2_special_q;
      s3_special_result_q <= s2_special_result_q;
      s3_special_flags_q <= s2_special_flags_q;
      s3_rounding_mode_q <= s2_rounding_mode_q;
    end
    if (s3_valid_q) begin
      result_q <= stage4_result_c;
      flags_q <= stage4_flags_c;
    end
    if (reset || flush) begin
      s1_valid_q <= 1'b0;
      s2_valid_q <= 1'b0;
      s3_valid_q <= 1'b0;
      s4_valid_q <= 1'b0;
    end
  end
endmodule
