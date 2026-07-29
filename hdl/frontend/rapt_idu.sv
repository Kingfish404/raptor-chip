`include "rapt.svh"
`include "rapt_if.svh"

// Instruction Decode Unit (IDU) - single-stage pipeline register + decode.
//
// Pipeline control: simple IDLE/VALID FSM with valid/ready handshaking.
// Decode is purely combinational via generated decoders.
// CSR validity is checked via a dedicated function for maintainability.
module rapt_idu #(
    parameter unsigned RLEN = `RAPT_REG_LEN,
    parameter int XLEN = `RAPT_XLEN
) (
    input clock,

    cmu_bcast_if.in cmu_bcast,
    csr_bcast_if.in csr_bcast,

    ifu_idu_if.slave  ifu_idu,
    idu_bpu_if.out    idu_bpu,
    idu_rnu_if.master idu_rnu,

    input reset
);
  // ================================================================
  // Pipeline Stage Control (IDLE / VALID FSM)
  // ================================================================
  typedef enum logic {
    IDLE  = 1'b0,
    VALID = 1'b1
  } state_idu_t;

  state_idu_t state_idu;

  logic valid, ready;

  // ================================================================
  // Early Resteer: resolve prediction errors whose target is statically known
  // ================================================================
  // If BPU predicted taken (pnpc != pc + inst_len) but the decoded
  // instruction is not a branch/jump, resteer IFU to the correct
  // sequential address immediately, avoiding a full pipeline flush
  // at commit time.
  logic [XLEN-1:0] correct_npc;
  logic bpu_predicted_taken;
  logic is_branch_or_jump;
  logic target_resolvable;
  logic early_resteer_cond;
  logic idu_redirect_event;
  logic resteer_sent;
  logic slot_b_direct_jal;
  logic slot_b_cond_branch;

  assign valid = (state_idu == VALID);
  assign ready = (state_idu == IDLE) || idu_rnu.ready;
  assign idu_rnu.valid_a = valid;
  assign ifu_idu.ready = ready && !early_resteer_cond && !idu_redirect_event;

  // Pipeline latch: capture from IFU when ready
  // Slot A pipeline latch
  logic [    31:0] inst_a;
  logic [XLEN-1:0] pc_idu_a;

`ifdef RAPT_DUAL_ISSUE
  // Slot B pipeline latch
  logic [    31:0] inst_b;
  logic [XLEN-1:0] pc_idu_b;
  logic            ifu_valid_b;
`endif

  logic [XLEN-1:0] pnpc_idu;
  logic            ifu_trap;
  logic [XLEN-1:0] ifu_cause;
  logic [XLEN-1:0] ifu_tval;

  always_ff @(posedge clock) begin
    if (reset) begin
      state_idu <= IDLE;
`ifdef RAPT_DUAL_ISSUE
      ifu_valid_b <= 0;
`endif
    end else begin
      unique case (state_idu)
        IDLE: begin
          if (idu_redirect_event) begin
            // Stay IDLE on flush
`ifdef RAPT_DUAL_ISSUE
            ifu_valid_b <= 0;
`endif
          end else if (ifu_idu.valid_a) begin
            state_idu <= VALID;
          end
        end
        VALID: begin
          if (idu_redirect_event) begin
            state_idu <= IDLE;
`ifdef RAPT_DUAL_ISSUE
            ifu_valid_b <= 0;
`endif
          end else if (early_resteer_cond) begin
            // Discard wrong-path IFU output while the decoded early-resteer
            // condition is still visible; the resteer pulse itself is one-shot.
            if (idu_rnu.ready) state_idu <= IDLE;
          end else if (idu_rnu.ready && !ifu_idu.valid_a) begin
            state_idu <= IDLE;
          end
          // If idu_rnu.ready && ifu_idu.valid && !resteer => stay VALID (back-to-back)
        end
        default: ;
      endcase

      // Latch IFU data when pipeline slot is available.
      // Block latch while early-resteer condition is visible: this IFU output
      // is still from the mispredicted path and must be discarded.
      if (ready && ifu_idu.valid_a && !early_resteer_cond && !idu_redirect_event) begin
        inst_a    <= ifu_idu.inst_a;
        pc_idu_a    <= ifu_idu.pc_a;
        pnpc_idu  <= ifu_idu.pnpc;
        ifu_trap  <= ifu_idu.trap;
        ifu_cause <= ifu_idu.cause;
        ifu_tval  <= ifu_idu.tval;
