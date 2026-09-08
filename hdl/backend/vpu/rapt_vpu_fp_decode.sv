// Same-width and widening floating-point arithmetic admission and raw element operand map.
// Caller supplies resolved FRM and enabled=(VS!=Off && FS!=Off), validates
// register geometry, and captures all outputs at execution request acceptance.
// This module does not authorize architectural effects or process mask bits.
module rapt_vpu_fp_decode #(
    parameter int ELEN = 64
) (
    // Register indices and vm belong to the caller.
    /* verilator lint_off UNUSEDSIGNAL */
    input logic [31:0] insn,
    /* verilator lint_on UNUSEDSIGNAL */
    input logic [2:0] sew,
    frm,
    input logic enabled,
    vill,
    input logic [63:0] vs2,
    vs1,
    old_destination,
    scalar,
    output logic recognized,
    legal,
    source_scalar,
    uses_old_destination,
    output logic divide_sqrt,
    sqrt_operation,
    uses_vs1,
    output logic miscellaneous,
    mask_result,
    widen,
    wide_source_a,
    output logic format_convert,
    narrow,
    round_odd,
    output logic [3:0] misc_operation,
    output logic [1:0] operation,
    output logic negate_product,
    negate_addend,
    output logic [63:0] a,
    b,
    c
);
  logic fused, reverse_subtract, accumulator, division, square_root;
  logic [63:0] operand;
  logic [1:0] selected_operation;
  logic misc, classify, estimate, widening, wide_input, conversion, narrowing, odd;
  logic [3:0] selected_misc;
  always_comb begin
    recognized = 0;
    fused = 0;
    reverse_subtract = 0;
    accumulator = 0;
    selected_operation = 0;
    division = 0;
    square_root = 0;
    misc = 0;
    classify = 0;
    estimate = 0;
    selected_misc = 0;
    widening = 0;
    wide_input = 0;
    conversion = 0;
    narrowing = 0;
    odd = 0;
    if (insn[6:0] == 7'h57 && (insn[14:12] == 1 || insn[14:12] == 5)) begin
      case (insn[31:26])
        6'h12: begin
          conversion = insn[19:15] == 12 || insn[19:15] == 20 || insn[19:15] == 21;
          recognized = insn[14:12] == 1 && conversion;
          widening = insn[19:15] == 12;
          narrowing = insn[19:15] == 20 || insn[19:15] == 21;
          odd = insn[19:15] == 21;
        end
        6'h30, 6'h32, 6'h34, 6'h36: begin
          recognized = 1;
          widening = 1;
          wide_input = insn[28];
          selected_operation = insn[27] ? 2'd2 : 2'd1;
        end
        6'h38: begin
          recognized = 1;
          widening = 1;
          selected_operation = 3;
        end
        6'h3c, 6'h3d, 6'h3e, 6'h3f: begin
          recognized = 1;
          widening = 1;
          fused = 1;
          accumulator = 1;
        end
        6'h00: begin
          recognized = 1;
          selected_operation = 1;
        end
        6'h02: begin
          recognized = 1;
          selected_operation = 2;
        end
        6'h20: begin
          recognized = 1;
          division = 1;
        end
        6'h21: begin
          recognized = insn[14:12] == 5;
          division = 1;
          reverse_subtract = 1;
        end
        6'h13: begin
          square_root = insn[19:15] == 0;
          classify = insn[19:15] == 16;
          estimate = insn[19:15] == 4 || insn[19:15] == 5;
          misc = classify || estimate;
          selected_misc = estimate ? (insn[15] ? 4'd12 : 4'd13) : classify ? 4'd5 : 4'd0;
          recognized = insn[14:12] == 1 && (square_root || classify || estimate);
        end
        6'h04: begin
          recognized = 1;
          misc = 1;
          selected_misc = 0;
        end
        6'h06: begin
          recognized = 1;
          misc = 1;
          selected_misc = 1;
        end
        6'h08: begin
          recognized = 1;
          misc = 1;
          selected_misc = 2;
        end
        6'h09: begin
          recognized = 1;
          misc = 1;
          selected_misc = 3;
        end
        6'h0a: begin
          recognized = 1;
          misc = 1;
          selected_misc = 4;
        end
        6'h18: begin
          recognized = 1;
          misc = 1;
          selected_misc = 6;
        end
        6'h1c: begin
          recognized = 1;
          misc = 1;
          selected_misc = 7;
        end
        6'h1b: begin
          recognized = 1;
          misc = 1;
          selected_misc = 8;
        end
        6'h19: begin
          recognized = 1;
          misc = 1;
          selected_misc = 9;
        end
        6'h1d: begin
          recognized = insn[14:12] == 5;
          misc = 1;
          selected_misc = 10;
        end
        6'h1f: begin
          recognized = insn[14:12] == 5;
          misc = 1;
          selected_misc = 11;
        end
        6'h24: begin
          recognized = 1;
          selected_operation = 3;
        end
        6'h27: begin
          recognized = insn[14:12] == 5;
          selected_operation = 2;
          reverse_subtract = 1;
        end
        6'h28, 6'h29, 6'h2a, 6'h2b, 6'h2c, 6'h2d, 6'h2e, 6'h2f: begin
          recognized = 1;
          fused = 1;
          accumulator = insn[28];
        end
        default: ;
      endcase
    end
    legal = recognized && enabled && !vill && frm <= 4
        && (sew == 2 || (sew == 3 && ELEN >= 64)) && ELEN >= 32
        && (!(widening || conversion) || (sew == 2 && ELEN >= 64));
    widen = 0;
    wide_source_a = 0;
    format_convert = 0;
    narrow = 0;
    round_odd = 0;
    divide_sqrt = 0;
    sqrt_operation = 0;
    uses_vs1 = 0;
    miscellaneous = 0;
    mask_result = 0;
    misc_operation = 0;
    source_scalar = 0;
    uses_old_destination = 0;
    operation = 0;
    negate_product = 0;
    negate_addend = 0;
    a = 0;
    b = 0;
    c = 0;
    operand = 0;
    if (legal) begin
      widen = widening;
      wide_source_a = wide_input;
      format_convert = conversion;
      narrow = narrowing;
      round_odd = odd;
      divide_sqrt = division || square_root;
      sqrt_operation = square_root;
      uses_vs1 = !(square_root || classify || estimate || conversion);
      miscellaneous = misc;
      misc_operation = selected_misc;
      mask_result = misc && selected_misc >= 6 && selected_misc <= 11;
      source_scalar = insn[14:12] == 5;
      uses_old_destination = fused;
      operation = selected_operation;
      // Only scalar FPR inputs are NaN-box checked. Vector elements are raw.
      operand = source_scalar ? (sew == 2 && scalar[63:32] != 32'hffffffff
          ? 64'h000000007fc00000 : scalar) : vs1;
      if (fused) begin
        a = operand;
        b = accumulator ? vs2 : old_destination;
        c = accumulator ? old_destination : vs2;
        negate_product = insn[26];
        negate_addend = insn[26] ^ insn[27];
      end else begin
        a = reverse_subtract ? operand : vs2;
        b = (square_root || classify || estimate || conversion) ? 64'b0 : reverse_subtract ? vs2 : operand;
      end
      if (sew == 2) begin
        if (!wide_input && !narrowing) a = {32'b0, a[31:0]};
        b = {32'b0, b[31:0]};
        if (!widening) c = {32'b0, c[31:0]};
      end
    end
  end
endmodule
