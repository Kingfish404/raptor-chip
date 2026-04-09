`include "ysyx.svh"
`include "ysyx_if.svh"

// Instruction Decode Unit (IDU) - single-stage pipeline register + decode.
//
// Pipeline control: simple IDLE/VALID FSM with valid/ready handshaking.
// Decode is purely combinational via generated decoders.
// CSR validity is checked via a dedicated function for maintainability.
module ysyx_idu #(
    parameter unsigned RLEN = `YSYX_REG_LEN,
    parameter bit [7:0] XLEN = `YSYX_XLEN
) (
    input clock,

    cmu_bcast_if.in cmu_bcast,

    ifu_idu_if.slave  ifu_idu,
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
  // Early Resteer: detect BPU misprediction on non-branch instructions
  // ================================================================
  // If BPU predicted taken (pnpc != pc + inst_len) but the decoded
  // instruction is not a branch/jump, resteer IFU to the correct
  // sequential address immediately, avoiding a full pipeline flush
  // at commit time.
  logic [XLEN-1:0] correct_npc;
  logic bpu_predicted_taken;
  logic is_branch_or_jump;
  logic early_resteer_cond;
  logic resteer_sent;

  assign valid = (state_idu == VALID);
  assign ready = (state_idu == IDLE) || idu_rnu.ready;
  assign idu_rnu.valid_a = valid;
  assign ifu_idu.ready = ready;

  // Pipeline latch: capture from IFU when ready
  // Slot A pipeline latch
  logic [    31:0] inst_a;
  logic [XLEN-1:0] pc_idu_a;

`ifdef YSYX_DUAL_ISSUE
  // Slot B pipeline latch
  logic [    31:0] inst_b;
  logic [XLEN-1:0] pc_idu_b;
  logic            ifu_valid_b;
`endif

  logic [XLEN-1:0] pnpc_idu;
  logic            ifu_trap;
  logic [XLEN-1:0] ifu_cause;

  always @(posedge clock) begin
    if (reset) begin
      state_idu <= IDLE;
`ifdef YSYX_DUAL_ISSUE
      ifu_valid_b <= 0;
`endif
    end else begin
      unique case (state_idu)
        IDLE: begin
          if (cmu_bcast.flush_pipe) begin
            // Stay IDLE on flush
`ifdef YSYX_DUAL_ISSUE
            ifu_valid_b <= 0;
`endif
          end else if (ifu_idu.valid_a) begin
            state_idu <= VALID;
          end
        end
        VALID: begin
          if (cmu_bcast.flush_pipe) begin
            state_idu <= IDLE;
`ifdef YSYX_DUAL_ISSUE
            ifu_valid_b <= 0;
`endif
          end else if (ifu_idu.resteer) begin
            // Early resteer fired: IFU output is from the mispredicted path.
            // Go IDLE even if IFU appears valid — that instruction must be
            // discarded. The resteered IFU will provide the correct one later.
            if (idu_rnu.ready) state_idu <= IDLE;
          end else if (idu_rnu.ready && !ifu_idu.valid_a) begin
            state_idu <= IDLE;
          end
          // If idu_rnu.ready && ifu_idu.valid && !resteer => stay VALID (back-to-back)
        end
        default: ;
      endcase

      // Latch IFU data when pipeline slot is available.
      // Block latch when resteer fires — IFU output that cycle is from
      // the mispredicted path and must be discarded.
      if (ready && ifu_idu.valid_a && !ifu_idu.resteer) begin
        inst_a    <= ifu_idu.inst_a;
        pc_idu_a    <= ifu_idu.pc_a;
        pnpc_idu  <= ifu_idu.pnpc;
        ifu_trap  <= ifu_idu.trap;
        ifu_cause <= ifu_idu.cause;
`ifdef YSYX_DUAL_ISSUE
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
  logic [ 4:0] alu_a;
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
  logic [ 4:0] alu_b;
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

  ysyx_idu_decoder_c idu_de_c (
      .clock     (clock),
      .io_cinst  (inst_a[15:0]),
      .io_is_rv64(XLEN == 64 ? 1'b1 : 1'b0),
      .io_inst   (inst_de_a),
      .reset     (reset)
  );

  ysyx_idu_decoder idu_de (
      .clock  (clock),
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
      .out_rs2(rs2_a),

      .reset(reset)
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

  assign illegal_inst_a = (alu_a == `YSYX_ALU_ILL_);
  assign illegal_csr_a  = (csr_csw_a != 3'b000) && !csr_addr_valid(csr_a);
  assign is_illegal_a   = illegal_inst_a || illegal_csr_a;

  // CSR address validity check - returns 1 if the CSR address is legal.
  // Extend this function when adding new CSR registers.
  function automatic logic csr_addr_valid(input logic [11:0] addr);
    case (addr)
      // Supervisor-level CSRs
      `YSYX_CSR_SSTATUS,  `YSYX_CSR_SIE____,  `YSYX_CSR_STVEC__,  `YSYX_CSR_SCOUNTE,
      `YSYX_CSR_SSCRATC,  `YSYX_CSR_SEPC___,  `YSYX_CSR_SCAUSE_,  `YSYX_CSR_STVAL__,
      `YSYX_CSR_SIP____,  `YSYX_CSR_SATP___,
      // Machine Trap Setup
      `YSYX_CSR_MSTATUS,  `YSYX_CSR_MISA___,  `YSYX_CSR_MEDELEG,  `YSYX_CSR_MIDELEG,
      `YSYX_CSR_MIE____,  `YSYX_CSR_MTVEC__,  `YSYX_CSR_MSTATUSH,
      // Machine Trap Handling
      `YSYX_CSR_MSCRATCH, `YSYX_CSR_MEPC___,  `YSYX_CSR_MCAUSE_,  `YSYX_CSR_MTVAL__,
      `YSYX_CSR_MIP____,
      // Machine Counters
      `YSYX_CSR_MCYCLE_, `YSYX_CSR_MCYCLEH, `YSYX_CSR_CYCLE__, `YSYX_CSR_CYCLEH_,
      `YSYX_CSR_TIME___, `YSYX_CSR_TIMEH__,
      `YSYX_CSR_MINSTRET, `YSYX_CSR_MINSTRETH, `YSYX_CSR_INSTRET_, `YSYX_CSR_INSTRETH,
      // Machine Information
      `YSYX_CSR_MVENDORID, `YSYX_CSR_MARCHID__, `YSYX_CSR_IMPID____, `YSYX_CSR_MHARTID__:
      return 1'b1;
      default: return 1'b0;
    endcase
  endfunction

  // ================================================================
  // UOP Output Assembly
  // ================================================================
  assign idu_rnu.uop_a.c            = is_c_a;
  assign idu_rnu.uop_a.word         = word_flag_a;
  assign idu_rnu.uop_a.alu          = alu_a;
  assign idu_rnu.uop_a.rd[RLEN-1:0] = is_illegal_a ? '0 : rd_a[RLEN-1:0];
  assign idu_rnu.uop_a.csr_csw      = csr_csw_a;

  // Trap aggregation: IFU traps (e.g., page fault) or decode-time illegality
  assign idu_rnu.uop_a.trap         = ifu_trap || is_illegal_a;
  assign idu_rnu.uop_a.tval         = ifu_trap ? pc_idu_a : is_illegal_a ? inst_idu_a : '0;
  assign idu_rnu.uop_a.cause        = ifu_trap ? ifu_cause : is_illegal_a ? 'h2 : '0;

`ifdef YSYX_DUAL_ISSUE
  // When dual-issuing, correct_npc is after BOTH instructions (group end)
  assign correct_npc              = ifu_valid_b
      ? (pc_idu_b + (is_c_b ? XLEN'('d2) : XLEN'('d4)))
      : (pc_idu_a + (is_c_a ? XLEN'('d2) : XLEN'('d4)));
`else
  assign correct_npc = pc_idu_a + (is_c_a ? XLEN'('d2) : XLEN'('d4));
