// RVV 1.0 vfrec7/vfrsqrt7 raw element estimates. Lookup constants are the
// normative vfrec7.adoc and vfrsqrt7.adoc tables in riscvarchive/riscv-v-spec.
// Combinational leaf: caller owns instruction admission, masking and flags.
module rapt_vpu_fp_estimate #(
    parameter bit Double = 1
) (
    /* verilator lint_off UNUSEDSIGNAL */
    input logic [63:0] operand,
    /* verilator lint_on UNUSEDSIGNAL */
    input logic reciprocal_sqrt,
    input logic [2:0] rm,
    output logic [63:0] result,
    output logic [4:0] flags,
    output logic illegal
);
  localparam int F = Double ? 52 : 23;
  localparam int E = Double ? 11 : 8;
  localparam int Bias = (1 << (E - 1)) - 1;
  localparam int MaxExp = (1 << E) - 1;
  logic sign_bit;
  logic [E-1:0] exponent;
  logic [F-1:0] fraction;
  logic [6:0] normalized_fraction;
  logic [6:0] index_value, estimate;
  logic [F:0] significand;
  logic [F+E:0] encoded;
  int normalized_exponent, output_exponent, leading;
  function automatic logic [6:0] reciprocal_table(input logic [6:0] index_bits);
    case (index_bits)
      7'd0: reciprocal_table = 7'd127;
      7'd1: reciprocal_table = 7'd125;
      7'd2: reciprocal_table = 7'd123;
      7'd3: reciprocal_table = 7'd121;
      7'd4: reciprocal_table = 7'd119;
      7'd5: reciprocal_table = 7'd117;
      7'd6: reciprocal_table = 7'd116;
      7'd7: reciprocal_table = 7'd114;
      7'd8: reciprocal_table = 7'd112;
      7'd9: reciprocal_table = 7'd110;
      7'd10: reciprocal_table = 7'd109;
      7'd11: reciprocal_table = 7'd107;
      7'd12: reciprocal_table = 7'd105;
      7'd13: reciprocal_table = 7'd104;
      7'd14: reciprocal_table = 7'd102;
      7'd15: reciprocal_table = 7'd100;
      7'd16: reciprocal_table = 7'd99;
      7'd17: reciprocal_table = 7'd97;
      7'd18: reciprocal_table = 7'd96;
      7'd19: reciprocal_table = 7'd94;
      7'd20: reciprocal_table = 7'd93;
      7'd21: reciprocal_table = 7'd91;
      7'd22: reciprocal_table = 7'd90;
      7'd23: reciprocal_table = 7'd88;
      7'd24: reciprocal_table = 7'd87;
      7'd25: reciprocal_table = 7'd85;
      7'd26: reciprocal_table = 7'd84;
      7'd27: reciprocal_table = 7'd83;
      7'd28: reciprocal_table = 7'd81;
      7'd29: reciprocal_table = 7'd80;
      7'd30: reciprocal_table = 7'd79;
      7'd31: reciprocal_table = 7'd77;
      7'd32: reciprocal_table = 7'd76;
      7'd33: reciprocal_table = 7'd75;
      7'd34: reciprocal_table = 7'd74;
      7'd35: reciprocal_table = 7'd72;
      7'd36: reciprocal_table = 7'd71;
      7'd37: reciprocal_table = 7'd70;
      7'd38: reciprocal_table = 7'd69;
      7'd39: reciprocal_table = 7'd68;
      7'd40: reciprocal_table = 7'd66;
      7'd41: reciprocal_table = 7'd65;
      7'd42: reciprocal_table = 7'd64;
      7'd43: reciprocal_table = 7'd63;
      7'd44: reciprocal_table = 7'd62;
      7'd45: reciprocal_table = 7'd61;
      7'd46: reciprocal_table = 7'd60;
      7'd47: reciprocal_table = 7'd59;
      7'd48: reciprocal_table = 7'd58;
      7'd49: reciprocal_table = 7'd57;
      7'd50: reciprocal_table = 7'd56;
      7'd51: reciprocal_table = 7'd55;
      7'd52: reciprocal_table = 7'd54;
      7'd53: reciprocal_table = 7'd53;
      7'd54: reciprocal_table = 7'd52;
      7'd55: reciprocal_table = 7'd51;
      7'd56: reciprocal_table = 7'd50;
      7'd57: reciprocal_table = 7'd49;
      7'd58: reciprocal_table = 7'd48;
      7'd59: reciprocal_table = 7'd47;
      7'd60: reciprocal_table = 7'd46;
      7'd61: reciprocal_table = 7'd45;
      7'd62: reciprocal_table = 7'd44;
      7'd63: reciprocal_table = 7'd43;
      7'd64: reciprocal_table = 7'd42;
      7'd65: reciprocal_table = 7'd41;
      7'd66: reciprocal_table = 7'd40;
      7'd67: reciprocal_table = 7'd40;
      7'd68: reciprocal_table = 7'd39;
      7'd69: reciprocal_table = 7'd38;
      7'd70: reciprocal_table = 7'd37;
      7'd71: reciprocal_table = 7'd36;
      7'd72: reciprocal_table = 7'd35;
      7'd73: reciprocal_table = 7'd35;
      7'd74: reciprocal_table = 7'd34;
      7'd75: reciprocal_table = 7'd33;
      7'd76: reciprocal_table = 7'd32;
      7'd77: reciprocal_table = 7'd31;
      7'd78: reciprocal_table = 7'd31;
      7'd79: reciprocal_table = 7'd30;
      7'd80: reciprocal_table = 7'd29;
      7'd81: reciprocal_table = 7'd28;
      7'd82: reciprocal_table = 7'd28;
      7'd83: reciprocal_table = 7'd27;
      7'd84: reciprocal_table = 7'd26;
      7'd85: reciprocal_table = 7'd25;
      7'd86: reciprocal_table = 7'd25;
      7'd87: reciprocal_table = 7'd24;
      7'd88: reciprocal_table = 7'd23;
      7'd89: reciprocal_table = 7'd23;
      7'd90: reciprocal_table = 7'd22;
      7'd91: reciprocal_table = 7'd21;
      7'd92: reciprocal_table = 7'd21;
      7'd93: reciprocal_table = 7'd20;
      7'd94: reciprocal_table = 7'd19;
      7'd95: reciprocal_table = 7'd19;
      7'd96: reciprocal_table = 7'd18;
      7'd97: reciprocal_table = 7'd17;
      7'd98: reciprocal_table = 7'd17;
      7'd99: reciprocal_table = 7'd16;
      7'd100: reciprocal_table = 7'd15;
      7'd101: reciprocal_table = 7'd15;
      7'd102: reciprocal_table = 7'd14;
      7'd103: reciprocal_table = 7'd14;
      7'd104: reciprocal_table = 7'd13;
      7'd105: reciprocal_table = 7'd12;
      7'd106: reciprocal_table = 7'd12;
      7'd107: reciprocal_table = 7'd11;
      7'd108: reciprocal_table = 7'd11;
      7'd109: reciprocal_table = 7'd10;
      7'd110: reciprocal_table = 7'd9;
      7'd111: reciprocal_table = 7'd9;
      7'd112: reciprocal_table = 7'd8;
      7'd113: reciprocal_table = 7'd8;
      7'd114: reciprocal_table = 7'd7;
      7'd115: reciprocal_table = 7'd7;
      7'd116: reciprocal_table = 7'd6;
      7'd117: reciprocal_table = 7'd5;
      7'd118: reciprocal_table = 7'd5;
      7'd119: reciprocal_table = 7'd4;
      7'd120: reciprocal_table = 7'd4;
      7'd121: reciprocal_table = 7'd3;
      7'd122: reciprocal_table = 7'd3;
      7'd123: reciprocal_table = 7'd2;
      7'd124: reciprocal_table = 7'd2;
      7'd125: reciprocal_table = 7'd1;
      7'd126: reciprocal_table = 7'd1;
      7'd127: reciprocal_table = 7'd0;
      default: reciprocal_table = 0;
    endcase
  endfunction
  function automatic logic [6:0] rsqrt_table(input logic [6:0] index_bits);
    case (index_bits)
      7'd0: rsqrt_table = 7'd52;
      7'd1: rsqrt_table = 7'd51;
      7'd2: rsqrt_table = 7'd50;
      7'd3: rsqrt_table = 7'd48;
      7'd4: rsqrt_table = 7'd47;
      7'd5: rsqrt_table = 7'd46;
      7'd6: rsqrt_table = 7'd44;
      7'd7: rsqrt_table = 7'd43;
      7'd8: rsqrt_table = 7'd42;
      7'd9: rsqrt_table = 7'd41;
      7'd10: rsqrt_table = 7'd40;
      7'd11: rsqrt_table = 7'd39;
      7'd12: rsqrt_table = 7'd38;
      7'd13: rsqrt_table = 7'd36;
      7'd14: rsqrt_table = 7'd35;
      7'd15: rsqrt_table = 7'd34;
      7'd16: rsqrt_table = 7'd33;
      7'd17: rsqrt_table = 7'd32;
      7'd18: rsqrt_table = 7'd31;
      7'd19: rsqrt_table = 7'd30;
      7'd20: rsqrt_table = 7'd30;
      7'd21: rsqrt_table = 7'd29;
      7'd22: rsqrt_table = 7'd28;
      7'd23: rsqrt_table = 7'd27;
      7'd24: rsqrt_table = 7'd26;
      7'd25: rsqrt_table = 7'd25;
      7'd26: rsqrt_table = 7'd24;
      7'd27: rsqrt_table = 7'd23;
      7'd28: rsqrt_table = 7'd23;
      7'd29: rsqrt_table = 7'd22;
      7'd30: rsqrt_table = 7'd21;
      7'd31: rsqrt_table = 7'd20;
      7'd32: rsqrt_table = 7'd19;
      7'd33: rsqrt_table = 7'd19;
      7'd34: rsqrt_table = 7'd18;
      7'd35: rsqrt_table = 7'd17;
      7'd36: rsqrt_table = 7'd16;
      7'd37: rsqrt_table = 7'd16;
      7'd38: rsqrt_table = 7'd15;
      7'd39: rsqrt_table = 7'd14;
      7'd40: rsqrt_table = 7'd14;
      7'd41: rsqrt_table = 7'd13;
      7'd42: rsqrt_table = 7'd12;
      7'd43: rsqrt_table = 7'd12;
      7'd44: rsqrt_table = 7'd11;
      7'd45: rsqrt_table = 7'd10;
      7'd46: rsqrt_table = 7'd10;
      7'd47: rsqrt_table = 7'd9;
      7'd48: rsqrt_table = 7'd9;
      7'd49: rsqrt_table = 7'd8;
      7'd50: rsqrt_table = 7'd7;
      7'd51: rsqrt_table = 7'd7;
      7'd52: rsqrt_table = 7'd6;
      7'd53: rsqrt_table = 7'd6;
      7'd54: rsqrt_table = 7'd5;
      7'd55: rsqrt_table = 7'd4;
      7'd56: rsqrt_table = 7'd4;
      7'd57: rsqrt_table = 7'd3;
      7'd58: rsqrt_table = 7'd3;
      7'd59: rsqrt_table = 7'd2;
      7'd60: rsqrt_table = 7'd2;
      7'd61: rsqrt_table = 7'd1;
      7'd62: rsqrt_table = 7'd1;
      7'd63: rsqrt_table = 7'd0;
      7'd64: rsqrt_table = 7'd127;
      7'd65: rsqrt_table = 7'd125;
      7'd66: rsqrt_table = 7'd123;
      7'd67: rsqrt_table = 7'd121;
      7'd68: rsqrt_table = 7'd119;
      7'd69: rsqrt_table = 7'd118;
      7'd70: rsqrt_table = 7'd116;
      7'd71: rsqrt_table = 7'd114;
      7'd72: rsqrt_table = 7'd113;
      7'd73: rsqrt_table = 7'd111;
      7'd74: rsqrt_table = 7'd109;
      7'd75: rsqrt_table = 7'd108;
      7'd76: rsqrt_table = 7'd106;
      7'd77: rsqrt_table = 7'd105;
      7'd78: rsqrt_table = 7'd103;
      7'd79: rsqrt_table = 7'd102;
      7'd80: rsqrt_table = 7'd100;
      7'd81: rsqrt_table = 7'd99;
      7'd82: rsqrt_table = 7'd97;
      7'd83: rsqrt_table = 7'd96;
      7'd84: rsqrt_table = 7'd95;
      7'd85: rsqrt_table = 7'd93;
      7'd86: rsqrt_table = 7'd92;
      7'd87: rsqrt_table = 7'd91;
      7'd88: rsqrt_table = 7'd90;
      7'd89: rsqrt_table = 7'd88;
      7'd90: rsqrt_table = 7'd87;
      7'd91: rsqrt_table = 7'd86;
      7'd92: rsqrt_table = 7'd85;
      7'd93: rsqrt_table = 7'd84;
      7'd94: rsqrt_table = 7'd83;
      7'd95: rsqrt_table = 7'd82;
      7'd96: rsqrt_table = 7'd80;
      7'd97: rsqrt_table = 7'd79;
      7'd98: rsqrt_table = 7'd78;
      7'd99: rsqrt_table = 7'd77;
      7'd100: rsqrt_table = 7'd76;
      7'd101: rsqrt_table = 7'd75;
      7'd102: rsqrt_table = 7'd74;
      7'd103: rsqrt_table = 7'd73;
      7'd104: rsqrt_table = 7'd72;
      7'd105: rsqrt_table = 7'd71;
      7'd106: rsqrt_table = 7'd70;
      7'd107: rsqrt_table = 7'd70;
      7'd108: rsqrt_table = 7'd69;
      7'd109: rsqrt_table = 7'd68;
      7'd110: rsqrt_table = 7'd67;
      7'd111: rsqrt_table = 7'd66;
      7'd112: rsqrt_table = 7'd65;
      7'd113: rsqrt_table = 7'd64;
      7'd114: rsqrt_table = 7'd63;
      7'd115: rsqrt_table = 7'd63;
      7'd116: rsqrt_table = 7'd62;
      7'd117: rsqrt_table = 7'd61;
      7'd118: rsqrt_table = 7'd60;
      7'd119: rsqrt_table = 7'd59;
      7'd120: rsqrt_table = 7'd59;
      7'd121: rsqrt_table = 7'd58;
      7'd122: rsqrt_table = 7'd57;
      7'd123: rsqrt_table = 7'd56;
      7'd124: rsqrt_table = 7'd56;
      7'd125: rsqrt_table = 7'd55;
      7'd126: rsqrt_table = 7'd54;
      7'd127: rsqrt_table = 7'd53;
      default: rsqrt_table = 0;
    endcase
  endfunction
  always_comb begin
    sign_bit = operand[F+E];
    exponent = operand[F +: E];
    fraction = operand[F-1:0];
    normalized_exponent = int'({1'b0,exponent});
    normalized_fraction = fraction[F-1 -: 7];
    leading = 0;
    for (int b = 0; b < F; b++) if (fraction[b]) leading = b;
    if (exponent == 0 && fraction != 0) begin
      normalized_exponent = leading-F+1;
      normalized_fraction = 7'((fraction << (F-leading)) >> (F-7));
    end
    index_value = reciprocal_sqrt ? {normalized_exponent[0],normalized_fraction[6:1]}
        : normalized_fraction;
    estimate = reciprocal_sqrt ? rsqrt_table(index_value) : reciprocal_table(index_value);
    output_exponent = reciprocal_sqrt ? (3*Bias-1-normalized_exponent) >>> 1
        : 2*Bias-1-normalized_exponent;
    significand = {1'b1,estimate,{(F-7){1'b0}}};
    if (!reciprocal_sqrt && output_exponent <= 0) begin
      significand = significand >> (1-output_exponent);
      output_exponent = 0;
    end
    encoded = {sign_bit,E'(output_exponent),significand[F-1:0]};
    flags = 0;
    // Special values precede finite overflow handling. Signed zero is retained.
    if (exponent == E'(MaxExp) && fraction != 0) begin
      encoded = {1'b0,{E{1'b1}},1'b1,{(F-1){1'b0}}};
      flags = fraction[F-1] ? 5'd0 : 5'd16;
    end else if (exponent == 0 && fraction == 0) begin
      encoded = {sign_bit,{E{1'b1}},{F{1'b0}}};
      flags = 5'd8;
    end else if (reciprocal_sqrt && sign_bit) begin
      encoded = {1'b0,{E{1'b1}},1'b1,{(F-1){1'b0}}};
      flags = 5'd16;
    end else if (exponent == E'(MaxExp)) begin
      encoded = {sign_bit, {(F + E) {1'b0}}};
    end else if (!reciprocal_sqrt && output_exponent >= MaxExp) begin
      flags = 5'd5;
      if (rm == 1 || (rm == 2 && !sign_bit) || (rm == 3 && sign_bit))
        encoded = {sign_bit, E'(MaxExp - 1), {F{1'b1}}};
      else encoded = {sign_bit, {E{1'b1}}, {F{1'b0}}};
    end
    illegal = rm > 4;
    result = illegal ? 64'd0 : 64'(encoded);
    if (illegal) flags = 0;
  end
endmodule
