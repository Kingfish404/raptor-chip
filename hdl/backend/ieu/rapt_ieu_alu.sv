`include "rapt.svh"

module rapt_ieu_alu #(
    parameter int XLEN = `RAPT_XLEN
) (
    input        [XLEN-1:0] s1,
    input        [XLEN-1:0] s2,
    input        [     5:0] op,
    input                   word,  // RV64 W-variant: operate on lower 32 bits, sign-extend result
    output logic [XLEN-1:0] out_r
);
  // Shift amount width: 5-bit for RV32, 6-bit for RV64 base (W-variants use 5 bits)
  localparam int ShamtW = $clog2(XLEN);  // 5 for RV32, 6 for RV64
  logic [XLEN-1:0] alu_r;

  // zext.w(rs1): zero-extend low 32 bits for RV64 Zba .UW variants
  logic [XLEN-1:0] s1_uw;
  assign s1_uw = (XLEN > 32) ? {{(XLEN - 32) {1'b0}}, s1[31:0]} : s1;

  // `word_uw`: for SH1/2/3ADD, when word=1 it means .UW semantics (zext.w(rs1));
  // for ADD.UW and SLLI.UW we use dedicated opcodes below.
  logic is_sh_uw;
  assign is_sh_uw = word && (XLEN > 32);

  // Share arithmetic hardware explicitly across opcode families.
  logic [XLEN-1:0] add_lhs, add_rhs, add_result;
  logic subtract;
  assign subtract = op == `RAPT_ALU_SUB_;
  always_comb begin
    add_lhs = s1;
    case (op)
      `RAPT_ALU_SH1ADD: add_lhs = (is_sh_uw ? s1_uw : s1) << 1;
      `RAPT_ALU_SH2ADD: add_lhs = (is_sh_uw ? s1_uw : s1) << 2;
      `RAPT_ALU_SH3ADD: add_lhs = (is_sh_uw ? s1_uw : s1) << 3;
      `RAPT_ALU_ADD_UW: add_lhs = s1_uw;
      default: ;
    endcase
  end
  assign add_rhs = s2 ^ {XLEN{subtract}};
  assign add_result = add_lhs + add_rhs + XLEN'(subtract);
  logic less_unsigned, less_signed, operands_equal;
  assign less_unsigned = s1 < s2;
  assign less_signed = s1[XLEN-1] != s2[XLEN-1] ? s1[XLEN-1] : less_unsigned;
  assign operands_equal = s1 == s2;

  // A shared right shifter handles left operations by bit reversal. Repeat
  // the low word for word rotates so the wrap boundary remains at 32 bits.
  logic shift_left, shift_rotate, shift_arithmetic, shift_fill;
  logic [ShamtW-1:0] shift_amount;
  logic [XLEN-1:0] shift_input, shift_ordered, shift_result;
  logic [XLEN-1:0] shift_stage[ShamtW+1];
  assign shift_left = op == `RAPT_ALU_SLL_ || op == `RAPT_ALU_SLLI_UW
      || op == `RAPT_ALU_ROL_;
  assign shift_rotate = op == `RAPT_ALU_ROL_ || op == `RAPT_ALU_ROR_;
  assign shift_arithmetic = op == `RAPT_ALU_SRA_;
  assign shift_amount = (word && op != `RAPT_ALU_SLLI_UW && op != `RAPT_ALU_BEXT)
      ? ShamtW'(s2[4:0]) : s2[ShamtW-1:0];
  always_comb begin
    shift_input = s1;
    if (op == `RAPT_ALU_SLLI_UW) shift_input = s1_uw;
    else if (word && XLEN > 32) begin
      if (shift_rotate) shift_input = XLEN'({s1[31:0], s1[31:0]});
      else if (op == `RAPT_ALU_SRL_) shift_input = s1_uw;
      else if (shift_arithmetic) shift_input = {{XLEN - 32{s1[31]}}, s1[31:0]};
    end
  end
  assign shift_fill = shift_arithmetic && shift_input[XLEN-1];
  for (genvar b = 0; b < XLEN; b++) begin : g_shift_reverse
    assign shift_ordered[b] = shift_left ? shift_input[XLEN-1-b] : shift_input[b];
    assign shift_result[b] = shift_left ? shift_stage[ShamtW][XLEN-1-b]
        : shift_stage[ShamtW][b];
  end
  assign shift_stage[0] = shift_ordered;
  for (genvar level = 0; level < ShamtW; level++) begin : g_shift_stage
    localparam int Distance = 1 << level;
    wire [Distance-1:0] high_bits = shift_rotate ? shift_stage[level][Distance-1:0]
        : {Distance{shift_fill}};
    assign shift_stage[level+1] = shift_amount[level]
        ? {high_bits, shift_stage[level][XLEN-1:Distance]} : shift_stage[level];
  end

  // Encode the first and last set bits with a shared balanced validity tree.
  // The word form masks the upper half before selection. Zero operands return
  // the active width, without a serial found/increment dependency per bit.
  localparam int ZeroLeaves = 1 << ShamtW;
  wire zero_nonzero[2*ZeroLeaves];
  wire [ShamtW-1:0] zero_first[2*ZeroLeaves], zero_last[2*ZeroLeaves];
  wire [ShamtW:0] count_width, clz_count, ctz_count;
  for (genvar bit_idx = 0; bit_idx < ZeroLeaves; bit_idx++) begin : g_zero_leaf
    if (bit_idx < XLEN) begin : g_bit
      assign zero_nonzero[ZeroLeaves+bit_idx] =
          s1[bit_idx] && !(word && XLEN > 32 && bit_idx >= 32);
    end else begin : g_pad
      assign zero_nonzero[ZeroLeaves+bit_idx] = 1'b0;
    end
    assign zero_first[ZeroLeaves+bit_idx] = ShamtW'(bit_idx);
    assign zero_last[ZeroLeaves+bit_idx] = ShamtW'(bit_idx);
  end
  for (genvar node = 1; node < ZeroLeaves; node++) begin : g_zero_select
    assign zero_nonzero[node] = zero_nonzero[2*node] || zero_nonzero[2*node+1];
    assign zero_first[node] = zero_nonzero[2*node] ? zero_first[2*node] : zero_first[2*node+1];
    assign zero_last[node] = zero_nonzero[2*node+1] ? zero_last[2*node+1] : zero_last[2*node];
  end
  assign count_width = (ShamtW+1)'(word && XLEN > 32 ? 32 : XLEN);
  assign ctz_count = zero_nonzero[1] ? (ShamtW+1)'(zero_first[1]) : count_width;
  assign clz_count = !zero_nonzero[1] ? count_width : (word && XLEN > 32)
      ? (ShamtW+1)'(31) - (ShamtW+1)'(zero_last[1])
      : (ShamtW+1)'(XLEN-1) - (ShamtW+1)'(zero_last[1]);

  // CPOP: independent bit leaves and a balanced sum tree, not XLEN serial
  // conditional increments. Mask W operands before reduction; zero padding
  // keeps the structure well-defined for non-power-of-two widths too.
  localparam int PopLeaves = 1 << ShamtW;
  wire [ShamtW:0] pop_count[2*PopLeaves];
  for (genvar bit_idx = 0; bit_idx < PopLeaves; bit_idx++) begin : g_pop_leaf
    if (bit_idx < XLEN) begin : g_bit
      assign pop_count[PopLeaves + bit_idx] = (ShamtW+1)'(
          s1[bit_idx] && !(word && XLEN > 32 && bit_idx >= 32));
    end else begin : g_pad
      assign pop_count[PopLeaves+bit_idx] = '0;
    end
  end
  for (genvar node = 1; node < PopLeaves; node++) begin : g_pop_sum
    assign pop_count[node] = pop_count[2*node] + pop_count[2*node+1];
  end

  // Share the full polynomial product across CLMUL/H/R. Independent masked
  // partial products feed a balanced XOR tree, bounding the depth to log2(XLEN).
  // Conditional accumulation in an XLEN-step loop creates a serial mux/XOR chain.
  localparam int ClmulLeaves = 1 << ShamtW;
  wire [2*XLEN-1:0] clmul_tree[2*ClmulLeaves];
  for (genvar bit_idx = 0; bit_idx < ClmulLeaves; bit_idx++) begin : g_clmul_leaf
    if (bit_idx < XLEN) begin : g_bit
      assign clmul_tree[ClmulLeaves+bit_idx] =
          {2*XLEN{s2[bit_idx]}} & ((2*XLEN)'(s1) << bit_idx);
    end else begin : g_pad
      assign clmul_tree[ClmulLeaves+bit_idx] = '0;
    end
  end
  for (genvar node = 1; node < ClmulLeaves; node++) begin : g_clmul_xor
    assign clmul_tree[node] = clmul_tree[2*node] ^ clmul_tree[2*node+1];
  end

  always_comb begin
    unique case (op)
      // verilog_format: off
      `RAPT_ALU_ADD_: begin alu_r = add_result; end
      `RAPT_ALU_SUB_: begin alu_r = add_result; end
      `RAPT_ALU_EQ__: begin alu_r = operands_equal ? 'h1 : 0; end
      `RAPT_ALU_SLT_: begin alu_r = less_signed ? 'h1 : 0;  end
      `RAPT_ALU_SLE_: begin alu_r = (less_signed || operands_equal) ? 'h1 : 0; end
      `RAPT_ALU_SGE_: begin alu_r = !less_signed ? 'h1 : 0; end
      `RAPT_ALU_SLTU: begin alu_r = less_unsigned ? 'h1 : 0;  end
      `RAPT_ALU_SLEU: begin alu_r = (less_unsigned || operands_equal) ? 'h1 : 0; end
      `RAPT_ALU_SGEU: begin alu_r = !less_unsigned ? 'h1 : 0; end
      `RAPT_ALU_XOR_: begin alu_r = s1 ^ s2; end
      `RAPT_ALU_OR__: begin alu_r = s1 | s2; end
      `RAPT_ALU_AND_: begin alu_r = s1 & s2; end
      `RAPT_ALU_SLL_: begin alu_r = shift_result; end
      `RAPT_ALU_SRL_: begin alu_r = shift_result; end
      `RAPT_ALU_SRA_: begin alu_r = shift_result; end

      // Zba (Address Generation). For RV64, when `word`=1 these are the .UW
      // variants (sh1add.uw / sh2add.uw / sh3add.uw): zero-extend rs1[31:0]
      // before the shift-add. Output sign-ext is suppressed below for SH*ADD.
      `RAPT_ALU_SH1ADD: begin alu_r = add_result; end
      `RAPT_ALU_SH2ADD: begin alu_r = add_result; end
      `RAPT_ALU_SH3ADD: begin alu_r = add_result; end

      // RV64 Zba dedicated .UW opcodes (full 64-bit result, no trunc+sext).
      `RAPT_ALU_ADD_UW:  begin alu_r = add_result; end
      `RAPT_ALU_SLLI_UW: begin alu_r = shift_result; end

      // Zbb (Basic Bit-manipulation): logic
      `RAPT_ALU_ANDN: begin alu_r = s1 & ~s2; end
      `RAPT_ALU_ORN_:  begin alu_r = s1 | ~s2; end
      `RAPT_ALU_XNOR: begin alu_r = ~(s1 ^ s2); end

      // Zbb: count
      `RAPT_ALU_CLZ_:  begin alu_r = XLEN'(clz_count); end
      `RAPT_ALU_CTZ_:  begin alu_r = XLEN'(ctz_count); end
      `RAPT_ALU_CPOP: begin alu_r = XLEN'(pop_count[1]); end

      // Zbb: compare-and-select
      `RAPT_ALU_MAX_:  begin alu_r = !less_signed ? s1 : s2; end
      `RAPT_ALU_MAXU: begin alu_r = !less_unsigned ? s1 : s2; end
      `RAPT_ALU_MIN_:  begin alu_r = less_signed ? s1 : s2; end
      `RAPT_ALU_MINU: begin alu_r = less_unsigned ? s1 : s2; end

      // Zbb: sign/zero extension
      `RAPT_ALU_SEXTB: begin alu_r = {{XLEN-8{s1[7]}}, s1[7:0]}; end
      `RAPT_ALU_SEXTH: begin alu_r = {{XLEN-16{s1[15]}}, s1[15:0]}; end
      `RAPT_ALU_ZEXTH: begin alu_r = {{XLEN-16{1'b0}}, s1[15:0]}; end

      // Zbb: byte-level operations
      `RAPT_ALU_REV8: begin
        for (int i = 0; i < XLEN; i += 8)
          alu_r[i+:8] = s1[XLEN-8-i+:8];
      end
      `RAPT_ALU_ORCB: begin
        for (int i = 0; i < XLEN; i += 8)
          alu_r[i+:8] = {8{|s1[i+:8]}};
      end

      // Zbb: rotate
      `RAPT_ALU_ROL_: begin alu_r = shift_result; end
      `RAPT_ALU_ROR_: begin alu_r = shift_result; end

      // Zbs (Single-bit Operations)
      `RAPT_ALU_BCLR: begin alu_r = s1 & ~(XLEN'(1) << s2[ShamtW-1:0]); end
      `RAPT_ALU_BEXT: begin alu_r = XLEN'(shift_result[0]); end
      `RAPT_ALU_BINV: begin alu_r = s1 ^ (XLEN'(1) << s2[ShamtW-1:0]); end
      `RAPT_ALU_BSET: begin alu_r = s1 | (XLEN'(1) << s2[ShamtW-1:0]); end

      // Zicond (Conditional Operations)
      `RAPT_ALU_CZERO_EQZ: begin alu_r = (s2 == '0) ? '0 : s1; end
      `RAPT_ALU_CZERO_NEZ: begin alu_r = (s2 != '0) ? '0 : s1; end

      // Zbc (Carry-less Multiplication)
      `RAPT_ALU_CLMUL:  begin alu_r = clmul_tree[1][XLEN-1:0]; end
      `RAPT_ALU_CLMULH: begin alu_r = clmul_tree[1][2*XLEN-1:XLEN]; end
      `RAPT_ALU_CLMULR: begin alu_r = clmul_tree[1][2*XLEN-2-:XLEN]; end
      // verilog_format: on
      default: begin
        alu_r = 'h0;
      end
    endcase
  end

  // W-variant: sign-extend lower 32-bit result to XLEN.
  // .UW variants (ALU_ADD_UW / ALU_SLLI_UW and SH*ADD+word=1) produce a full
  // 64-bit result and must NOT be truncated/sign-extended here.
  generate
    if (XLEN > 32) begin : gen_word_ext
      logic is_uw_op;
      assign is_uw_op = (op == `RAPT_ALU_ADD_UW)
             || (op == `RAPT_ALU_SLLI_UW)
             || (op == `RAPT_ALU_SH1ADD)
             || (op == `RAPT_ALU_SH2ADD)
             || (op == `RAPT_ALU_SH3ADD);
      assign out_r = (word && !is_uw_op) ? {{XLEN - 32{alu_r[31]}}, alu_r[31:0]} : alu_r;
    end else begin : gen_no_word
      assign out_r = alu_r;
    end
  endgenerate
endmodule