`ifdef RAPT_DUAL_ISSUE
        inst_b      <= ifu_idu.inst_b;
        pc_idu_b    <= ifu_idu.pc_b;
        ifu_valid_b <= ifu_idu.valid_b;
`endif
      end
    end
  end

  // ================================================================
  // Instruction Decoding (combinational)
  // Solt A: main instruction (could be compressed or regular)
  // ================================================================
  logic [ 5:0] alu_a;
  logic        word_flag_a;
  logic [11:0] csr_a;
  logic [ 2:0] csr_csw_a;
  logic [4:0] rd_a, rs1_a, rs2_a;

  // Compressed instruction expansion
  logic        is_c_a;
  logic [31:0] inst_de_a;
  logic [31:0] inst_idu_a;

  // ================================================================
  // Slot B: Second Instruction Decode (dual-issue)
  // ================================================================
  // Slot B can be compressed or regular 32-bit (generalized dual-fetch).
  logic [ 5:0] alu_b;
  logic        word_flag_b;
  logic [11:0] csr_b;
  logic [ 2:0] csr_csw_b;
  logic [4:0] rd_b, rs1_b, rs2_b;

  // Compressed instruction expansion
  logic        is_c_b;
  logic [31:0] inst_de_b;  // Expanded from compressed
  logic [31:0] inst_idu_b;

  // Decoder output wires (always 64-bit from generated decoder)
  /* verilator lint_off UNUSEDSIGNAL */
  logic [63:0] dec_imm_a, dec_op1_a, dec_op2_a;
  logic [63:0] dec_imm_b, dec_op1_b, dec_op2_b;
  /* verilator lint_on UNUSEDSIGNAL */

  assign is_c_a     = (inst_a[1:0] != 2'b11);
  assign inst_idu_a = is_c_a ? inst_de_a : inst_a;

  rapt_idu_decoder_c idu_de_c (
      .io_cinst  (inst_a[15:0]),
      .io_is_rv64(XLEN == 64 ? 1'b1 : 1'b0),
      .io_inst   (inst_de_a)
  );

  rapt_idu_decoder idu_de (
      .in_pc  ({{(64 - XLEN) {1'b0}}, pc_idu_a}),
      .in_inst(inst_idu_a),

      .out_alu (alu_a),
      .out_word(word_flag_a),
      .out_ben (idu_rnu.uop_a.ben),
      .out_jen (idu_rnu.uop_a.jen),
      .out_jren(idu_rnu.uop_a.jren),
      .out_wen (idu_rnu.uop_a.wen),
      .out_ren (idu_rnu.uop_a.ren),
      .out_atom(idu_rnu.uop_a.atom),

      .out_sys_system (idu_rnu.uop_a.system),
      .out_sys_ebreak (idu_rnu.uop_a.ebreak),
      .out_sys_ecall  (idu_rnu.uop_a.ecall),
      .out_sys_mret   (idu_rnu.uop_a.mret),
      .out_sys_sret   (idu_rnu.uop_a.sret),
      .out_sys_csr_csw(csr_csw_a),

      .out_fence_i   (idu_rnu.uop_a.f_i),
      .out_fence_time(idu_rnu.uop_a.f_time),

      .out_imm(dec_imm_a),
      .out_rd (rd_a),
      .out_csr(csr_a),

      .out_op1(dec_op1_a),
      .out_op2(dec_op2_a),
      .out_rs1(rs1_a),
      .out_rs2(rs2_a)
  );

  // Truncate 64-bit decoder outputs to XLEN
  assign idu_rnu.uop_a.imm = dec_imm_a[XLEN-1:0];
  assign idu_rnu.op1_a     = dec_op1_a[XLEN-1:0];
  assign idu_rnu.op2_a     = dec_op2_a[XLEN-1:0];

  // ================================================================
  // Illegality detection for slot A
  // check if the decoded ALU operation is illegal or if a CSR
  // ================================================================
  logic illegal_inst_a, illegal_csr_a, is_illegal_a;

  // Illegality detection for slot B
  logic illegal_inst_b, illegal_csr_b, is_illegal_b;

  assign illegal_inst_a = (alu_a == `RAPT_ALU_ILL_);
  // CSR write attempt: CSRRW/CSRRWI always write; CSRRS/C/SI/CI write if rs1/uimm != 0
  logic csr_write_a;
  assign csr_write_a = (csr_csw_a[1:0] == 2'b01) || (rs1_a != 5'b0);
  assign illegal_csr_a = (csr_csw_a != `RAPT_CSR_CSW_NONE) && (!csr_addr_valid(
      csr_a
  )  // unknown CSR address
  || (csr_a[9:8] > csr_bcast.priv)  // insufficient privilege
  || (csr_a[11:10] == 2'b11 && csr_write_a)  // write to read-only CSR
  );

  // Privileged system-instruction gating (TSR/TVM/TW + counteren).
  //   WFI: illegal in U-mode always, illegal in S-mode when mstatus.TW=1.
  //   SRET: illegal in U-mode, illegal in S-mode when mstatus.TSR=1.
  //   SFENCE.VMA: illegal in U-mode; illegal in S-mode when mstatus.TVM=1.
  //   satp: illegal in S-mode when mstatus.TVM=1 (generic priv check catches U).
  //   cycle/time/instret (+h): read from S or U needs mcounteren bit;
  //     read from U additionally needs scounteren bit.
  logic is_wfi_a, is_sfence_vma_a;
  logic wfi_illegal_a, sret_illegal_a, sfence_vma_illegal_a, satp_illegal_a;
  logic counter_illegal_a;
  logic [2:0] counter_sel_a;
  assign is_wfi_a = (inst_idu_a == `RAPT_INST_WFI);
  assign is_sfence_vma_a = (inst_idu_a[31:25] == `RAPT_F7_SFENCE_VMA)
                        && (inst_idu_a[14:12] == `RAPT_F3_SYS___)
                        && (inst_idu_a[11:7]  == 5'b0)
                        && (inst_idu_a[6:0]   == `RAPT_OP_SYSTEM);
  assign wfi_illegal_a = is_wfi_a
      && ((csr_bcast.priv == `RAPT_PRIV_U)
       || (csr_bcast.priv == `RAPT_PRIV_S && csr_bcast.tw));
  assign sret_illegal_a = idu_rnu.uop_a.sret
      && ((csr_bcast.priv == `RAPT_PRIV_U)
       || (csr_bcast.priv == `RAPT_PRIV_S && csr_bcast.tsr));
  assign sfence_vma_illegal_a = is_sfence_vma_a
      && ((csr_bcast.priv == `RAPT_PRIV_U)
       || (csr_bcast.priv == `RAPT_PRIV_S && csr_bcast.tvm));
  assign satp_illegal_a = (csr_csw_a != `RAPT_CSR_CSW_NONE) && (csr_a == `RAPT_CSR_SATP___)
      && (csr_bcast.priv == `RAPT_PRIV_S) && csr_bcast.tvm;
  assign counter_sel_a = (csr_a ==
      `RAPT_CSR_CYCLE__
      || csr_a == `RAPT_CSR_CYCLEH_) ?
      `RAPT_CTR_SEL_CY__
      : (csr_a == `RAPT_CSR_TIME___ || csr_a == `RAPT_CSR_TIMEH__) ?
      `RAPT_CTR_SEL_TM__
      : (csr_a == `RAPT_CSR_INSTRET_ || csr_a == `RAPT_CSR_INSTRETH) ?
      `RAPT_CTR_SEL_IR__
      : `RAPT_CTR_SEL_NONE;
  assign counter_illegal_a = (csr_csw_a != `RAPT_CSR_CSW_NONE)
        && (counter_sel_a != `RAPT_CTR_SEL_NONE)
      && ((csr_bcast.priv ==
      `RAPT_PRIV_U
      && (((counter_sel_a & csr_bcast.mcounteren) == `RAPT_CTR_SEL_NONE) ||
          ((counter_sel_a & csr_bcast.scounteren) == `RAPT_CTR_SEL_NONE))) || (csr_bcast.priv ==
      `RAPT_PRIV_S
      && ((counter_sel_a & csr_bcast.mcounteren) == `RAPT_CTR_SEL_NONE)));

  assign is_illegal_a = illegal_inst_a || illegal_csr_a
      || wfi_illegal_a || sret_illegal_a || sfence_vma_illegal_a
      || satp_illegal_a || counter_illegal_a;

  // CSR address validity check - returns 1 if the CSR address is legal.
  // Extend this function when adding new CSR registers.
  function automatic logic csr_addr_valid(input logic [11:0] addr);
    // PMP CSRs: 8 active entries (pmpcfg0/1, pmpaddr0..7) backed by rapt_csr;
    // pmpcfg2/3 and pmpaddr8..15 are WARL-hardwired to zero but remain legal addresses.
    if (addr >= `RAPT_CSR_PMPCFG0 && addr <= `RAPT_CSR_PMPCFG3) return 1'b1;  // pmpcfg0-3
    if (addr >= `RAPT_CSR_PMPADDR0 && addr <= `RAPT_CSR_PMPADDR15) return 1'b1;  // pmpaddr0-15
    case (addr)
      // Supervisor-level CSRs
      `RAPT_CSR_SSTATUS,  `RAPT_CSR_SIE____,  `RAPT_CSR_STVEC__,  `RAPT_CSR_SCOUNTE,
      `RAPT_CSR_SENVCFG,
      `RAPT_CSR_SSCRATC,  `RAPT_CSR_SEPC___,  `RAPT_CSR_SCAUSE_,  `RAPT_CSR_STVAL__,
      `RAPT_CSR_SIP____,  `RAPT_CSR_STIMECMP, `RAPT_CSR_STIMECMPH, `RAPT_CSR_SATP___,
      // Machine Trap Setup
      `RAPT_CSR_MSTATUS,  `RAPT_CSR_MISA___,  `RAPT_CSR_MEDELEG,  `RAPT_CSR_MIDELEG,
      `RAPT_CSR_MIE____,  `RAPT_CSR_MTVEC__,  `RAPT_CSR_MCOUNTE,  `RAPT_CSR_MSTATUSH,
      `RAPT_CSR_MENVCFG,
      // Machine Trap Handling
      `RAPT_CSR_MSCRATCH, `RAPT_CSR_MEPC___,  `RAPT_CSR_MCAUSE_,  `RAPT_CSR_MTVAL__,
      `RAPT_CSR_MIP____,
      // Machine Counters
      `RAPT_CSR_MCYCLE_, `RAPT_CSR_MCYCLEH, `RAPT_CSR_CYCLE__, `RAPT_CSR_CYCLEH_,
      `RAPT_CSR_TIME___, `RAPT_CSR_TIMEH__,
      `RAPT_CSR_MINSTRET, `RAPT_CSR_MINSTRETH, `RAPT_CSR_INSTRET_, `RAPT_CSR_INSTRETH,
      // Machine Information
      `RAPT_CSR_MVENDORID, `RAPT_CSR_MARCHID__, `RAPT_CSR_IMPID____, `RAPT_CSR_MHARTID__:
      return 1'b1;
      default: return 1'b0;
    endcase
  endfunction

  // ================================================================
  // UOP Output Assembly
  // ================================================================
  assign idu_rnu.uop_a.c = is_c_a;
  // `out_word` doesn't include AMO.W/LR.W/SC.W in current decoder table.
  // For atomics, use funct3=010 to mark 32-bit variant on RV64.
  assign idu_rnu.uop_a.word = word_flag_a
      || (idu_rnu.uop_a.atom && inst_idu_a[14:12] == `RAPT_F3_AMO_W_);
  assign idu_rnu.uop_a.alu = alu_a;
  assign idu_rnu.uop_a.rd[RLEN-1:0] = is_illegal_a ? '0 : rd_a[RLEN-1:0];
  assign idu_rnu.uop_a.csr_csw = csr_csw_a;

  // Trap aggregation: IFU traps (e.g., page fault) or decode-time illegality
  assign idu_rnu.uop_a.trap = ifu_trap || is_illegal_a;
  assign idu_rnu.uop_a.tval = ifu_trap ? ifu_tval : is_illegal_a ? inst_idu_a : '0;
  assign idu_rnu.uop_a.cause = ifu_trap ? ifu_cause : is_illegal_a ? `RAPT_CAUSE_ILLEGAL_INST : '0;

  // Group-sequential PC (= next PC if every slot in the group falls through).
  // Per IFU pre-decode, dual-fetch suppresses on any control op, so slot B
  // is non-control by construction (see IDU_SLOT_B_NO_CONTROL).
  logic [XLEN-1:0] group_seq;
`ifdef RAPT_DUAL_ISSUE
  assign group_seq = ifu_valid_b
      ? (pc_idu_b + (is_c_b ? XLEN'('d2) : XLEN'('d4)))
      : (pc_idu_a + (is_c_a ? XLEN'('d2) : XLEN'('d4)));
