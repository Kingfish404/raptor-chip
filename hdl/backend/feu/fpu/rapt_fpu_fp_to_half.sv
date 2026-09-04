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
  logic found;
  integer leading;
  integer scan;
  integer unbiased;
  integer shift_count;
  logic [52:0] significand;
  logic [10:0] retained;
  logic guard_bit, sticky_bit, inexact, round_up;
  logic [11:0] rounded;
  integer rounded_exp;
  logic overflow_to_inf;
  logic [15:0] half_result;

  always_comb begin
    sign = source_double ? operand[63] : operand[31];
    boxed = source_double || (&operand[63:32]);
    is_zero = 1'b0;
    is_inf = 1'b0;
    is_nan = 1'b0;
    is_snan = 1'b0;
    found = 1'b0;
    leading = 0;
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
        for (scan = 51; scan >= 0; scan = scan - 1) begin
          if (!found && operand[scan]) begin
            leading = scan;
            found = 1'b1;
          end
        end
        unbiased = leading - 1074;
        significand = {1'b0, operand[51:0]} << (52 - leading);
      end else begin
        unbiased = integer'(operand[62:52]) - 1023;
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
        for (scan = 22; scan >= 0; scan = scan - 1) begin
          if (!found && operand[scan]) begin
            leading = scan;
            found = 1'b1;
          end
        end
        unbiased = leading - 149;
        significand = {30'b0, operand[22:0]} << (52 - leading);
      end else begin
        unbiased = integer'(operand[30:23]) - 127;
        significand = {1'b1, operand[22:0], 29'b0};
      end
    end

    retained = '0;
    guard_bit = 1'b0;
    sticky_bit = 1'b0;
    shift_count = 0;
    if (!(is_zero || is_inf || is_nan)) begin
      shift_count = (unbiased >= -14) ? 42 : (28 - unbiased);
      if (shift_count <= 52)
        retained = 11'(significand >> shift_count);
      if (shift_count > 0 && shift_count <= 53)
        guard_bit = significand[shift_count-1];
      if (shift_count > 53)
        sticky_bit = |significand;
      else if (shift_count > 1)
        for (scan = 0; scan < 53; scan = scan + 1)
          if (scan < shift_count - 1) sticky_bit |= significand[scan];
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
    rounded_exp = unbiased + rounded[11];
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
        flags_c[1] = inexact && !rounded[10];
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
      result_q <= '0;
      flags_q <= '0;
    end else begin
      valid_q <= valid && ready;
      if (valid && ready) begin
        result_q <= result_c;
        flags_q <= flags_c;
      end
    end
  end
endmodule
