`include "rapt.svh"

module rapt_fpu_convert_narrow (
    input  logic        clock,
    input  logic        reset,
    input  logic        flush,
    input  logic        valid,
    output logic        ready,
    input  logic [63:0] operand,
    input  logic [2:0]  rounding_mode,
    output logic [63:0] result,
    output logic [4:0]  flags,
    output logic        result_valid
);
  logic s1_valid_q, s2_valid_q, s3_valid_q;

  logic s1_sign_q, s1_special_q;
  logic signed [12:0] s1_exponent_q;
  logic [52:0] s1_significand_q;
  logic [63:0] s1_special_result_q;
  logic [4:0] s1_special_flags_q;
  logic [2:0] s1_rounding_mode_q;

  logic s2_sign_q, s2_normal_q, s2_guard_q, s2_sticky_q;
  logic s2_special_q;
  logic signed [12:0] s2_exponent_q;
  logic [23:0] s2_retained_q;
  logic [63:0] s2_special_result_q;
  logic [4:0] s2_special_flags_q;
  logic [2:0] s2_rounding_mode_q;

  logic [63:0] result_q;
  logic [4:0] flags_q;

  logic sign_c;
  logic [10:0] exponent_c;
  logic [51:0] fraction_c;
  logic signed [12:0] exponent_value_c;
  logic [52:0] significand_c;
  logic special_c;
  logic [63:0] special_result_c;
  logic [4:0] special_flags_c;
  logic leading_found_c;
  integer leading_index_c;
  integer leading_scan_index_c;

  logic normal_c;
  logic [23:0] retained_c;
  logic guard_c, sticky_c;
  integer shift_count_c;
  integer sticky_index_c;

  logic [63:0] stage3_result_c;
  logic [4:0] stage3_flags_c;
  logic inexact_c, round_up_c;
  logic [24:0] rounded_c;
  logic signed [12:0] rounded_exponent_c;

  always_comb begin
    sign_c = operand[63];
    exponent_c = operand[62:52];
    fraction_c = operand[51:0];
    exponent_value_c = '0;
    significand_c = '0;
    special_c = 1'b0;
    special_result_c = 64'hffff_ffff_7fc0_0000;
    special_flags_c = '0;
    leading_found_c = 1'b0;
    leading_index_c = 0;

    if (exponent_c == 11'h7ff) begin
      special_c = 1'b1;
      if (fraction_c == '0)
        special_result_c = {32'hffff_ffff, sign_c, 8'hff, 23'b0};
      else
        special_flags_c[4] = !fraction_c[51];
    end else if (exponent_c == '0 && fraction_c == '0) begin
      special_c = 1'b1;
      special_result_c = {32'hffff_ffff, sign_c, 31'b0};
    end else if (exponent_c == '0) begin
      for (leading_scan_index_c = 51; leading_scan_index_c >= 0;
           leading_scan_index_c = leading_scan_index_c - 1) begin
        if (!leading_found_c && fraction_c[leading_scan_index_c]) begin
          leading_index_c = leading_scan_index_c;
          leading_found_c = 1'b1;
        end
      end
      significand_c = {1'b0, fraction_c} << (52 - leading_index_c);
      exponent_value_c = 13'(-1022 - (52 - leading_index_c));
    end else begin
      significand_c = {1'b1, fraction_c};
      exponent_value_c = $signed({1'b0, exponent_c}) - 13'sd1023;
    end
  end

  always_comb begin
    normal_c = s1_exponent_q >= -13'sd126;
    shift_count_c = normal_c ? 29 : -integer'(s1_exponent_q) - 97;
    retained_c = '0;
    guard_c = 1'b0;
    sticky_c = 1'b0;
    if (shift_count_c < 64)
      retained_c = 24'(s1_significand_q >> shift_count_c);
    if (shift_count_c > 0 && shift_count_c <= 53)
      guard_c = s1_significand_q[shift_count_c - 1];
    if (shift_count_c > 53)
      sticky_c = |s1_significand_q;
    else if (shift_count_c > 1)
      for (sticky_index_c = 0; sticky_index_c < 53;
           sticky_index_c = sticky_index_c + 1)
        if (sticky_index_c < shift_count_c - 1)
          sticky_c = sticky_c | s1_significand_q[sticky_index_c];
  end

  always_comb begin
    stage3_result_c = s2_special_result_q;
    stage3_flags_c = s2_special_flags_q;
    inexact_c = s2_guard_q | s2_sticky_q;
    round_up_c = 1'b0;
    rounded_c = '0;
    rounded_exponent_c = s2_exponent_q;

    if (!s2_special_q) begin
      stage3_result_c = 64'hffff_ffff_0000_0000;
      stage3_flags_c = '0;
      case (s2_rounding_mode_q)
        3'b000: round_up_c = s2_guard_q && (s2_sticky_q || s2_retained_q[0]);
        3'b001: round_up_c = 1'b0;
        3'b010: round_up_c = inexact_c && s2_sign_q;
        3'b011: round_up_c = inexact_c && !s2_sign_q;
        3'b100: round_up_c = s2_guard_q;
        default: round_up_c = 1'b0;
      endcase
      rounded_c = {1'b0, s2_retained_q} + round_up_c;

      if (s2_normal_q) begin
        rounded_exponent_c = s2_exponent_q + rounded_c[24];
        if (rounded_exponent_c > 127) begin
          stage3_flags_c[2] = 1'b1;
          stage3_flags_c[0] = 1'b1;
          if (s2_rounding_mode_q == 3'b001
              || (s2_rounding_mode_q == 3'b011 && s2_sign_q)
              || (s2_rounding_mode_q == 3'b010 && !s2_sign_q))
            stage3_result_c[31:0] = {s2_sign_q, 8'hfe, 23'h7f_ffff};
          else
            stage3_result_c[31:0] = {s2_sign_q, 8'hff, 23'b0};
        end else begin
          stage3_result_c[31:0] = {
              s2_sign_q, 8'(rounded_exponent_c + 127), rounded_c[22:0]};
          stage3_flags_c[0] = inexact_c;
        end
      end else begin
        stage3_result_c[31:0] = rounded_c[23]
            ? {s2_sign_q, 8'h01, 23'b0}
            : {s2_sign_q, 8'h00, rounded_c[22:0]};
        stage3_flags_c[1] = inexact_c && !rounded_c[23];
        stage3_flags_c[0] = inexact_c;
      end
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
        s1_sign_q <= sign_c;
        s1_exponent_q <= exponent_value_c;
        s1_significand_q <= significand_c;
        s1_special_q <= special_c;
        s1_special_result_q <= special_result_c;
        s1_special_flags_q <= special_flags_c;
        s1_rounding_mode_q <= rounding_mode;
      end
      if (s1_valid_q) begin
        s2_sign_q <= s1_sign_q;
        s2_exponent_q <= s1_exponent_q;
        s2_normal_q <= normal_c;
        s2_retained_q <= retained_c;
        s2_guard_q <= guard_c;
        s2_sticky_q <= sticky_c;
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
