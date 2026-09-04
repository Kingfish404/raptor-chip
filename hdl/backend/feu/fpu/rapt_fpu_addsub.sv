`include "rapt.svh"

// Three-stage, one-operation-at-a-time IEEE-754 floating-point add/sub unit.
//
// Stage 1: decode operands, classify specials, align mantissas with sticky.
// Stage 2: add/subtract aligned mantissas and normalize (priority-encoded
//          leading-zero count plus one barrel shift, replacing the old
//          serial normalization loop that dominated the FPU critical path).
// Stage 3: round, pack, and raise flags.
//
// The unit exposes the same ready/valid/flush boundary as rapt_fpu_fma so
// the FPU execution pipe can treat it as a generic long-latency op: metadata
// is held at launch and the FPR/ROB/flags are written only at completion.
module rapt_fpu_addsub #(
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
    input  logic [2:0]  rounding_mode,
    output logic [63:0] result,
    output logic [4:0]  flags,
    output logic        result_valid
);
  localparam int FracBits = TARGET_DOUBLE ? 52 : 23;
  localparam int MantExtBits = FracBits + 4;
  localparam int ExpBias = TARGET_DOUBLE ? 1023 : 127;
  localparam int MaxExponent = TARGET_DOUBLE ? 2047 : 255;
  localparam int InfExponent = TARGET_DOUBLE ? 11'h7ff : 11'h0ff;
  localparam int LzcBits = $clog2(MantExtBits + 1);

  logic s1_valid_q, s2_valid_q, s3_valid_q;

  // ---- Stage 1 -> 2 registers -------------------------------------------
  logic [MantExtBits-1:0] s1_aligned_a_q, s1_aligned_b_q;
  logic s1_is_sub_q;
  logic s1_sign_a_q, s1_sign_b_q;
  logic s1_signs_equal_q;
  logic signed [13:0] s1_exponent_q;
  logic s1_special_q;
  logic [63:0] s1_special_result_q;
  logic [4:0] s1_special_flags_q;
  logic [2:0] s1_rounding_mode_q;

  // ---- Stage 2 -> 3 registers -------------------------------------------
  logic [MantExtBits-1:0] s2_mant_q;
  logic signed [13:0] s2_exponent_q;
  logic s2_result_sign_q;
  logic s2_signs_equal_q;
  logic s2_sign_a_q;
  logic s2_special_q;
  logic [63:0] s2_special_result_q;
  logic [4:0] s2_special_flags_q;
  logic [2:0] s2_rounding_mode_q;

  logic [63:0] result_q;
  logic [4:0] flags_q;

  // ---- Stage 1 combinational --------------------------------------------
  logic sign_a_c, sign_b_c;
  logic [10:0] exp_a_c, exp_b_c;
  logic [51:0] frac_a_c, frac_b_c;
  logic a_nan_c, b_nan_c, a_snan_c, b_snan_c, a_inf_c, b_inf_c;
  logic is_sub_c;
  logic [10:0] exp_common_c;
  logic [MantExtBits-1:0] mant_a_c, mant_b_c;
  logic [MantExtBits-1:0] aligned_a_c, aligned_b_c;
  logic special_c;
  logic [63:0] special_result_c;
  logic [4:0] special_flags_c;

  // ---- Stage 2 combinational --------------------------------------------
  logic [MantExtBits-1:0] s2_mant_c;
  logic signed [13:0] s2_exponent_c;
  logic s2_result_sign_c;

  // ---- Stage 3 combinational --------------------------------------------
  logic [63:0] stage3_result_c;
  logic [4:0] stage3_flags_c;

  function automatic [MantExtBits-1:0] shift_sticky(input logic [MantExtBits-1:0] value,
                                                    input integer amount);
    logic [MantExtBits-1:0] shifted;
    integer index;
    begin
      shifted = '0;
      if (amount == 0) shifted = value;
      else if (amount >= MantExtBits) shifted[0] = |value;
      else begin
        shifted = value >> amount;
        for (index = 0; index < MantExtBits; index = index + 1)
        if (index < amount) shifted[0] = shifted[0] | value[index];
      end
      shift_sticky = shifted;
    end
  endfunction

  // ---------------------- Stage 1: decode + align ------------------------
  always_comb begin
    if (TARGET_DOUBLE) begin
      sign_a_c = operand_a[63];
      sign_b_c = operand_b[63] ^ (op == `RAPT_FP_OP_FSUB_D);
      exp_a_c = operand_a[62:52];
      exp_b_c = operand_b[62:52];
      frac_a_c = operand_a[51:0];
      frac_b_c = operand_b[51:0];
    end else begin
      sign_a_c = operand_a[31];
      sign_b_c = operand_b[31] ^ (op == `RAPT_FP_OP_FSUB_S);
      // In an FLEN=64 implementation, every single-precision source must be
      // NaN-boxed.  An unboxed source is consumed as canonical qNaN.  Keep
      // the synthetic exponent in the single-precision domain: using 0x7ff
      // here fails the comparison against InfExponent (0x0ff), so the bad
      // box would incorrectly flow through the finite datapath.
      exp_a_c = operand_a[63:32] == '1 ? {3'b0, operand_a[30:23]} : 11'h0ff;
      exp_b_c = operand_b[63:32] == '1 ? {3'b0, operand_b[30:23]} : 11'h0ff;
      frac_a_c = operand_a[63:32] == '1
        ? {29'b0, operand_a[22:0]} : {29'b0, 1'b1, 22'b0};
      frac_b_c = operand_b[63:32] == '1
        ? {29'b0, operand_b[22:0]} : {29'b0, 1'b1, 22'b0};
    end

    a_nan_c = exp_a_c == InfExponent && frac_a_c[FracBits-1:0] != '0;
    b_nan_c = exp_b_c == InfExponent && frac_b_c[FracBits-1:0] != '0;
    a_snan_c = a_nan_c && !frac_a_c[FracBits-1];
    b_snan_c = b_nan_c && !frac_b_c[FracBits-1];
    a_inf_c = exp_a_c == InfExponent && frac_a_c[FracBits-1:0] == '0;
    b_inf_c = exp_b_c == InfExponent && frac_b_c[FracBits-1:0] == '0;
    is_sub_c = sign_a_c != sign_b_c;

    exp_common_c = exp_a_c > exp_b_c ? exp_a_c : exp_b_c;
    mant_a_c = {exp_a_c != 0, frac_a_c[FracBits-1:0], 3'b0};
    mant_b_c = {exp_b_c != 0, frac_b_c[FracBits-1:0], 3'b0};
    /* Subnormal operands are aligned as if their exponent were Emin (1).
     * When both are subnormal (exp_common == 0) no shift is applied. */
    aligned_a_c = shift_sticky(mant_a_c,
      (exp_common_c == 0) ? 0 : exp_common_c - (exp_a_c == 0 ? 1 : exp_a_c));
    aligned_b_c = shift_sticky(mant_b_c,
      (exp_common_c == 0) ? 0 : exp_common_c - (exp_b_c == 0 ? 1 : exp_b_c));

    special_c = 1'b0;
    special_result_c = TARGET_DOUBLE ? 64'h7ff8_0000_0000_0000
      : {32'hffff_ffff, 32'h7fc0_0000};
    special_flags_c = '0;

    if (a_nan_c || b_nan_c) begin
      special_c = 1'b1;
      special_flags_c[4] = a_snan_c || b_snan_c;
    end else if (a_inf_c || b_inf_c) begin
      special_c = 1'b1;
      if (a_inf_c && b_inf_c && is_sub_c) begin
        special_flags_c[4] = 1'b1;
      end else if (a_inf_c) begin
        special_result_c = TARGET_DOUBLE ? {sign_a_c, 11'h7ff, 52'b0}
          : {32'hffff_ffff, sign_a_c, 8'hff, 23'b0};
      end else begin
        special_result_c = TARGET_DOUBLE ? {sign_b_c, 11'h7ff, 52'b0}
          : {32'hffff_ffff, sign_b_c, 8'hff, 23'b0};
      end
    end
  end

  // --------------- Stage 2: add/sub + normalize --------------------------
  // Priority-encoded leading-zero count and a single barrel shift replace
  // the old bit-serial normalization loop (the dominant critical path).
  logic [MantExtBits:0] sum_c;
  logic [MantExtBits-1:0] diff_c;
  logic [LzcBits-1:0] lzc_c;
  logic lzc_found_c;
  logic signed [13:0] shift_clamped_c;
  always_comb begin
    sum_c = {1'b0, s1_aligned_a_q} + {1'b0, s1_aligned_b_q};
    diff_c = '0;
    s2_result_sign_c = s1_sign_a_q;
    if (s1_aligned_a_q >= s1_aligned_b_q) diff_c = s1_aligned_a_q - s1_aligned_b_q;
    else diff_c = s1_aligned_b_q - s1_aligned_a_q;
    if (s1_aligned_b_q > s1_aligned_a_q) s2_result_sign_c = s1_sign_b_q;

    // Leading-zero count of the subtraction result (priority encoder).
    lzc_c = '0;
    lzc_found_c = 1'b0;
    for (int i = MantExtBits - 1; i >= 0; i--) begin
      if (!lzc_found_c && diff_c[i]) begin
        lzc_c = MantExtBits - 1 - i;
        lzc_found_c = 1'b1;
      end
    end

    s2_mant_c = '0;
    s2_exponent_c = s1_exponent_q;
    shift_clamped_c = 14'sd0;
    if (!s1_is_sub_q) begin
      // Addition: at most a single right shift (carry out).
      if (sum_c[MantExtBits]) begin
        s2_mant_c = sum_c[MantExtBits:1];
        s2_mant_c[0] = s2_mant_c[0] | sum_c[0];
        s2_exponent_c = s1_exponent_q + 1;
      end else begin
        s2_mant_c = sum_c[MantExtBits-1:0];
      end
    end else begin
      // Subtraction: normalize with one barrel shift; clamp at Emin.
      if (diff_c != 0) begin
        if (lzc_c < s1_exponent_q - 1) begin
          s2_mant_c = diff_c << lzc_c;
          s2_exponent_c = s1_exponent_q - 14'(lzc_c);
        end else begin
          shift_clamped_c = s1_exponent_q > 1 ? s1_exponent_q - 1 : 14'sd0;
          s2_mant_c = diff_c << shift_clamped_c[5:0];
          s2_exponent_c = 14'sd1;
        end
      end
    end
  end

  // ---------------------- Stage 3: round + pack --------------------------
  logic inexact_3, round_up_3;
  logic [FracBits+1:0] rounded_sum_3;
  logic [FracBits:0] rounded_significand_3;
  logic signed [13:0] exponent_3;
  always_comb begin
    stage3_result_c = s2_special_result_q;
    stage3_flags_c = s2_special_flags_q;
    inexact_3 = 1'b0;
    round_up_3 = 1'b0;
    rounded_sum_3 = '0;
    rounded_significand_3 = '0;
    exponent_3 = s2_exponent_q;

    if (!s2_special_q) begin
      stage3_flags_c = '0;
      if (s2_mant_q == 0) begin
        // Exact zero: sign follows rounding mode for exact cancellation.
        stage3_result_c = TARGET_DOUBLE
          ? {(s2_signs_equal_q ? s2_sign_a_q
              : (s2_rounding_mode_q == 3'b010)), 63'b0}
          : {32'hffff_ffff,
             (s2_signs_equal_q ? s2_sign_a_q
              : (s2_rounding_mode_q == 3'b010)), 31'b0};
      end else begin
        inexact_3 = |s2_mant_q[2:0];
        case (s2_rounding_mode_q)
          3'b000: round_up_3 = s2_mant_q[2]
            && (s2_mant_q[1] || s2_mant_q[0] || s2_mant_q[3]);
          3'b001: round_up_3 = 1'b0;
          3'b010: round_up_3 = inexact_3 && s2_result_sign_q;
          3'b011: round_up_3 = inexact_3 && !s2_result_sign_q;
          3'b100: round_up_3 = s2_mant_q[2];
          default: round_up_3 = 1'b0;
        endcase
        rounded_sum_3 = {1'b0, s2_mant_q[MantExtBits-1:3]} + round_up_3;
        if (rounded_sum_3[FracBits+1]) begin
          rounded_significand_3 = rounded_sum_3[FracBits+1:1];
          exponent_3 = s2_exponent_q + 1;
        end else begin
          rounded_significand_3 = rounded_sum_3[FracBits:0];
        end
        if (exponent_3 >= MaxExponent) begin
          // Overflow.  IEEE 754 overflow always implies inexact.
          stage3_flags_c[2] = 1'b1;
          inexact_3 = 1'b1;
          if (s2_rounding_mode_q == 3'b001
              || (s2_rounding_mode_q == 3'b010 && !s2_result_sign_q)
              || (s2_rounding_mode_q == 3'b011 && s2_result_sign_q)) begin
            stage3_result_c = TARGET_DOUBLE
              ? {s2_result_sign_q, 11'h7fe, 52'hf_ffff_ffff_ffff}
              : {32'hffff_ffff, s2_result_sign_q, 8'hfe, 23'h7f_ffff};
          end else begin
            stage3_result_c = TARGET_DOUBLE
              ? {s2_result_sign_q, 11'h7ff, 52'b0}
              : {32'hffff_ffff, s2_result_sign_q, 8'hff, 23'b0};
          end
        end else if (exponent_3 == 1 && !rounded_significand_3[FracBits]) begin
          // Subnormal result.
          stage3_result_c = TARGET_DOUBLE
            ? {s2_result_sign_q, 11'b0, rounded_significand_3[51:0]}
            : {32'hffff_ffff, s2_result_sign_q, 8'b0,
               rounded_significand_3[22:0]};
          stage3_flags_c[1] = inexact_3;
        end else begin
          stage3_result_c = TARGET_DOUBLE
            ? {s2_result_sign_q, exponent_3[10:0], rounded_significand_3[51:0]}
            : {32'hffff_ffff, s2_result_sign_q, exponent_3[7:0],
               rounded_significand_3[22:0]};
        end
      end
      stage3_flags_c[0] = inexact_3;
      if (stage3_flags_c[4]) stage3_flags_c[0] = 1'b0;
    end
  end

  assign ready = !(s1_valid_q || s2_valid_q || s3_valid_q);
  assign result = result_q;
  assign flags = flags_q;
  assign result_valid = s3_valid_q;

  always_ff @(posedge clock) begin
    if (reset || flush) begin
      s1_valid_q <= 1'b0;
      s2_valid_q <= 1'b0;
      s3_valid_q <= 1'b0;
      result_q <= '0;
      flags_q <= '0;
    end else begin
      s3_valid_q <= s2_valid_q;
      s2_valid_q <= s1_valid_q;
      s1_valid_q <= valid && ready;
      if (valid && ready) begin
        s1_aligned_a_q <= aligned_a_c;
        s1_aligned_b_q <= aligned_b_c;
        s1_is_sub_q <= is_sub_c;
        s1_sign_a_q <= sign_a_c;
        s1_sign_b_q <= sign_b_c;
        s1_signs_equal_q <= sign_a_c == sign_b_c;
        s1_exponent_q <= exp_common_c == 0 ? 14'sd1 : {3'b0, exp_common_c};
        s1_special_q <= special_c;
        s1_special_result_q <= special_result_c;
        s1_special_flags_q <= special_flags_c;
        s1_rounding_mode_q <= rounding_mode;
      end
      if (s1_valid_q) begin
        s2_mant_q <= s2_mant_c;
        s2_exponent_q <= s2_exponent_c;
        s2_result_sign_q <= s2_result_sign_c;
        s2_signs_equal_q <= s1_signs_equal_q;
        s2_sign_a_q <= s1_sign_a_q;
        s2_special_q <= s1_special_q;
        s2_special_result_q <= s1_special_result_q;
        s2_special_flags_q <= s1_special_flags_q;
        s2_rounding_mode_q <= s1_rounding_mode_q;
      end
      if (s2_valid_q) begin
        result_q <= stage3_result_c;
        flags_q <= stage3_flags_c;
      end
    end
  end
endmodule
