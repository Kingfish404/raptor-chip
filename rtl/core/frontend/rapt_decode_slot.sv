`include "rapt.svh"
`include "rapt_if.svh"

// Pure single-instruction decode. No slot identity or pipeline control here.
module rapt_decode_slot #(
    parameter int XLEN = `RAPT_XLEN,
    parameter int RLEN = (`RAPT_REG_LEN),
    // Emit constant operands as small selectors (see rapt_pkg::derive_op*)
    // instead of XLEN values; the ROU rebuilds them from the uop at dispatch.
    parameter bit DerivedConstants = 1'b0
) (
    input rapt_pkg::fetch_slot_t fetched,
    csr_bcast_if.in csr_bcast,
    output rapt_pkg::decoded_slot_t decoded
);
  logic [31:0] inst;
  logic [5:0] ifu_cause;
  logic ifu_trap;
  assign inst = fetched.inst;
  assign ifu_trap = fetched.trap;
  assign ifu_cause = fetched.cause;
  logic [20:0] dec_imm_low;
  logic dec_imm_u;
  logic [31:0] dec_imm;
  logic [1:0] dec_op1_sel;
  logic dec_op2_sel;
  logic [5:0] alu;
  logic ren_dec, wen_dec;
  logic        word_flag;
  logic [11:0] csr;
  logic [ 2:0] csr_csw;
  logic [4:0] rd, rs1, rs2;
  logic sys_valid_dec, vector_valid, vector_rs1, vector_rs2, vector_rd;
  logic is_c;
  logic [31:0] inst_idu;
  logic vector_dec;
  // V scalar dependencies come from the generated decoder. FP scalar
  // operands use the architectural FP read port after ROB serialization.
  assign vector_valid = rapt_pkg::VectorEnable && !is_c && vector_dec;

  logic fp_valid;
  logic [5:0] fp_op;
  logic unused_fp_to_int;
  logic fp_writes_fpr;
  logic fp_i2f, fp_rv64_only, fp_zfa;
  logic fp_load, fp_store;
  logic fp_load_d, fp_store_d, fp_load_h, fp_store_h;
  logic fp_width_d;
  logic [2:0] fp_rm;
  logic [4:0] fp_rs1, fp_rs2, fp_rs3, fp_rd;

  // Compressed instruction expansion
  logic [31:0] inst_de;
  logic [31:0] illegal_tval;
  logic illegal_inst, illegal_csr, virt_csr, fp_disabled, is_illegal, is_virt_inst, decode_trap;
  logic is_wfi, is_wrs, wrs_illegal, is_sfence_vma, is_sinval_vma, is_inval_fence;
  logic is_hfence_vvma, is_hfence_gvma, is_hfence, hfence_illegal, hfence_virt;
  logic is_hmem, hmem_illegal, hmem_virt;

  assign is_c     = (inst[1:0] != 2'b11);
  assign inst_idu = is_c ? inst_de : inst;
  // Sstvala requires the actual faulting instruction, right-justified. Do
  // not report the decompressor output: a reserved 16-bit encoding expands
  // to the decoder's illegal sentinel and would otherwise lose its raw bits.
  assign illegal_tval = is_c ? {16'b0, inst[15:0]} : inst;

  rapt_idu_decoder_c idu_de_c (
      .io_cinst  (inst[15:0]),
      .io_is_rv64(XLEN == 64 ? 1'b1 : 1'b0),
      .io_inst   (inst_de)
  );

  rapt_idu_decoder idu_de (
      .in_inst(inst_idu),

      .out_alu (alu),
      .out_word(word_flag),
      .out_ben (decoded.uop.execute.branch.conditional),
      .out_jen (decoded.uop.execute.branch.jump),
      .out_jren(decoded.uop.execute.branch.indirect),
      .out_wen (wen_dec),
      .out_ren (ren_dec),
      .out_atom(decoded.uop.execute.memory.atomic),

      .out_vector_valid(vector_dec),
      .out_vector_rs1(vector_rs1),
      .out_vector_rs2(vector_rs2),
      .out_vector_rd(vector_rd),

      .out_sys_system (sys_valid_dec),
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
      .out_fp_to_int(unused_fp_to_int),
      .out_fp_writes_fpr(fp_writes_fpr),

      .out_imm(dec_imm_low),
      .out_imm_u(dec_imm_u),
      .out_rd (rd),
      .out_csr(csr),

      .out_op1_sel(dec_op1_sel),
      .out_op2_sel(dec_op2_sel),
      .out_rs1(rs1),
      .out_rs2(rs2)
  );

  assign decoded.uop.execute.sys.valid = sys_valid_dec || vector_valid;
`ifdef RAPT_V_EXTENSION
  assign decoded.uop.execute.vector = vector_valid;
`endif
  assign dec_imm = dec_imm_u ? {dec_imm_low[19:0], 12'b0}
      : {{11{dec_imm_low[20]}}, dec_imm_low};

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

  // All scalar immediates fit signed 32 bits. Non-immediate operations reuse
  // the payload for raw illegal/FP encodings or compact CSR/fence metadata.
  assign decode_trap = is_illegal || is_virt_inst;
  assign decoded.uop.imm = decode_trap && !ifu_trap ? illegal_tval[31:0]
      : (vector_valid || is_wrs || is_hmem) ? inst_idu
      : fp_valid && !(fp_load || fp_store || fp_load_d || fp_store_d) ? inst_idu
      : |csr_csw ? {15'b0, inst_idu[19:15], dec_imm[11:0]}
      : is_hfence ? 32'd3
      : (is_sfence_vma || is_sinval_vma)
          ? {30'b0, (inst_idu[24:20] == 0), (inst_idu[19:15] == 0)}
      : (inst_idu[6:0] == `RAPT_OP_FENCE_ && inst_idu[14:12] == 3'b000)
          ? {31'b0, (inst_idu == 32'h0100_000f || inst_idu == 32'h8330_000f)}
      : dec_imm[31:0];
  // Transport the generated selectors directly. Comparing resolved XLEN values
  // here would rebuild wide muxes and comparators on every decode lane.
  if (DerivedConstants) begin : g_derived_constants
    assign decoded.op1 = vector_valid ? '0 : XLEN'(dec_op1_sel);
    assign decoded.op2 = vector_valid ? '0 : XLEN'(dec_op2_sel);
  end else begin : g_value_constants
    assign decoded.op1 = vector_valid ? '0 : rapt_pkg::derive_op1(
        XLEN'(dec_op1_sel), fetched.pc, dec_imm, inst_idu[19:15]
    );
    assign decoded.op2 = vector_valid ? '0
        : rapt_pkg::derive_op2(XLEN'(dec_op2_sel), dec_imm);
  end

  // Per-instruction legality is independent of the decode position. Check the
  // ALU encoding, CSR access, privilege gates and extension availability here;
  // ordered group policy belongs to rapt_idu.
  assign illegal_inst = (alu == `RAPT_ALU_ILL_) && !vector_valid;
  // Zfa shares the legacy compare/convert operation tags; the reserved
  // funct3/rs2 bits identify the added forms after the generated decode.
  assign fp_zfa = inst_idu[6:0] == 7'h53 && (fp_op == `RAPT_FP_OP_ZFA_SIMPLE
      || (inst_idu[31:26] == 6'b001010 && fp_rm[1])
      || (inst_idu[31:26] == 6'b101000 && fp_rm[2])
      || (fp_op == `RAPT_FP_OP_FCVT_W_D && inst_idu[23]));
  assign fp_disabled = fp_valid && (csr_bcast.fs == 2'b00
      || (fp_zfa && !(rapt_pkg::ZfaEnable && XLEN == 64)));
  // CSR write attempt: CSRRW/CSRRWI always write; CSRRS/C/SI/CI write if rs1/uimm != 0
  logic csr_write;
  logic csr_op;
  logic [1:0] csr_priv;
  logic csr_exists, csr_ro_violation, csr_mstateen_ok;
  logic guest_hs_csr, guest_hs_qualified;
  logic hs_priv_allowed;
  // The decoded GPR rs1 is zero for immediate CSR operations. The raw
  // instruction field carries either rs1 or uimm and determines write intent.
  assign csr_write = (csr_csw[1:0] == 2'b01) || (inst_idu[19:15] != 5'b0);
  assign csr_op = !vector_valid && (csr_csw != `RAPT_CSR_CSW_NONE);
  assign csr_priv = csr[9:8];
  assign csr_exists = csr_addr_valid(csr);
  assign csr_ro_violation = csr[11:10] == 2'b11 && csr_write;
  assign csr_mstateen_ok = stateen_m_allows_s(csr);
  wire is_any_stimecmp = csr == `RAPT_CSR_STIMECMP || csr == `RAPT_CSR_STIMECMPH
      || (rapt_pkg::HypervisorEnable && XLEN == 64 && csr == `RAPT_CSR_VSTIMECMP);
  wire stimecmp_m_ok = !is_any_stimecmp
      || (csr_bcast.menvcfg_stce && csr_bcast.mcounteren[`RAPT_CSR_COUNTEREN_TM]);
  assign guest_hs_csr = csr_bcast.virt && (
      csr_priv == 2'd2
      || (csr_bcast.priv == `RAPT_PRIV_S && csr_priv == 2'd1
          && !is_guest_vs_alias(csr) && !is_guest_shared_s_csr(csr))
      || (csr_bcast.priv == `RAPT_PRIV_U && csr_priv == 2'd1 && csr_exists));
  assign guest_hs_qualified = csr_exists && !csr_ro_violation
      && csr_mstateen_ok && stimecmp_m_ok;
  assign hs_priv_allowed = rapt_pkg::HypervisorEnable && XLEN == 64
      && csr_priv == 2'd2 && csr_bcast.priv == `RAPT_PRIV_S && !csr_bcast.virt;
  wire fp_csr_disabled = (csr == `RAPT_CSR_FFLAGS || csr == `RAPT_CSR_FRM
      || csr == `RAPT_CSR_FCSR) && csr_bcast.fs == 2'b00;
  wire non_guest_csr_illegal = !csr_exists || (csr_priv > csr_bcast.priv && !hs_priv_allowed)
      || csr_ro_violation || fp_csr_disabled;
  assign illegal_csr = csr_op && (
      (guest_hs_csr && !guest_hs_qualified)
      || (!guest_hs_csr && non_guest_csr_illegal));

  // Privileged system-instruction gating (TSR/TVM/TW + counteren + H).
  logic wfi_illegal, wfi_virt, mret_illegal, sret_illegal, sret_virt;
  logic sfence_vma_illegal, sfence_vma_virt, satp_illegal, satp_virt;
  logic counter_illegal, counter_virt, stimecmp_illegal, stimecmp_virt;
  logic stateen_illegal, stateen_virt;
  logic is_hpm_counter;
  logic is_cbo_inval, is_cbo_clean, is_cbo_flush, is_cbo_zero;
  logic cbo_illegal, cbo_virt;
  logic inval_fence_illegal, inval_fence_virt;
  logic [3:0] counter_sel;
  assign is_wfi = (inst_idu == `RAPT_INST_WFI);
`ifdef RAPT_ZAWRS
  assign is_wrs = (inst_idu & 32'hfeff_ffff) == 32'h00d0_0073;
  assign wrs_illegal = 1'b0;
`else
  assign is_wrs = 1'b0;
  assign wrs_illegal = (inst_idu & 32'hfeff_ffff) == 32'h00d0_0073;
`endif
  assign is_sfence_vma = (inst_idu[31:25] == `RAPT_F7_SFENCE_VMA)
                        && (inst_idu[14:12] == `RAPT_F3_SYS___)
                        && (inst_idu[11:7]  == 5'b0)
                        && (inst_idu[6:0]   == `RAPT_OP_SYSTEM);
  assign is_sinval_vma = (inst_idu & 32'hfe00_7fff) == 32'h1600_0073;
  assign is_inval_fence = inst_idu == 32'h1800_0073 || inst_idu == 32'h1810_0073;
  assign is_hfence_vvma = inst_idu[6:0] == `RAPT_OP_SYSTEM && inst_idu[14:7] == 8'h00
      && (inst_idu[31:25] == 7'b0010001 || inst_idu[31:25] == 7'b0010011);
  assign is_hfence_gvma = inst_idu[6:0] == `RAPT_OP_SYSTEM && inst_idu[14:7] == 8'h00
      && (inst_idu[31:25] == 7'b0110001 || inst_idu[31:25] == 7'b0110011);
  assign is_hfence = is_hfence_vvma || is_hfence_gvma;
  assign is_hmem = rapt_pkg::is_hmem_inst(inst_idu);
  assign hfence_virt = is_hfence && csr_bcast.virt;
  assign hfence_illegal = is_hfence && !hfence_virt
      && (!(rapt_pkg::HypervisorEnable && XLEN == 64)
          || csr_bcast.priv == `RAPT_PRIV_U
          || (is_hfence_gvma && csr_bcast.priv == `RAPT_PRIV_S && csr_bcast.tvm));
  assign hmem_virt = is_hmem && csr_bcast.virt;
  assign hmem_illegal = is_hmem && !hmem_virt
      && (!(rapt_pkg::HypervisorEnable && XLEN == 64)
          || (csr_bcast.priv == `RAPT_PRIV_U && !csr_bcast.hstatus_hu));
  assign wfi_virt = is_wfi && csr_bcast.virt && !csr_bcast.tw
      && (csr_bcast.priv == `RAPT_PRIV_U || csr_bcast.hstatus_vtw);
  assign wfi_illegal = is_wfi && !wfi_virt
      && (csr_bcast.priv == `RAPT_PRIV_U
       || (csr_bcast.priv == `RAPT_PRIV_S && csr_bcast.tw));
  assign sret_virt = decoded.uop.execute.sys.sret && csr_bcast.virt
      && (csr_bcast.priv == `RAPT_PRIV_U || csr_bcast.hstatus_vtsr);
  assign sret_illegal = decoded.uop.execute.sys.sret && !csr_bcast.virt
      && (csr_bcast.priv == `RAPT_PRIV_U
       || (csr_bcast.priv == `RAPT_PRIV_S && csr_bcast.tsr));
  assign mret_illegal = decoded.uop.execute.sys.mret && csr_bcast.priv != `RAPT_PRIV_M;
  assign sfence_vma_virt = (is_sfence_vma || is_sinval_vma) && csr_bcast.virt
      && (csr_bcast.priv == `RAPT_PRIV_U || csr_bcast.hstatus_vtvm);
  assign sfence_vma_illegal = (is_sfence_vma || is_sinval_vma) && !csr_bcast.virt
      && (csr_bcast.priv == `RAPT_PRIV_U
       || (csr_bcast.priv == `RAPT_PRIV_S && csr_bcast.tvm));
  assign satp_illegal = csr_op && !guest_hs_csr
      && (csr == `RAPT_CSR_SATP___ || csr == `RAPT_CSR_HGATP)
      && csr_bcast.priv == `RAPT_PRIV_S && !csr_bcast.virt && csr_bcast.tvm;
  assign satp_virt = csr_op && !guest_hs_csr && csr == `RAPT_CSR_SATP___
      && csr_bcast.priv == `RAPT_PRIV_S && csr_bcast.virt && csr_bcast.hstatus_vtvm;
  assign stimecmp_illegal = csr_op && !guest_hs_csr
      && csr_bcast.priv != `RAPT_PRIV_M && !stimecmp_m_ok;
  assign stimecmp_virt = csr_op && !guest_hs_csr && !stimecmp_illegal
      && csr == `RAPT_CSR_STIMECMP && csr_bcast.virt
      && (!csr_bcast.henvcfg_stce || !csr_bcast.hcounteren[`RAPT_CSR_COUNTEREN_TM]);
  assign stateen_illegal = csr_op && !guest_hs_csr
      && csr_bcast.priv == `RAPT_PRIV_S && !csr_mstateen_ok;
  wire sstateen_addr = csr >= `RAPT_CSR_SSTATEEN0 && csr <= `RAPT_CSR_SSTATEEN3;
  wire sstateen_h_denied = sstateen_addr && !csr_bcast.hstateen_se0[csr[1:0]];
  assign stateen_virt = rapt_pkg::SmstateenEnable && csr_op && !guest_hs_csr
      && csr_bcast.virt && csr_bcast.priv == `RAPT_PRIV_S && csr_mstateen_ok
      && ((csr == `RAPT_CSR_SENVCFG && !csr_bcast.hstateen0_envcfg) || sstateen_h_denied);
  wire is_hpm3_csr = (csr == (`RAPT_CSR_HPMCOUNTER3))
      || (XLEN == 32 && csr == (`RAPT_CSR_HPMCOUNTER3H));
  assign counter_sel = (csr == `RAPT_CSR_CYCLE__
      || (XLEN == 32 && csr == `RAPT_CSR_CYCLEH_)) ? `RAPT_CTR_SEL_CY__
      : (csr == `RAPT_CSR_TIME___ || (XLEN == 32 && csr == `RAPT_CSR_TIMEH__))
      ? `RAPT_CTR_SEL_TM__
      : (csr == `RAPT_CSR_INSTRET_ || (XLEN == 32 && csr == `RAPT_CSR_INSTRETH))
      ? `RAPT_CTR_SEL_IR__
      : (rapt_pkg::SscofpmfEnable && is_hpm3_csr)
      ? `RAPT_CTR_SEL_HPM3 : `RAPT_CTR_SEL_NONE;
  assign is_hpm_counter = ((csr >= `RAPT_CSR_HPMCOUNTER3 && csr <= `RAPT_CSR_HPMCOUNTER31)
      || (XLEN == 32 && csr >= `RAPT_CSR_HPMCOUNTER3H && csr <= `RAPT_CSR_HPMCOUNTER31H))
      && !(rapt_pkg::SscofpmfEnable && is_hpm3_csr);
  logic ctr_m_denied, ctr_h_denied, ctr_s_denied;
  assign ctr_m_denied = counter_sel != `RAPT_CTR_SEL_NONE && csr_bcast.priv != `RAPT_PRIV_M
      && ((counter_sel & csr_bcast.mcounteren) == `RAPT_CTR_SEL_NONE);
  assign ctr_h_denied = counter_sel != `RAPT_CTR_SEL_NONE && csr_bcast.virt
      && ((counter_sel & csr_bcast.hcounteren) == `RAPT_CTR_SEL_NONE);
  assign ctr_s_denied = counter_sel != `RAPT_CTR_SEL_NONE && csr_bcast.priv == `RAPT_PRIV_U
      && ((counter_sel & csr_bcast.scounteren) == `RAPT_CTR_SEL_NONE);
  assign counter_illegal = csr_op && !guest_hs_csr
      && (ctr_m_denied || (!csr_bcast.virt && ctr_s_denied)
          || (is_hpm_counter && csr_bcast.priv != `RAPT_PRIV_M));
  assign counter_virt = csr_op && !guest_hs_csr && !ctr_m_denied
      && csr_bcast.virt && (ctr_h_denied || ctr_s_denied);
  assign virt_csr = csr_op && (
      (guest_hs_csr && guest_hs_qualified)
      || stateen_virt || satp_virt || stimecmp_virt || counter_virt);

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
  wire host_u_mode = csr_bcast.priv == `RAPT_PRIV_U && !csr_bcast.virt;
  wire cbo_inval_m_denied = csr_bcast.menvcfg_cbie == 2'b00
      || (host_u_mode && csr_bcast.senvcfg_cbie == 2'b00);
  wire cbo_clean_m_denied = !csr_bcast.menvcfg_cbcfe || (host_u_mode && !csr_bcast.senvcfg_cbcfe);
  wire cbo_zero_m_denied = !csr_bcast.menvcfg_cbze || (host_u_mode && !csr_bcast.senvcfg_cbze);
  assign cbo_illegal = (csr_bcast.priv != `RAPT_PRIV_M) && (
      (is_cbo_inval && cbo_inval_m_denied)
      || ((is_cbo_clean || is_cbo_flush) && cbo_clean_m_denied)
      || (is_cbo_zero && cbo_zero_m_denied));
  assign cbo_virt = csr_bcast.virt && !cbo_illegal && (
      (is_cbo_inval && (csr_bcast.henvcfg_cbie == 2'b00
        || (csr_bcast.priv == `RAPT_PRIV_U && csr_bcast.senvcfg_cbie == 2'b00)))
      || ((is_cbo_clean || is_cbo_flush) && (!csr_bcast.henvcfg_cbcfe
        || (csr_bcast.priv == `RAPT_PRIV_U && !csr_bcast.senvcfg_cbcfe)))
      || (is_cbo_zero && (!csr_bcast.henvcfg_cbze
        || (csr_bcast.priv == `RAPT_PRIV_U && !csr_bcast.senvcfg_cbze))));
  assign inval_fence_illegal = is_inval_fence && csr_bcast.priv == `RAPT_PRIV_U
      && !csr_bcast.virt;
  assign inval_fence_virt = is_inval_fence && csr_bcast.priv == `RAPT_PRIV_U
      && csr_bcast.virt;

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
  assign rev8_xlen_illegal = XLEN == 64 && (inst_idu & 32'hfff0707f) == 32'h69805013;
  // C.ZEXT.H already expands to the XLEN-specific opcode. Reject only
  // the unimplemented RV32 native encoding when executing RV64.
  assign zexth_xlen_illegal = XLEN == 64 && (inst_idu & 32'hfff0707f) == 32'h08004033;

  assign is_illegal = (illegal_inst && !fp_valid) || illegal_csr
      || shift_imm_xlen_illegal || rev8_xlen_illegal || zexth_xlen_illegal
      || (XLEN == 32 && integer_rv64_only)
      || wfi_illegal || wrs_illegal || mret_illegal || sret_illegal || sfence_vma_illegal
      || satp_illegal || counter_illegal || stimecmp_illegal || stateen_illegal || fp_disabled
      || cbo_illegal || inval_fence_illegal || hfence_illegal || hmem_illegal
      || (fp_rv64_only && XLEN != 64);
  assign is_virt_inst = !is_illegal
      && (virt_csr || wfi_virt || sret_virt || sfence_vma_virt
          || cbo_virt || inval_fence_virt || hfence_virt || hmem_virt);

  function automatic logic is_guest_vs_alias(input logic [11:0] addr);
    case (addr)
      `RAPT_CSR_SSTATUS, `RAPT_CSR_SIE____, `RAPT_CSR_STVEC__,
      `RAPT_CSR_SSCRATC, `RAPT_CSR_SEPC___, `RAPT_CSR_SCAUSE_,
      `RAPT_CSR_STVAL__, `RAPT_CSR_SIP____, `RAPT_CSR_STIMECMP,
      `RAPT_CSR_SATP___:
        return 1'b1;
      default: return 1'b0;
    endcase
  endfunction

  function automatic logic is_guest_shared_s_csr(input logic [11:0] addr);
    return (addr == (`RAPT_CSR_SCOUNTE)) || (addr == (`RAPT_CSR_SENVCFG))
        || (rapt_pkg::SscofpmfEnable && addr == (`RAPT_CSR_SCOUNTOVF))
        || (addr >= (`RAPT_CSR_SSTATEEN0) && addr <= (`RAPT_CSR_SSTATEEN3));
  endfunction

  function automatic logic stateen_m_allows_s(input logic [11:0] addr);
    if (!rapt_pkg::SmstateenEnable) return 1'b1;
    if (addr >= `RAPT_CSR_SSTATEEN0 && addr <= `RAPT_CSR_SSTATEEN3)
      return csr_bcast.mstateen_se0[addr[1:0]];
    if (rapt_pkg::HypervisorEnable && XLEN == 64
        && addr >= `RAPT_CSR_HSTATEEN0 && addr <= `RAPT_CSR_HSTATEEN3)
      return csr_bcast.mstateen_se0[addr[1:0]];
    if (addr == `RAPT_CSR_SENVCFG) return csr_bcast.mstateen0_envcfg;
    if (rapt_pkg::HypervisorEnable && XLEN == 64 && addr == `RAPT_CSR_HENVCFG)
      return csr_bcast.mstateen0_envcfg;
    return 1'b1;
  endfunction

  // CSR address validity check - returns 1 if the CSR address is legal.
  // Extend this function when adding new CSR registers.
  function automatic logic csr_addr_valid(input logic [11:0] addr);
    // RV64 packs eight PMP entries per even pmpcfg CSR; odd encodings do
    // not exist. All sixteen implemented pmpaddr CSRs exist at either XLEN.
    if (addr >= `RAPT_CSR_PMPCFG0 && addr <= `RAPT_CSR_PMPCFG3) return XLEN == 32 || !addr[0];
    if (addr >= `RAPT_CSR_PMPADDR0 && addr <= `RAPT_CSR_PMPADDR15) return 1'b1;
    if (addr == `RAPT_CSR_MSTATUSH || addr == (`RAPT_CSR_MENVCFGH) || addr == `RAPT_CSR_STIMECMPH)
      return XLEN == 32;
    if (rapt_pkg::SscofpmfEnable) begin
      if (addr == `RAPT_CSR_SCOUNTOVF) return 1'b1;
      if (XLEN == 32 && addr >= `RAPT_CSR_MHPMEVENT3H && addr <= `RAPT_CSR_MHPMEVENT31H)
        return 1'b1;
    end
    if (rapt_pkg::SmstateenEnable) begin
      if (addr >= `RAPT_CSR_SSTATEEN0 && addr <= `RAPT_CSR_SSTATEEN3) return 1'b1;
      if (addr >= `RAPT_CSR_MSTATEEN0 && addr <= `RAPT_CSR_MSTATEEN3) return 1'b1;
      if (XLEN == 32 && addr >= `RAPT_CSR_MSTATEEN0H && addr <= `RAPT_CSR_MSTATEEN3H) return 1'b1;
      if (rapt_pkg::HypervisorEnable && XLEN == 64
          && addr >= `RAPT_CSR_HSTATEEN0 && addr <= `RAPT_CSR_HSTATEEN3)
        return 1'b1;
    end
    if (rapt_pkg::HypervisorEnable && XLEN == 64) begin
      case (addr)
        `RAPT_CSR_VSSTATUS, `RAPT_CSR_VSIE_____, `RAPT_CSR_VSTVEC___, `RAPT_CSR_VSSCRATCH,
        `RAPT_CSR_VSEPC____, `RAPT_CSR_VSCAUSE__, `RAPT_CSR_VSTVAL___, `RAPT_CSR_VSIP_____,
        `RAPT_CSR_VSTIMECMP, `RAPT_CSR_VSATP____, `RAPT_CSR_HSTATUS, `RAPT_CSR_HEDELEG,
        `RAPT_CSR_HIDELEG, `RAPT_CSR_HIE____, `RAPT_CSR_HTIMEDELTA, `RAPT_CSR_HCOUNTEREN,
        `RAPT_CSR_HGEIE, `RAPT_CSR_HENVCFG, `RAPT_CSR_HTVAL, `RAPT_CSR_HIP____,
        `RAPT_CSR_HVIP___, `RAPT_CSR_HTINST, `RAPT_CSR_HGATP, `RAPT_CSR_HGEIP,
        `RAPT_CSR_MTINST, `RAPT_CSR_MTVAL2:
          return 1'b1;
        default: begin
        end
      endcase
    end
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
      `RAPT_CSR_SIP____,  `RAPT_CSR_STIMECMP, `RAPT_CSR_SATP___,
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
      `RAPT_CSR_MVENDORID, `RAPT_CSR_MARCHID__, `RAPT_CSR_IMPID____,
      `RAPT_CSR_MHARTID__, `RAPT_CSR_MCONFIGPTR:
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
  assign decoded.uop.execute.fp.rd = vector_valid ? inst_idu[11:7] : fp_rd;
  assign decoded.uop.execute.memory.load = !vector_valid && (ren_dec || fp_load || fp_load_d);
  assign decoded.uop.execute.memory.store = !vector_valid && (wen_dec || fp_store || fp_store_d);
  assign decoded.uop.rd[RLEN-1:0] = vector_valid && !decode_trap
      ? (vector_rd ? inst_idu[11:7] : '0)
      : (decode_trap || fp_writes_fpr
      || fp_store || fp_store_d) ? '0
      : (fp_valid ? fp_rd[RLEN-1:0] : rd[RLEN-1:0]);
  assign decoded.uop.execute.sys.csr_csw = (vector_valid || decode_trap) ? '0 : csr_csw;
  assign decoded.uop.execute.branch.ras = rapt_pkg::ras_action(inst_idu);
  assign decoded.uop.execute.memory.aq = inst_idu[26];
  assign decoded.uop.execute.memory.rl = inst_idu[25];
  assign decoded.uop.execute.sys.kind = is_wrs ? rapt_pkg::SYS_WRS
      : (is_sfence_vma || is_sinval_vma || is_hfence) ? rapt_pkg::SYS_TRANSLATION
      : (is_cbo_inval || is_cbo_flush) ? rapt_pkg::SYS_CBO_INVAL
      : is_cbo_clean ? rapt_pkg::SYS_CBO_CLEAN
      : is_cbo_zero ? rapt_pkg::SYS_CBO_ZERO
      : (inst_idu[6:0] == `RAPT_OP_FENCE_ && inst_idu[14:12] == 3'b001) ? rapt_pkg::SYS_FENCE_I
      : (inst_idu[6:0] == `RAPT_OP_FENCE_ && inst_idu[14:12] == 3'b000) ? rapt_pkg::SYS_FENCE
      : rapt_pkg::SYS_NORMAL;


  // Trap aggregation: IFU traps (e.g., page fault) or decode-time illegality
  assign decoded.uop.trap = ifu_trap || decode_trap;
  assign decoded.uop.fetch_tval_plus2 = fetched.fetch_tval_plus2;
  assign decoded.uop.cause = ifu_trap ? ifu_cause
      : is_illegal ? `RAPT_CAUSE_ILLEGAL_INST
      : is_virt_inst ? `RAPT_CAUSE_VIRT_INST : '0;

`ifdef RAPT_UOP_HAS_INST
  assign decoded.uop.inst = inst_idu;
`endif
`ifdef RAPT_RVFI
  // RVFI must report the original instruction word: compressed instructions
  // are reported as the raw 16-bit encoding zero-extended (so `insn[1:0]!=2'b11`),
  // not the decompressed 32-bit form used internally for decode/difftest.
  assign decoded.uop.rvfi_inst = is_c ? {16'b0, inst[15:0]} : inst;
`endif
  assign decoded.uop.pc        = fetched.pc;

  // Translation fences need real GPR dependencies for their commit descriptor.
  // Keep the generated decoder's serialization flags and constant operands.
  assign decoded.rs1[RLEN-1:0] = vector_valid
      ? (vector_rs1 ? inst_idu[19:15] : '0)
      : (`RAPT_SFENCE_SELECTIVE != 0
      && (is_sfence_vma || is_sinval_vma)) ? inst_idu[19:15] : (fp_valid &&
        (fp_op == `RAPT_FP_OP_FMV_W_X || fp_op == (`RAPT_FP_OP_FMV_D_X)
         || fp_i2f || fp_load || fp_store || fp_load_d || fp_store_d))
        ? fp_rs1[RLEN-1:0] : rs1[RLEN-1:0];
  assign decoded.rs2[RLEN-1:0] = vector_valid
      ? (vector_rs2 ? inst_idu[24:20] : '0)
      : (`RAPT_SFENCE_SELECTIVE != 0
      && (is_sfence_vma || is_sinval_vma)) ? inst_idu[24:20]
      : fp_valid ? fp_rs2[RLEN-1:0] : rs2[RLEN-1:0];

  assign decoded.pnpc = fetched.pnpc;
  assign decoded.uop.execute.branch.predicted_taken = fetched.predicted_taken;
endmodule