`else
  assign group_seq = pc_idu_a + (is_c_a ? XLEN'('d2) : XLEN'('d4));
`endif

  // Static target derivation for slot A control instructions.
  // Operates on inst_idu_a so compressed forms are pre-expanded by the
  // RVC decoder upstream (`inst_de_a`).
  //   JAL imm: inst[31|19:12|20|30:21] << 1     (signed 21-bit)
  logic [20:0] jal_imm21_a;
  logic [XLEN-1:0] jal_target_a;
  assign jal_imm21_a = {inst_idu_a[31], inst_idu_a[19:12], inst_idu_a[20], inst_idu_a[30:21], 1'b0};
  assign jal_target_a = pc_idu_a + {{(XLEN - 21) {jal_imm21_a[20]}}, jal_imm21_a};

  assign is_branch_or_jump = idu_rnu.uop_a.ben || idu_rnu.uop_a.jen || idu_rnu.uop_a.jren;
`ifdef RAPT_DUAL_ISSUE
  assign slot_b_direct_jal = ifu_valid_b && idu_rnu.uop_b.jen && !idu_rnu.uop_b.jren;
  assign slot_b_cond_branch = ifu_valid_b && idu_rnu.uop_b.ben;
`else
  assign slot_b_direct_jal = 1'b0;
  assign slot_b_cond_branch = 1'b0;
`endif
  assign bpu_predicted_taken = (pnpc_idu != group_seq);

  // Resolve what the BPU *should* have predicted, when statically derivable.
  // The BPU side-channel (`idu_bpu.train_*`) updates the BTB so a recurring
  // mispredicted control op stops triggering the same resteer forever.
  //
  //  1. A=JAL with mismatch (pnpc != jal_target):
  //     resteer to jal_target; train BTB with type=DIRE. Safe because JAL
  //     is unconditional taken => uop_a.pnpc = jal_target_a leaves RS with
  //     mispredict=0 unconditionally.
  //  2. A=non-control with BPU-taken (BTB alias):
  //     resteer to group_seq. BTB has no invalidate port today, so we do
  //     NOT train; the alias re-fires on every encounter (rare; ~1 event
  //     per CoreMark run empirically).
  //  3. A=JALR: target depends on rs1; unresolvable at IDU.
  logic train_jal_a;
  // Note: the decoder asserts `jen` for BOTH JAL and JALR. Gate strictly on
  // `jen && !jren` so we only train/patch for true JAL (PC-relative,
  // statically-resolvable target). JAL_imm21 bits would otherwise be
  // garbage when applied to a JALR encoding.
  assign train_jal_a = idu_rnu.uop_a.jen && !idu_rnu.uop_a.jren && (pnpc_idu != jal_target_a);

  always_comb begin
    if (train_jal_a) begin
      target_resolvable = 1'b1;
      correct_npc       = jal_target_a;
    end else if (!is_branch_or_jump && !slot_b_direct_jal && !slot_b_cond_branch
           && bpu_predicted_taken) begin
      target_resolvable = 1'b1;
      correct_npc       = group_seq;
    end else begin
      target_resolvable = 1'b0;
      correct_npc       = pnpc_idu;  // unused: gated by target_resolvable
    end
  end

  assign early_resteer_cond = valid && !ifu_trap && target_resolvable && (pnpc_idu != correct_npc);
  assign idu_redirect_event = cmu_bcast.flush_pipe || cmu_bcast.sys_resume;

  // BPU training side-channel fires with the one-shot resteer pulse for the
  // statically-resolvable direct-JAL target.
  logic resteer_pulse;
  assign resteer_pulse        = early_resteer_cond && !resteer_sent;
  assign idu_bpu.train_en     = resteer_pulse && train_jal_a;
  assign idu_bpu.train_pc     = pc_idu_a;
  assign idu_bpu.train_target = correct_npc;
  assign idu_bpu.train_type   = 2'b01;  // DIRE (JAL)

  // Speculative RSB push: direct calls may be in either issue slot. B-slot
  // support is deliberately limited to the statically predicted direct JAL
  // form; flush recovery rewinds `rsb_spec_idx` to the architectural pointer.
  logic is_link_rd_a;
  assign is_link_rd_a    = (rd_a == 5'd1) || (rd_a == 5'd5);
`ifdef RAPT_DUAL_ISSUE
  logic is_link_rd_b;
  logic slot_b_direct_call;
  assign is_link_rd_b = (rd_b == 5'd1) || (rd_b == 5'd5);
  assign slot_b_direct_call = slot_b_direct_jal && is_link_rd_b;
`endif
`ifdef RAPT_DUAL_ISSUE
  assign idu_bpu.push_en = valid && !ifu_trap && !early_resteer_cond
                            && (((idu_rnu.uop_a.jen || idu_rnu.uop_a.jren) && is_link_rd_a)
                             || slot_b_direct_call);
  assign idu_bpu.push_addr = slot_b_direct_call
    ? pc_idu_b + (is_c_b ? XLEN'('d2) : XLEN'('d4))
    : pc_idu_a + (is_c_a ? XLEN'('d2) : XLEN'('d4));
