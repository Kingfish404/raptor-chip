`include "rapt.svh"

// Six-stage, one-operation-at-a-time IEEE-754 fused multiply-add unit.
//
// Stage 1: decode/normalize operands and calculate the mantissa product.
// Stage 2: align the product/addend in the fixed-point work window.
// Stage 3: calculate the signed sum with a parallel-prefix adder.
// Stage 4: apply the discarded-bit correction and form the magnitude.
// Stage 5: calculate the leading-one position.
// Stage 6: normalize, round, and pack the architectural result.
//
// The unit deliberately exposes a ready/valid boundary. The FPU execution
// pipe holds the ROB metadata while this unit is occupied and writes the FPR
// only with result_valid. This creates real RTL timing boundaries; no FPGA
// multicycle exception is required for the FMA datapath.

// A technology-independent parallel-prefix adder prevents wide FMA sums from
// degrading into a linear ripple-carry chain in standard-cell synthesis.  The
// prefix network has O(log2(WIDTH)) logic depth and intentionally drops carry
// out, matching SystemVerilog's fixed-width addition semantics.
module rapt_fpu_prefix_adder #(
    parameter int WIDTH = 256
) (
    input  logic [WIDTH-1:0] lhs,
    input  logic [WIDTH-1:0] rhs,
    output logic [WIDTH-1:0] sum
);
  localparam int LEVELS = $clog2(WIDTH);
  wire [WIDTH-1:0] bit_propagate;
  wire [WIDTH-1:0] prefix_generate[0:LEVELS];
  wire [WIDTH-1:0] prefix_propagate[0:LEVELS];

  assign bit_propagate = lhs ^ rhs;
  assign prefix_generate[0] = lhs & rhs;
  assign prefix_propagate[0] = bit_propagate;

  for (genvar level = 0; level < LEVELS; level++) begin : gen_prefix_level
    localparam int DISTANCE = 1 << level;
    for (genvar bit_index = 0; bit_index < WIDTH; bit_index++) begin : gen_prefix_bit
      if (bit_index >= DISTANCE) begin : gen_combine
        assign prefix_generate[level+1][bit_index] =
            prefix_generate[level][bit_index]
            | (prefix_propagate[level][bit_index]
               & prefix_generate[level][bit_index-DISTANCE]);
        assign prefix_propagate[level+1][bit_index] =
            prefix_propagate[level][bit_index]
            & prefix_propagate[level][bit_index-DISTANCE];
      end else begin : gen_pass
        assign prefix_generate[level+1][bit_index] = prefix_generate[level][bit_index];
        assign prefix_propagate[level+1][bit_index] = prefix_propagate[level][bit_index];
      end
    end
  end

  assign sum[0] = bit_propagate[0];
  for (genvar bit_index = 1; bit_index < WIDTH; bit_index++) begin : gen_sum_bit
    assign sum[bit_index] = bit_propagate[bit_index]
        ^ prefix_generate[LEVELS][bit_index-1];
  end
endmodule

module rapt_fpu_fma #(
    parameter bit TARGET_DOUBLE = 1'b0
) (
    input  logic        clock,
    input  logic        reset,
    input  logic        flush,
    input  logic        valid,
    output logic        ready,
    input  logic [5:0]  op,
    input  logic [63:0] operand_a,
    input  logic [63:0] operand_b,
    input  logic [63:0] operand_c,
    input  logic [2:0]  rounding_mode,
    output logic [63:0] result,
    output logic [4:0]  flags,
    output logic        result_valid
);
  localparam int FracBits = TARGET_DOUBLE ? 52 : 23;
  localparam int MantBits = FracBits + 1;
  localparam int ProductBits = 2 * MantBits;
  // Enough room for the product, retained precision, and sticky information.
  // Alignment shifts beyond this window are saturated into sticky bits.
  localparam int WorkBits = TARGET_DOUBLE ? 256 : 128;
  localparam int ExpBias = TARGET_DOUBLE ? 1023 : 127;
  localparam int MinExp = TARGET_DOUBLE ? -1022 : -126;
  localparam int MaxExp = TARGET_DOUBLE ? 1023 : 127;
  localparam int InfExponent = TARGET_DOUBLE ? 11'h7ff : 11'h0ff;
  localparam int LeadingBits = $clog2(WorkBits + 1);
  localparam int LeadingGroupBits = 16;
  localparam int LeadingGroups = WorkBits / LeadingGroupBits;

  function automatic logic [LeadingBits-1:0] find_leading_one(input logic [WorkBits-1:0] value);
    logic [LeadingGroups-1:0] group_nonzero;
    logic group_found;
    logic bit_found;
    begin
      for (int group_index = 0; group_index < LeadingGroups; group_index++)
      group_nonzero[group_index] = |value[group_index*LeadingGroupBits+:LeadingGroupBits];

      find_leading_one = '0;
      group_found = 1'b0;
      for (int group_index = LeadingGroups - 1; group_index >= 0; group_index--) begin
        if (!group_found && group_nonzero[group_index]) begin
          bit_found = 1'b0;
          for (int bit_index = LeadingGroupBits - 1; bit_index >= 0; bit_index--) begin
            if (!bit_found && value[group_index*LeadingGroupBits+bit_index]) begin
              find_leading_one = LeadingBits'(
                group_index * LeadingGroupBits + bit_index + 1);
              bit_found = 1'b1;
            end
          end
          group_found = 1'b1;
        end
      end
    end
  endfunction

  logic s1_valid_q, align_valid_q, s2_valid_q, s3_valid_q, s4_valid_q, s5_valid_q;

  logic [MantBits-1:0] s1_mant_a_q, s1_mant_b_q, s1_mant_c_q;
  logic [ProductBits-1:0] s1_product_q;
  logic signed [13:0] s1_exp_a_q, s1_exp_b_q, s1_exp_c_q;
  logic s1_product_sign_q, s1_addend_sign_q;
  logic s1_product_zero_q, s1_addend_zero_q;
  logic s1_special_q;
  logic [63:0] s1_special_result_q;
  logic [4:0] s1_special_flags_q;
  logic [2:0] s1_rounding_mode_q;

  logic [WorkBits-1:0] align_product_term_q, align_addend_term_q;
  logic align_product_sign_q, align_addend_sign_q, align_discarded_sign_q;
  logic signed [13:0] align_common_base_q;
  logic align_zero_sign_q, align_sticky_q;
  logic align_special_q;
  logic [63:0] align_special_result_q;
  logic [4:0] align_special_flags_q;
  logic [2:0] align_rounding_mode_q;

  logic signed [WorkBits-1:0] s2_total_q;
  logic signed [13:0] s2_common_base_q;
  logic s2_result_sign_q, s2_discarded_sign_q;
  logic s2_sticky_q;
  logic s2_special_q;
  logic [63:0] s2_special_result_q;
  logic [4:0] s2_special_flags_q;
  logic [2:0] s2_rounding_mode_q;

  logic [WorkBits-1:0] s3_magnitude_q;
  logic signed [13:0] s3_common_base_q;
  logic s3_result_sign_q;
  logic s3_zero_sign_q;
  logic s3_sticky_q;
  logic s3_special_q;
  logic [63:0] s3_special_result_q;
  logic [4:0] s3_special_flags_q;
  logic [2:0] s3_rounding_mode_q;

  logic [WorkBits-1:0] s4_magnitude_q;
  logic [LeadingBits-1:0] s4_leading_one_q;
  logic signed [13:0] s4_common_base_q;
  logic s4_result_sign_q;
  logic s4_zero_sign_q;
  logic s4_sticky_q;
  logic s4_special_q;
  logic [63:0] s4_special_result_q;
  logic [4:0] s4_special_flags_q;
  logic [2:0] s4_rounding_mode_q;

  logic [63:0] result_q;
  logic [4:0] flags_q;

  logic sign_a_c, sign_b_c, sign_c_c;
  logic [10:0] exp_a_c, exp_b_c, exp_c_c;
  logic [FracBits-1:0] frac_a_c, frac_b_c, frac_c_c;
  logic [MantBits-1:0] mant_a_c, mant_b_c, mant_c_c;
  logic signed [13:0] exponent_a_c, exponent_b_c, exponent_c_c;
  logic product_sign_c, addend_sign_c;
  logic a_nan_c, b_nan_c, c_nan_c;
  logic a_snan_c, b_snan_c, c_snan_c;
  logic a_inf_c, b_inf_c, c_inf_c;
  logic a_zero_c, b_zero_c, c_zero_c;
  logic special_c;
  logic [63:0] special_result_c;
  logic [4:0] special_flags_c;
  logic [ProductBits-1:0] product_c;

  logic [WorkBits-1:0] align_product_term_c, align_addend_term_c;
  logic signed [13:0] align_common_base_c;
  logic align_zero_sign_c, align_sticky_c, align_discarded_sign_c;
  logic align_special_c;
  logic [63:0] align_special_result_c;
  logic [4:0] align_special_flags_c;

  logic [WorkBits-1:0] signed_product_c, signed_addend_c, sign_bias_c;
  logic [WorkBits-1:0] carry_save_sum_c, carry_save_carry_c;
  logic [WorkBits-1:0] s2_total_c;
  logic [WorkBits-1:0] magnitude_base_c, magnitude_adjust_c, s3_magnitude_c;
  logic s3_result_sign_c;
  logic [LeadingBits-1:0] s4_leading_one_c;
  logic [63:0] stage4_result_c;
  logic [4:0] stage4_flags_c;

  /* Normalize a subnormal fraction to an internal (mantissa, exponent) pair
   * with the leading one at bit MantBits-1.  Internal convention:
   *     value = mantissa * 2^(exponent - FracBits)
   * A subnormal operand has value fraction * 2^(MinExp - FracBits), so with
   * the leading one at bit FracBits the exponent is
   *     E = MinExp - FracBits + index_of_leading_one.
   * The previous code returned E = index - (FracBits-1), dropping the MinExp
   * base and corrupting every subnormal operand (e.g. double min-subnormal
   * 2^-1074 was interpreted as ~2^-51). */
  function automatic logic [MantBits-1:0] normalize_subnormal(
      input logic [FracBits-1:0] fraction, output logic signed [13:0] exponent_adjust);
    logic [MantBits-1:0] normalized;
    integer index;
    begin
      normalized = '0;
      exponent_adjust = MinExp;
      for (index = FracBits - 1; index >= 0; index = index - 1) begin
        if (fraction[index] && normalized == '0) begin
          normalized = {1'b0, fraction} << (MantBits - index - 1);
          exponent_adjust = MinExp - FracBits + index;
        end
      end
      normalize_subnormal = normalized;
    end
  endfunction

  always_comb begin
    sign_a_c = TARGET_DOUBLE ? operand_a[63] : operand_a[31];
    sign_b_c = TARGET_DOUBLE ? operand_b[63] : operand_b[31];
    sign_c_c = TARGET_DOUBLE ? operand_c[63] : operand_c[31];
    exp_a_c = TARGET_DOUBLE ? operand_a[62:52] : {3'b0, operand_a[30:23]};
    exp_b_c = TARGET_DOUBLE ? operand_b[62:52] : {3'b0, operand_b[30:23]};
    exp_c_c = TARGET_DOUBLE ? operand_c[62:52] : {3'b0, operand_c[30:23]};
    frac_a_c = TARGET_DOUBLE ? operand_a[51:0] : operand_a[22:0];
    frac_b_c = TARGET_DOUBLE ? operand_b[51:0] : operand_b[22:0];
    frac_c_c = TARGET_DOUBLE ? operand_c[51:0] : operand_c[22:0];

    product_sign_c = sign_a_c ^ sign_b_c
      ^ (TARGET_DOUBLE
        ? (op == `RAPT_FP_OP_FNMSUB_D || op == `RAPT_FP_OP_FNMADD_D)
        : (op == `RAPT_FP_OP_FNMSUB_S || op == `RAPT_FP_OP_FNMADD_S));
    addend_sign_c = sign_c_c
      ^ (TARGET_DOUBLE
        ? (op == `RAPT_FP_OP_FMSUB_D || op == `RAPT_FP_OP_FNMADD_D)
        : (op == `RAPT_FP_OP_FMSUB_S || op == `RAPT_FP_OP_FNMADD_S));

    a_nan_c = exp_a_c == InfExponent && frac_a_c != '0;
    b_nan_c = exp_b_c == InfExponent && frac_b_c != '0;
    c_nan_c = exp_c_c == InfExponent && frac_c_c != '0;
    a_snan_c = a_nan_c && !frac_a_c[FracBits-1];
    b_snan_c = b_nan_c && !frac_b_c[FracBits-1];
    c_snan_c = c_nan_c && !frac_c_c[FracBits-1];
    a_inf_c = exp_a_c == InfExponent && frac_a_c == '0;
    b_inf_c = exp_b_c == InfExponent && frac_b_c == '0;
    c_inf_c = exp_c_c == InfExponent && frac_c_c == '0;
    a_zero_c = exp_a_c == '0 && frac_a_c == '0;
    b_zero_c = exp_b_c == '0 && frac_b_c == '0;
    c_zero_c = exp_c_c == '0 && frac_c_c == '0;
    exponent_a_c = exp_a_c == 0 ? MinExp : $signed({1'b0, exp_a_c}) - ExpBias;
    exponent_b_c = exp_b_c == 0 ? MinExp : $signed({1'b0, exp_b_c}) - ExpBias;
    exponent_c_c = exp_c_c == 0 ? MinExp : $signed({1'b0, exp_c_c}) - ExpBias;

    mant_a_c = exp_a_c == 0 ? normalize_subnormal(frac_a_c, exponent_a_c)
                             : {1'b1, frac_a_c};
    mant_b_c = exp_b_c == 0 ? normalize_subnormal(frac_b_c, exponent_b_c)
                             : {1'b1, frac_b_c};
    mant_c_c = exp_c_c == 0 ? normalize_subnormal(frac_c_c, exponent_c_c)
                             : {1'b1, frac_c_c};
    if (a_zero_c) mant_a_c = '0;
    if (b_zero_c) mant_b_c = '0;
    if (c_zero_c) mant_c_c = '0;
    special_result_c = TARGET_DOUBLE ? 64'h7ff8_0000_0000_0000
      : {32'hffff_ffff, 32'h7fc0_0000};
    special_flags_c = {a_snan_c || b_snan_c || c_snan_c, 4'b0};
    special_c = a_nan_c || b_nan_c || c_nan_c
      || (a_inf_c && b_zero_c) || (a_zero_c && b_inf_c)
      || (!a_nan_c && !b_nan_c && (a_inf_c || b_inf_c) && c_inf_c
        && addend_sign_c != product_sign_c)
      || a_inf_c || b_inf_c || c_inf_c;
    if (a_nan_c || b_nan_c || c_nan_c
        || (a_inf_c && b_zero_c) || (a_zero_c && b_inf_c)
        || (!a_nan_c && !b_nan_c && (a_inf_c || b_inf_c) && c_inf_c
          && addend_sign_c != product_sign_c)) begin
      special_result_c = TARGET_DOUBLE ? 64'h7ff8_0000_0000_0000
        : {32'hffff_ffff, 32'h7fc0_0000};
      special_flags_c[4] = special_flags_c[4]
        || (a_inf_c && b_zero_c) || (a_zero_c && b_inf_c)
        || (!a_nan_c && !b_nan_c && (a_inf_c || b_inf_c) && c_inf_c
          && addend_sign_c != product_sign_c);
    end else if (a_inf_c || b_inf_c) begin
      special_result_c = TARGET_DOUBLE ? {product_sign_c, 11'h7ff, 52'b0}
        : {32'hffff_ffff, product_sign_c, 8'hff, 23'b0};
    end else if (c_inf_c) begin
      special_result_c = TARGET_DOUBLE ? {addend_sign_c, 11'h7ff, 52'b0}
        : {32'hffff_ffff, addend_sign_c, 8'hff, 23'b0};
    end
    product_c = mant_a_c * mant_b_c;
  end

  always_comb begin
    logic [WorkBits-1:0] product_term;
    logic [WorkBits-1:0] addend_term;
    logic signed [13:0] product_base;
    logic signed [13:0] addend_base;
    logic signed [13:0] common_base;
    logic signed [14:0] base_delta;
    logic signed [14:0] product_shift;
    logic signed [14:0] addend_shift;
    logic product_discarded;
    logic addend_discarded;
    logic discarded_sign;

    align_product_term_c = '0;
    align_addend_term_c = '0;
    align_common_base_c = '0;
    /* Preserve the sign of the nonzero term when the other FMA term is
     * exactly zero.  The opposite-sign/RDN rule applies only when two
     * nonzero magnitudes cancel exactly. */
    align_zero_sign_c = (s1_product_zero_q && s1_addend_zero_q)
      ? ((s1_product_sign_q == s1_addend_sign_q)
        ? s1_product_sign_q
        : (s1_rounding_mode_q == 3'b010))
      : s1_product_zero_q
        ? s1_addend_sign_q
        : s1_addend_zero_q
          ? s1_product_sign_q
          : (s1_product_sign_q == s1_addend_sign_q)
            ? s1_product_sign_q
            : (s1_rounding_mode_q == 3'b010);
    align_sticky_c = 1'b0;
    align_discarded_sign_c = 1'b0;
    align_special_c = s1_special_q;
    align_special_result_c = s1_special_result_q;
    align_special_flags_c = s1_special_flags_q;
    product_term = '0;
    addend_term = '0;
    product_discarded = 1'b0;
    addend_discarded = 1'b0;
    discarded_sign = 1'b0;
    /* A zero operand makes the product/addend identically zero; its (useless)
     * placeholder exponent MinExp must NOT drag the fixed-point base down,
     * otherwise the other term's shift saturates WorkBits and the value is
     * lost (e.g. fmadd.d(x, 0, min_subnormal) dropped the addend). */
    product_base = s1_product_zero_q
      ? s1_exp_c_q - FracBits
      : s1_exp_a_q + s1_exp_b_q - (2 * FracBits);
    addend_base = s1_exp_c_q - FracBits;
    base_delta = 15'(product_base) - 15'(addend_base);
    /* Prefer the lower exponent when the complete product and addend fit in
     * the fixed-point window.  Keeping only a sticky bit for a discarded
     * opposite-sign addend loses the borrow/carry at the rounding boundary
     * (e.g. fmsub.s 0x7 * 0x73741824 - 0xa0, a 1-ULP RNE error). */
    /* s2_total_c is signed; leave one top bit as sign headroom.  Allowing
     * the aligned product to occupy bit WorkBits-1 turns a large positive
     * product into a negative value and can produce -inf instead of +inf. */
    if (base_delta >= 0) begin
      if (base_delta <= WorkBits - 1 - ProductBits) begin
        common_base = addend_base;
        product_shift = -base_delta;
        addend_shift = '0;
      end else begin
        common_base = product_base - ProductBits;
        product_shift = -ProductBits;
        addend_shift = base_delta - ProductBits;
      end
    end else begin
      if (-base_delta <= WorkBits - 1 - ProductBits) begin
        common_base = product_base;
        product_shift = '0;
        addend_shift = base_delta;
      end else begin
        common_base = addend_base - ProductBits;
        product_shift = -base_delta - ProductBits;
        addend_shift = -ProductBits;
      end
    end

    if (!s1_special_q) begin
      if (product_shift < 0) begin
        product_term = WorkBits'(s1_product_q) <<< (-product_shift);
      end else if (product_shift >= WorkBits) begin
        product_discarded = |s1_product_q;
      end else begin
        product_term = WorkBits'(s1_product_q) >> product_shift;
        for (integer index = 0; index < ProductBits; index = index + 1)
        if (index < product_shift) product_discarded = product_discarded || s1_product_q[index];
      end
      if (addend_shift < 0) begin
        addend_term = WorkBits'(s1_mant_c_q) <<< (-addend_shift);
      end else if (addend_shift >= WorkBits) begin
        addend_discarded = |s1_mant_c_q;
      end else begin
        addend_term = WorkBits'(s1_mant_c_q) >> addend_shift;
        for (integer index = 0; index < MantBits; index = index + 1)
        if (index < addend_shift) addend_discarded = addend_discarded || s1_mant_c_q[index];
      end
      discarded_sign = product_discarded
        ? s1_product_sign_q : s1_addend_sign_q;
      align_product_term_c = product_term;
      align_addend_term_c = addend_term;
      align_common_base_c = common_base;
      align_sticky_c = product_discarded || addend_discarded;
      align_discarded_sign_c = discarded_sign;
    end
  end

  // Convert both aligned magnitudes to two's-complement operands without a
  // carry-propagating negation.  A carry-save compressor folds in the two
  // sign-bias bits; only the following prefix network propagates carry.
  always_comb begin
    signed_product_c = align_product_term_q ^ {WorkBits{align_product_sign_q}};
    signed_addend_c = align_addend_term_q ^ {WorkBits{align_addend_sign_q}};
    sign_bias_c = '0;
    sign_bias_c[1:0] = {
      align_product_sign_q & align_addend_sign_q,
      align_product_sign_q ^ align_addend_sign_q
    };
    carry_save_sum_c = signed_product_c ^ signed_addend_c ^ sign_bias_c;
    carry_save_carry_c = ((signed_product_c & signed_addend_c)
        | (signed_product_c & sign_bias_c)
        | (signed_addend_c & sign_bias_c)) << 1;
  end

  rapt_fpu_prefix_adder #(.WIDTH(WorkBits)) u_total_adder (
      .lhs(carry_save_sum_c),
      .rhs(carry_save_carry_c),
      .sum(s2_total_c)
  );

  // Fold the one-ULP discarded-bit correction into the absolute-value
  // operation.  This needs one more prefix addition, but no linear negation.
  always_comb begin
    magnitude_base_c = '0;
    magnitude_adjust_c = '0;
    s3_result_sign_c = s2_total_q[WorkBits-1];
    if (!s2_total_q[WorkBits-1]) begin
      magnitude_base_c = s2_total_q;
      if (s2_sticky_q && s2_discarded_sign_q) begin
        if (s2_total_q == '0) begin
          magnitude_adjust_c[0] = 1'b1;
          s3_result_sign_c = 1'b1;
        end else begin
          magnitude_adjust_c = '1;
        end
      end
    end else begin
      magnitude_base_c = ~s2_total_q;
      if (s2_sticky_q && !s2_discarded_sign_q) begin
        if (s2_total_q == '1) s3_result_sign_c = 1'b0;
      end else begin
        magnitude_adjust_c[0] = 1'b1;
      end
    end
  end

  rapt_fpu_prefix_adder #(.WIDTH(WorkBits)) u_magnitude_adder (
      .lhs(magnitude_base_c),
      .rhs(magnitude_adjust_c),
      .sum(s3_magnitude_c)
  );

  always_comb begin
    logic [WorkBits-1:0] magnitude_aligned;
    logic [FracBits:0] retained;
    logic [FracBits+1:0] rounded;
    logic result_sign;
    logic guard_bit, sticky_bit, inexact, round_up, invalid;
    logic signed [13:0] exponent_value;
    logic [10:0] result_exponent;
    integer shift_amount;
    integer index;

    stage4_result_c = s4_special_result_q;
    stage4_flags_c = s4_special_flags_q;
    result_sign = s4_result_sign_q;
    retained = '0;
    rounded = '0;
    guard_bit = 1'b0;
    sticky_bit = s4_sticky_q;
    inexact = 1'b0;
    round_up = 1'b0;
    invalid = 1'b0;
    exponent_value = '0;
    result_exponent = '0;
    shift_amount = 0;
    magnitude_aligned = '0;

    if (!s4_special_q && s4_leading_one_q == 0) begin
      /* Exact zero OR total underflow to zero.  If sticky captured discarded
       * bits (tiny product shifted below the WorkBits window), the true value
       * is nonzero but rounds to zero: raise NX and UF per IEEE 754. */
      round_up = s4_sticky_q
        && ((s4_rounding_mode_q == 3'b010 && s4_zero_sign_q)
          || (s4_rounding_mode_q == 3'b011 && !s4_zero_sign_q));
      stage4_result_c = TARGET_DOUBLE
        ? {s4_zero_sign_q, 62'b0, round_up}
        : {32'hffff_ffff, s4_zero_sign_q, 30'b0, round_up};
      stage4_flags_c[0] = s4_sticky_q;
      stage4_flags_c[1] = s4_sticky_q;
    end else if (!s4_special_q) begin
      exponent_value = 14'(s4_leading_one_q) + s4_common_base_q - 1;
      shift_amount = integer'(s4_leading_one_q) > MantBits
        ? integer'(s4_leading_one_q) - MantBits : 0;
      if (exponent_value < MinExp) shift_amount = shift_amount + (MinExp - exponent_value);
      if (shift_amount >= WorkBits) begin
        retained = '0;
        guard_bit = 1'b0;
        sticky_bit = sticky_bit || (|s4_magnitude_q);
      end else begin
        magnitude_aligned = shift_amount == 0
          ? s4_magnitude_q << (MantBits - integer'(s4_leading_one_q))
          : s4_magnitude_q >> shift_amount;
        retained = magnitude_aligned[MantBits-1:0];
        guard_bit = shift_amount > 0
          ? s4_magnitude_q[shift_amount - 1] : 1'b0;
        if (shift_amount > 1)
          for (index = 0; index < WorkBits; index = index + 1)
          if (index < shift_amount - 1) sticky_bit = sticky_bit || s4_magnitude_q[index];
      end
      inexact = guard_bit || sticky_bit;
      case (s4_rounding_mode_q)
        3'b000: round_up = guard_bit && (sticky_bit || retained[0]);
        3'b001: round_up = 1'b0;
        3'b010: round_up = inexact && result_sign;
        3'b011: round_up = inexact && !result_sign;
        3'b100: round_up = guard_bit;
        default: round_up = 1'b0;
      endcase
      rounded = {1'b0, retained} + round_up;
      if (rounded[FracBits+1]) begin
        retained = rounded[FracBits+1:1];
        exponent_value = exponent_value + 1;
      end else begin
        retained = rounded[FracBits:0];
      end
      invalid = 1'b0;
      if (exponent_value > MaxExp) begin
        stage4_flags_c[2] = 1'b1;
        stage4_flags_c[0] = 1'b1;
        if (s4_rounding_mode_q == 3'b001
          || (s4_rounding_mode_q == 3'b010 && !result_sign)
          || (s4_rounding_mode_q == 3'b011 && result_sign))
          stage4_result_c = TARGET_DOUBLE
            ? {result_sign, 11'h7fe, 52'hf_ffff_ffff_ffff}
            : {32'hffff_ffff, result_sign, 8'hfe, 23'h7f_ffff};
        else
          stage4_result_c = TARGET_DOUBLE
            ? {result_sign, 11'h7ff, 52'b0}
            : {32'hffff_ffff, result_sign, 8'hff, 23'b0};
      end else if (exponent_value < MinExp
          || (exponent_value == MinExp && !retained[FracBits])) begin
        stage4_result_c = TARGET_DOUBLE
          ? {result_sign, 11'b0, retained[51:0]}
          : {32'hffff_ffff, result_sign, 8'b0, retained[22:0]};
        stage4_flags_c[1] = inexact;
        stage4_flags_c[0] = inexact;
      end else begin
        result_exponent = exponent_value + ExpBias;
        stage4_result_c = TARGET_DOUBLE
          ? {result_sign, result_exponent, retained[51:0]}
          : {32'hffff_ffff, result_sign, result_exponent[7:0], retained[22:0]};
        stage4_flags_c[0] = inexact;
      end
    end
  end

  always_comb s4_leading_one_c = find_leading_one(s3_magnitude_q);

  assign ready = !(s1_valid_q || align_valid_q || s2_valid_q
    || s3_valid_q || s4_valid_q || s5_valid_q);
  assign result = result_q;
  assign flags = flags_q;
  assign result_valid = s5_valid_q;

  always_ff @(posedge clock) begin
    if (reset || flush) begin
      s1_valid_q <= 1'b0;
      align_valid_q <= 1'b0;
      s2_valid_q <= 1'b0;
      s3_valid_q <= 1'b0;
      s4_valid_q <= 1'b0;
      s5_valid_q <= 1'b0;
      result_q <= '0;
      flags_q <= '0;
    end else begin
      s5_valid_q <= s4_valid_q;
      s4_valid_q <= s3_valid_q;
      s3_valid_q <= s2_valid_q;
      s2_valid_q <= align_valid_q;
      align_valid_q <= s1_valid_q;
      s1_valid_q <= valid && ready;
      if (valid && ready) begin
        s1_mant_a_q <= mant_a_c;
        s1_mant_b_q <= mant_b_c;
        s1_mant_c_q <= mant_c_c;
        s1_product_q <= product_c;
        s1_exp_a_q <= exponent_a_c;
        s1_exp_b_q <= exponent_b_c;
        s1_exp_c_q <= exponent_c_c;
        s1_product_sign_q <= product_sign_c;
        s1_addend_sign_q <= addend_sign_c;
        s1_product_zero_q <= a_zero_c || b_zero_c;
        s1_addend_zero_q <= c_zero_c;
        s1_special_q <= special_c;
        s1_special_result_q <= special_result_c;
        s1_special_flags_q <= special_flags_c;
        s1_rounding_mode_q <= rounding_mode;
      end
      if (s1_valid_q) begin
        align_product_term_q <= align_product_term_c;
        align_addend_term_q <= align_addend_term_c;
        align_product_sign_q <= s1_product_sign_q;
        align_addend_sign_q <= s1_addend_sign_q;
        align_discarded_sign_q <= align_discarded_sign_c;
        align_common_base_q <= align_common_base_c;
        align_zero_sign_q <= align_zero_sign_c;
        align_sticky_q <= align_sticky_c;
        align_special_q <= align_special_c;
        align_special_result_q <= align_special_result_c;
        align_special_flags_q <= align_special_flags_c;
        align_rounding_mode_q <= s1_rounding_mode_q;
      end
      if (align_valid_q) begin
        s2_total_q <= s2_total_c;
        s2_common_base_q <= align_common_base_q;
        s2_result_sign_q <= align_zero_sign_q;
        s2_discarded_sign_q <= align_discarded_sign_q;
        s2_sticky_q <= align_sticky_q;
        s2_special_q <= align_special_q;
        s2_special_result_q <= align_special_result_q;
        s2_special_flags_q <= align_special_flags_q;
        s2_rounding_mode_q <= align_rounding_mode_q;
      end
      if (s2_valid_q) begin
        s3_magnitude_q <= s3_magnitude_c;
        s3_common_base_q <= s2_common_base_q;
        s3_result_sign_q <= s3_result_sign_c;
        s3_zero_sign_q <= s2_result_sign_q;
        s3_sticky_q <= s2_sticky_q;
        s3_special_q <= s2_special_q;
        s3_special_result_q <= s2_special_result_q;
        s3_special_flags_q <= s2_special_flags_q;
        s3_rounding_mode_q <= s2_rounding_mode_q;
      end
      if (s3_valid_q) begin
        s4_magnitude_q <= s3_magnitude_q;
        s4_leading_one_q <= s4_leading_one_c;
        s4_common_base_q <= s3_common_base_q;
        s4_result_sign_q <= s3_result_sign_q;
        s4_zero_sign_q <= s3_zero_sign_q;
        s4_sticky_q <= s3_sticky_q;
        s4_special_q <= s3_special_q;
        s4_special_result_q <= s3_special_result_q;
        s4_special_flags_q <= s3_special_flags_q;
        s4_rounding_mode_q <= s3_rounding_mode_q;
      end
      if (s4_valid_q) begin
        result_q <= stage4_result_c;
        flags_q <= stage4_flags_c;
      end
    end
  end
endmodule
