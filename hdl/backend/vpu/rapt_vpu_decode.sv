// Standalone raw instruction decoder. Only implemented operations are admitted;
// unsupported/reserved encodings trap instead of falling through to an ALU op.
// Scalar-core Chisel decode is untouched until the integration adapter exists.
module rapt_vpu_decode (
    // Register identities are validated by the geometry-aware scheduler.
    /* verilator lint_off UNUSEDSIGNAL */
    input logic [31:0] insn,
    /* verilator lint_on UNUSEDSIGNAL */
    output logic is_config,
    is_csr,
    is_integer,
    is_memory,
    is_reduce,
    is_move,
    is_scalar_move,
    element_index,
    is_mask_scan,
    mask_prefix,
    iota,
    compress,
    slide,
    gather,
    gather16,
    output logic src_vector,
    uses_vs2,
    merge,
    muldiv,
    mac,
    mask_result,
    mask_logic,
    carry,
    output logic widen,
    wide_a,
    narrow,
    extend,
    a_signed,
    b_signed,
    output logic fixed_point,
    fraction,
    output logic [3:0] fixed_op,
    output logic [1:0] extend_shift,
    output logic [5:0] alu_op,
    output logic illegal
);
  logic opiv;
  always_comb begin
    is_config = 0;
    is_csr = insn[6:0] == 7'h73 && insn[13:12] != 0;
    is_integer = 0;
    is_reduce = 0;
    is_move = 0;
    is_scalar_move = 0;
    element_index = 0;
    is_mask_scan = 0;
    mask_prefix = 0;
    iota = 0;
    compress = 0;
    slide = 0;
    gather = 0;
    gather16 = 0;
    // Full memory legality, including EMUL and special transfers, belongs to
    // the geometry-aware memory sequencer.
    is_memory = insn[6:0] == 7'h07 || insn[6:0] == 7'h27;
    src_vector = insn[14:12] == 3'b000 || insn[14:12] == 3'b010;
    uses_vs2 = 1;
    merge = 0;
    muldiv = 0;
    mac = 0;
    mask_result = 0;
    mask_logic = 0;
    carry = 0;
    widen = 0;
    wide_a = 0;
    narrow = 0;
    extend = 0;
    a_signed = 0;
    b_signed = 0;
    extend_shift = 0;
    fixed_point = 0;
    fraction = 0;
    fixed_op = 0;
    alu_op = insn[31:26];
    opiv = insn[14:12] == 3'b000 || insn[14:12] == 3'b100 || insn[14:12] == 3'b011;
    if (insn[6:0] == 7'h57) begin
      if (insn[14:12] == 3'b111)
        is_config = !insn[31] || insn[31:30] == 2'b11 || insn[31:25] == 7'b1000000;
      else if ((insn[31:26] == 6'h0c && opiv) || (insn[31:26] == 6'h0e && insn[14:12] == 0)) begin
        is_integer = 1;
        gather = 1;
        gather16 = insn[27];
      end else if ((insn[31:26] == 6'h0e || insn[31:26] == 6'h0f)
          && (insn[14:12] == 3 || insn[14:12] == 4 || insn[14:12] == 6)) begin
        is_integer = 1;
        slide = 1;
        src_vector = 0;
      end else if (insn[31:26] == 6'h17 && insn[14:12] == 2 && insn[25]) begin
        is_integer = 1;
        compress = 1;
        src_vector = 0;
      end else if (insn[31:26] == 6'h14 && insn[14:12] == 2 && insn[19:15] == 16) begin
        is_integer = 1;
        iota = 1;
        src_vector = 0;
      end else if (insn[31:26] == 6'h14 && insn[14:12] == 2 && insn[19:15] >= 1 && insn[19:15] <= 3) begin
        is_integer = 1;
        mask_prefix = 1;
        mask_result = 1;
        mask_logic = 1;
        src_vector = 0;
      end else if (insn[31:26] == 6'h10 && insn[14:12] == 2 && insn[19:16] == 4'b1000) begin
        is_mask_scan = 1;
      end else if (insn[31:26] == 6'h14 && insn[14:12] == 2
          && insn[19:15] == 17 && insn[24:20] == 0) begin
        is_integer = 1;
        element_index = 1;
        uses_vs2 = 0;
        src_vector = 0;
      end else if (insn[31:26] == 6'h10 && insn[25]
          && ((insn[14:12] == 2 && insn[19:15] == 0)
              || (insn[14:12] == 6 && insn[24:20] == 0))) begin
        is_scalar_move = 1;
      end else if (insn[14:12] == 3 && insn[31:26] == 6'h27) begin
        is_move = 1;
      end else if ((insn[14:12] == 3'b010 && insn[31:29] == 0)
          || (insn[14:12] == 0 && insn[31:27] == 5'b11000)) begin
        is_reduce = 1;
      end else if ((insn[14:12] == 3'b010 || insn[14:12] == 3'b110) && insn[31:28] == 4'b0010) begin
        is_integer = 1;
        fixed_point = 1;
        fixed_op = {2'b01,insn[27:26]};
      end else if ((insn[14:12] == 3'b010 || insn[14:12] == 3'b110) && insn[31:30] == 2'b11) begin
        widen = 1;
        if (!insn[29]) begin
          is_integer = 1;
          wide_a = insn[28];
          a_signed = insn[26];
          b_signed = insn[26];
          alu_op = insn[27] ? 6'h02 : 6'h00;
        end else if (insn[31:26] != 6'h39 && (insn[31:26] != 6'h3e || !src_vector)) begin
          is_integer = 1;
          muldiv = 1;
          mac = insn[28];
          case (insn[31:26])
            6'h3a, 6'h3e: a_signed = 1;
            6'h3b, 6'h3d: begin a_signed = 1; b_signed = 1; end
            6'h3f: b_signed = 1;
            default: ;
          endcase
        end
      end else if (insn[14:12] == 3'b010 && insn[31:26] == 6'h12
          && insn[19:15] >= 2 && insn[19:15] <= 7) begin
        is_integer = 1;
        extend = 1;
        src_vector = 0;
        extend_shift = 2'(4-int'(insn[17:16]));
        a_signed = insn[15];
      end else if (insn[14:12] == 3'b010 && insn[31:29] == 3'b011) begin
        is_integer = insn[25];
        mask_result = 1;
        mask_logic = 1;
      end else if ((insn[14:12] == 3'b010 || insn[14:12] == 3'b110)
          && (insn[31:29] == 3'b100 || insn[31:26] == 6'h29
              || insn[31:26] == 6'h2b || insn[31:26] == 6'h2d || insn[31:26] == 6'h2f)) begin
        is_integer = 1;
        muldiv = 1;
        mac = insn[29];
      end else if (opiv) begin
        case (insn[31:26])
          6'h00, 6'h09, 6'h0a, 6'h0b, 6'h25, 6'h28, 6'h29: is_integer = 1;
          6'h02, 6'h04, 6'h05, 6'h06, 6'h07: is_integer = insn[14:12] != 3'b011;
          6'h10, 6'h11, 6'h12, 6'h13: begin
            carry = 1; mask_result = insn[26];
            is_integer = (insn[26] || !insn[25]) && (!insn[27] || insn[14:12] != 3'b011);
          end
          6'h2c, 6'h2d: begin
            is_integer = 1; narrow = 1; alu_op = insn[26] ? 6'h29 : 6'h28;
          end
          6'h20, 6'h21, 6'h22, 6'h23: begin
            is_integer = !insn[27] || insn[14:12] != 3'b011;
            fixed_point = 1; fixed_op = {2'b00,insn[27:26]};
          end
          6'h2a, 6'h2b: begin is_integer = 1; fixed_point = 1; fixed_op = {3'b100,insn[26]}; end
          6'h2e, 6'h2f: begin
            is_integer = 1; fixed_point = 1; fixed_op = {3'b101,insn[26]}; narrow = 1;
          end
          6'h27: begin
            is_integer = insn[14:12] != 3'b011;
            fixed_point = 1; fraction = 1; muldiv = 1; fixed_op = 12;
          end
          6'h03: is_integer = !src_vector;
          6'h18, 6'h19, 6'h1c, 6'h1d: begin is_integer = 1; mask_result = 1; end
          6'h1a, 6'h1b: begin is_integer = insn[14:12] != 3'b011; mask_result = 1; end
          6'h1e, 6'h1f: begin is_integer = !src_vector; mask_result = 1; end
          6'h17: begin
            merge = !insn[25];
            uses_vs2 = !insn[25];
            is_integer = !insn[25] || insn[24:20] == 0;
          end
          default: ;
        endcase
      end
    end
    illegal = !(is_config || is_csr || is_integer || is_memory || is_reduce || is_move || is_scalar_move || is_mask_scan);
  end
endmodule