`else
  assign idu_bpu.push_en = valid && !ifu_trap && !early_resteer_cond
                            && (idu_rnu.uop_a.jen || idu_rnu.uop_a.jren)
                            && is_link_rd_a;
  assign idu_bpu.push_addr = pc_idu_a + (is_c_a ? XLEN'('d2) : XLEN'('d4));
`endif

  // One-shot pulse: only fire resteer on the first cycle of detection
  always_ff @(posedge clock) begin
    if (reset || cmu_bcast.flush_pipe) begin
      resteer_sent <= 0;
    end else if (state_idu == IDLE) begin
      resteer_sent <= 0;
    end else if (early_resteer_cond && !resteer_sent) begin
      resteer_sent <= 1;
    end
  end

  assign ifu_idu.resteer    = early_resteer_cond && !resteer_sent;
  assign ifu_idu.resteer_pc = correct_npc;

  // PMU: registered resteer pulse for C++ sampling
  /* verilator lint_off UNUSEDSIGNAL */
  logic pmu_early_resteer;
  /* verilator lint_on UNUSEDSIGNAL */
  always_ff @(posedge clock) begin
    if (reset) pmu_early_resteer <= 0;
    else pmu_early_resteer <= ifu_idu.resteer;
  end

  // Correct pnpc before sending downstream so that downstream RS
  // mispredict comparison (`computed_npc != uop.pnpc`) stays self-consistent
  // with the resteer we just emitted. Without this, exec would observe a
  // mismatch and trigger a commit-flush, undoing the IDU resteer plus its
  // BTB training and forcing the same misprediction to repeat forever.
  //
  //   - A=JAL                    : unconditional taken     -> jal_target_a
  //   - A=non-control alias case : sequential              -> group_seq
  //   - dual-issue, B valid      : sequential to slot B PC -> pc_idu_b
  //   - otherwise                : trust BPU's prediction  -> pnpc_idu
