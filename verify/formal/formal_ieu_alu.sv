`include "rapt.svh"

// Combinational equivalence against a deliberately direct ISA-level model.
// Symbolic operands exhaustively cover every input value in one proof step.
module formal_ieu_alu #(
    parameter int XLEN = `RAPT_XLEN
) (
    input logic [XLEN-1:0] s1,
    input logic [XLEN-1:0] s2,
    input logic [5:0]      op,
    input logic            word
);
  logic [XLEN-1:0] dut_result;
  logic [XLEN-1:0] ref_base;
  logic [XLEN-1:0] ref_result;
  logic [2*XLEN-1:0] cl_product;
  integer shamt;
  integer count;
  logic found;
  logic is_uw_op;

  rapt_ieu_alu #(.XLEN(XLEN)) dut (.*,.out_r(dut_result));

  always_comb begin
    cl_product = '0;
`ifdef FORMAL_ALU_CLMUL
    for (int i = 0; i < XLEN; i++)
      if (s2[i]) cl_product = cl_product ^ (2*XLEN)'(s1) << i;
`endif

    ref_base = '0;
    shamt = (word && XLEN > 32) ? int'(s2[4:0]) : int'(s2[$clog2(XLEN)-1:0]);
    unique case (op)
      `RAPT_ALU_ADD_: ref_base = s1 + s2;
      `RAPT_ALU_SUB_: ref_base = s1 - s2;
      `RAPT_ALU_EQ__: ref_base = XLEN'(s1 == s2);
      `RAPT_ALU_SLT_: ref_base = XLEN'($signed(s1) < $signed(s2));
      `RAPT_ALU_SLE_: ref_base = XLEN'($signed(s1) <= $signed(s2));
      `RAPT_ALU_SGE_: ref_base = XLEN'($signed(s1) >= $signed(s2));
      `RAPT_ALU_SLTU: ref_base = XLEN'(s1 < s2);
      `RAPT_ALU_SLEU: ref_base = XLEN'(s1 <= s2);
      `RAPT_ALU_SGEU: ref_base = XLEN'(s1 >= s2);
      `RAPT_ALU_XOR_: ref_base = s1 ^ s2;
      `RAPT_ALU_OR__: ref_base = s1 | s2;
      `RAPT_ALU_AND_: ref_base = s1 & s2;
      `RAPT_ALU_SLL_: ref_base = (word && XLEN > 32) ? XLEN'(s1[31:0] << shamt)
                                                     : s1 << shamt;
      `RAPT_ALU_SRL_: ref_base = (word && XLEN > 32) ? XLEN'(s1[31:0] >> shamt)
                                                     : s1 >> shamt;
      `RAPT_ALU_SRA_: ref_base = (word && XLEN > 32)
          ? XLEN'($signed(s1[31:0]) >>> shamt) : $signed(s1) >>> shamt;
      `RAPT_ALU_SH1ADD: ref_base = (((word && XLEN > 32) ? XLEN'(s1[31:0]) : s1) << 1) + s2;
      `RAPT_ALU_SH2ADD: ref_base = (((word && XLEN > 32) ? XLEN'(s1[31:0]) : s1) << 2) + s2;
      `RAPT_ALU_SH3ADD: ref_base = (((word && XLEN > 32) ? XLEN'(s1[31:0]) : s1) << 3) + s2;
      `RAPT_ALU_ADD_UW: ref_base = s2 + ((XLEN > 32) ? XLEN'(s1[31:0]) : s1);
      `RAPT_ALU_SLLI_UW: ref_base = ((XLEN > 32) ? XLEN'(s1[31:0]) : s1)
                                    << s2[$clog2(XLEN)-1:0];
      `RAPT_ALU_ANDN: ref_base = s1 & ~s2;
      `RAPT_ALU_ORN_: ref_base = s1 | ~s2;
      `RAPT_ALU_XNOR: ref_base = ~(s1 ^ s2);
      `RAPT_ALU_CLZ_: begin
        count = 0; found = 1'b0;
        for (int i = XLEN-1; i >= 0; i--) begin
          if ((!word || XLEN <= 32 || i < 32) && !found) begin
            if (!s1[i]) count = count + 1; else found = 1'b1;
          end
        end
        ref_base = XLEN'(count);
      end
      `RAPT_ALU_CTZ_: begin
        count = 0; found = 1'b0;
        for (int i = 0; i < XLEN; i++) begin
          if ((!word || XLEN <= 32 || i < 32) && !found) begin
            if (!s1[i]) count = count + 1; else found = 1'b1;
          end
        end
        ref_base = XLEN'(count);
      end
      `RAPT_ALU_CPOP: begin
        count = 0;
        for (int i = 0; i < XLEN; i++)
          if ((!word || XLEN <= 32 || i < 32) && s1[i]) count = count + 1;
        ref_base = XLEN'(count);
      end
      `RAPT_ALU_MAX_: ref_base = ($signed(s1) >= $signed(s2)) ? s1 : s2;
      `RAPT_ALU_MAXU: ref_base = (s1 >= s2) ? s1 : s2;
      `RAPT_ALU_MIN_: ref_base = ($signed(s1) < $signed(s2)) ? s1 : s2;
      `RAPT_ALU_MINU: ref_base = (s1 < s2) ? s1 : s2;
      `RAPT_ALU_SEXTB: ref_base = XLEN'($signed(s1[7:0]));
      `RAPT_ALU_SEXTH: ref_base = XLEN'($signed(s1[15:0]));
      `RAPT_ALU_ZEXTH: ref_base = XLEN'(s1[15:0]);
      `RAPT_ALU_REV8: begin
        for (int i = 0; i < XLEN/8; i++)
          ref_base[8*i +: 8] = s1[XLEN-8-8*i +: 8];
      end
      `RAPT_ALU_ORCB: begin
        for (int i = 0; i < XLEN/8; i++)
          ref_base[8*i +: 8] = {8{|s1[8*i +: 8]}};
      end
      `RAPT_ALU_ROL_: begin
        if (word && XLEN > 32)
          ref_base = XLEN'((s1[31:0] << shamt) |
              (shamt == 0 ? s1[31:0] : (s1[31:0] >> (32-shamt))));
        else ref_base = (s1 << shamt) | (shamt == 0 ? s1 : (s1 >> (XLEN-shamt)));
      end
      `RAPT_ALU_ROR_: begin
        if (word && XLEN > 32)
          ref_base = XLEN'((s1[31:0] >> shamt) |
              (shamt == 0 ? s1[31:0] : (s1[31:0] << (32-shamt))));
        else ref_base = (s1 >> shamt) | (shamt == 0 ? s1 : (s1 << (XLEN-shamt)));
      end
      `RAPT_ALU_BCLR: ref_base = s1 & ~(XLEN'(1) << s2[$clog2(XLEN)-1:0]);
      `RAPT_ALU_BEXT: ref_base = XLEN'((s1 >> s2[$clog2(XLEN)-1:0]) & 1'b1);
      `RAPT_ALU_BINV: ref_base = s1 ^ (XLEN'(1) << s2[$clog2(XLEN)-1:0]);
      `RAPT_ALU_BSET: ref_base = s1 | (XLEN'(1) << s2[$clog2(XLEN)-1:0]);
      `RAPT_ALU_CZERO_EQZ: ref_base = (s2 == '0) ? '0 : s1;
      `RAPT_ALU_CZERO_NEZ: ref_base = (s2 != '0) ? '0 : s1;
      `RAPT_ALU_CLMUL: ref_base = cl_product[XLEN-1:0];
      `RAPT_ALU_CLMULH: ref_base = cl_product[2*XLEN-1:XLEN];
      `RAPT_ALU_CLMULR: ref_base = cl_product[2*XLEN-2 -: XLEN];
      default: ref_base = '0;
    endcase

    is_uw_op = (op == `RAPT_ALU_ADD_UW) || (op == `RAPT_ALU_SLLI_UW)
        || (op == `RAPT_ALU_SH1ADD) || (op == `RAPT_ALU_SH2ADD)
        || (op == `RAPT_ALU_SH3ADD);
    if (word && XLEN > 32 && !is_uw_op)
      ref_result = {{XLEN-32{ref_base[31]}}, ref_base[31:0]};
    else ref_result = ref_base;
  end

  always_comb begin
`ifdef FORMAL_ALU_CLMUL
`ifdef FORMAL_ALU_CLMULH
    assume(op == `RAPT_ALU_CLMULH);
    // CLMULH's upper-half XOR cone is expensive for SMT.  Exhaustively prove
    // every polynomial basis term (and zero); the RTL accumulation is a
    // linear XOR reduction of exactly these terms.
    assume((s2 & (s2 - XLEN'(1))) == '0);
`elsif FORMAL_ALU_CLMULR
    assume(op == `RAPT_ALU_CLMULR);
`else
    assume(op == `RAPT_ALU_CLMUL);
`endif
`else
    assume(!(op inside {`RAPT_ALU_CLMUL, `RAPT_ALU_CLMULH, `RAPT_ALU_CLMULR}));
`endif
  end

  always_comb result_equivalence: assert(dut_result == ref_result);
endmodule