`endif
  assign bpu_predicted_taken = (pnpc_idu != correct_npc);
  assign is_branch_or_jump   = idu_rnu.uop_a.ben || idu_rnu.uop_a.jen || idu_rnu.uop_a.jren;
  assign early_resteer_cond  = valid && bpu_predicted_taken && !is_branch_or_jump && !ifu_trap;

  // One-shot pulse: only fire resteer on the first cycle of detection
  always @(posedge clock) begin
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
  always @(posedge clock) begin
    if (reset) pmu_early_resteer <= 0;
    else pmu_early_resteer <= ifu_idu.resteer;
  end

  // Correct pnpc before sending downstream: if resteer detected,
  // replace the wrong BPU prediction with the correct sequential address
  // so that ROU commit won't see a spurious npc != pnpc mismatch.
  // During dual-fetch, Slot A's sequential npc is pc_b (B-slot PC, P+2),
  // not the IFU's next-group address (pnpc_idu = P+4).  Patch pnpc so
  // that the ROB commit comparison (npc == pnpc) succeeds for Slot A.
`ifdef YSYX_DUAL_ISSUE
  assign idu_rnu.uop_a.pnpc = early_resteer_cond ? correct_npc : ifu_valid_b ? pc_idu_b : pnpc_idu;
`else
  assign idu_rnu.uop_a.pnpc = early_resteer_cond ? correct_npc : pnpc_idu;
`endif
  assign idu_rnu.uop_a.inst      = inst_idu_a;
  assign idu_rnu.uop_a.pc        = pc_idu_a;

  assign idu_rnu.rs1_a[RLEN-1:0] = rs1_a[RLEN-1:0];
  assign idu_rnu.rs2_a[RLEN-1:0] = rs2_a[RLEN-1:0];

