`include "rapt.svh"
`include "rapt_if.svh"

// Pure single-instruction decode. No slot identity or pipeline control here.
module rapt_decode_slot #(
    parameter int XLEN = `RAPT_XLEN,
    parameter int RLEN = (`RAPT_REG_LEN)
) (
    input rapt_pkg::fetch_slot_t fetched,
    csr_bcast_if.in csr_bcast,
    output rapt_pkg::decoded_slot_t decoded
);
  logic [31:0] inst;
  logic [XLEN-1:0] pc_idu, ifu_tval, ifu_cause;
  logic ifu_trap;
  assign inst = fetched.inst;
  assign pc_idu = fetched.pc;
  assign ifu_trap = fetched.trap;
  assign ifu_tval = fetched.tval;
  assign ifu_cause = fetched.cause;
  logic [63:0] dec_imm, dec_op1, dec_op2;
  logic [5:0] alu;
  logic ren_dec, wen_dec;
  logic        word_flag;
  logic [11:0] csr;
  logic [ 2:0] csr_csw;
  logic [4:0] rd, rs1, rs2;

  logic fp_valid;
  logic [5:0] fp_op;
  logic fp_to_int;
  logic fp_writes_fpr;
  logic fp_i2f, fp_rv64_only;
  logic fp_load, fp_store;
  logic fp_load_d, fp_store_d, fp_load_h, fp_store_h;
  logic fp_width_d;
  logic [2:0] fp_rm;
  logic [4:0] fp_rs1, fp_rs2, fp_rs3, fp_rd;

  // Compressed instruction expansion
  logic        is_c;
  logic [31:0] inst_de;
  logic [31:0] inst_idu;
  logic [XLEN-1:0] illegal_tval;

  assign is_c     = (inst[1:0] != 2'b11);
  assign inst_idu = is_c ? inst_de : inst;
  // Sstvala requires the actual faulting instruction, right-justified. Do
  // not report the decompressor output: a reserved 16-bit encoding expands
  // to the decoder's illegal sentinel and would otherwise lose its raw bits.
  assign illegal_tval = is_c ? XLEN'(inst[15:0]) : XLEN'(inst);

  rapt_idu_decoder_c idu_de_c (
      .io_cinst  (inst[15:0]),
      .io_is_rv64(XLEN == 64 ? 1'b1 : 1'b0),
      .io_inst   (inst_de)
  );

  rapt_idu_decoder idu_de (
      .in_pc  ({{(64 - XLEN) {1'b0}}, pc_idu}),
      .in_inst(inst_idu),

      .out_alu (alu),
      .out_word(word_flag),
      .out_ben (decoded.uop.execute.branch.conditional),
      .out_jen (decoded.uop.execute.branch.jump),
      .out_jren(decoded.uop.execute.branch.indirect),
      .out_wen (wen_dec),
      .out_ren (ren_dec),
      .out_atom(decoded.uop.execute.memory.atomic),

      .out_sys_system (decoded.uop.execute.sys.valid),
      .out_sys_ebreak (decoded.uop.execute.sys.ebreak),
      .out_sys_ecall  (decoded.uop.execute.sys.ecall),
      .out_sys_mret   (decoded.uop.execute.sys.mret),
      .out_sys_sret   (decoded.uop.execute.sys.sret),
      .out_sys_csr_csw(csr_csw),

      .out_fence_i   (decoded.uop.execute.sys.fence_i),
      .out_fence_time(decoded.uop.execute.sys.fence),

      .out_fp_valid(fp_valid),
      .out_fp_op(fp_op),
      .out_fp_rm(fp_rm),
      .out_fp_rs1(fp_rs1),
      .out_fp_rs2(fp_rs2),
      .out_fp_rs3(fp_rs3),
      .out_fp_rd(fp_rd),
      .out_fp_load(fp_load),
      .out_fp_store(fp_store),
      .out_fp_width_d(fp_width_d),
      .out_fp_to_int(fp_to_int),
      .out_fp_writes_fpr(fp_writes_fpr),

      .out_imm(dec_imm),
      .out_rd (rd),
      .out_csr(csr),

      .out_op1(dec_op1),
      .out_op2(dec_op2),
      .out_rs1(rs1),
      .out_rs2(rs2)
  );

  assign fp_load_d = fp_load && fp_width_d;
  assign fp_store_d = fp_store && fp_width_d;
  assign fp_load_h = fp_load && fp_op == `RAPT_FP_OP_ZFHMIN;
  assign fp_store_h = fp_store && fp_op == `RAPT_FP_OP_ZFHMIN;
  assign fp_i2f = (fp_op == `RAPT_FP_OP_FCVT_S_W)
    || (fp_op == `RAPT_FP_OP_FCVT_S_WU)
    || (fp_op == `RAPT_FP_OP_FCVT_S_L)
    || (fp_op == `RAPT_FP_OP_FCVT_S_LU)
    || (fp_op == `RAPT_FP_OP_FCVT_D_W)
    || (fp_op == `RAPT_FP_OP_FCVT_D_WU)
    || (fp_op == `RAPT_FP_OP_FCVT_D_L)
    || (fp_op == `RAPT_FP_OP_FCVT_D_LU)
    || (fp_op == `RAPT_FP_OP_ZFHMIN && inst_idu[31:25] == 7'b1111010);
  assign fp_rv64_only = (fp_op == `RAPT_FP_OP_FMV_X_D)
    || (fp_op == `RAPT_FP_OP_FMV_D_X)
    || (fp_op == `RAPT_FP_OP_FCVT_L_S)
    || (fp_op == `RAPT_FP_OP_FCVT_LU_S)
    || (fp_op == `RAPT_FP_OP_FCVT_S_L)
    || (fp_op == `RAPT_FP_OP_FCVT_S_LU)
    || (fp_op == `RAPT_FP_OP_FCVT_L_D)
    || (fp_op == `RAPT_FP_OP_FCVT_LU_D)
    || (fp_op == `RAPT_FP_OP_FCVT_D_L)
    || (fp_op == `RAPT_FP_OP_FCVT_D_LU);

  // Truncate 64-bit decoder outputs to XLEN
  assign decoded.uop.imm = dec_imm[XLEN-1:0];
  assign decoded.op1     = dec_op1[XLEN-1:0];
  assign decoded.op2     = dec_op2[XLEN-1:0];

  // Per-instruction legality is independent of the decode position. Check the
  // ALU encoding, CSR access, privilege gates and extension availability here;
  // ordered group policy belongs to rapt_idu.
  logic illegal_inst, illegal_csr, fp_disabled, is_illegal;

  assign illegal_inst = (alu == `RAPT_ALU_ILL_);
  assign fp_disabled = fp_valid && (csr_bcast.fs == 2'b00);
  // CSR write attempt: CSRRW/CSRRWI always write; CSRRS/C/SI/CI write if rs1/uimm != 0
  logic csr_write;
  // The decoded GPR rs1 is zero for immediate CSR operations. The raw
  // instruction field carries either rs1 or uimm and determines write intent.
  assign csr_write = (csr_csw[1:0] == 2'b01) || (inst_idu[19:15] != 5'b0);
  assign illegal_csr = (csr_csw != `RAPT_CSR_CSW_NONE) && (!csr_addr_valid(
      csr
  )  // unknown CSR address
  || (csr[9:8] > csr_bcast.priv)  // insufficient privilege
  || (csr[11:10] == 2'b11 && csr_write)  // write to read-only CSR
  // FS gates all FP state, including reads and writes through the integer
  // CSR execution path (which does not assert fp_valid).
  || ((csr == `RAPT_CSR_FFLAGS || csr == `RAPT_CSR_FRM || csr == `RAPT_CSR_FCSR)
      && csr_bcast.fs == 2'b00)
  );

  // Privileged system-instruction gating (TSR/TVM/TW + counteren).
  //   WFI: illegal in U-mode always, illegal in S-mode when mstatus.TW=1.
  //   SRET: illegal in U-mode, illegal in S-mode when mstatus.TSR=1.
  //   SFENCE.VMA: illegal in U-mode; illegal in S-mode when mstatus.TVM=1.
  //   satp: illegal in S-mode when mstatus.TVM=1 (generic priv check catches U).
  //   cycle/time/instret (+h): read from S or U needs mcounteren bit;
  //     read from U additionally needs scounteren bit.
  logic is_wfi, is_sfence_vma, is_sinval_vma, is_inval_fence;
  logic wfi_illegal, mret_illegal, sret_illegal, sfence_vma_illegal, satp_illegal;
  logic counter_illegal, stimecmp_illegal;
  logic is_hpm_counter;
  logic is_cbo_inval, is_cbo_clean, is_cbo_flush, is_cbo_zero;
  logic cbo_illegal;
  logic [2:0] counter_sel;
  assign is_wfi = (inst_idu == `RAPT_INST_WFI);
  assign is_sfence_vma = (inst_idu[31:25] == `RAPT_F7_SFENCE_VMA)
                        && (inst_idu[14:12] == `RAPT_F3_SYS___)
                        && (inst_idu[11:7]  == 5'b0)
                        && (inst_idu[6:0]   == `RAPT_OP_SYSTEM);
  assign is_sinval_vma = (inst_idu & 32'hfe00_7fff) == 32'h1600_0073;
  assign is_inval_fence = inst_idu == 32'h1800_0073 || inst_idu == 32'h1810_0073;
  assign wfi_illegal = is_wfi
      && ((csr_bcast.priv == `RAPT_PRIV_U)
       || (csr_bcast.priv == `RAPT_PRIV_S && csr_bcast.tw));
  assign sret_illegal = decoded.uop.execute.sys.sret
      && ((csr_bcast.priv == `RAPT_PRIV_U)
       || (csr_bcast.priv == `RAPT_PRIV_S && csr_bcast.tsr));
  assign mret_illegal = decoded.uop.execute.sys.mret && csr_bcast.priv != `RAPT_PRIV_M;
  assign sfence_vma_illegal = (is_sfence_vma || is_sinval_vma)
      && ((csr_bcast.priv == `RAPT_PRIV_U)
       || (csr_bcast.priv == `RAPT_PRIV_S && csr_bcast.tvm));
  assign satp_illegal = (csr_csw != `RAPT_CSR_CSW_NONE) && (csr == `RAPT_CSR_SATP___)
      && (csr_bcast.priv == `RAPT_PRIV_S) && csr_bcast.tvm;
  assign stimecmp_illegal = (csr_csw != `RAPT_CSR_CSW_NONE)
      && (csr == `RAPT_CSR_STIMECMP || csr == `RAPT_CSR_STIMECMPH)
      && csr_bcast.priv != (`RAPT_PRIV_M)
      && (!csr_bcast.menvcfg_stce || !csr_bcast.mcounteren[`RAPT_CSR_COUNTEREN_TM]);
  assign counter_sel = (csr == (`RAPT_CSR_CYCLE__)
      || (XLEN == 32 && csr == `RAPT_CSR_CYCLEH_)) ?
      (`RAPT_CTR_SEL_CY__)
      : (csr == `RAPT_CSR_TIME___ || (XLEN == 32 && csr == `RAPT_CSR_TIMEH__)) ?
      (`RAPT_CTR_SEL_TM__)
      : (csr == `RAPT_CSR_INSTRET_ || (XLEN == 32 && csr == `RAPT_CSR_INSTRETH)) ?
      (`RAPT_CTR_SEL_IR__)
      : `RAPT_CTR_SEL_NONE;
  assign is_hpm_counter = (csr >= (`RAPT_CSR_HPMCOUNTER3)
                          && csr <= `RAPT_CSR_HPMCOUNTER31)
      || (XLEN == 32 && csr >= (`RAPT_CSR_HPMCOUNTER3H)
                     && csr <= `RAPT_CSR_HPMCOUNTER31H);
  assign counter_illegal = (csr_csw != `RAPT_CSR_CSW_NONE)
      && (((counter_sel != `RAPT_CTR_SEL_NONE) && ((csr_bcast.priv ==
      (`RAPT_PRIV_U)
      && (((counter_sel & csr_bcast.mcounteren) == `RAPT_CTR_SEL_NONE) ||
          ((counter_sel & csr_bcast.scounteren) == `RAPT_CTR_SEL_NONE))) || (csr_bcast.priv ==
      (`RAPT_PRIV_S)
      && ((counter_sel & csr_bcast.mcounteren) == `RAPT_CTR_SEL_NONE))))
      // All HPM enable bits are WARL-zero because every HPM counter is the
      // architecturally permitted read-only-zero implementation.
      || (is_hpm_counter && csr_bcast.priv != `RAPT_PRIV_M));

  assign is_cbo_inval = inst_idu[31:20] == 12'h000
      && inst_idu[14:12] == 3'b010 && inst_idu[11:7] == 0
      && inst_idu[6:0] == `RAPT_OP_FENCE_;
  assign is_cbo_clean = inst_idu[31:20] == 12'h001
      && inst_idu[14:12] == 3'b010 && inst_idu[11:7] == 0
      && inst_idu[6:0] == `RAPT_OP_FENCE_;
  assign is_cbo_flush = inst_idu[31:20] == 12'h002
      && inst_idu[14:12] == 3'b010 && inst_idu[11:7] == 0
      && inst_idu[6:0] == `RAPT_OP_FENCE_;
  assign is_cbo_zero = inst_idu[31:20] == 12'h004
      && inst_idu[14:12] == 3'b010 && inst_idu[11:7] == 0
      && inst_idu[6:0] == `RAPT_OP_FENCE_;
  assign cbo_illegal = (csr_bcast.priv != `RAPT_PRIV_M) && (
      (is_cbo_inval && (csr_bcast.menvcfg_cbie == 2'b00
        || (csr_bcast.priv == `RAPT_PRIV_U && csr_bcast.senvcfg_cbie == 2'b00)))
      || ((is_cbo_clean || is_cbo_flush) && (!csr_bcast.menvcfg_cbcfe
        || (csr_bcast.priv == `RAPT_PRIV_U && !csr_bcast.senvcfg_cbcfe)))
      || (is_cbo_zero && (!csr_bcast.menvcfg_cbze
        || (csr_bcast.priv == `RAPT_PRIV_U && !csr_bcast.senvcfg_cbze))));

  // The shared generated decoder describes both XLENs. OP-32 and OP-IMM-32
  // are RV64 integer spaces, including M word and bit-manipulation forms.
  logic integer_rv64_only;
  assign integer_rv64_only = inst_idu[6:0] == 7'h3b || inst_idu[6:0] == 7'h1b;

  // Six-bit immediate shifts are RV64-only. This also excludes the RV64
  // REV8 encoding in RV32; other accepted unary bit operations have bit25=0.
  logic shift_imm_xlen_illegal, rev8_xlen_illegal, zexth_xlen_illegal;
  assign shift_imm_xlen_illegal = XLEN == 32 && inst_idu[6:0] == 7'h13
      && (inst_idu[14:12] == 3'b001 || inst_idu[14:12] == 3'b101)
      && inst_idu[25];
  assign rev8_xlen_illegal = XLEN == 64
      && (inst_idu & 32'hfff0707f) == 32'h69805013;
  // C.ZEXT.H already expands to the XLEN-specific opcode. Reject only
  // the unimplemented RV32 native encoding when executing RV64.
  assign zexth_xlen_illegal = XLEN == 64
      && (inst_idu & 32'hfff0707f) == 32'h08004033;

  assign is_illegal = (illegal_inst && !fp_valid) || illegal_csr
      || shift_imm_xlen_illegal || rev8_xlen_illegal || zexth_xlen_illegal
      || (XLEN == 32 && integer_rv64_only)
      || wfi_illegal || mret_illegal || sret_illegal || sfence_vma_illegal
      || satp_illegal || counter_illegal || stimecmp_illegal || fp_disabled
      || cbo_illegal || (is_inval_fence && csr_bcast.priv == `RAPT_PRIV_U)
      || (fp_rv64_only && XLEN != 64);

  // CSR address validity check - returns 1 if the CSR address is legal.
  // Extend this function when adding new CSR registers.
  function automatic logic csr_addr_valid(input logic [11:0] addr);
    // RV64 packs eight PMP entries per even pmpcfg CSR; odd encodings do
    // not exist. All sixteen implemented pmpaddr CSRs exist at either XLEN.
    if (addr >= `RAPT_CSR_PMPCFG0 && addr <= `RAPT_CSR_PMPCFG3) return XLEN == 32 || !addr[0];
    if (addr >= `RAPT_CSR_PMPADDR0 && addr <= `RAPT_CSR_PMPADDR15) return 1'b1;
    if (addr == `RAPT_CSR_MSTATUSH || addr == (`RAPT_CSR_MENVCFGH) || addr == `RAPT_CSR_STIMECMPH)
      return XLEN == 32;
    // Zihpm zero-counter implementation: all standard machine/user counter
    // and event-selector CSRs exist and read zero.  RV32 additionally exposes
    // the high-half aliases; those encodings remain illegal in RV64.
    if (addr >= `RAPT_CSR_MHPMCOUNTER3 && addr <= `RAPT_CSR_MHPMCOUNTER31) return 1'b1;
    if (addr >= `RAPT_CSR_MHPMEVENT3 && addr <= `RAPT_CSR_MHPMEVENT31) return 1'b1;
    if (addr >= `RAPT_CSR_HPMCOUNTER3 && addr <= `RAPT_CSR_HPMCOUNTER31) return 1'b1;
    if (XLEN == 32 && addr >= (`RAPT_CSR_MHPMCOUNTER3H) && addr <= `RAPT_CSR_MHPMCOUNTER31H)
      return 1'b1;
    if (XLEN == 32 && addr >= (`RAPT_CSR_HPMCOUNTER3H) && addr <= `RAPT_CSR_HPMCOUNTER31H)
      return 1'b1;
    if (XLEN == 32 && (addr == `RAPT_CSR_MCYCLEH || addr == (`RAPT_CSR_CYCLEH_)
        || addr == `RAPT_CSR_TIMEH__ || addr == (`RAPT_CSR_MINSTRETH)
        || addr == `RAPT_CSR_INSTRETH))
      return 1'b1;
    case (addr)
      `RAPT_CSR_FFLAGS, `RAPT_CSR_FRM, `RAPT_CSR_FCSR,
      // Supervisor-level CSRs
      `RAPT_CSR_SSTATUS,  `RAPT_CSR_SIE____,  `RAPT_CSR_STVEC__,  `RAPT_CSR_SCOUNTE,
      `RAPT_CSR_SENVCFG,
      `RAPT_CSR_SSCRATC,  `RAPT_CSR_SEPC___,  `RAPT_CSR_SCAUSE_,  `RAPT_CSR_STVAL__,
      `RAPT_CSR_SIP____,  `RAPT_CSR_STIMECMP, `RAPT_CSR_STIMECMPH, `RAPT_CSR_SATP___,
      // Machine Trap Setup
      `RAPT_CSR_MSTATUS,  `RAPT_CSR_MISA___,  `RAPT_CSR_MEDELEG,  `RAPT_CSR_MIDELEG,
      `RAPT_CSR_MIE____,  `RAPT_CSR_MTVEC__,  `RAPT_CSR_MCOUNTE,
      `RAPT_CSR_MENVCFG,
      `RAPT_CSR_MBERR_STATUS, `RAPT_CSR_MBERR_ADDR,
      // Machine Trap Handling
      `RAPT_CSR_MSCRATCH, `RAPT_CSR_MEPC___,  `RAPT_CSR_MCAUSE_,  `RAPT_CSR_MTVAL__,
      `RAPT_CSR_MIP____,
      // Machine Counters
      `RAPT_CSR_MCYCLE_, `RAPT_CSR_CYCLE__, `RAPT_CSR_TIME___,
      `RAPT_CSR_MINSTRET, `RAPT_CSR_INSTRET_,
      // Machine Information
      `RAPT_CSR_MVENDORID, `RAPT_CSR_MARCHID__, `RAPT_CSR_IMPID____, `RAPT_CSR_MHARTID__:
      return 1'b1;
      default: return 1'b0;
    endcase
  endfunction

  assign decoded.uop.schedule = rapt_pkg::schedule_uop(decoded.uop);
  assign decoded.uop.c = is_c;
  // `out_word` doesn't include AMO.W/LR.W/SC.W in current decoder table.
  // For atomics, use funct3=010 to mark 32-bit variant on RV64.
  assign decoded.uop.execute.int_op.word = word_flag
      || (decoded.uop.execute.memory.atomic && inst_idu[14:12] == `RAPT_F3_AMO_W_);
  assign decoded.uop.execute.int_op.alu = fp_load_h ? (`RAPT_ALU_LH__)
      : (fp_store_h ? (`RAPT_SH_WSTRB)
      : (fp_load_d ? (`RAPT_ALU_LD__)
      : (fp_store_d ? (`RAPT_SD_WSTRB)
      : (fp_load ? (`RAPT_ALU_LW__)
      : (fp_store ? `RAPT_SW_WSTRB : alu)))));
  assign decoded.uop.execute.fp.valid = fp_valid;
  assign decoded.uop.execute.fp.op = fp_op;
  assign decoded.uop.execute.fp.rm = fp_rm;
  assign decoded.uop.execute.fp.rs1 = fp_rs1;
  assign decoded.uop.execute.fp.rs2 = fp_rs2;
  assign decoded.uop.execute.fp.rs3 = fp_rs3;
  assign decoded.uop.execute.fp.rd = fp_rd;
  assign decoded.uop.execute.memory.load = ren_dec || fp_load || fp_load_d;
  assign decoded.uop.execute.memory.store = wen_dec || fp_store || fp_store_d;
  assign decoded.uop.rd[RLEN-1:0] = (is_illegal || fp_writes_fpr
      || fp_store || fp_store_d) ? '0
      : (fp_valid ? fp_rd[RLEN-1:0] : rd[RLEN-1:0]);
  assign decoded.uop.execute.sys.csr_csw = csr_csw;

  // Trap aggregation: IFU traps (e.g., page fault) or decode-time illegality
  assign decoded.uop.trap = ifu_trap || is_illegal;
  assign decoded.uop.tval = ifu_trap ? ifu_tval
                             : is_illegal ? illegal_tval : '0;
  assign decoded.uop.cause = ifu_trap ? ifu_cause : is_illegal ? `RAPT_CAUSE_ILLEGAL_INST : '0;

  assign decoded.uop.inst = inst_idu;
`ifdef RAPT_RVFI
  // RVFI must report the original instruction word: compressed instructions
  // are reported as the raw 16-bit encoding zero-extended (so `insn[1:0]!=2'b11`),
  // not the decompressed 32-bit form used internally for decode/difftest.
  assign decoded.uop.rvfi_inst = is_c ? {16'b0, inst[15:0]} : inst;
`endif
  assign decoded.uop.pc        = pc_idu;

  assign decoded.rs1[RLEN-1:0] = (fp_valid &&
        (fp_op == `RAPT_FP_OP_FMV_W_X || fp_op == (`RAPT_FP_OP_FMV_D_X)
         || fp_i2f || fp_load || fp_store || fp_load_d || fp_store_d))
        ? fp_rs1[RLEN-1:0] : rs1[RLEN-1:0];
  assign decoded.rs2[RLEN-1:0] = fp_valid ? fp_rs2[RLEN-1:0] : rs2[RLEN-1:0];

  assign decoded.uop.pnpc = fetched.pnpc;
  assign decoded.uop.execute.branch.predicted_taken = fetched.predicted_taken;
endmodule
