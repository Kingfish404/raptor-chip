`include "ysyx.svh"

module ysyx_exu_alu #(
    parameter bit [7:0] XLEN = `YSYX_XLEN
) (
    input        [XLEN-1:0] s1,
    input        [XLEN-1:0] s2,
    input        [     5:0] op,
    input                   word,  // RV64 W-variant: operate on lower 32 bits, sign-extend result
    output logic [XLEN-1:0] out_r
);
  // Shift amount mask: 5-bit for RV32 or W-variants, 6-bit for RV64 base
  localparam int ShamtMask = XLEN - 1;  // 31 for RV32, 63 for RV64
  localparam int ShamtW = $clog2(XLEN);  // 5 for RV32, 6 for RV64
  logic [XLEN-1:0] alu_r;

  // CLZ helper: count leading zeros
  function automatic logic [ShamtW:0] fn_clz(input logic [XLEN-1:0] val, input logic w);
    logic [ShamtW:0] cnt;
    logic found;
    cnt   = 0;
    found = 0;
    if (w && XLEN > 32) begin
      // W-variant: operate on lower 32 bits
      for (int i = 31; i >= 0; i--) begin
        if (!found && val[i] == 1'b0) cnt = cnt + 1;
        else found = 1'b1;
      end
    end else begin
      for (int i = XLEN - 1; i >= 0; i--) begin
        if (!found && val[i] == 1'b0) cnt = cnt + 1;
        else found = 1'b1;
      end
    end
    return cnt;
  endfunction

  // CTZ helper: count trailing zeros
  function automatic logic [ShamtW:0] fn_ctz(input logic [XLEN-1:0] val, input logic w);
    logic [ShamtW:0] cnt;
    logic found;
    int upper;
    cnt   = 0;
    found = 0;
    upper = (w && XLEN > 32) ? 32 : XLEN;
    for (int i = 0; i < XLEN; i++) begin
      if (i < upper) begin
        if (!found && val[i] == 1'b0) cnt = cnt + 1;
        else found = 1'b1;
      end
    end
    return cnt;
  endfunction

  // CPOP helper: population count
  function automatic logic [ShamtW:0] fn_cpop(input logic [XLEN-1:0] val, input logic w);
    logic [ShamtW:0] cnt;
    int upper;
    cnt   = 0;
    upper = (w && XLEN > 32) ? 32 : XLEN;
    for (int i = 0; i < XLEN; i++) begin
      if (i < upper && val[i]) cnt = cnt + 1;
    end
    return cnt;
  endfunction

  always_comb begin
    unique case (op)
      // verilog_format: off
      `YSYX_ALU_ADD_: begin alu_r = s1 + s2; end
      `YSYX_ALU_SUB_: begin alu_r = s1 - s2; end
      `YSYX_ALU_EQ__: begin alu_r = (s1 == s2) ? 'h1 : 0; end
      `YSYX_ALU_SLT_: begin alu_r = (($signed(s1)) < ($signed(s2))) ? 'h1 : 0;  end
      `YSYX_ALU_SLE_: begin alu_r = (($signed(s1)) <= ($signed(s2))) ? 'h1 : 0; end
      `YSYX_ALU_SGE_: begin alu_r = (($signed(s1)) >= ($signed(s2))) ? 'h1 : 0; end
      `YSYX_ALU_SLTU: begin alu_r = (s1 < s2) ? 'h1 : 0;  end
      `YSYX_ALU_SLEU: begin alu_r = (s1 <= s2) ? 'h1 : 0; end
      `YSYX_ALU_SGEU: begin alu_r = (s1 >= s2) ? 'h1 : 0; end
      `YSYX_ALU_XOR_: begin alu_r = s1 ^ s2; end
      `YSYX_ALU_OR__: begin alu_r = s1 | s2; end
      `YSYX_ALU_AND_: begin alu_r = s1 & s2; end
      `YSYX_ALU_SLL_: begin alu_r = word ? s1 << s2[4:0] : s1 << s2[ShamtW-1:0]; end
      `YSYX_ALU_SRL_: begin alu_r = word
        ? {{XLEN-32{1'b0}}, s1[31:0]} >> s2[4:0] : s1 >> s2[ShamtW-1:0]; end
      `YSYX_ALU_SRA_: begin alu_r = word
        ? $signed({{XLEN-32{s1[31]}}, s1[31:0]}) >>> s2[4:0] : $signed(s1) >>> s2[ShamtW-1:0]; end

      // Zba (Address Generation)
      `YSYX_ALU_SH1ADD: begin alu_r = (s1 << 1) + s2; end
      `YSYX_ALU_SH2ADD: begin alu_r = (s1 << 2) + s2; end
      `YSYX_ALU_SH3ADD: begin alu_r = (s1 << 3) + s2; end

      // Zbb (Basic Bit-manipulation): logic
      `YSYX_ALU_ANDN: begin alu_r = s1 & ~s2; end
      `YSYX_ALU_ORN_:  begin alu_r = s1 | ~s2; end
      `YSYX_ALU_XNOR: begin alu_r = ~(s1 ^ s2); end

      // Zbb: count
      `YSYX_ALU_CLZ_:  begin alu_r = XLEN'(fn_clz(s1, word)); end
      `YSYX_ALU_CTZ_:  begin alu_r = XLEN'(fn_ctz(s1, word)); end
      `YSYX_ALU_CPOP: begin alu_r = XLEN'(fn_cpop(s1, word)); end

      // Zbb: compare-and-select
      `YSYX_ALU_MAX_:  begin alu_r = ($signed(s1) >= $signed(s2)) ? s1 : s2; end
      `YSYX_ALU_MAXU: begin alu_r = (s1 >= s2) ? s1 : s2; end
      `YSYX_ALU_MIN_:  begin alu_r = ($signed(s1) < $signed(s2)) ? s1 : s2; end
      `YSYX_ALU_MINU: begin alu_r = (s1 < s2) ? s1 : s2; end

      // Zbb: sign/zero extension
      `YSYX_ALU_SEXTB: begin alu_r = {{XLEN-8{s1[7]}}, s1[7:0]}; end
      `YSYX_ALU_SEXTH: begin alu_r = {{XLEN-16{s1[15]}}, s1[15:0]}; end
      `YSYX_ALU_ZEXTH: begin alu_r = {{XLEN-16{1'b0}}, s1[15:0]}; end

      // Zbb: byte-level operations
      `YSYX_ALU_REV8: begin
        for (int i = 0; i < XLEN; i += 8)
          alu_r[i+:8] = s1[XLEN-8-i+:8];
      end
      `YSYX_ALU_ORCB: begin
        for (int i = 0; i < XLEN; i += 8)
          alu_r[i+:8] = {8{|s1[i+:8]}};
      end

      // Zbb: rotate
      `YSYX_ALU_ROL_: begin
        if (word && XLEN > 32) begin
          logic [31:0] rot32;
          rot32 = (s1[31:0] << s2[4:0]) | (s1[31:0] >> (5'd0 - s2[4:0]));
          alu_r = {{XLEN-32{rot32[31]}}, rot32};
        end else begin
          alu_r = (s1 << s2[ShamtW-1:0]) | (s1 >> (ShamtW'(0) - s2[ShamtW-1:0]));
        end
      end
      `YSYX_ALU_ROR_: begin
        if (word && XLEN > 32) begin
          logic [31:0] rot32;
          rot32 = (s1[31:0] >> s2[4:0]) | (s1[31:0] << (5'd0 - s2[4:0]));
          alu_r = {{XLEN-32{rot32[31]}}, rot32};
        end else begin
          alu_r = (s1 >> s2[ShamtW-1:0]) | (s1 << (ShamtW'(0) - s2[ShamtW-1:0]));
        end
      end

      // Zbs (Single-bit Operations)
      `YSYX_ALU_BCLR: begin alu_r = s1 & ~(XLEN'(1) << s2[ShamtW-1:0]); end
      `YSYX_ALU_BEXT: begin alu_r = XLEN'((s1 >> s2[ShamtW-1:0]) & XLEN'(1)); end
      `YSYX_ALU_BINV: begin alu_r = s1 ^ (XLEN'(1) << s2[ShamtW-1:0]); end
      `YSYX_ALU_BSET: begin alu_r = s1 | (XLEN'(1) << s2[ShamtW-1:0]); end

      // Zicond (Conditional Operations)
      `YSYX_ALU_CZERO_EQZ: begin alu_r = (s2 == '0) ? '0 : s1; end
      `YSYX_ALU_CZERO_NEZ: begin alu_r = (s2 != '0) ? '0 : s1; end

      // Zbc (Carry-less Multiplication)
      `YSYX_ALU_CLMUL_: begin
        alu_r = '0;
        for (int i = 0; i < XLEN; i++)
          if (s2[i]) alu_r = alu_r ^ (s1 << i);
      end
      `YSYX_ALU_CLMULH: begin
        alu_r = '0;
        for (int i = 1; i < XLEN; i++)
          if (s2[i]) alu_r = alu_r ^ (s1 >> (XLEN - i));
      end
      `YSYX_ALU_CLMULR: begin
        alu_r = '0;
        for (int i = 0; i < XLEN; i++)
          if (s2[i]) alu_r = alu_r ^ (s1 >> (XLEN - 1 - i));
      end
      // verilog_format: on
      default: begin
        alu_r = 'h0;
      end
    endcase
  end

  // W-variant: sign-extend lower 32-bit result to XLEN
  generate
    if (XLEN > 32) begin : gen_word_ext
      assign out_r = word ? {{XLEN - 32{alu_r[31]}}, alu_r[31:0]} : alu_r;
    end else begin : gen_no_word
      assign out_r = alu_r;
    end
  endgenerate
endmodule