`ifdef YSYX_DUAL_ISSUE
  assign is_c_b     = (inst_b[1:0] != 2'b11);
  assign inst_idu_b = is_c_b ? inst_de_b : inst_b;

  ysyx_idu_decoder_c idu_de_c_b (
      .clock     (clock),
      .io_cinst  (inst_b[15:0]),
      .io_is_rv64(XLEN == 64 ? 1'b1 : 1'b0),
      .io_inst   (inst_de_b),
      .reset     (reset)
  );

  ysyx_idu_decoder idu_de_b (
      .clock  (clock),
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
      .out_rs2(rs2_b),

      .reset(reset)
  );

  assign illegal_inst_b             = (alu_b == `YSYX_ALU_ILL_);
  assign illegal_csr_b              = (csr_csw_b != 3'b000) && !csr_addr_valid(csr_b);
  assign is_illegal_b               = illegal_inst_b || illegal_csr_b;

  // Slot B UOP assembly
  assign idu_rnu.uop_b.c            = is_c_b;
  assign idu_rnu.uop_b.word         = word_flag_b;
  assign idu_rnu.uop_b.alu          = alu_b;
  assign idu_rnu.uop_b.rd[RLEN-1:0] = is_illegal_b ? '0 : rd_b[RLEN-1:0];
  assign idu_rnu.uop_b.csr_csw      = csr_csw_b;

  assign idu_rnu.uop_b.trap         = is_illegal_b;
  assign idu_rnu.uop_b.tval         = is_illegal_b ? inst_idu_b : '0;
  assign idu_rnu.uop_b.cause        = is_illegal_b ? 'h2 : '0;

  assign idu_rnu.uop_b.pnpc         = pc_idu_b + (is_c_b ? XLEN'('d2) : XLEN'('d4));
  assign idu_rnu.uop_b.inst         = inst_idu_b;
  assign idu_rnu.uop_b.pc           = pc_idu_b;

  assign idu_rnu.uop_b.imm          = dec_imm_b[XLEN-1:0];
  assign idu_rnu.op1_b              = dec_op1_b[XLEN-1:0];
  assign idu_rnu.op2_b              = dec_op2_b[XLEN-1:0];

  assign idu_rnu.rs1_b[RLEN-1:0]    = rs1_b[RLEN-1:0];
  assign idu_rnu.rs2_b[RLEN-1:0]    = rs2_b[RLEN-1:0];

  // Slot B valid: IFU provided a second instruction AND slot A is not a trap
  // or branch/jump (branches in slot A could skip slot B on the taken path).
  assign idu_rnu.valid_b            = valid && ifu_valid_b && !ifu_trap && !is_branch_or_jump;
`endif

endmodule