`ifdef RAPT_DUAL_ISSUE
  assign idu_rnu.uop_a.pnpc =
      train_jal_a          ? jal_target_a
    : early_resteer_cond   ? correct_npc
    : ifu_valid_b          ? pc_idu_b
    :                        pnpc_idu;
`else
  assign idu_rnu.uop_a.pnpc =
      train_jal_a          ? jal_target_a
    : early_resteer_cond   ? correct_npc
    :                        pnpc_idu;
`endif
  assign idu_rnu.uop_a.inst      = inst_idu_a;
`ifdef RAPT_RVFI
  // RVFI must report the original instruction word: compressed instructions
  // are reported as the raw 16-bit encoding zero-extended (so `insn[1:0]!=2'b11`),
  // not the decompressed 32-bit form used internally for decode/difftest.
  assign idu_rnu.uop_a.rvfi_inst = is_c_a ? {16'b0, inst_a[15:0]} : inst_a;
`endif
  assign idu_rnu.uop_a.pc        = pc_idu_a;

  assign idu_rnu.rs1_a[RLEN-1:0] = rs1_a[RLEN-1:0];
  assign idu_rnu.rs2_a[RLEN-1:0] = rs2_a[RLEN-1:0];

`ifdef RAPT_DUAL_ISSUE
  assign is_c_b     = (inst_b[1:0] != 2'b11);
  assign inst_idu_b = is_c_b ? inst_de_b : inst_b;

  rapt_idu_decoder_c idu_de_c_b (
      .io_cinst  (inst_b[15:0]),
      .io_is_rv64(XLEN == 64 ? 1'b1 : 1'b0),
      .io_inst   (inst_de_b)
  );

  rapt_idu_decoder idu_de_b (
      .in_pc  ({{(64 - XLEN) {1'b0}}, pc_idu_b}),
      .in_inst(inst_idu_b),

      .out_alu (alu_b),
      .out_word(word_flag_b),
      .out_ben (idu_rnu.uop_b.ben),
      .out_jen (idu_rnu.uop_b.jen),
      .out_jren(idu_rnu.uop_b.jren),
      .out_wen (idu_rnu.uop_b.wen),
      .out_ren (idu_rnu.uop_b.ren),
      .out_atom(idu_rnu.uop_b.atom),

      .out_sys_system (idu_rnu.uop_b.system),
      .out_sys_ebreak (idu_rnu.uop_b.ebreak),
      .out_sys_ecall  (idu_rnu.uop_b.ecall),
      .out_sys_mret   (idu_rnu.uop_b.mret),
      .out_sys_sret   (idu_rnu.uop_b.sret),
      .out_sys_csr_csw(csr_csw_b),

      .out_fence_i   (idu_rnu.uop_b.f_i),
      .out_fence_time(idu_rnu.uop_b.f_time),

      .out_imm(dec_imm_b),
      .out_rd (rd_b),
      .out_csr(csr_b),

      .out_op1(dec_op1_b),
      .out_op2(dec_op2_b),
      .out_rs1(rs1_b),
      .out_rs2(rs2_b)
  );

  assign illegal_inst_b = (alu_b == `RAPT_ALU_ILL_);
  logic csr_write_b;
  assign csr_write_b = (csr_csw_b[1:0] == 2'b01) || (rs1_b != 5'b0);
  assign illegal_csr_b = (csr_csw_b != `RAPT_CSR_CSW_NONE) && (!csr_addr_valid(
      csr_b
  ) || (csr_b[9:8] > csr_bcast.priv) || (csr_b[11:10] == 2'b11 && csr_write_b));

  // Slot B privileged-mode gating (mirrors slot A).
  logic is_wfi_b, is_sfence_vma_b;
  logic wfi_illegal_b, sret_illegal_b, sfence_vma_illegal_b, satp_illegal_b;
  logic counter_illegal_b;
  logic [2:0] counter_sel_b;
  assign is_wfi_b = (inst_idu_b == `RAPT_INST_WFI);
  assign is_sfence_vma_b = (inst_idu_b[31:25] == `RAPT_F7_SFENCE_VMA)
                        && (inst_idu_b[14:12] == `RAPT_F3_SYS___)
                        && (inst_idu_b[11:7]  == 5'b0)
                        && (inst_idu_b[6:0]   == `RAPT_OP_SYSTEM);
  assign wfi_illegal_b = is_wfi_b
      && ((csr_bcast.priv == `RAPT_PRIV_U)
       || (csr_bcast.priv == `RAPT_PRIV_S && csr_bcast.tw));
  assign sret_illegal_b = idu_rnu.uop_b.sret
      && ((csr_bcast.priv == `RAPT_PRIV_U)
       || (csr_bcast.priv == `RAPT_PRIV_S && csr_bcast.tsr));
  assign sfence_vma_illegal_b = is_sfence_vma_b
      && ((csr_bcast.priv == `RAPT_PRIV_U)
       || (csr_bcast.priv == `RAPT_PRIV_S && csr_bcast.tvm));
  assign satp_illegal_b = (csr_csw_b != `RAPT_CSR_CSW_NONE) && (csr_b == `RAPT_CSR_SATP___)
      && (csr_bcast.priv == `RAPT_PRIV_S) && csr_bcast.tvm;
  assign counter_sel_b = (csr_b ==
      `RAPT_CSR_CYCLE__
      || csr_b == `RAPT_CSR_CYCLEH_) ?
      `RAPT_CTR_SEL_CY__
      : (csr_b == `RAPT_CSR_TIME___ || csr_b == `RAPT_CSR_TIMEH__) ?
      `RAPT_CTR_SEL_TM__
      : (csr_b == `RAPT_CSR_INSTRET_ || csr_b == `RAPT_CSR_INSTRETH) ?
      `RAPT_CTR_SEL_IR__
      : `RAPT_CTR_SEL_NONE;
  assign counter_illegal_b = (csr_csw_b != `RAPT_CSR_CSW_NONE)
        && (counter_sel_b != `RAPT_CTR_SEL_NONE)
      && ((csr_bcast.priv ==
      `RAPT_PRIV_U
      && (((counter_sel_b & csr_bcast.mcounteren) == `RAPT_CTR_SEL_NONE) ||
          ((counter_sel_b & csr_bcast.scounteren) == `RAPT_CTR_SEL_NONE))) || (csr_bcast.priv ==
      `RAPT_PRIV_S
      && ((counter_sel_b & csr_bcast.mcounteren) == `RAPT_CTR_SEL_NONE)));

  assign is_illegal_b = illegal_inst_b || illegal_csr_b
      || wfi_illegal_b || sret_illegal_b || sfence_vma_illegal_b
      || satp_illegal_b || counter_illegal_b;

  // Slot B UOP assembly
  assign idu_rnu.uop_b.c = is_c_b;
  assign idu_rnu.uop_b.word = word_flag_b
      || (idu_rnu.uop_b.atom && inst_idu_b[14:12] == `RAPT_F3_AMO_W_);
  assign idu_rnu.uop_b.alu = alu_b;
  assign idu_rnu.uop_b.rd[RLEN-1:0] = is_illegal_b ? '0 : rd_b[RLEN-1:0];
  assign idu_rnu.uop_b.csr_csw = csr_csw_b;

  assign idu_rnu.uop_b.trap = is_illegal_b;
  assign idu_rnu.uop_b.tval = is_illegal_b ? inst_idu_b : '0;
  assign idu_rnu.uop_b.cause = is_illegal_b ? `RAPT_CAUSE_ILLEGAL_INST : '0;

  assign idu_rnu.uop_b.pnpc = (slot_b_direct_jal || slot_b_cond_branch)
    ? pnpc_idu
    : pc_idu_b + (is_c_b ? XLEN'('d2) : XLEN'('d4));
  assign idu_rnu.uop_b.inst = inst_idu_b;
`ifdef RAPT_RVFI
  assign idu_rnu.uop_b.rvfi_inst = is_c_b ? {16'b0, inst_b[15:0]} : inst_b;
`endif
  assign idu_rnu.uop_b.pc = pc_idu_b;

  assign idu_rnu.uop_b.imm = dec_imm_b[XLEN-1:0];
  assign idu_rnu.op1_b = dec_op1_b[XLEN-1:0];
  assign idu_rnu.op2_b = dec_op2_b[XLEN-1:0];

  assign idu_rnu.rs1_b[RLEN-1:0] = rs1_b[RLEN-1:0];
  assign idu_rnu.rs2_b[RLEN-1:0] = rs2_b[RLEN-1:0];

  // Slot B valid: IFU provided a second instruction AND slot A is not a trap
  // or branch/jump (branches in slot A could skip slot B on the taken path).
  assign idu_rnu.valid_b = valid && ifu_valid_b && !ifu_trap && !is_branch_or_jump;
`endif

  // ==========================================================================
  //  Assertions (enable with +define+RAPT_ASSERT_EN)
  // ==========================================================================

  // HANDSHAKE: redirect windows must not advertise IFU consumption. This guards
  // the Linux early-resteer bug where IDU discarded a wrong-path fetch locally
  // but still let IFU consume it through ready.
  `RAPT_SVA_IMPLY(clock, reset, IDU_EARLY_RESTEER_NOT_IFU_READY, early_resteer_cond, !ifu_idu.ready)

  `RAPT_SVA_IMPLY(clock, reset, IDU_REDIRECT_NOT_IFU_READY, idu_redirect_event, !ifu_idu.ready)

  // COMMIT_DURABLE: the uop that caused early-resteer must carry the corrected
  // sequential pnpc so ROB commit does not later see a false branch mismatch.
  `RAPT_SVA_IMPLY(clock, reset, IDU_EARLY_RESTEER_CORRECTS_PNPC, early_resteer_cond,
                  idu_rnu.uop_a.pnpc == correct_npc)

  `RAPT_COVER(clock, reset, IDU_EARLY_RESTEER_EVENT, ifu_idu.resteer)

`ifdef RAPT_DUAL_ISSUE
    // DUAL_COMMIT_SEMANTICS: slot B may carry a direct JAL or a conditionally
    // predicted branch. JALR and serializing uops remain forbidden.
  `RAPT_SVA_IMPLY(
        clock, reset, IDU_SLOT_B_ONLY_PREDICTED_CONTROL, idu_rnu.valid_b,
        !(idu_rnu.uop_b.jren || idu_rnu.uop_b.system || idu_rnu.uop_b.f_i
      || idu_rnu.uop_b.f_time || idu_rnu.uop_b.atom))
    `RAPT_SVA_IMPLY(clock, reset, IDU_SLOT_B_DIRECT_JAL_PNPC,
            idu_rnu.valid_b && slot_b_direct_jal,
            idu_rnu.uop_b.pnpc == pnpc_idu)
    `RAPT_SVA_IMPLY(clock, reset, IDU_SLOT_B_COND_BRANCH_PNPC,
                    idu_rnu.valid_b && slot_b_cond_branch,
                    idu_rnu.uop_b.pnpc == pnpc_idu)
`endif

endmodule
