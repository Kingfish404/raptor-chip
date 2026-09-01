`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_soc.svh"

/* verilator lint_off UNUSEDPARAM */
module rapt_ifu #(
    parameter bit [$clog2(`RAPT_PHT_SIZE):0] PHT_SIZE = `RAPT_PHT_SIZE,
    parameter bit [$clog2(`RAPT_BTB_SIZE):0] BTB_SIZE = `RAPT_BTB_SIZE,
    parameter bit [$clog2(`RAPT_RSB_SIZE):0] RSB_SIZE = `RAPT_RSB_SIZE,
    parameter int XLEN = `RAPT_XLEN
) (
    input clock,

    cmu_bcast_if.in cmu_bcast,

    ifu_bpu_if.out ifu_bpu,
    ifu_l1i_if.master ifu_l1i,
    ifu_idu_if.master ifu_idu,

    input reset
);
  /* verilator lint_on UNUSEDPARAM */
  /* verilator lint_off UNUSEDSIGNAL */
  typedef enum logic [1:0] {
    IDLE  = 'b00,
    VALID = 'b01,
    STALL = 'b10
  } state_ifu_t;

  typedef enum logic [1:0] {
    IDLE_ORIGIN_NONE     = 2'b00,
    IDLE_ORIGIN_REDIRECT = 2'b01,
    IDLE_ORIGIN_L1I_GAP  = 2'b10
  } idle_origin_t;

  state_ifu_t state_ifu;
  idle_origin_t idle_origin;
  logic [XLEN-1:0] pc_ifu;
  logic [XLEN-1:0] seqpc;
  logic [XLEN-1:0] nextpc;

  // Sequential PC candidates derived combinationally from pc_ifu.
  //
  // Previously these were registered from (nextpc + N) to avoid a pc_ifu
  // self-loop through the adder. But STA showed the BTB r_raddr fanout cone
  // drives nextpc with a >10 ns delay, and the +4 adder sitting between
  // nextpc and the seq4/D register turned the BTB path into the chip's
  // global critical path terminating at ifu.seq4[28].
  //
  // Phase A': compute seq* combinationally from the registered pc_ifu. This
  // moves the +2/+4/+6/+8 adders out of the BTB -> nextpc cone. The new
  // pc_ifu self-loop (pc_ifu/Q -> +N -> seqpc mux -> nextpc mux -> pc_ifu/D)
  // is short (~3 ns) because it no longer involves the BTB mux tree.
  logic [XLEN-1:0] seq2;
  logic [XLEN-1:0] seq4;
