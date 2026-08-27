module rapt_fpu_classify (
    input  logic        is_double,
    input  logic [63:0] operand,
    output logic [9:0]  result
);
  logic        sign;
  logic [10:0] exponent;
  logic [51:0] fraction;
  logic        exponent_zero;
  logic        exponent_ones;
  logic        fraction_zero;
  logic        quiet_nan;

  always_comb begin
    if (is_double) begin
      sign = operand[63];
      exponent = operand[62:52];
      fraction = operand[51:0];
      exponent_zero = exponent == 11'h000;
      exponent_ones = exponent == 11'h7ff;
      fraction_zero = fraction == '0;
      quiet_nan = fraction[51];
    end else if (operand[63:32] == '1) begin
      sign = operand[31];
      exponent = {3'b000, operand[30:23]};
      fraction = {29'b0, operand[22:0]};
      exponent_zero = exponent[7:0] == 8'h00;
      exponent_ones = exponent[7:0] == 8'hff;
      fraction_zero = fraction[22:0] == '0;
      quiet_nan = fraction[22];
    end else begin
      sign = 1'b0;
      exponent = 11'h7ff;
      fraction = 52'h8_0000_0000_0000;
      exponent_zero = 1'b0;
      exponent_ones = 1'b1;
      fraction_zero = 1'b0;
      quiet_nan = 1'b1;
    end

    result = '0;
    if (exponent_ones && !fraction_zero)
      result[quiet_nan ? 9 : 8] = 1'b1;
    else if (exponent_ones)
      result[sign ? 0 : 7] = 1'b1;
    else if (exponent_zero && fraction_zero)
      result[sign ? 3 : 4] = 1'b1;
    else if (exponent_zero)
      result[sign ? 2 : 5] = 1'b1;
    else
      result[sign ? 1 : 6] = 1'b1;
  end
endmodule
