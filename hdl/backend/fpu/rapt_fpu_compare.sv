`include "rapt.svh"

module rapt_fpu_compare (
    input  logic [5:0]  op,
    input  logic [63:0] operand_a,
    input  logic [63:0] operand_b,
    output logic [63:0] result,
    output logic [4:0]  flags
);
  logic is_double;
  logic is_minmax;
  logic is_maximum;
  logic is_equal;
  logic is_less;
  logic a_nan;
  logic b_nan;
  logic a_snan;
  logic b_snan;
  logic a_zero;
  logic b_zero;
  logic a_sign;
  logic b_sign;
  logic [63:0] a_magnitude;
  logic [63:0] b_magnitude;
  logic [63:0] a_value;
  logic [63:0] b_value;
  logic [63:0] canonical_nan;

  always_comb begin
    is_double = (op == `RAPT_FP_OP_FMIN_D)
      || (op == `RAPT_FP_OP_FMAX_D)
      || (op == `RAPT_FP_OP_FLE_D)
      || (op == `RAPT_FP_OP_FLT_D)
      || (op == `RAPT_FP_OP_FEQ_D);
    is_minmax = (op == `RAPT_FP_OP_FMIN_S)
      || (op == `RAPT_FP_OP_FMAX_S)
      || (op == `RAPT_FP_OP_FMIN_D)
      || (op == `RAPT_FP_OP_FMAX_D);
    is_maximum = (op == `RAPT_FP_OP_FMAX_S)
      || (op == `RAPT_FP_OP_FMAX_D);
    canonical_nan = is_double ? 64'h7ff8_0000_0000_0000
      : 64'hffff_ffff_7fc0_0000;

    if (is_double) begin
      a_value = operand_a;
      b_value = operand_b;
      a_sign = operand_a[63];
      b_sign = operand_b[63];
      a_magnitude = {1'b0, operand_a[62:0]};
      b_magnitude = {1'b0, operand_b[62:0]};
      a_nan = (&operand_a[62:52]) && (|operand_a[51:0]);
      b_nan = (&operand_b[62:52]) && (|operand_b[51:0]);
      a_snan = a_nan && !operand_a[51];
      b_snan = b_nan && !operand_b[51];
      a_zero = (operand_a[62:0] == '0);
      b_zero = (operand_b[62:0] == '0);
    end else begin
      a_value = operand_a[63:32] == '1
        ? operand_a : 64'hffff_ffff_7fc0_0000;
      b_value = operand_b[63:32] == '1
        ? operand_b : 64'hffff_ffff_7fc0_0000;
      a_sign = a_value[31];
      b_sign = b_value[31];
      a_magnitude = {33'b0, a_value[30:0]};
      b_magnitude = {33'b0, b_value[30:0]};
      a_nan = (&a_value[30:23]) && (|a_value[22:0]);
      b_nan = (&b_value[30:23]) && (|b_value[22:0]);
      a_snan = a_nan && !a_value[22];
      b_snan = b_nan && !b_value[22];
      a_zero = (a_value[30:0] == '0);
      b_zero = (b_value[30:0] == '0);
    end

    is_equal = !a_nan && !b_nan
      && ((a_zero && b_zero)
        || (a_sign == b_sign && a_magnitude == b_magnitude));
    is_less = !a_nan && !b_nan && !is_equal
      && (a_sign != b_sign ? a_sign
        : a_sign ? a_magnitude > b_magnitude
        : a_magnitude < b_magnitude);

    result = '0;
    flags = '0;
    if (is_minmax) begin
      flags[4] = a_snan || b_snan;
      if (a_nan && b_nan)
        result = canonical_nan;
      else if (a_nan)
        result = b_value;
      else if (b_nan)
        result = a_value;
      else if (is_equal && a_zero && b_zero)
        result = is_maximum
          ? (a_sign ? b_value : a_value)
          : (a_sign ? a_value : b_value);
      else
        result = (is_less == is_maximum) ? b_value : a_value;
    end else begin
      flags[4] = a_snan || b_snan
        || ((op != `RAPT_FP_OP_FEQ_S) && (op != `RAPT_FP_OP_FEQ_D)
          && (a_nan || b_nan));
      result[0] = (op == `RAPT_FP_OP_FEQ_S)
        || (op == `RAPT_FP_OP_FEQ_D) ? is_equal
        : (op == `RAPT_FP_OP_FLT_S)
          || (op == `RAPT_FP_OP_FLT_D) ? is_less
        : is_less || is_equal;
    end
  end
endmodule
