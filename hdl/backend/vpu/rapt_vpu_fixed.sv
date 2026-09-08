// Stateless fixed-point rounding/saturation stage. The caller supplies legal
// widths: narrowing clip consumes 2*SEW <= 64. Fractional multiplication uses
// a signed full product from the separately handshaked multiplier, not a new
// combinational multiplier. No architectural CSR state is stored here.
module rapt_vpu_fixed (
    input logic [3:0] op,
    input logic [1:0] sew,
    vxrm,
    input logic [63:0] a,
    b,
    input logic [127:0] product,
    output logic [63:0] result,
    output logic saturated
);
  logic [6:0] bits, source_bits, shift;
  logic [63:0] mask, source_mask, au, bu;
  logic signed [63:0] sa, sb;
  logic signed [127:0] value, rounded, minimum, maximum;
  logic clip, signed_op, saturating;
  function automatic logic signed [127:0] roundoff(input logic signed [127:0] v,
                                                   input logic [6:0] amount, input logic [1:0] rm);
    logic [127:0] low_mask;
    logic discarded, half, lower, increment;
    logic signed [127:0] q;
    low_mask = (128'b1 << amount)-1'b1;
    q = v >>> amount;
    discarded = |(v & low_mask);
    half = amount != 0 && v[amount-1'b1];
    lower = |(v & (low_mask >> 1));
    case (rm)
      0: increment = half;
      1: increment = half && (lower || q[0]);
      2: increment = 0;
      3: increment = discarded && !q[0];
      default: increment = 0;
    endcase
    return q + 128'(increment);
  endfunction
  always_comb begin
    bits = 7'(8 << sew);
    clip = op == 10 || op == 11;
    source_bits = clip ? bits << 1 : bits;
    mask = 64'hffffffffffffffff >> (64-bits);
    source_mask = 64'hffffffffffffffff >> (64-source_bits);
    au = a & source_mask;
    bu = b & mask;
    sa = $signed(au << (64-source_bits)) >>> (64-source_bits);
    sb = $signed(bu << (64-bits)) >>> (64-bits);
    signed_op = op[0] || op == 12;
    saturating = op <= 3 || clip || op == 12;
    minimum = signed_op ? -(128'sd1 << (bits-1'b1)) : 128'sd0;
    maximum = signed_op ? (128'sd1 << (bits-1'b1))-1'b1 : $signed({64'b0,mask});
    value = 0;
    shift = 0;
    case (op)
      0: value = $signed({64'b0,au}) + $signed({64'b0,bu});
      1: value = 128'(sa) + 128'(sb);
      2: value = $signed({64'b0,au}) - $signed({64'b0,bu});
      3: value = 128'(sa) - 128'(sb);
      4: begin value = $signed({64'b0,au}) + $signed({64'b0,bu}); shift = 1; end
      5: begin value = 128'(sa) + 128'(sb); shift = 1; end
      6: begin value = $signed({64'b0,au}) - $signed({64'b0,bu}); shift = 1; end
      7: begin value = 128'(sa) - 128'(sb); shift = 1; end
      8, 10: begin value = $signed({64'b0,au}); shift = {1'b0,b[5:0]} & (source_bits-1'b1); end
      9, 11: begin value = 128'(sa); shift = {1'b0,b[5:0]} & (source_bits-1'b1); end
      12: begin value = $signed(product); shift = bits-1'b1; end
      default: ;
    endcase
    rounded = roundoff(value,shift,vxrm);
    saturated = saturating && (rounded < minimum || rounded > maximum);
    if (saturating && rounded < minimum) result = minimum[63:0] & mask;
    else if (saturating && rounded > maximum) result = maximum[63:0] & mask;
    else result = rounded[63:0] & mask;
  end
endmodule
