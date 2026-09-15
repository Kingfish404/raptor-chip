`include "rapt.svh"

// IEEE-754 binary32/binary64 to binary16 conversion for FCVT.H.S/D.
// Tininess is detected after rounding, matching the RISC-V floating-point
// control-state requirement.
module rapt_fpu_fp_to_half (
    input  logic        clock,
    input  logic        reset,
    input  logic        flush,
    input  logic        valid,
    output logic        ready,
    input  logic [63:0] operand,
    input  logic        source_double,
    input  logic [2:0]  rounding_mode,
    output logic [63:0] result,
    output logic [4:0]  flags,
    output logic        result_valid
);
  logic valid_q;
  logic [63:0] result_c, result_q;
  logic [4:0] flags_c, flags_q;
  logic sign;
  logic boxed;
  logic is_zero, is_inf, is_nan, is_snan;
  integer scan;
  logic signed [11:0] unbiased;
  logic [5:0] shift_count;
  logic [52:0] significand;
  logic [10:0] retained;
  logic guard_bit, sticky_bit, inexact, round_up;
  logic precision_guard, precision_sticky, precision_round_up, tiny;
  logic [11:0] rounded;
  logic signed [11:0] rounded_exp;
  logic overflow_to_inf;
  logic [15:0] half_result;

  always_comb begin
    sign = source_double ? operand[63] : operand[31];
    boxed = source_double || (&operand[63:32]);
    is_zero = 1'b0;
    is_inf = 1'b0;
    is_nan = 1'b0;
    is_snan = 1'b0;
    unbiased = 0;
    significand = '0;

    if (!boxed) begin
      is_nan = 1'b1;
      sign = 1'b0;
    end else if (source_double) begin
      if (operand[62:52] == 11'h7ff) begin
        is_inf = operand[51:0] == 0;
        is_nan = operand[51:0] != 0;
        is_snan = is_nan && !operand[51];
      end else if (operand[62:52] == 0 && operand[51:0] == 0) begin
        is_zero = 1'b1;
      end else if (operand[62:52] == 0) begin
        // Every nonzero binary64 subnormal is below half of binary16's
        // minimum subnormal. Only sign and a sticky bit affect rounding;
        // normalization would add a priority encoder and wide barrel shifter.
        unbiased = -12'sd26;
        significand = 53'd1;
      end else begin
        unbiased = $signed({1'b0, operand[62:52]}) - 12'sd1023;
        significand = {1'b1, operand[51:0]};
      end
    end else begin
      if (operand[30:23] == 8'hff) begin
        is_inf = operand[22:0] == 0;
        is_nan = operand[22:0] != 0;
        is_snan = is_nan && !operand[22];
      end else if (operand[30:23] == 0 && operand[22:0] == 0) begin
        is_zero = 1'b1;
      end else if (operand[30:23] == 0) begin
        // The same sticky-only reduction holds for binary32 subnormals.
        unbiased = -12'sd26;
        significand = 53'd1;
      end else begin
        unbiased = $signed({4'b0, operand[30:23]}) - 12'sd127;
        significand = {1'b1, operand[22:0], 29'b0};
      end
    end

    // Round at binary16 precision with an unbounded exponent for tininess.
    // Rounding again onto the subnormal grid can produce min-normal with UF.
    precision_guard = significand[41];
    precision_sticky = |significand[40:0];
    case (rounding_mode)
      3'b000: precision_round_up = precision_guard && (precision_sticky || significand[42]);
      3'b001: precision_round_up = 1'b0;
      3'b010: precision_round_up = (precision_guard || precision_sticky) && sign;
      3'b011: precision_round_up = (precision_guard || precision_sticky) && !sign;
      3'b100: precision_round_up = precision_guard;
      default: precision_round_up = 1'b0;
    endcase
    tiny = (unbiased < -14)
        && !((unbiased == -15) && precision_round_up && (&significand[52:42]));

    retained = '0;
    guard_bit = 1'b0;
    sticky_bit = 1'b0;
    shift_count = 0;
    if (!(is_zero || is_inf || is_nan)) begin
      // Shifts beyond the 53-bit significand are indistinguishable: all
      // retained/guard bits are zero and only sticky remains. Bound the
      // selector instead of building a 32-bit variable shift/index path.
      shift_count = (unbiased >= -14) ? 6'd42 : (unbiased < -25) ? 6'd54 : 6'(12'sd28 - unbiased);
      if (shift_count <= 52) retained = 11'(significand >> shift_count);
      if (shift_count > 0 && shift_count <= 53) guard_bit = significand[shift_count-6'd1];
      if (shift_count > 53) sticky_bit = |significand;
      else if (shift_count > 1)
        for (scan = 0; scan < 53; scan = scan + 1)
        if (6'(scan) < shift_count - 6'd1) sticky_bit |= significand[scan];
    end

    inexact = guard_bit | sticky_bit;
    round_up = 1'b0;
    case (rounding_mode)
      3'b000: round_up = guard_bit && (sticky_bit || retained[0]); // RNE
      3'b001: round_up = 1'b0;                                   // RTZ
      3'b010: round_up = inexact && sign;                         // RDN
      3'b011: round_up = inexact && !sign;                        // RUP
      3'b100: round_up = guard_bit;                               // RMM
      default: round_up = 1'b0;
    endcase
    rounded = {1'b0, retained} + round_up;
    rounded_exp = unbiased + $signed({11'b0, rounded[11]});
    overflow_to_inf = rounding_mode == 3'b000 || rounding_mode == 3'b100
        || (rounding_mode == 3'b010 && sign)
        || (rounding_mode == 3'b011 && !sign);

    half_result = {sign, 15'b0};
    flags_c = '0;
    if (is_nan) begin
      half_result = 16'h7e00;
      flags_c[4] = is_snan;
    end else if (is_inf) begin
      half_result = {sign, 5'h1f, 10'b0};
    end else if (!is_zero) begin
      if (unbiased > 15 || (unbiased >= -14 && rounded_exp > 15)) begin
        half_result = overflow_to_inf ? {sign, 5'h1f, 10'b0}
                                      : {sign, 5'h1e, 10'h3ff};
        flags_c[2] = 1'b1;
        flags_c[0] = 1'b1;
      end else if (unbiased >= -14) begin
        half_result = {sign, 5'(rounded_exp + 15), rounded[9:0]};
        flags_c[0] = inexact;
      end else begin
        if (rounded[10]) half_result = {sign, 5'h01, 10'b0};
        else half_result = {sign, 5'h00, rounded[9:0]};
        flags_c[1] = inexact && tiny;
        flags_c[0] = inexact;
      end
    end
    result_c = {48'hffff_ffff_ffff, half_result};
  end

  assign ready = !valid_q;
  assign result = result_q;
  assign flags = flags_q;
  assign result_valid = valid_q;

  always_ff @(posedge clock) begin
    if (reset || flush) begin
      valid_q <= 1'b0;
      // Result/flags are meaningful only with result_valid; keep payload
      // unreset so reset/flush only cancels the valid pipeline.
    end else begin
      valid_q <= valid && ready;
      if (valid && ready) begin
        result_q <= result_c;
        flags_q <= flags_c;
      end
    end
  end
endmodule