`ifdef RAPT_DUAL_ISSUE
  logic [XLEN-1:0] seq6;
  logic [XLEN-1:0] seq8;
`endif

  logic ifu_hazard;
  logic recv_ready;
  logic redirect_event;
  logic valid;

  // --- Unified redirect arbiter (Phase 0) ---------------------------------
  // Single prioritized frontend redirect channel. Priority (highest first):
  //   1. commit flush  (cmu_bcast.flush_pipe -> cpc)   [pipeline squash]
  //   2. sys resume    (cmu_bcast.sys_resume -> cpc)    [pipeline squash]
  //   3. IDU resteer   (ifu_idu.resteer -> resteer_pc)  [decode redirect]
  //   4. BPU taken     (ifu_bpu.taken -> npc)           [predicted steer]
  // `redirect_squash` covers sources 1-3 (they squash in-flight uops). The BPU
  // predicted-taken steer is a normal fetch redirection and is intentionally
  // excluded from the squash/`redirect_event` set (matches legacy behavior).
  logic            redirect_squash;
  logic [XLEN-1:0] redirect_squash_pc;


  // PMU: registered signals for accurate cycle-level sampling
  /* verilator lint_off UNUSEDSIGNAL */
  logic pmu_fetch_fire;
  logic [1:0] pmu_fetch_slots;
  logic pmu_ifu_stall;  // Total stall (deprecated; use decomposed below)
  // A1: Decomposed IFU stall root causes (mutually exclusive).
  // `flush_stall` is the one-cycle response staging bubble after an IFU
  // invalid interval; branch-recovery duration is measured separately by
  // the ROU-to-first-fetch PMU path.
  logic pmu_ifu_icache_stall;  // No L1I/PTW response while not serializing
  logic pmu_ifu_flush_stall;  // IDLE response staging (valid L1I response)
  logic pmu_ifu_empty_stall;  // Serialization/trap hold (STALL state)
  logic pmu_ifu_response_after_redirect;
  logic pmu_ifu_response_after_l1i_gap;
  logic pmu_ifu_response_bypass_candidate;
  // Slot-B opportunity loss, sampled only when the IFU consumes an L1I
  // response. The four causes are mutually exclusive and deliberately omit
  // IDU backpressure, which is reported separately.
  logic pmu_fetch_response_consume;
  logic pmu_fetch_dual_fire;
  logic pmu_fetch_bpu_taken;
  logic pmu_fetch_slot_a_control;
  logic pmu_fetch_slot_b_control;
  logic pmu_fetch_slot_b_jal_pack;
  logic pmu_fetch_slot_b_cond_pack;
  logic pmu_fetch_n1_unavailable;
  logic pmu_fetch_n1_unavailable_unaligned;
  logic pmu_fetch_n1_unavailable_l1i;
  logic pmu_fetch_downstream_blocked;
  logic pmu_fetch_target_steer;
  /* verilator lint_on UNUSEDSIGNAL */

  logic [XLEN-1:0] pc_a;
  logic [XLEN-1:0] inst_a;
  logic pre_is_c_a;
  logic is_c_a;
  logic [6:0] opcode_a;
  logic is_sys_a;
  logic is_atomic_a;

  logic trap;
  logic [XLEN-1:0] cause;
  logic [XLEN-1:0] tval;

  assign ifu_hazard = state_ifu == STALL;
  assign pre_is_c_a = !(ifu_l1i.inst_n0[1:0] == 2'b11);
  assign is_c_a = !(inst_a[1:0] == 2'b11);
  assign opcode_a = is_c_a ? {2'b0, {inst_a[15:13]}, {inst_a[1:0]}} : inst_a[6:0];
  assign is_sys_a = (opcode_a == `RAPT_OP_SYSTEM) || (opcode_a == `RAPT_OP_FENCE_);
  assign is_atomic_a = (opcode_a == `RAPT_OP_AMO___);

  assign valid = state_ifu == VALID;

`ifdef RAPT_DUAL_ISSUE
  // --- Generalized dual-fetch ---
  // Supports C+C, C+R32, R32+C, and R32+R32 at either halfword alignment.
  //
  // Data sources:
  //   ifu_l1i.inst[31:0]    : 32 bits assembled starting from PC
  //   ifu_l1i.inst_n1[31:0] : next 4-byte-aligned word from L1I
  //     pc[1]=0: {hw@pc+6, hw@pc+4}   pc[1]=1: {hw@pc+4, hw@pc+2}
  logic [15:0] hw_pc4;
  logic [15:0] inst_b_lo_pre;
  logic pre_is_c_b;
  logic pre_is_branch_a;
  logic pre_is_branch_b;
  logic pre_is_direct_jal_b;
  logic slot_b_r32_r32_unaligned;
  logic pre_is_cond_branch_b;
  logic inst_b_needs_n1;
  logic inst_b_data_avail;
  logic dual_fetch;
  logic slot_b_direct_jal;
  logic slot_b_cond_branch;
  logic [XLEN-1:0] pc_b_pre;
  logic [15:0] inst_b_hi_pre;
  logic [31:0] inst_b_pre;
  logic [20:0] jal_imm21_b;
  logic [11:0] cjal_imm12_b;
  logic [XLEN-1:0] direct_jal_target_b;
  logic [12:0] branch_imm13_b;
  logic [8:0] cbranch_imm9_b;
  logic [XLEN-1:0] cond_branch_target_b;

  // Halfword at pc+4 extracted from inst_n1 based on alignment
  assign hw_pc4 = pc_ifu[1] ? ifu_l1i.inst_n1[31:16] : ifu_l1i.inst_n1[15:0];

  // inst_b lower halfword: at pc+2 (C inst_a) or pc+4 (R32 inst_a)
  assign inst_b_lo_pre = pre_is_c_a ? ifu_l1i.inst_n0[31:16] : hw_pc4;
  assign pre_is_c_b = !(inst_b_lo_pre[1:0] == 2'b11);
  assign pc_b_pre = pc_ifu + (pre_is_c_a ? XLEN'('d2) : XLEN'('d4));

  // Assemble inst_b before classifying a direct jump so the 32-bit immediate
  // and compressed C.J/C.JAL immediate both use the complete instruction.
  // An unaligned R32 slot A leaves slot B's upper halfword in L1I's third
  // lookahead word; all other forms are fully covered by inst_n1.
  assign inst_b_hi_pre = pre_is_c_a ? hw_pc4
                     : slot_b_r32_r32_unaligned ? ifu_l1i.inst_n2[15:0]
                     : ifu_l1i.inst_n1[31:16];
  assign inst_b_pre = pre_is_c_b ? {16'b0, inst_b_lo_pre} : {inst_b_hi_pre, inst_b_lo_pre};

  // Slot A pre-decode: suppress dual-fetch for branches/jumps/serialization.
  // C-type: C.BEQZ, C.BNEZ, C.J, C.JAL (C1), C.JR, C.JALR/C.EBREAK (C2)
  // R32: BRANCH, JAL, JALR, SYSTEM, FENCE, AMO
  assign pre_is_branch_a = pre_is_c_a
    ? (((ifu_l1i.inst_n0[1:0] == 2'b01)
          && ((ifu_l1i.inst_n0[15] && ifu_l1i.inst_n0[14])
           || (ifu_l1i.inst_n0[13] && !ifu_l1i.inst_n0[14])))
      || ((ifu_l1i.inst_n0[1:0] == 2'b10)
          && ifu_l1i.inst_n0[15] && (ifu_l1i.inst_n0[6:2] == 5'b0)))
      : ((ifu_l1i.inst_n0[6:0] == `RAPT_OP_B_TYPE_)
      || (ifu_l1i.inst_n0[6:0] == `RAPT_OP_JAL___)
      || (ifu_l1i.inst_n0[6:0] == `RAPT_OP_JALR__)
      || (ifu_l1i.inst_n0[6:0] == `RAPT_OP_SYSTEM)
      || (ifu_l1i.inst_n0[6:0] == `RAPT_OP_FENCE_)
      || (ifu_l1i.inst_n0[6:0] == `RAPT_OP_AMO___));

  // Slot B pre-decode: suppress dual-fetch for branches/jumps/serialization.
  // Slot B has no BPU prediction: branches would always be mispredicted.
  assign pre_is_branch_b = pre_is_c_b
    ? (((inst_b_lo_pre[1:0] == 2'b01)
          && ((inst_b_lo_pre[15] && inst_b_lo_pre[14])
           || (inst_b_lo_pre[13] && !inst_b_lo_pre[14])))
      || ((inst_b_lo_pre[1:0] == 2'b10)
          && inst_b_lo_pre[15] && (inst_b_lo_pre[6:2] == 5'b0)))
      : ((inst_b_lo_pre[6:0] == `RAPT_OP_B_TYPE_)
      || (inst_b_lo_pre[6:0] == `RAPT_OP_JAL___)
      || (inst_b_lo_pre[6:0] == `RAPT_OP_JALR__)
      || (inst_b_lo_pre[6:0] == `RAPT_OP_SYSTEM)
      || (inst_b_lo_pre[6:0] == `RAPT_OP_FENCE_)
      || (inst_b_lo_pre[6:0] == `RAPT_OP_AMO___));

  // The first B-CFI pack form is statically resolvable: R32 JAL, C.J, and
  // RV32 C.JAL. Conditional branches and JALR still require a second BPU
  // lookup and remain packet terminators.
  assign pre_is_direct_jal_b = pre_is_c_b
    ? ((inst_b_lo_pre[1:0] == 2'b01)
      && ((inst_b_lo_pre[15:13] == 3'b101)
       || ((XLEN == 32) && (inst_b_lo_pre[15:13] == 3'b001))))
    : (inst_b_lo_pre[6:0] == `RAPT_OP_JAL___);
  assign pre_is_cond_branch_b = pre_is_c_b
    ? ((inst_b_lo_pre[1:0] == 2'b01)
      && ((inst_b_lo_pre[15:13] == 3'b110) || (inst_b_lo_pre[15:13] == 3'b111)))
    : (inst_b_lo_pre[6:0] == `RAPT_OP_B_TYPE_);
  assign jal_imm21_b = {inst_b_pre[31], inst_b_pre[19:12], inst_b_pre[20], inst_b_pre[30:21], 1'b0};
  assign cjal_imm12_b = {inst_b_lo_pre[12], inst_b_lo_pre[8], inst_b_lo_pre[10:9],
                         inst_b_lo_pre[6], inst_b_lo_pre[7], inst_b_lo_pre[2],
                         inst_b_lo_pre[11], inst_b_lo_pre[5:3], 1'b0};
  assign direct_jal_target_b = pc_b_pre + (pre_is_c_b
    ? {{(XLEN - 12) {cjal_imm12_b[11]}}, cjal_imm12_b}
    : {{(XLEN - 21) {jal_imm21_b[20]}}, jal_imm21_b});
  assign branch_imm13_b = {inst_b_pre[31], inst_b_pre[7], inst_b_pre[30:25],
                           inst_b_pre[11:8], 1'b0};
  assign cbranch_imm9_b = {inst_b_lo_pre[12], inst_b_lo_pre[6:5], inst_b_lo_pre[2],
                            inst_b_lo_pre[11:10], inst_b_lo_pre[4:3], 1'b0};
  assign cond_branch_target_b = pc_b_pre + (pre_is_c_b
    ? {{(XLEN - 9) {cbranch_imm9_b[8]}}, cbranch_imm9_b}
    : {{(XLEN - 13) {branch_imm13_b[12]}}, branch_imm13_b});

  // inst_b needs inst_n1 data unless both are C at word-aligned PC
  assign inst_b_needs_n1 = !pre_is_c_a || !pre_is_c_b || pc_ifu[1];

  // Data availability: an unaligned R32+R32 pair additionally needs inst_n2.
  assign slot_b_r32_r32_unaligned = !pre_is_c_a && !pre_is_c_b && pc_ifu[1];
  assign inst_b_data_avail = (!inst_b_needs_n1 || ifu_l1i.inst_n1_valid)
                           && (!slot_b_r32_r32_unaligned || ifu_l1i.inst_n2_valid);

  assign dual_fetch = ifu_l1i.valid && !ifu_bpu.taken && !ifu_l1i.trap
                    && !pre_is_branch_a
                    && (!pre_is_branch_b || pre_is_direct_jal_b || pre_is_cond_branch_b)
                    && inst_b_data_avail;
  assign slot_b_direct_jal = dual_fetch && pre_is_direct_jal_b;
  assign slot_b_cond_branch = dual_fetch && pre_is_cond_branch_b;

  logic [31:0] inst_b_raw;
  logic [XLEN-1:0] pc_b;
  logic inst_b_valid;

  assign ifu_idu.inst_b  = inst_b_raw;
  assign ifu_idu.pc_b    = pc_b;
  assign ifu_idu.valid_b = inst_b_valid && valid && !redirect_event;
`endif

  assign ifu_bpu.pc = pc_ifu;
  assign ifu_bpu.nextpc = nextpc;
`ifdef RAPT_DUAL_ISSUE
  assign ifu_bpu.slot_b_query = ifu_l1i.valid && !ifu_bpu.taken && !ifu_l1i.trap
                              && !pre_is_branch_a && pre_is_cond_branch_b
                              && inst_b_data_avail;
  assign ifu_bpu.slot_b_pc = pc_b_pre;
  assign ifu_bpu.slot_b_pred_valid = recv_ready && slot_b_cond_branch;
`endif

  // Phase 1: two-level redirect.
  //   redirect_squash (state invalidation): fires immediately when flush_pipe=1
  //     (cycle N), killing the wrong-path instruction before it enters the IDU.
  //   redirect_pc_update (PC update): fires one cycle later (N+1) via the
  //     registered flush_redirect+redirect_pc pair, breaking the long
  //     ROB->...->pc_ifu->L1I combinational path.
  logic redirect_pc_update;
  assign redirect_pc_update = cmu_bcast.flush_redirect || cmu_bcast.sys_resume || ifu_idu.resteer;
  assign redirect_squash = cmu_bcast.flush_pipe || redirect_pc_update;
  assign redirect_squash_pc = cmu_bcast.flush_redirect ? cmu_bcast.redirect_pc
                            : cmu_bcast.flush_pipe     ? cmu_bcast.cpc
                            : cmu_bcast.sys_resume      ? cmu_bcast.cpc
                            :                             ifu_idu.resteer_pc;
  assign redirect_event = redirect_squash;
  assign ifu_bpu.pc_update = recv_ready || redirect_event;

  assign ifu_l1i.pc = pc_ifu;
  assign ifu_l1i.invalid = cmu_bcast.fence_i;
  // The current packet is already backed by the previous SRAM read. Dedicate
  // the next data-SRAM read to the exact next PC of every accepted packet;
  // this covers sequential +2/+4/+6/+8 strides as well as predicted targets.
  // Redirect targets use the same side-effect-free hint path.
  assign ifu_l1i.prefetch_valid = redirect_event || recv_ready;
  assign ifu_l1i.prefetch_pc = redirect_event ? redirect_squash_pc : nextpc;

  assign ifu_idu.inst_a = inst_a;
  assign ifu_idu.pc_a = pc_a;
  assign ifu_idu.valid_a = valid && !redirect_event;
  assign ifu_idu.pnpc = pc_ifu;
  assign ifu_idu.trap = trap;
  assign ifu_idu.cause = cause;
  assign ifu_idu.tval = tval;


`ifdef RAPT_DUAL_ISSUE
  // Stride: +2 (single C), +4 (single R32 or C+C), +6 (C+R32 or R32+C), +8 (R32+R32)
  assign seqpc = !dual_fetch ? (pre_is_c_a ? seq2 : seq4)
               : (pre_is_c_a ? (pre_is_c_b ? seq4 : seq6)
                              : (pre_is_c_b ? seq6 : seq8));
`else
  assign seqpc = pre_is_c_a ? seq2 : seq4;
`endif
  logic [XLEN-1:0] nextpc_fallback;
`ifdef RAPT_DUAL_ISSUE
  assign nextpc_fallback = slot_b_direct_jal ? direct_jal_target_b
                         : slot_b_cond_branch && ifu_bpu.slot_b_taken ? cond_branch_target_b
                         : seqpc;
`else
  assign nextpc_fallback = seqpc;
`endif
  assign nextpc = redirect_squash ? redirect_squash_pc
                : ifu_bpu.taken   ? ifu_bpu.npc
                :                   nextpc_fallback;
  assign recv_ready = ifu_l1i.valid && (ifu_idu.ready || (state_ifu == IDLE)) && !ifu_hazard
                    && !redirect_event;

  logic [1:0] pmu_fetch_slots_next;
`ifdef RAPT_DUAL_ISSUE
  assign pmu_fetch_slots_next = ifu_idu.valid_b ? 2'd2 : 2'd1;
`else
  assign pmu_fetch_slots_next = 2'd1;
`endif

  // Combinational sequential-PC candidates (see declaration for rationale).
  assign seq2 = pc_ifu + 'h2;
  assign seq4 = pc_ifu + 'h4;
`ifdef RAPT_DUAL_ISSUE
  assign seq6 = pc_ifu + 'h6;
  assign seq8 = pc_ifu + 'h8;
`endif

  always_ff @(posedge clock) begin
    if (reset) begin
      state_ifu <= IDLE;
      idle_origin <= IDLE_ORIGIN_NONE;
      pc_ifu <= `RAPT_PC_INIT;
      trap <= 0;
      tval <= 0;
      pmu_fetch_fire <= 0;
      pmu_fetch_slots <= '0;
      pmu_ifu_stall <= 0;
      pmu_ifu_icache_stall <= 0;
      pmu_ifu_flush_stall <= 0;
      pmu_ifu_empty_stall <= 0;
      pmu_ifu_response_after_redirect <= 0;
      pmu_ifu_response_after_l1i_gap <= 0;
      pmu_ifu_response_bypass_candidate <= 0;
      pmu_fetch_response_consume <= 0;
      pmu_fetch_dual_fire <= 0;
      pmu_fetch_bpu_taken <= 0;
      pmu_fetch_slot_a_control <= 0;
      pmu_fetch_slot_b_control <= 0;
      pmu_fetch_slot_b_jal_pack <= 0;
      pmu_fetch_slot_b_cond_pack <= 0;
      pmu_fetch_n1_unavailable <= 0;
      pmu_fetch_n1_unavailable_unaligned <= 0;
      pmu_fetch_n1_unavailable_l1i <= 0;
      pmu_fetch_downstream_blocked <= 0;
      pmu_fetch_target_steer <= 0;
`ifdef RAPT_DUAL_ISSUE
      inst_b_valid <= 0;
`endif
    end else begin
      pmu_fetch_fire <= valid && ifu_idu.ready;
      pmu_fetch_slots <= !(valid && ifu_idu.ready) ? 2'd0 : pmu_fetch_slots_next;
      pmu_ifu_stall <= !valid && ifu_idu.ready;  // Total (sum of below)
      // A1: Decomposed stall causes. Give serializing STALL priority, then
      // split IDLE by whether L1I has supplied the next response. The three
      // probes exactly partition `pmu_ifu_stall`.
      pmu_ifu_empty_stall <= !valid && ifu_idu.ready && (state_ifu == STALL);
      pmu_ifu_icache_stall <= !valid && ifu_idu.ready && (state_ifu != STALL)
                && !ifu_l1i.valid;
      pmu_ifu_flush_stall <= !valid && ifu_idu.ready && (state_ifu == IDLE)
               && ifu_l1i.valid;
      pmu_ifu_response_after_redirect <= !valid && ifu_idu.ready && (state_ifu == IDLE)
                   && ifu_l1i.valid && (idle_origin == IDLE_ORIGIN_REDIRECT);
      pmu_ifu_response_after_l1i_gap <= !valid && ifu_idu.ready && (state_ifu == IDLE)
                  && ifu_l1i.valid && (idle_origin == IDLE_ORIGIN_L1I_GAP);
      // A non-control packet can bypass the IDLE->VALID register if the
      // downstream fetch-bundle queue is ready. Control and trap packets keep
      // the registered path until their redirect/serialization contract is
      // explicitly handled by a later change.
`ifdef RAPT_DUAL_ISSUE
      pmu_ifu_response_bypass_candidate <= !valid && ifu_idu.ready && (state_ifu == IDLE)
                    && ifu_l1i.valid && !redirect_event
                    && !pre_is_branch_a && !ifu_l1i.trap;
`else
      pmu_ifu_response_bypass_candidate <= 1'b0;
`endif
`ifdef RAPT_DUAL_ISSUE
      pmu_fetch_response_consume <= recv_ready;
      pmu_fetch_dual_fire <= valid && ifu_idu.ready && ifu_idu.valid_b;
      pmu_fetch_downstream_blocked <= valid && !ifu_idu.ready;
      pmu_fetch_bpu_taken <= recv_ready && ifu_bpu.taken;
      pmu_fetch_slot_a_control <= recv_ready && !ifu_bpu.taken && !ifu_l1i.trap
          && pre_is_branch_a;
      pmu_fetch_slot_b_control <= recv_ready && !ifu_bpu.taken && !ifu_l1i.trap
          && !pre_is_branch_a && inst_b_data_avail && pre_is_branch_b
          && !pre_is_direct_jal_b && !pre_is_cond_branch_b;
      pmu_fetch_slot_b_jal_pack <= recv_ready && slot_b_direct_jal;
      pmu_fetch_slot_b_cond_pack <= recv_ready && slot_b_cond_branch;
      pmu_fetch_n1_unavailable <= recv_ready && !ifu_bpu.taken && !ifu_l1i.trap
          && !pre_is_branch_a && !inst_b_data_avail;
      pmu_fetch_n1_unavailable_unaligned <= recv_ready && !ifu_bpu.taken && !ifu_l1i.trap
          && !pre_is_branch_a && slot_b_r32_r32_unaligned
          && !inst_b_data_avail;
      pmu_fetch_n1_unavailable_l1i <= recv_ready && !ifu_bpu.taken && !ifu_l1i.trap
          && !pre_is_branch_a && !slot_b_r32_r32_unaligned
          && !inst_b_data_avail;
      // Accepted packets whose next PC is a predicted non-sequential target
      // can use target-directed L1I data SRAM read-ahead on the next cycle.
      pmu_fetch_target_steer <= recv_ready && !redirect_event && (nextpc != seqpc);
`else
      pmu_fetch_response_consume <= 1'b0;
      pmu_fetch_dual_fire <= 1'b0;
      pmu_fetch_bpu_taken <= 1'b0;
      pmu_fetch_slot_a_control <= 1'b0;
      pmu_fetch_slot_b_control <= 1'b0;
      pmu_fetch_slot_b_jal_pack <= 1'b0;
      pmu_fetch_slot_b_cond_pack <= 1'b0;
      pmu_fetch_n1_unavailable <= 1'b0;
      pmu_fetch_n1_unavailable_unaligned <= 1'b0;
      pmu_fetch_n1_unavailable_l1i <= 1'b0;
      pmu_fetch_downstream_blocked <= 1'b0;
      pmu_fetch_target_steer <= 1'b0;
`endif
      unique case (state_ifu)
        IDLE: begin
          if (redirect_event) begin
            state_ifu <= IDLE;
          end else if (ifu_l1i.valid) begin
            state_ifu <= VALID;
          end
        end
        VALID: begin
          if (redirect_event) begin
            state_ifu <= IDLE;
          end else if (ifu_idu.ready) begin
            if (is_sys_a || is_atomic_a || trap) begin
              state_ifu <= STALL;
            end else
            if (ifu_l1i.valid) begin
            end else begin
              state_ifu <= IDLE;
            end
          end
        end
        STALL: begin
          if (redirect_event) begin
            state_ifu <= IDLE;
            trap <= 0;
          end
        end
        default: begin
          state_ifu <= IDLE;
        end
      endcase
      if (recv_ready || redirect_pc_update) begin
        pc_ifu <= nextpc;
      end
      if (redirect_event) begin
        idle_origin <= IDLE_ORIGIN_REDIRECT;
      end else if ((state_ifu == VALID) && ifu_idu.ready && !ifu_l1i.valid) begin
        idle_origin <= IDLE_ORIGIN_L1I_GAP;
      end else if ((state_ifu == IDLE) && ifu_l1i.valid) begin
        idle_origin <= IDLE_ORIGIN_NONE;
      end
      if (recv_ready) begin
        pc_a   <= pc_ifu;
        inst_a <= ifu_l1i.inst_n0;
        trap   <= ifu_l1i.trap;
        cause  <= ifu_l1i.cause;
        tval   <= ifu_l1i.tval;
`ifdef RAPT_DUAL_ISSUE
        pc_b         <= pc_b_pre;
        inst_b_raw   <= inst_b_pre;
        inst_b_valid <= dual_fetch;
`endif
      end
    end
  end
  /* verilator lint_on UNUSEDPARAM */
  /* verilator lint_on UNUSEDSIGNAL */

  // ==========================================================================
  //  Assertions (enable with +define+RAPT_ASSERT_EN)
  // ==========================================================================

  // HANDSHAKE: no L1I response may be consumed in the same cycle as a redirect.
  // Redirect priority is pc-only; accepting instruction data here can create
  // ghost frontend uops from the pre-redirect path.
  `RAPT_SVA_IMPLY(clock, reset, IFU_REDIRECT_NOT_RECV_READY, redirect_event, !recv_ready)

`ifdef RAPT_DUAL_ISSUE
  `RAPT_SVA_IMPLY(clock, reset, IFU_SLOT_B_IMPLIES_SLOT_A, ifu_idu.valid_b, ifu_idu.valid_a)
  `RAPT_SVA_IMPLY(clock, reset, IFU_SLOT_B_DIRECT_JAL_STEERS, recv_ready && slot_b_direct_jal,
                  nextpc == direct_jal_target_b)
  `RAPT_SVA_IMPLY(clock, reset, IFU_SLOT_B_COND_STEERS,
                  recv_ready && slot_b_cond_branch && ifu_bpu.slot_b_taken,
                  nextpc == cond_branch_target_b)
`endif

  `RAPT_COVER(clock, reset, IFU_RESTEER_EVENT, ifu_idu.resteer)
  `RAPT_COVER(clock, reset, IFU_SYS_RESUME_EVENT, cmu_bcast.sys_resume)

endmodule
