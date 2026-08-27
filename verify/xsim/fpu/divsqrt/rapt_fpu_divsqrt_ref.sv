`include "rapt.svh"

// One-operation-at-a-time IEEE-754 divider/square-root unit. The datapath
// computes a p+3-bit quotient/root and uses the remaining residue as sticky
// information, so the final packer implements all architectural RISC-V RMs.
module rapt_fpu_divsqrt_ref #(
    parameter int XLEN = `RAPT_XLEN
) (
    input  logic        clock,
    input  logic        reset,
    input  logic [63:0] operand_a,
    input  logic [63:0] operand_b,
    input  logic [2:0]  rounding_mode,
    input  logic        src_is_double,
    input  logic        dst_is_double,
    input  logic        divide,
    input  logic        sqrt,
    input  logic        flush,
    input  logic        valid,
    output logic        ready,
    output logic [63:0] result,
    output logic [4:0]  flags,
    output logic        result_valid
);
  logic        busy_q;
  logic [63:0] result_q;
  logic [4:0]  flags_q;
  logic [63:0] next_result;
  logic [4:0]  next_flags;

  function automatic [63:0] integer_sqrt(input logic [127:0] radicand);
    logic [127:0] trial;
    logic [127:0] square;
    integer bit_index;
    begin
      integer_sqrt = '0;
      for (bit_index = 63; bit_index >= 0; bit_index = bit_index - 1) begin
        trial = integer_sqrt | (128'(1) << bit_index);
        square = trial * trial;
        if (square <= radicand)
          integer_sqrt = trial[63:0];
      end
    end
  endfunction

  task automatic calculate(
      input  logic [63:0] input_a,
      input  logic [63:0] input_b,
      input  logic [2:0]  rm,
      input  logic        is_double,
      input  logic        do_divide,
      output logic [63:0] result_value,
      output logic [4:0]  flag_value
  );
    logic sign_a, sign_b, result_sign;
    logic [10:0] exponent_a, exponent_b;
    logic [51:0] fraction_a, fraction_b;
    logic [63:0] mantissa_a, mantissa_b, hidden_bit;
    logic [127:0] dividend, quotient, remainder, radicand, root_square;
    logic [63:0] root;
    logic a_nan, b_nan, a_snan, b_snan, a_inf, b_inf, a_zero, b_zero;
    logic invalid, divide_by_zero, inexact, round_up, subnormal;
    logic [63:0] significand;
    integer precision, bias, min_exponent, exponent_value, packed_exponent;
    integer shift_amount, bit_index;
    begin
      precision = is_double ? 53 : 24;
      bias = is_double ? 1023 : 127;
      min_exponent = 1 - bias;
      sign_a = is_double ? input_a[63] : input_a[31];
      sign_b = is_double ? input_b[63] : input_b[31];
      exponent_a = is_double ? input_a[62:52] : {3'b0, input_a[30:23]};
      exponent_b = is_double ? input_b[62:52] : {3'b0, input_b[30:23]};
      fraction_a = is_double ? input_a[51:0] : {29'b0, input_a[22:0]};
      fraction_b = is_double ? input_b[51:0] : {29'b0, input_b[22:0]};
      hidden_bit = is_double ? 64'h0010_0000_0000_0000 : 64'h0000_0000_0080_0000;
      a_nan = (exponent_a == (is_double ? 11'h7ff : 11'h0ff)) && (fraction_a != '0);
      b_nan = (exponent_b == (is_double ? 11'h7ff : 11'h0ff)) && (fraction_b != '0);
      a_snan = a_nan && !(is_double ? fraction_a[51] : fraction_a[22]);
      b_snan = b_nan && !(is_double ? fraction_b[51] : fraction_b[22]);
      a_inf = (exponent_a == (is_double ? 11'h7ff : 11'h0ff)) && (fraction_a == '0);
      b_inf = (exponent_b == (is_double ? 11'h7ff : 11'h0ff)) && (fraction_b == '0);
      a_zero = exponent_a == '0 && fraction_a == '0;
      b_zero = exponent_b == '0 && fraction_b == '0;
      result_sign = do_divide ? (sign_a ^ sign_b) : sign_a;
      invalid = a_snan || b_snan;
      divide_by_zero = 1'b0;
      inexact = 1'b0;
      round_up = 1'b0;
      subnormal = 1'b0;
      mantissa_a = '0;
      mantissa_b = '0;
      dividend = '0;
      quotient = '0;
      remainder = '0;
      radicand = '0;
      root_square = '0;
      root = '0;
      significand = '0;
      exponent_value = 0;
      packed_exponent = 0;
      shift_amount = 0;
      result_value = is_double ? 64'h7ff8_0000_0000_0000 : 64'hffff_ffff_7fc0_0000;
      flag_value = '0;

      if (a_nan || (do_divide && b_nan)) begin
        result_value = is_double ? 64'h7ff8_0000_0000_0000 : 64'hffff_ffff_7fc0_0000;
      end else if (!do_divide && sign_a && !a_zero) begin
        invalid = 1'b1;
      end else if (do_divide && ((a_zero && b_zero) || (a_inf && b_inf))) begin
        invalid = 1'b1;
      end else if (do_divide && b_zero) begin
        divide_by_zero = 1'b1;
        result_value = is_double ? {result_sign, 11'h7ff, 52'b0}
          : {32'hffff_ffff, result_sign, 8'hff, 23'b0};
      end else if (a_inf || (do_divide && b_inf)) begin
        if (do_divide && b_inf)
          result_value = is_double ? {result_sign, 63'b0}
            : {32'hffff_ffff, result_sign, 31'b0};
        else
          result_value = is_double ? {result_sign, 11'h7ff, 52'b0}
            : {32'hffff_ffff, result_sign, 8'hff, 23'b0};
      end else if (a_zero) begin
        result_value = is_double ? {result_sign, 63'b0}
          : {32'hffff_ffff, result_sign, 31'b0};
      end else begin
        mantissa_a = fraction_a;
        exponent_value = exponent_a == '0 ? min_exponent : exponent_a - bias;
        if (exponent_a != '0)
          mantissa_a = mantissa_a | hidden_bit;
        for (bit_index = 0; bit_index < 64; bit_index = bit_index + 1) begin
          if ((mantissa_a & hidden_bit) == '0) begin
            mantissa_a = mantissa_a << 1;
            exponent_value = exponent_value - 1;
          end
        end

        if (do_divide) begin
          mantissa_b = fraction_b;
          packed_exponent = exponent_b == '0 ? min_exponent : exponent_b - bias;
          if (exponent_b != '0)
            mantissa_b = mantissa_b | hidden_bit;
          for (bit_index = 0; bit_index < 64; bit_index = bit_index + 1) begin
            if ((mantissa_b & hidden_bit) == '0) begin
              mantissa_b = mantissa_b << 1;
              packed_exponent = packed_exponent - 1;
            end
          end
          exponent_value = exponent_value - packed_exponent;
          if (mantissa_a < mantissa_b) begin
            mantissa_a = mantissa_a << 1;
            exponent_value = exponent_value - 1;
          end
          dividend = {64'b0, mantissa_a} << (precision + 2);
          quotient = dividend / mantissa_b;
          remainder = dividend % mantissa_b;
        end else begin
          if (exponent_value[0]) begin
            mantissa_a = mantissa_a << 1;
            exponent_value = exponent_value - 1;
          end
          exponent_value = exponent_value / 2;
          radicand = {64'b0, mantissa_a} << (precision + 5);
          root = integer_sqrt(radicand);
          root_square = root * root;
          quotient = root;
          remainder = radicand - root_square;
        end

        if (exponent_value < min_exponent) begin
          shift_amount = min_exponent - exponent_value;
          if (shift_amount >= 128) begin
            remainder = remainder | quotient;
            quotient = '0;
          end else begin
            for (bit_index = 0; bit_index < 128; bit_index = bit_index + 1)
              if (bit_index < shift_amount)
                remainder = remainder | quotient[bit_index];
            quotient = quotient >> shift_amount;
          end
          exponent_value = min_exponent;
          subnormal = 1'b1;
        end

        inexact = quotient[2] || quotient[1] || quotient[0] || (remainder != '0);
        case (rm)
          3'b000: round_up = quotient[2] && (quotient[1] || quotient[0]
            || (remainder != '0) || quotient[3]);
          3'b001: round_up = 1'b0;
          3'b010: round_up = inexact && result_sign;
          3'b011: round_up = inexact && !result_sign;
          3'b100: round_up = quotient[2];
          default: round_up = 1'b0;
        endcase
        significand = (quotient >> 3) + round_up;
        if (significand >= (hidden_bit << 1)) begin
          significand = significand >> 1;
          exponent_value = exponent_value + 1;
          subnormal = 1'b0;
        end

        if (exponent_value > bias) begin
          flag_value[2] = 1'b1;
          if (rm == 3'b001 || (rm == 3'b010 && !result_sign)
              || (rm == 3'b011 && result_sign))
            result_value = is_double ? {result_sign, 11'h7fe, 52'hf_ffff_ffff_ffff}
              : {32'hffff_ffff, result_sign, 8'hfe, 23'h7f_ffff};
          else
            result_value = is_double ? {result_sign, 11'h7ff, 52'b0}
              : {32'hffff_ffff, result_sign, 8'hff, 23'b0};
        end else begin
          packed_exponent = exponent_value + bias;
          if (subnormal && significand < hidden_bit)
            packed_exponent = 0;
          if (is_double)
            result_value = {result_sign, packed_exponent[10:0], significand[51:0]};
          else
            result_value = {32'hffff_ffff, result_sign, packed_exponent[7:0], significand[22:0]};
          flag_value[1] = (packed_exponent == 0) && inexact;
        end
        flag_value[0] = inexact;
      end

      if (invalid) begin
        result_value = is_double ? 64'h7ff8_0000_0000_0000 : 64'hffff_ffff_7fc0_0000;
        flag_value = 5'b1_0000;
      end else begin
        flag_value[3] = divide_by_zero;
      end
    end
  endtask

  always_comb begin
    calculate(src_is_double || operand_a[63:32] == '1 ? operand_a
        : {32'hffff_ffff, 32'h7fc0_0000},
      src_is_double || operand_b[63:32] == '1 ? operand_b
        : {32'hffff_ffff, 32'h7fc0_0000},
      rounding_mode, src_is_double, divide,
      next_result, next_flags);
  end

  assign ready = !busy_q;
  assign result = result_q;
  assign flags = flags_q;
  assign result_valid = busy_q;

  always_ff @(posedge clock) begin
    // Only the busy flag needs reset: result_q/flags_q are consumed only when
    // result_valid (= busy_q) is set, so their data flops are don't-care
    // while idle (same principle as rapt_prf).
    if (reset || flush) begin
      busy_q <= 1'b0;
    end else if (busy_q) begin
      busy_q <= 1'b0;
    end else if (valid && (divide || sqrt)) begin
      busy_q <= 1'b1;
      result_q <= next_result;
      flags_q <= next_flags;
    end
  end
endmodule
