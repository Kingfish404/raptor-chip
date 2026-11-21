// One integer element. Decode maps unary Zvbb operations to spare ALU controls.
// Truncation and signed comparisons use the element width.
module rapt_vpu_alu #(
    parameter bit Zvbb = 0
) (
    input logic [5:0] funct6,
    input logic [1:0] sew,
    input logic [63:0] a,
    input logic [63:0] b,
    input logic mask_bit,
    input logic mask_logic,
    output logic [63:0] result
);
  logic [63:0] mask, au, bu, reverse_bits, shr_out_rev;
  logic signed [63:0] sa, sb;
  logic [5:0] shift, shr_amt;
  logic [64:0] carry_sum, borrow_difference, cmp_a, cmp_b;
  logic add_cin, sub_bin, sub_swap, carry_bit, borrow_bit, a_eq_b, a_lt_b, is_shl;
  logic [63:0] shr_hi, shr_lo, shr_res, bit_result;

  assign is_shl = funct6 == 6'h25;
  for (genvar bit_idx = 0; bit_idx < 64; bit_idx++) begin : g_rev
    assign reverse_bits[bit_idx] = au[63 - bit_idx];
    assign shr_out_rev[bit_idx] = shr_res[63 - bit_idx];
  end

  if (Zvbb) begin : g_bitmanip
    logic [63:0] reverse_byte_bits, reverse_bytes;
    logic [63:0] rep64, rev_bytes_sew, rev_bits_sew, ctz_in;
    logic [6:0] width;
    logic [5:0] rotate_shift, rotate_mask;
    logic is_rot;
    wire nonzero[127:1];
    wire [5:0] first_set[127:1];
    wire [6:0] ones[127:1];

    always_comb begin
      case (sew)
        2'd0: begin
          width = 7'd8;
          rotate_mask = 6'h07;
          rep64 = {8{a[7:0]}};
          rev_bytes_sew = {56'b0, reverse_bytes[63:56]};
          rev_bits_sew = {56'b0, reverse_bits[63:56]};
        end
        2'd1: begin
          width = 7'd16;
          rotate_mask = 6'h0f;
          rep64 = {4{a[15:0]}};
          rev_bytes_sew = {48'b0, reverse_bytes[63:48]};
          rev_bits_sew = {48'b0, reverse_bits[63:48]};
        end
        2'd2: begin
          width = 7'd32;
          rotate_mask = 6'h1f;
          rep64 = {2{a[31:0]}};
          rev_bytes_sew = {32'b0, reverse_bytes[63:32]};
          rev_bits_sew = {32'b0, reverse_bits[63:32]};
        end
        default: begin
          width = 7'd64;
          rotate_mask = 6'h3f;
          rep64 = a;
          rev_bytes_sew = reverse_bytes;
          rev_bits_sew = reverse_bits;
        end
      endcase
    end
    assign is_rot = funct6 == 6'h14 || funct6 == 6'h15;
    assign rotate_shift = funct6 == 6'h15 ? (-shift & rotate_mask) : shift;
    assign shr_hi = is_rot ? (sew == 2'd3 ? a : 64'b0) : {64{funct6 == 6'h29 && sa[63]}};
    assign shr_lo = is_rot ? rep64 : (is_shl ? reverse_bits : (funct6 == 6'h29 ? 64'(sa) : au));
    assign shr_amt = is_rot ? rotate_shift : shift;
    assign ctz_in = (funct6 == 6'h34) ? rev_bits_sew : au;
    for (genvar bit_idx = 0; bit_idx < 64; bit_idx++) begin : g_bit
      localparam int ByteIndex = bit_idx / 8;
      localparam int ByteBit   = bit_idx % 8;
      assign reverse_byte_bits[bit_idx] = au[8 * ByteIndex + 7 - ByteBit];
      assign reverse_bytes[bit_idx] = au[8 * (7 - ByteIndex) + ByteBit];
      assign nonzero[64 + bit_idx] = ctz_in[bit_idx];
      assign first_set[64 + bit_idx] = 6'(bit_idx);
      assign ones[64 + bit_idx] = 7'(au[bit_idx]);
    end
    for (genvar node = 1; node < 64; node++) begin : g_count_zeros
      assign nonzero[node] = nonzero[2 * node] || nonzero[2 * node + 1];
      assign first_set[node] = nonzero[2 * node] ? first_set[2 * node] : first_set[2 * node + 1];
      assign ones[node] = ones[2 * node] + ones[2 * node + 1];
    end
    always_comb begin
      case (funct6)
        6'h01: bit_result = au & ~bu;
        6'h14, 6'h15: bit_result = shr_res;
        6'h30: bit_result = reverse_byte_bits;
        6'h31: bit_result = rev_bytes_sew;
        6'h32: bit_result = rev_bits_sew;
        6'h34, 6'h35: bit_result = nonzero[1] ? 64'(first_set[1]) : 64'(width);
        6'h36: bit_result = 64'(ones[1]);
        default: bit_result = 64'd0;
      endcase
    end
  end else begin : g_no_bitmanip
    assign shr_hi = {64{funct6 == 6'h29 && sa[63]}};
    assign shr_lo = is_shl ? reverse_bits : (funct6 == 6'h29 ? 64'(sa) : au);
    assign shr_amt = shift;
    assign bit_result = 64'd0;
  end

  assign shr_res = 64'({shr_hi, shr_lo} >> shr_amt);

  always_comb begin
    // SEW has only four encodings. Explicit wiring avoids constructing
    // variable left/right shifters merely to sign-extend an operand.
    case (sew)
      2'd0: begin
        mask = 64'hff;
        sa = {{56{a[7]}}, a[7:0]};
        sb = {{56{b[7]}}, b[7:0]};
        shift = {3'b0, b[2:0]};
      end
      2'd1: begin
        mask = 64'hffff;
        sa = {{48{a[15]}}, a[15:0]};
        sb = {{48{b[15]}}, b[15:0]};
        shift = {2'b0, b[3:0]};
      end
      2'd2: begin
        mask = 64'hffffffff;
        sa = {{32{a[31]}}, a[31:0]};
        sb = {{32{b[31]}}, b[31:0]};
        shift = {1'b0, b[4:0]};
      end
      default: begin
        mask = 64'hffff_ffff_ffff_ffff;
        sa = $signed(a);
        sb = $signed(b);
        shift = b[5:0];
      end
    endcase
  end
  assign au = a & mask;
  assign bu = b & mask;
  assign add_cin = (funct6 == 6'h10 || funct6 == 6'h11) && mask_bit;
  assign carry_sum = {1'b0, au} + {1'b0, bu} + 65'(add_cin);
  assign sub_swap = funct6 == 6'h03;
  assign sub_bin = (funct6 == 6'h12 || funct6 == 6'h13) && mask_bit;
  assign borrow_difference = {1'b0, sub_swap ? bu : au} - {1'b0, sub_swap ? au : bu} - 65'(sub_bin);
  assign cmp_a = {funct6[0] && sa[63], funct6[0] ? 64'(sa) : au};
  assign cmp_b = {funct6[0] && sb[63], funct6[0] ? 64'(sb) : bu};
  assign a_eq_b = au == bu;
  assign a_lt_b = $signed(cmp_a) < $signed(cmp_b);

  always_comb begin
    case (sew)
      2'd0: begin
        carry_bit = carry_sum[8];
        borrow_bit = borrow_difference[8];
      end
      2'd1: begin
        carry_bit = carry_sum[16];
        borrow_bit = borrow_difference[16];
      end
      2'd2: begin
        carry_bit = carry_sum[32];
        borrow_bit = borrow_difference[32];
      end
      default: begin
        carry_bit = carry_sum[64];
        borrow_bit = borrow_difference[64];
      end
    endcase
    result = 64'd0;
    case (funct6)
      6'h00, 6'h10: result = carry_sum[63:0];
      6'h02, 6'h03, 6'h12: result = borrow_difference[63:0];
      6'h04, 6'h05: result = a_lt_b ? au : bu;
      6'h06, 6'h07: result = a_lt_b ? bu : au;
      6'h09: result = au & bu;
      6'h0a: result = au | bu;
      6'h0b: result = au ^ bu;
      6'h11: result = {63'b0, carry_bit};
      6'h13: result = {63'b0, borrow_bit};
      6'h17: result = mask_bit ? bu : au;
      6'h18: result = {63'b0, a_eq_b};
      6'h19: result = {63'b0, !a_eq_b};
      6'h1a, 6'h1b: result = {63'b0, a_lt_b};
      6'h1c, 6'h1d: result = {63'b0, a_lt_b || a_eq_b};
      6'h1e, 6'h1f: result = {63'b0, !a_lt_b && !a_eq_b};
      6'h25: result = shr_out_rev;
      6'h28, 6'h29: result = shr_res;
      default: result = bit_result;
    endcase
    if (mask_logic) begin
      case (funct6[2:0])
        3'd0: result = {63'b0, au[0] && !bu[0]};
        3'd1: result = {63'b0, au[0] && bu[0]};
        3'd2: result = {63'b0, au[0] || bu[0]};
        3'd3: result = {63'b0, au[0] != bu[0]};
        3'd4: result = {63'b0, au[0] || !bu[0]};
        3'd5: result = {63'b0, !(au[0] && bu[0])};
        3'd6: result = {63'b0, !(au[0] || bu[0])};
        default: result = {63'b0, !(au[0] != bu[0])};
      endcase
    end
    result &= mask;
  end
endmodule
