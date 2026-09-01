`include "rapt.svh"

module rapt_fpu_int_to_fp #(
    parameter bit TARGET_DOUBLE = 1'b0,
    parameter bit INT64_INPUT   = 1'b0
) (
    input  logic        clock,
    input  logic        reset,
    input  logic        flush,
    input  logic        valid,
    output logic        ready,
    input  logic [63:0] operand,
    input  logic        unsigned_input,
    input  logic [2:0]  rounding_mode,
    output logic [63:0] result,
    output logic [4:0]  flags,
    output logic        result_valid
);
  localparam int Precision = TARGET_DOUBLE ? 53 : 24;
  localparam int Bias = TARGET_DOUBLE ? 1023 : 127;

  logic s1_valid_q, s2_valid_q, s3_valid_q;
  logic s1_sign_q;
  logic [63:0] s1_magnitude_q;
  logic [6:0] s1_leading_one_q;
  logic [2:0] s1_rounding_mode_q;

  logic s2_sign_q, s2_guard_q, s2_sticky_q, s2_zero_q;
  logic [63:0] s2_retained_q;
  logic [6:0] s2_leading_one_q;
  logic [2:0] s2_rounding_mode_q;

  logic [63:0] result_q;
  logic [4:0] flags_q;

  logic [63:0] source_c, magnitude_c;
  logic sign_c, leading_found_c;
  logic [6:0] leading_one_c;
  integer leading_index_c;

  logic [63:0] retained_c;
  logic guard_c, sticky_c;
  integer shift_count_c;
  integer sticky_index_c;

  logic [63:0] stage3_result_c;
  logic [4:0] stage3_flags_c;
  logic inexact_c, round_up_c;
  logic [53:0] rounded_c;
  logic [10:0] exponent_c;

  always_comb begin
    if (INT64_INPUT) source_c = operand;
    else if (unsigned_input) source_c = {32'b0, operand[31:0]};
    else source_c = {{32{operand[31]}}, operand[31:0]};

    sign_c = !unsigned_input && source_c[63];
    magnitude_c = sign_c ? (~source_c + 64'd1) : source_c;
    leading_one_c = '0;
    leading_found_c = 1'b0;
    for (leading_index_c = 63; leading_index_c >= 0; leading_index_c = leading_index_c - 1) begin
      if (!leading_found_c && magnitude_c[leading_index_c]) begin
        leading_one_c = 7'(leading_index_c + 1);
        leading_found_c = 1'b1;
      end
    end
  end

  always_comb begin
    shift_count_c = integer'(s1_leading_one_q) > Precision
      ? integer'(s1_leading_one_q) - Precision : 0;
    retained_c = '0;
    guard_c = 1'b0;
    sticky_c = 1'b0;
    if (s1_leading_one_q != 0) begin
      retained_c = shift_count_c == 0
          ? s1_magnitude_q << (Precision - integer'(s1_leading_one_q))
          : s1_magnitude_q >> shift_count_c;
      if (shift_count_c > 0) begin
        guard_c = s1_magnitude_q[shift_count_c-1];
        for (sticky_index_c = 0; sticky_index_c < 64; sticky_index_c = sticky_index_c + 1)
        if (sticky_index_c < shift_count_c - 1)
          sticky_c = sticky_c | s1_magnitude_q[sticky_index_c];
      end
    end
  end

  always_comb begin
    stage3_result_c = TARGET_DOUBLE ? 64'b0 : 64'hffff_ffff_0000_0000;
    stage3_flags_c = '0;
    inexact_c = s2_guard_q | s2_sticky_q;
    round_up_c = 1'b0;
    rounded_c = '0;
    exponent_c = '0;

    if (!s2_zero_q) begin
      case (s2_rounding_mode_q)
        3'b000: round_up_c = s2_guard_q
            && (s2_sticky_q || s2_retained_q[0]);
        3'b001: round_up_c = 1'b0;
        3'b010: round_up_c = inexact_c && s2_sign_q;
        3'b011: round_up_c = inexact_c && !s2_sign_q;
        3'b100: round_up_c = s2_guard_q;
        default: round_up_c = 1'b0;
      endcase
      rounded_c = {1'b0, s2_retained_q[52:0]} + round_up_c;
      exponent_c = 11'(Bias - 1) + {4'b0, s2_leading_one_q}
          + {{10{1'b0}}, TARGET_DOUBLE ? rounded_c[53] : rounded_c[24]};
      if (TARGET_DOUBLE) stage3_result_c = {s2_sign_q, exponent_c[10:0], rounded_c[51:0]};
      else stage3_result_c[31:0] = {s2_sign_q, exponent_c[7:0], rounded_c[22:0]};
      stage3_flags_c[0] = inexact_c;
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
        s1_magnitude_q <= magnitude_c;
        s1_leading_one_q <= leading_one_c;
        s1_rounding_mode_q <= rounding_mode;
      end
      if (s1_valid_q) begin
        s2_sign_q <= s1_sign_q;
        s2_retained_q <= retained_c;
        s2_guard_q <= guard_c;
        s2_sticky_q <= sticky_c;
        s2_zero_q <= s1_leading_one_q == 0;
        s2_leading_one_q <= s1_leading_one_q;
        s2_rounding_mode_q <= s1_rounding_mode_q;
      end
      if (s2_valid_q) begin
        result_q <= stage3_result_c;
        flags_q <= stage3_flags_c;
      end
    end
  end
endmodule
