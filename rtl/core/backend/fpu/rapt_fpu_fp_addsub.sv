`include "rapt.svh"

// Three-stage, one-operation-per-cycle IEEE-754 floating-point add/sub unit.
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
module rapt_fpu_fp_addsub #(
    parameter bit TARGET_DOUBLE = 1'b0,
    parameter bit MULTI_FORMAT = 1'b0
) (
    input  logic        clock,
    input  logic        reset,
    input  logic        flush,
    input  logic        valid,
    output logic        ready,
    input  logic [5:0]  op,
    input  logic        target_double,
    input  logic [63:0] operand_a,
    input  logic [63:0] operand_b,
    input  logic [2:0]  rounding_mode,
    output logic [63:0] result,
    output logic [4:0]  flags,
    output logic        result_valid
);
  localparam int FracBits = MULTI_FORMAT ? 52 : (TARGET_DOUBLE ? 52 : 23);
  localparam int MantExtBits = FracBits + 4;
  // Single precision occupies the upper lane only in the shared datapath.
  localparam int SingleTail = MULTI_FORMAT ? 29 : 0;
  logic input_double_c, s1_double_q, s2_double_q;
  logic [10:0] inf_exponent_c;
  assign input_double_c = MULTI_FORMAT ? target_double : TARGET_DOUBLE;
  assign inf_exponent_c = input_double_c ? 11'h7ff : 11'h0ff;
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
  logic [MantExtBits-1:0] raw_mant_a_c, raw_mant_b_c;
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

  function automatic [MantExtBits-1:0] shift_sticky(
      input logic [MantExtBits-1:0] value, input integer amount, input logic single_format);
    logic [MantExtBits-1:0] shifted;
    integer tail, index;
    begin
      tail = single_format ? SingleTail : 0;
      shifted = value >> amount;
      if (amount >= MantExtBits - tail) shifted = '0;
      for (index = 0; index < MantExtBits; index++)
      if (index < amount + tail && value[index]) shifted[tail] = 1'b1;
      if (MULTI_FORMAT && single_format) shifted = (shifted >> SingleTail) << SingleTail;
      shift_sticky = shifted;
    end
  endfunction

  // ---------------------- Stage 1: decode + align ------------------------
  always_comb begin
    if (input_double_c) begin
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

    a_nan_c = exp_a_c == inf_exponent_c && frac_a_c != '0;
    b_nan_c = exp_b_c == inf_exponent_c && frac_b_c != '0;
    a_snan_c = a_nan_c && !(input_double_c ? frac_a_c[51] : frac_a_c[22]);
    b_snan_c = b_nan_c && !(input_double_c ? frac_b_c[51] : frac_b_c[22]);
    a_inf_c = exp_a_c == inf_exponent_c && frac_a_c == '0;
    b_inf_c = exp_b_c == inf_exponent_c && frac_b_c == '0;
    is_sub_c = sign_a_c != sign_b_c;

    exp_common_c = exp_a_c > exp_b_c ? exp_a_c : exp_b_c;
    raw_mant_a_c = input_double_c ? {exp_a_c != 0, frac_a_c, 3'b0}
        : MantExtBits'({exp_a_c != 0, frac_a_c[22:0], 3'b0}) << SingleTail;
    raw_mant_b_c = input_double_c ? {exp_b_c != 0, frac_b_c, 3'b0}
        : MantExtBits'({exp_b_c != 0, frac_b_c[22:0], 3'b0}) << SingleTail;
    mant_a_c = raw_mant_a_c;
    mant_b_c = raw_mant_b_c;
    /* Subnormal operands are aligned as if their exponent were Emin (1).
     * When both are subnormal (exp_common == 0) no shift is applied. */
    aligned_a_c = shift_sticky(mant_a_c,
      (exp_common_c == 0) ? 0 : int'(exp_common_c) - (exp_a_c == 0 ? 1 : int'(exp_a_c)),
      !input_double_c);
    aligned_b_c = shift_sticky(mant_b_c,
      (exp_common_c == 0) ? 0 : int'(exp_common_c) - (exp_b_c == 0 ? 1 : int'(exp_b_c)),
      !input_double_c);

    special_c = 1'b0;
    special_result_c = input_double_c ? 64'h7ff8_0000_0000_0000
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
        special_result_c = input_double_c ? {sign_a_c, 11'h7ff, 52'b0}
          : {32'hffff_ffff, sign_a_c, 8'hff, 23'b0};
      end else begin
        special_result_c = input_double_c ? {sign_b_c, 11'h7ff, 52'b0}
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
  logic [LzcBits-1:0] shift_clamped_c;
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
        lzc_c = LzcBits'(MantExtBits - 1 - i);
        lzc_found_c = 1'b1;
      end
    end

    s2_mant_c = '0;
    s2_exponent_c = s1_exponent_q;
    shift_clamped_c = '0;
    if (!s1_is_sub_q) begin
      // Addition: at most a single right shift (carry out).
      if (sum_c[MantExtBits]) begin
        s2_mant_c = sum_c[MantExtBits:1];
        if (MULTI_FORMAT && !s1_double_q) begin
          s2_mant_c = (s2_mant_c >> SingleTail) << SingleTail;
          s2_mant_c[SingleTail] = s2_mant_c[SingleTail] | (|sum_c[SingleTail:0]);
        end else s2_mant_c[0] = s2_mant_c[0] | sum_c[0];
        s2_exponent_c = s1_exponent_q + 1;
      end else begin
        s2_mant_c = sum_c[MantExtBits-1:0];
      end
    end else begin
      // Subtraction: normalize with one barrel shift; clamp at Emin.
      if (diff_c != 0) begin
        if (int'(lzc_c) < int'(s1_exponent_q) - 1) begin
          s2_mant_c = diff_c << lzc_c;
          s2_exponent_c = s1_exponent_q - 14'(lzc_c);
        end else begin
          // This branch has exponent-1 <= lzc <= MantExtBits-1.
          shift_clamped_c = s1_exponent_q > 1 ? LzcBits'(s1_exponent_q - 1) : '0;
          s2_mant_c = diff_c << shift_clamped_c;
          s2_exponent_c = 14'sd1;
        end
      end
    end
  end

  // ---------------------- Stage 3: round + pack --------------------------
  logic inexact_3, round_up_3, guard_3, sticky_3, carry_3;
  logic [52:0] retained_3, significand_3;
  logic [53:0] rounded_3;
  logic signed [13:0] exponent_3;
  logic double_3;
  always_comb begin
    double_3 = MULTI_FORMAT ? s2_double_q : TARGET_DOUBLE;
    stage3_result_c = s2_special_result_q;
    stage3_flags_c = s2_special_flags_q;
    inexact_3 = 1'b0;
    round_up_3 = 1'b0;
    guard_3 = 1'b0;
    sticky_3 = 1'b0;
    carry_3 = 1'b0;
    retained_3 = '0;
    significand_3 = '0;
    rounded_3 = '0;
    exponent_3 = s2_exponent_q;

    if (!s2_special_q) begin
      stage3_flags_c = '0;
      if (s2_mant_q == 0) begin
        stage3_result_c = double_3
          ? {(s2_signs_equal_q ? s2_sign_a_q
              : (s2_rounding_mode_q == 3'b010)), 63'b0}
          : {32'hffff_ffff,
             (s2_signs_equal_q ? s2_sign_a_q
              : (s2_rounding_mode_q == 3'b010)), 31'b0};
      end else begin
        if (double_3) begin
          retained_3 = 53'(s2_mant_q >> 3);
          guard_3 = s2_mant_q[2];
          sticky_3 = |s2_mant_q[1:0];
        end else if (MULTI_FORMAT) begin
          retained_3 = 53'(s2_mant_q >> (SingleTail + 3));
          guard_3 = s2_mant_q[SingleTail+2];
          sticky_3 = |s2_mant_q[SingleTail+1:SingleTail];
        end else begin
          retained_3 = 53'(s2_mant_q >> 3);
          guard_3 = s2_mant_q[2];
          sticky_3 = |s2_mant_q[1:0];
        end
        inexact_3 = guard_3 || sticky_3;
        case (s2_rounding_mode_q)
          3'b000: round_up_3 = guard_3 && (sticky_3 || retained_3[0]);
          3'b001: round_up_3 = 1'b0;
          3'b010: round_up_3 = inexact_3 && s2_result_sign_q;
          3'b011: round_up_3 = inexact_3 && !s2_result_sign_q;
          3'b100: round_up_3 = guard_3;
          default: round_up_3 = 1'b0;
        endcase
        rounded_3 = {1'b0, retained_3} + round_up_3;
        carry_3 = double_3 ? rounded_3[53] : rounded_3[24];
        if (carry_3) begin
          significand_3 = 53'(rounded_3 >> 1);
          exponent_3 = s2_exponent_q + 1;
        end else significand_3 = rounded_3[52:0];
        if (exponent_3 >= (double_3 ? 2047 : 255)) begin
          stage3_flags_c[2] = 1'b1;
          inexact_3 = 1'b1;
          if (s2_rounding_mode_q == 3'b001
              || (s2_rounding_mode_q == 3'b010 && !s2_result_sign_q)
              || (s2_rounding_mode_q == 3'b011 && s2_result_sign_q)) begin
            stage3_result_c = double_3
              ? {s2_result_sign_q, 11'h7fe, 52'hf_ffff_ffff_ffff}
              : {32'hffff_ffff, s2_result_sign_q, 8'hfe, 23'h7f_ffff};
          end else begin
            stage3_result_c = double_3
              ? {s2_result_sign_q, 11'h7ff, 52'b0}
              : {32'hffff_ffff, s2_result_sign_q, 8'hff, 23'b0};
          end
        end else if (exponent_3 == 1 && !significand_3[double_3?52 : 23]) begin
          stage3_result_c = double_3
            ? {s2_result_sign_q, 11'b0, significand_3[51:0]}
            : {32'hffff_ffff, s2_result_sign_q, 8'b0, significand_3[22:0]};
          stage3_flags_c[1] = inexact_3;
        end else begin
          stage3_result_c = double_3
            ? {s2_result_sign_q, exponent_3[10:0], significand_3[51:0]}
            : {32'hffff_ffff, s2_result_sign_q, exponent_3[7:0], significand_3[22:0]};
        end
      end
      stage3_flags_c[0] = inexact_3;
      if (stage3_flags_c[4]) stage3_flags_c[0] = 1'b0;
    end
  end

  assign ready = !reset && !flush;
  assign result = result_q;
  assign flags = flags_q;
  assign result_valid = s3_valid_q;

  always_ff @(posedge clock) begin
    // Payload is observed only with its valid/state owner. Clear control last.
    s3_valid_q <= s2_valid_q;
    s2_valid_q <= s1_valid_q;
    s1_valid_q <= valid && ready;
    begin
      s1_double_q <= input_double_c;
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
      s2_double_q <= s1_double_q;
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
    if (reset || flush) begin
      s1_valid_q <= 1'b0;
      s2_valid_q <= 1'b0;
      s3_valid_q <= 1'b0;
    end
  end
endmodule
