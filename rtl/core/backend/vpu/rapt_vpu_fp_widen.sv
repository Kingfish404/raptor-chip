// Exact raw FP32 operand expansion for FP64 widening arithmetic.
// This is NOT an architectural conversion instruction: NaN sign, payload and
// signaling status are retained so the consuming arithmetic unit raises NV.
// No rounding, overflow or underflow is possible for finite FP32 operands.
module rapt_vpu_fp_widen (
    input logic [31:0] value,
    output logic [63:0] result
);
  logic [10:0] exponent;
  logic [22:0] fraction;
  int unsigned shift;
  always_comb begin
    exponent = 0;
    fraction = value[22:0];
    shift = 0;
    if (value[30:23] == 8'hff) exponent = 11'h7ff;
    else if (value[30:23] != 0) exponent = {3'b0, value[30:23]} + 11'd896;
    else if (value[22:0] != 0) begin
      // Highest set fraction bit becomes the implicit leading one.
      for (int bit_index = 0; bit_index < 23; bit_index++)
      if (value[bit_index]) shift = 23 - bit_index;
      // The leading one shifts out of the stored fraction.
      fraction = value[22:0] << shift;
      exponent = 11'd897 - 11'(shift);
    end
    result = {value[31], exponent, fraction, 29'b0};
  end
endmodule
