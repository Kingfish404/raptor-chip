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
  logic clip, signed_op, saturating;
  logic [5:0] shift_mask, shift_amount;
  logic [63:0] mask, au, bu, low_mask;
  logic signed [63:0] sa, sb;
  logic signed [64:0] shift_in, shift_q;
  logic signed [65:0] add_a, add_b, add_sum, mul_raw_q, mul_q;
  logic signed [65:0] q, rounded, minimum, maximum;
  logic shift_half, shift_lower, mul_pos_ovf, mul_neg_ovf, mul_half, mul_lower;
  logic half, lower, discarded, increment, underflow, overflow;

  always_comb begin
    clip = op == 4'd10 || op == 4'd11;
    signed_op = op[0] || op == 4'd12;
    saturating = op <= 4'd3 || clip || op == 4'd12;
    case (sew)
      2'd0: begin
        mask = 64'h0000_0000_0000_00ff;
        bu = {56'b0, b[7:0]};
        sb = {{56{b[7]}}, b[7:0]};
        au = clip ? {48'b0, a[15:0]} : {56'b0, a[7:0]};
        sa = clip ? {{48{a[15]}}, a[15:0]} : {{56{a[7]}}, a[7:0]};
        shift_mask = clip ? 6'h0f : 6'h07;
        minimum = signed_op ? -66'sd128 : 66'sd0;
        maximum = signed_op ? 66'sd127 : 66'sd255;
      end
      2'd1: begin
        mask = 64'h0000_0000_0000_ffff;
        bu = {48'b0, b[15:0]};
        sb = {{48{b[15]}}, b[15:0]};
        au = clip ? {32'b0, a[31:0]} : {48'b0, a[15:0]};
        sa = clip ? {{32{a[31]}}, a[31:0]} : {{48{a[15]}}, a[15:0]};
        shift_mask = clip ? 6'h1f : 6'h0f;
        minimum = signed_op ? -66'sd32768 : 66'sd0;
        maximum = signed_op ? 66'sd32767 : 66'sd65535;
      end
      2'd2: begin
        mask = 64'h0000_0000_ffff_ffff;
        bu = {32'b0, b[31:0]};
        sb = {{32{b[31]}}, b[31:0]};
        au = clip ? a : {32'b0, a[31:0]};
        sa = clip ? $signed(a) : {{32{a[31]}}, a[31:0]};
        shift_mask = clip ? 6'h3f : 6'h1f;
        minimum = signed_op ? -66'sd2147483648 : 66'sd0;
        maximum = signed_op ? 66'sd2147483647 : 66'sh0_0000_0000_ffff_ffff;
      end
      default: begin
        mask = 64'hffff_ffff_ffff_ffff;
        bu = b;
        sb = $signed(b);
        au = clip ? 64'b0 : a;
        sa = clip ? 64'sd0 : $signed(a);
        shift_mask = 6'h3f;
        minimum = signed_op ? 66'sh3_8000_0000_0000_0000 : 66'sd0;
        maximum = signed_op ? 66'sh0_7fff_ffff_ffff_ffff : 66'sh0_ffff_ffff_ffff_ffff;
      end
    endcase

    add_a = op[0] ? {{2{sa[63]}}, sa} : {2'b00, au};
    add_b = op[0] ? {{2{sb[63]}}, sb} : {2'b00, bu};
    add_sum = op[1] ? (add_a - add_b) : (add_a + add_b);

    shift_amount = b[5:0] & shift_mask;
    shift_in = $signed({op[0] && sa[63], op[0] ? sa : au});
    shift_q = shift_in >>> shift_amount;
    low_mask = (64'd1 << shift_amount) - 64'd1;
    shift_half = shift_amount != 6'd0 && au[shift_amount - 6'd1];
    shift_lower = |(au & (low_mask >> 1));

    case (sew)
      2'd0: begin
        mul_pos_ovf = !product[127] && (|product[126:71]);
        mul_neg_ovf = product[127] && !(&product[126:71]);
        mul_raw_q = $signed({product[127], product[71:7]});
        mul_half = product[6];
        mul_lower = |product[5:0];
      end
      2'd1: begin
        mul_pos_ovf = !product[127] && (|product[126:79]);
        mul_neg_ovf = product[127] && !(&product[126:79]);
        mul_raw_q = $signed({product[127], product[79:15]});
        mul_half = product[14];
        mul_lower = |product[13:0];
      end
      2'd2: begin
        mul_pos_ovf = !product[127] && (|product[126:95]);
        mul_neg_ovf = product[127] && !(&product[126:95]);
        mul_raw_q = $signed({product[127], product[95:31]});
        mul_half = product[30];
        mul_lower = |product[29:0];
      end
      default: begin
        mul_pos_ovf = 1'b0;
        mul_neg_ovf = 1'b0;
        mul_raw_q = $signed({product[127], product[127:63]});
        mul_half = product[62];
        mul_lower = |product[61:0];
      end
    endcase
    if (mul_pos_ovf) mul_q = $signed({2'b01, 63'b0, mul_raw_q[0]});
    else if (mul_neg_ovf) mul_q = $signed({2'b10, 63'b0, mul_raw_q[0]});
    else mul_q = mul_raw_q;

    q = 66'sd0;
    half = 1'b0;
    lower = 1'b0;
    case (op)
      4'd0, 4'd1, 4'd2, 4'd3: q = add_sum;
      4'd4, 4'd5, 4'd6, 4'd7: begin
        q = add_sum >>> 1;
        half = add_sum[0];
      end
      4'd8, 4'd9, 4'd10, 4'd11: begin
        q = $signed({shift_q[64], shift_q});
        half = shift_half;
        lower = shift_lower;
      end
      4'd12: begin
        q = mul_q;
        half = mul_half;
        lower = mul_lower;
      end
      default: ;
    endcase

    discarded = half || lower;
    case (vxrm)
      2'd0: increment = half;
      2'd1: increment = half && (lower || q[0]);
      2'd2: increment = 1'b0;
      default: increment = discarded && !q[0];
    endcase
    rounded = q + $signed({65'b0, increment});
    underflow = saturating && (rounded < minimum);
    overflow = saturating && (rounded > maximum);
    saturated = underflow || overflow;
    if (underflow) result = minimum[63:0] & mask;
    else if (overflow) result = maximum[63:0] & mask;
    else result = rounded[63:0] & mask;
  end
endmodule
