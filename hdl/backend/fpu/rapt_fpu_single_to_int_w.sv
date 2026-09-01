`include "rapt.svh"

module rapt_fpu_single_to_int_w #(
    parameter bit SOURCE_DOUBLE = 1'b0
) (
    input  logic        clock,
    input  logic        reset,
    input  logic        flush,
    input  logic        valid,
    output logic        ready,
    input  logic [63:0] operand,
    input  logic        unsigned_result,
    input  logic        int64_target,
    input  logic [2:0]  rounding_mode,
    output logic [63:0] result,
    output logic [4:0]  flags,
    output logic        result_valid
);
  localparam int FracBits = SOURCE_DOUBLE ? 52 : 23;
  localparam logic signed [13:0] FracBitsSigned = SOURCE_DOUBLE ? 14'sd52 : 14'sd23;
  localparam logic signed [13:0] Bias = SOURCE_DOUBLE ? 1023 : 127;
  localparam logic signed [13:0] MinExponent = SOURCE_DOUBLE ? -1022 : -126;
  localparam logic [10:0] InfExponent = SOURCE_DOUBLE ? 11'h7ff : 11'h0ff;

  logic s1_valid_q, s2_valid_q, s3_valid_q;
  logic s1_sign_q, s1_nan_q, s1_inf_q, s1_zero_q;
  logic s1_unsigned_q, s1_int64_q;
  logic signed [13:0] s1_exponent_q;
  logic [52:0] s1_significand_q;
  logic [2:0] s1_rounding_mode_q;

  logic s2_sign_q, s2_nan_q, s2_inf_q, s2_invalid_q;
  logic s2_unsigned_q, s2_int64_q, s2_guard_q, s2_sticky_q;
  logic [63:0] s2_magnitude_q;
  logic [2:0] s2_rounding_mode_q;

  logic [63:0] result_q;
  logic [4:0] flags_q;

  logic [10:0] exponent_c;
  logic [51:0] fraction_c;
  logic sign_c, nan_c, inf_c, zero_c;
  logic signed [13:0] unbiased_exponent_c;
  logic [52:0] significand_c;

  logic [63:0] magnitude_c;
  logic guard_c, sticky_c, invalid_c;
  integer shift_count_c, sticky_index_c;

  logic [63:0] stage3_result_c, rounded_magnitude_c, int_result_c;
  logic [4:0] stage3_flags_c;
  logic inexact_c, round_up_c, range_invalid_c;

  always_comb begin
    sign_c = SOURCE_DOUBLE ? operand[63] : operand[31];
    if (SOURCE_DOUBLE) begin
      exponent_c = operand[62:52];
      fraction_c = operand[51:0];
    end else begin
      exponent_c = operand[63:32] == '1 ? {3'b0, operand[30:23]} : 11'h0ff;
      fraction_c = operand[63:32] == '1
          ? {29'b0, operand[22:0]} : {29'b0, 23'h40_0000};
    end
    nan_c = exponent_c == InfExponent && fraction_c[FracBits-1:0] != '0;
    inf_c = exponent_c == InfExponent && fraction_c[FracBits-1:0] == '0;
    zero_c = exponent_c == '0 && fraction_c[FracBits-1:0] == '0;
    unbiased_exponent_c = exponent_c == '0 ? MinExponent
      : $signed({3'b0, exponent_c}) - Bias;
    significand_c = '0;
    significand_c[FracBits:0] = {
        exponent_c != '0, fraction_c[FracBits-1:0]};
  end

  always_comb begin
    magnitude_c = '0;
    guard_c = 1'b0;
    sticky_c = 1'b0;
    invalid_c = s1_nan_q || s1_inf_q || s1_exponent_q > 63;
    shift_count_c = 0;
    if (!s1_zero_q && !s1_nan_q && !s1_inf_q) begin
      if (s1_exponent_q >= FracBitsSigned) begin
        shift_count_c = int'(s1_exponent_q) - FracBits;
        if (s1_exponent_q <= 63) magnitude_c = {11'b0, s1_significand_q} << shift_count_c;
      end else begin
        shift_count_c = FracBits - int'(s1_exponent_q);
        if (shift_count_c < 64) magnitude_c = {11'b0, s1_significand_q} >> shift_count_c;
        if (shift_count_c > 0 && shift_count_c <= FracBits + 1)
          guard_c = s1_significand_q[shift_count_c-1];
        if (shift_count_c > FracBits + 1) sticky_c = |s1_significand_q;
        else if (shift_count_c > 1)
          for (
              sticky_index_c = 0; sticky_index_c < FracBits + 1; sticky_index_c = sticky_index_c + 1
          )
          if (sticky_index_c < shift_count_c - 1)
            sticky_c = sticky_c | s1_significand_q[sticky_index_c];
      end
    end
  end

  always_comb begin
    inexact_c = s2_guard_q | s2_sticky_q;
    round_up_c = 1'b0;
    case (s2_rounding_mode_q)
      3'b000: round_up_c = s2_guard_q
          && (s2_sticky_q || s2_magnitude_q[0]);
      3'b001: round_up_c = 1'b0;
      3'b010: round_up_c = inexact_c && s2_sign_q;
      3'b011: round_up_c = inexact_c && !s2_sign_q;
      3'b100: round_up_c = s2_guard_q;
      default: round_up_c = 1'b0;
    endcase
    rounded_magnitude_c = s2_magnitude_q + round_up_c;
    range_invalid_c = s2_invalid_q;
    if (!s2_nan_q && !s2_inf_q && !s2_invalid_q) begin
      if (s2_unsigned_q)
        range_invalid_c = (s2_sign_q && rounded_magnitude_c != '0)
            || (!s2_int64_q && rounded_magnitude_c > 64'hffff_ffff);
      else if (s2_sign_q)
        range_invalid_c = !s2_int64_q
            ? rounded_magnitude_c > 64'h0000_0000_8000_0000
            : rounded_magnitude_c > 64'h8000_0000_0000_0000;
      else
        range_invalid_c = !s2_int64_q
            ? rounded_magnitude_c > 64'h0000_0000_7fff_ffff
            : rounded_magnitude_c > 64'h7fff_ffff_ffff_ffff;
    end

    int_result_c = s2_sign_q && !s2_unsigned_q
        ? (~rounded_magnitude_c + 64'd1) : rounded_magnitude_c;
    if (range_invalid_c) begin
      if (s2_int64_q) begin
        if (s2_unsigned_q) int_result_c = s2_sign_q && !s2_nan_q ? 64'b0 : {64{1'b1}};
        else
          int_result_c = s2_nan_q ? 64'h7fff_ffff_ffff_ffff
              : (s2_sign_q ? 64'h8000_0000_0000_0000
                            : 64'h7fff_ffff_ffff_ffff);
      end else if (s2_unsigned_q) begin
        int_result_c = s2_sign_q && !s2_nan_q ? 64'b0 : 64'h0000_0000_ffff_ffff;
      end else begin
        int_result_c = s2_nan_q ? 64'h0000_0000_7fff_ffff
            : (s2_sign_q ? 64'h0000_0000_8000_0000
                         : 64'h0000_0000_7fff_ffff);
      end
    end
    stage3_result_c = s2_int64_q
        ? int_result_c : {{32{int_result_c[31]}}, int_result_c[31:0]};
    stage3_flags_c = '0;
    stage3_flags_c[4] = range_invalid_c;
    stage3_flags_c[0] = inexact_c && !range_invalid_c;
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
        s1_sign_q <= sign_c;
        s1_nan_q <= nan_c;
        s1_inf_q <= inf_c;
        s1_zero_q <= zero_c;
        s1_unsigned_q <= unsigned_result;
        s1_int64_q <= int64_target;
        s1_exponent_q <= unbiased_exponent_c;
        s1_significand_q <= significand_c;
        s1_rounding_mode_q <= rounding_mode;
      end
      if (s1_valid_q) begin
        s2_sign_q <= s1_sign_q;
        s2_nan_q <= s1_nan_q;
        s2_inf_q <= s1_inf_q;
        s2_invalid_q <= invalid_c;
        s2_unsigned_q <= s1_unsigned_q;
        s2_int64_q <= s1_int64_q;
        s2_magnitude_q <= magnitude_c;
        s2_guard_q <= guard_c;
        s2_sticky_q <= sticky_c;
        s2_rounding_mode_q <= s1_rounding_mode_q;
      end
      if (s2_valid_q) begin
        result_q <= stage3_result_c;
        flags_q <= stage3_flags_c;
      end
    end
  end
endmodule
