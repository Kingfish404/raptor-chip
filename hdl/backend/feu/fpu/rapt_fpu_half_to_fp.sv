`include "rapt.svh"

// Exact widening conversion used by FCVT.S.H and FCVT.D.H.  Binary16 is
// narrow enough that every finite value is represented exactly by both
// binary32 and binary64, so only NaN-box validation and sNaN invalid flagging
// need special handling.
module rapt_fpu_half_to_fp (
    input  logic        clock,
    input  logic        reset,
    input  logic        flush,
    input  logic        valid,
    output logic        ready,
    input  logic [63:0] operand,
    input  logic        target_double,
    output logic [63:0] result,
    output logic [4:0]  flags,
    output logic        result_valid
);
  logic valid_q;
  logic [63:0] result_c, result_q;
  logic [4:0] flags_c, flags_q;
  logic [15:0] h;
  logic sign;
  logic [4:0] exponent;
  logic [9:0] fraction;
  logic boxed;
  logic found;
  integer leading;
  integer scan;
  integer unbiased;
  logic [9:0] normalized_fraction;

  always_comb begin
    h = operand[15:0];
    sign = h[15];
    exponent = h[14:10];
    fraction = h[9:0];
    boxed = &operand[63:16];
    result_c = target_double ? 64'h7ff8_0000_0000_0000
                             : 64'hffff_ffff_7fc0_0000;
    flags_c = '0;
    found = 1'b0;
    leading = 0;
    unbiased = 0;
    normalized_fraction = '0;

    if (!boxed) begin
      // A non-NaN-boxed narrower input is the canonical quiet NaN.
      result_c = target_double ? 64'h7ff8_0000_0000_0000
                               : 64'hffff_ffff_7fc0_0000;
    end else if (exponent == 5'h1f) begin
      if (fraction == 0)
        result_c = target_double ? {sign, 11'h7ff, 52'b0}
                                 : {32'hffff_ffff, sign, 8'hff, 23'b0};
      else begin
        result_c = target_double ? 64'h7ff8_0000_0000_0000
                                 : 64'hffff_ffff_7fc0_0000;
        flags_c[4] = !fraction[9];
      end
    end else if (exponent == 0 && fraction == 0) begin
      result_c = target_double ? {sign, 63'b0}
                               : {32'hffff_ffff, sign, 31'b0};
    end else begin
      if (exponent == 0) begin
        for (scan = 9; scan >= 0; scan = scan - 1) begin
          if (!found && fraction[scan]) begin
            leading = scan;
            found = 1'b1;
          end
        end
        unbiased = leading - 24;
        normalized_fraction = (fraction << (10 - leading)) & 10'h3ff;
      end else begin
        unbiased = integer'(exponent) - 15;
        normalized_fraction = fraction;
      end

      if (target_double)
        result_c = {sign, 11'(unbiased + 1023), normalized_fraction, 42'b0};
      else
        result_c = {32'hffff_ffff, sign, 8'(unbiased + 127),
                    normalized_fraction, 13'b0};
    end
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
