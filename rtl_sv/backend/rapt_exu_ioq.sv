`include "rapt.svh"
`include "rapt_if.svh"

// In-Order Queue (IOQ): dispatch ring for loads / stores / atomic ops.
//
// Responsibilities:
//   * Buffer L/S micro-ops in dispatch order (head retires, tail enqueues)
//   * Resolve load/store addresses against L1D (MMU translate via exu_l1d)
//   * Issue loads OoO with older-store hazard detection
//   * Forward operands from in-flight ALU/IOQ writebacks
//   * Drive `exu_ioq_bcast` writeback when head load/store completes
//
// Design notes:
//   * Single L1D outstanding load (`oo_pending` FSM)
//   * Atomics and uncached MMIO loads serialize at head only
//   * Stores always wait at head (no speculative writes)
module rapt_exu_ioq #(
    parameter unsigned IOQ_SIZE = `RAPT_IOQ_SIZE,
    parameter unsigned ROB_SIZE = `RAPT_ROB_SIZE,
    parameter unsigned PLEN     = `RAPT_PHY_LEN,
    parameter unsigned RLEN     = `RAPT_REG_LEN,
    parameter unsigned XLEN     = `RAPT_XLEN
) (
    input clock,
    input reset,

    cmu_bcast_if.in cmu_bcast,
    csr_bcast_if.in csr_bcast,

    // Dispatch source (read-only view of rou_exu, drive accepts via disp.io)
    rou_exu_if.monitor  rou_exu,
    exu_disp_ioq_if.ioq disp,

    // Forwarding sources (other writeback buses)
    exu_wb_if.in exu_rou,
    exu_wb_if.in exu_rou_b,
    exu_wb_if.in exu_wb_mul,

    // Outputs to memory subsystem & ROB writeback
    exu_lsu_if.master    exu_lsu,
    exu_l1d_if.master    exu_l1d,
    exu_wb_if.out        exu_ioq_bcast,
    exu_load_fast_if.source load_fast,

    // A2: PMU: one-cycle pulse when IOQ becomes full
    /* verilator lint_off UNUSEDSIGNAL */
    output logic pmu_ioq_full
    /* verilator lint_on UNUSEDSIGNAL */
);
  localparam unsigned IOQLen = $clog2(IOQ_SIZE);
  localparam unsigned ROBLen = $clog2(ROB_SIZE);

  // === IOQ state ===
  logic [IOQ_SIZE-1:0] ioq_valid;
  logic [  IOQLen-1:0] ioq_tail_a;
  logic [  IOQLen-1:0] ioq_head;

  logic [    XLEN-1:0] ioq_pc              [IOQ_SIZE];

  logic [    PLEN-1:0] ioq_pr1             [IOQ_SIZE];
  logic [    PLEN-1:0] ioq_pr2             [IOQ_SIZE];
  logic [    PLEN-1:0] ioq_prd             [IOQ_SIZE];
  logic [    RLEN-1:0] ioq_rd              [IOQ_SIZE];

  logic                ioq_c               [IOQ_SIZE];
  /* verilator lint_off UNUSEDSIGNAL */
  logic                ioq_word            [IOQ_SIZE];  // reserved for RV64 sub-word
  /* verilator lint_on UNUSEDSIGNAL */
  logic [         5:0] ioq_alu             [IOQ_SIZE];
  logic [    XLEN-1:0] ioq_vj              [IOQ_SIZE];
  logic [    XLEN-1:0] ioq_vk              [IOQ_SIZE];
  logic [  ROBLen-1:0] ioq_dest            [IOQ_SIZE];
  logic [    XLEN-1:0] ioq_imm             [IOQ_SIZE];

  logic [IOQ_SIZE-1:0] ioq_wen;
  logic [IOQ_SIZE-1:0] ioq_mmu_en;
  logic [IOQ_SIZE-1:0] ioq_trap;
  logic [    XLEN-1:0] ioq_cause           [IOQ_SIZE];
  logic [    XLEN-1:0] ioq_paddr           [IOQ_SIZE];
  logic [IOQ_SIZE-1:0] ioq_ren;
  logic [IOQ_SIZE-1:0] ioq_atom;

  // OoO load completion tracking
  logic [IOQ_SIZE-1:0] ioq_complete;
  logic [IOQ_SIZE-1:0] ioq_load_trap;
  logic [IOQ_SIZE-1:0] ioq_load_skip;
  logic [    XLEN-1:0] ioq_rdata           [IOQ_SIZE];
  logic [    XLEN-1:0] ioq_load_cause      [IOQ_SIZE];

  logic                oo_pending;
  logic [  IOQLen-1:0] oo_pending_idx;
  logic [  IOQLen-1:0] ioq_issue_idx;
  logic                ioq_issue_found;
  logic [IOQ_SIZE-1:0] ioq_load_issue_vec;
  logic [IOQ_SIZE-1:0] ioq_older_store_blk;

  logic                ioq_valid_found;
  logic                reservation_match;

  // === Status outputs to top-level dispatch ===
  logic [  IOQLen-1:0] ioq_tail_b;
  assign ioq_tail_b   = ioq_tail_a + 1'b1;
  assign disp.ready   = (ioq_valid[ioq_tail_a] == 1'b0);
  assign disp.ready_b = (ioq_valid[ioq_tail_b] == 1'b0);

  // === IOQ effective address & older-store blocker ===
  logic [XLEN-1:0] ioq_eff_addr[IOQ_SIZE];
  always_comb begin
    for (int i = 0; i < IOQ_SIZE; i++) begin
      ioq_eff_addr[i] = ioq_atom[i] ? ioq_vj[i] : ioq_vj[i] + ioq_imm[i];
    end
  end

  always_comb begin
    for (int i = 0; i < IOQ_SIZE; i++) begin
      ioq_older_store_blk[i] = 1'b0;
      for (int j = 0; j < IOQ_SIZE; j++) begin
        automatic logic [$clog2(IOQ_SIZE):0] age_i;
        automatic logic [$clog2(IOQ_SIZE):0] age_j;
        age_i = ({1'b0, i[$clog2(IOQ_SIZE)-1:0]} - {1'b0, ioq_head}) &
            ((1 << $clog2(IOQ_SIZE)) - 1);
        age_j = ({1'b0, j[$clog2(IOQ_SIZE)-1:0]} - {1'b0, ioq_head}) &
            ((1 << $clog2(IOQ_SIZE)) - 1);
        if (ioq_valid[j] && ioq_wen[j] && age_j < age_i) begin
          if (|ioq_pr1[j] || ioq_mmu_en[j] || (ioq_eff_addr[j][XLEN-1:$clog2(
                  XLEN/8
              )] == ioq_eff_addr[i][XLEN-1:$clog2(
                  XLEN/8
              )])) begin
            ioq_older_store_blk[i] = 1'b1;
          end
        end
      end
    end
  end

  // === Atomic op staging ===
  // AMO write data is computed only at the head (see `head_amo_wdata`),
  // using the live or captured load result. Per-entry pre-computation was
  // removed to eliminate IOQ_SIZE atomic ALU instances and fix a stale
  // `exu_lsu.rdata` capture for non-live writeback cycles.

  // === Issue eligibility & priority encoder ===
  logic ioq_at_rob_head;
  assign ioq_at_rob_head = (ioq_dest[ioq_head] == cmu_bcast.rob_head);

  always_comb begin
    for (int i = 0; i < IOQ_SIZE; i++) begin
      ioq_load_issue_vec[i] = ioq_valid[i] && ioq_ren[i]
          && !ioq_complete[i]
          && (ioq_pr1[i] == 0) && (ioq_pr2[i] == 0)
          && !ioq_atom[i]
          && !ioq_older_store_blk[i]
          && (csr_bcast.dmmu_en
              || rapt_pkg::addr_cacheable(ioq_eff_addr[i]) ||
          (i[$clog2(IOQ_SIZE)-1:0] == ioq_head && ioq_at_rob_head));
    end
  end

  always_comb begin
    ioq_issue_idx   = ioq_head;
    ioq_issue_found = 1'b0;
    for (int k = 0; k < IOQ_SIZE; k++) begin
      automatic logic [$clog2(IOQ_SIZE)-1:0] idx;
      idx = ioq_head + k[$clog2(IOQ_SIZE)-1:0];
      if (!ioq_issue_found && ioq_load_issue_vec[idx]) begin
        ioq_issue_idx   = idx;
        ioq_issue_found = 1'b1;
      end
    end
  end

  // active_idx = pending_idx during miss; else PE output (atomics preempt)
  logic [$clog2(IOQ_SIZE)-1:0] active_idx;
  logic head_is_atomic_ready;
  assign head_is_atomic_ready = ioq_valid[ioq_head] && ioq_atom[ioq_head]
      && ioq_pr1[ioq_head] == 0 && ioq_pr2[ioq_head] == 0;
  assign active_idx = oo_pending ? oo_pending_idx
                     : (head_is_atomic_ready ? ioq_head : ioq_issue_idx);

  logic issue_valid_now;
  assign issue_valid_now = oo_pending
      ? ioq_valid[oo_pending_idx]
      : (head_is_atomic_ready || ioq_issue_found);

  logic active_load_done;
  assign active_load_done = ioq_complete[active_idx];

  // === LSU output ===
  assign exu_lsu.rvalid = (issue_valid_now
      && ioq_ren[active_idx]
      && !active_load_done
      && ioq_pr1[active_idx] == 0 && ioq_pr2[active_idx] == 0
      && (csr_bcast.dmmu_en
          || rapt_pkg::addr_cacheable(
      exu_lsu.raddr
  ) || (active_idx == ioq_head && ioq_at_rob_head)));
  assign exu_lsu.raddr = ioq_atom[active_idx]
      ? ioq_vj[active_idx]
      : ioq_vj[active_idx] + ioq_imm[active_idx];
  assign exu_lsu.ralu = ioq_atom[active_idx]
      ? (ioq_word[active_idx] ? `RAPT_ALU_LW__ : `RAPT_ALU_LD__)
      : ioq_alu[active_idx][4:0];
  assign exu_lsu.atomic_lock = ioq_atom[active_idx] && ioq_alu[active_idx] == `RAPT_ATO_LR__;
  assign exu_lsu.pc = ioq_pc[active_idx];

  // === Hit-under-miss B issue (Phase A2, RAPT_LSU_HUM) ===
  // While the A channel is parked on a miss (oo_pending), offer the next
  // eligible load (in age order, skipping the pending entry) on the B
  // channel.  B is best-effort: it completes only on a clean L1D hit or SQ
  // forward; anything else just leaves the entry to retry via A later, so
  // no extra state is held here.  ioq_load_issue_vec already enforces
  // operand readiness, non-atomic, and older-store disambiguation.
`ifdef RAPT_LSU_HUM
  logic [$clog2(IOQ_SIZE)-1:0] b_issue_idx;
  logic b_issue_found;
  always_comb begin
    b_issue_idx   = ioq_head;
    b_issue_found = 1'b0;
    for (int k = 0; k < IOQ_SIZE; k++) begin
      automatic logic [$clog2(IOQ_SIZE)-1:0] idx;
      idx = ioq_head + k[$clog2(IOQ_SIZE)-1:0];
      if (!b_issue_found && ioq_load_issue_vec[idx]
          && idx != oo_pending_idx && !ioq_atom[idx]) begin
        b_issue_idx   = idx;
        b_issue_found = 1'b1;
      end
    end
  end
  assign exu_lsu.rvalid_b = oo_pending && b_issue_found;
  assign exu_lsu.raddr_b  = ioq_vj[b_issue_idx] + ioq_imm[b_issue_idx];
  assign exu_lsu.ralu_b   = ioq_alu[b_issue_idx][4:0];
`else
  assign exu_lsu.rvalid_b = 1'b0;
  assign exu_lsu.raddr_b  = '0;
  assign exu_lsu.ralu_b   = '0;
`endif

  // LSU/SQ store width expects SB/SH/SW/SD masks, while atomics carry
  // RAPT_ATO_* opcodes in ioq_alu. Convert AMO/SC width from uop.word.
  logic [4:0] head_store_walu;
`ifdef RAPT_RV64
  assign head_store_walu = ioq_atom[ioq_head]
        ? (ioq_word[ioq_head] ? `RAPT_SW_WSTRB : `RAPT_SD_WSTRB)
        : ioq_alu[ioq_head][4:0];
`else
  assign head_store_walu = ioq_atom[ioq_head] ? `RAPT_SW_WSTRB : ioq_alu[ioq_head][4:0];
`endif

  // === MMU for Store at head ===
  assign exu_l1d.mmu_en = (ioq_wen[ioq_head]
      && ioq_mmu_en[ioq_head]
      && ioq_pr1[ioq_head] == 0 && ioq_pr2[ioq_head] == 0);
  assign exu_l1d.vaddr = ioq_vj[ioq_head] + ioq_imm[ioq_head];
  assign exu_l1d.walu = head_store_walu;
  assign exu_l1d.valid = (ioq_wen[ioq_head] && ioq_pr1[ioq_head] == 0 && ioq_pr2[ioq_head] == 0);

  // === PMP check for bare-mode (non-MMU) stores at head ===
  // MMU-mode stores are PMP-checked in L1D on the translated paddr.
  // Bare-mode stores never reach L1D's MMU handshake, so check here on
  // the virtual==physical address.  MPRV is ignored for bare mode since
  // paging is off (SATP=0) in the most common arch-test setups; MSTATUS.
  // MPRV still takes effect on effective privilege for memory accesses.
  logic [1:0] ioq_store_eff_priv;
  logic       pmp_store_bare_fault;
  assign ioq_store_eff_priv = (csr_bcast.priv == `RAPT_PRIV_M && csr_bcast.mprv)
                              ? csr_bcast.mpp
                              : csr_bcast.priv;
  logic [3:0] store_bare_size_m1;
  always_comb begin
    unique case (head_store_walu)
      `RAPT_SB_WSTRB: store_bare_size_m1 = 4'd0;
      `RAPT_SH_WSTRB: store_bare_size_m1 = 4'd1;
      `RAPT_SW_WSTRB: store_bare_size_m1 = 4'd3;
      `RAPT_SD_WSTRB: store_bare_size_m1 = 4'd7;
      default:        store_bare_size_m1 = 4'd3;
    endcase
  end
  rapt_pmp u_pmp_store_bare (
      .addr          (ioq_vj[ioq_head] + ioq_imm[ioq_head]),
      .size_m1       (store_bare_size_m1),
      .priv          (ioq_store_eff_priv),
      .op_r          (1'b0),
      .op_w          (1'b1),
      .op_x          (1'b0),
      .pmp_napot_mask(csr_bcast.pmp_napot_mask),
      .pmp_napot_base(csr_bcast.pmp_napot_base),
      .pmp_tor_lo    (csr_bcast.pmp_tor_lo),
      .pmp_tor_hi    (csr_bcast.pmp_tor_hi),
      .pmp_cfg_r     (csr_bcast.pmp_cfg_r),
      .pmp_cfg_w     (csr_bcast.pmp_cfg_w),
      .pmp_cfg_x     (csr_bcast.pmp_cfg_x),
      .pmp_cfg_l     (csr_bcast.pmp_cfg_l),
      .pmp_mode_off  (csr_bcast.pmp_mode_off),
      .pmp_mode_tor  (csr_bcast.pmp_mode_tor),
      .pmp_mode_na4  (csr_bcast.pmp_mode_na4),
      .pmp_mode_napot(csr_bcast.pmp_mode_napot),
      .fault         (pmp_store_bare_fault)
  );
  logic store_bare_pmp_trap;
  assign store_bare_pmp_trap = ioq_wen[ioq_head]
                               && !ioq_mmu_en[ioq_head]
                               && !csr_bcast.dmmu_en
                               && (pmp_store_bare_fault
                                   || !rapt_pkg::addr_mapped(
      ioq_vj[ioq_head] + ioq_imm[ioq_head]
  ));

  assign reservation_match = exu_l1d.reservation == (csr_bcast.dmmu_en
      ? ioq_paddr[ioq_head]
      : (ioq_vj[ioq_head] + ioq_imm[ioq_head]));

  // === Head completion resolution ===
  logic head_load_done;
  logic [XLEN-1:0] head_rdata;
  logic head_trap_lsu;
  logic [XLEN-1:0] head_cause_lsu;
  logic head_skip_lsu;
  // Broadcast loads/AMOs only after the LSU response has been captured in
  // IOQ state. This removes the same-cycle raddr->LSU->broadcast loop from
  // the PRF/STQ writeback cone on FPGA builds.
  assign head_load_done = ioq_complete[ioq_head];
  assign head_rdata     = ioq_rdata[ioq_head];
  assign head_trap_lsu  = ioq_load_trap[ioq_head];
  assign head_cause_lsu = ioq_load_cause[ioq_head];
  assign head_skip_lsu  = ioq_load_skip[ioq_head];

  // AMO write data: computed from head_rdata (correct live/captured mux)
  // instead of ioq_data which uses stale exu_lsu.rdata on non-live writeback.
  logic [XLEN-1:0] head_amo_wdata;
  always_comb begin
    case (ioq_alu[ioq_head])
      `RAPT_ATO_LR__: head_amo_wdata = 'b0;
      `RAPT_ATO_SC__: head_amo_wdata = ioq_vk[ioq_head];
      `RAPT_ATO_SWAP: head_amo_wdata = ioq_vk[ioq_head];
      `RAPT_ATO_ADD_: head_amo_wdata = ioq_vk[ioq_head] + head_rdata;
      `RAPT_ATO_XOR_: head_amo_wdata = ioq_vk[ioq_head] ^ head_rdata;
      `RAPT_ATO_AND_: head_amo_wdata = ioq_vk[ioq_head] & head_rdata;
      `RAPT_ATO_OR__: head_amo_wdata = ioq_vk[ioq_head] | head_rdata;
      `RAPT_ATO_MIN_:
      head_amo_wdata = $signed(head_rdata) < $signed(ioq_vk[ioq_head]) ? head_rdata :
          ioq_vk[ioq_head];
      `RAPT_ATO_MAX_:
      head_amo_wdata = $signed(head_rdata) > $signed(ioq_vk[ioq_head]) ? head_rdata :
          ioq_vk[ioq_head];
      `RAPT_ATO_MINU:
      head_amo_wdata = head_rdata < ioq_vk[ioq_head] ? head_rdata : ioq_vk[ioq_head];
      `RAPT_ATO_MAXU:
      head_amo_wdata = head_rdata > ioq_vk[ioq_head] ? head_rdata : ioq_vk[ioq_head];
      default: head_amo_wdata = 'b0;
    endcase
  end

  // === Writeback (IOQ -> ROB) ===
  assign exu_ioq_bcast.pc = ioq_pc[ioq_head];
  assign exu_ioq_bcast.npc      = ioq_ren[ioq_head]
      ? (head_trap_lsu
          ? csr_bcast.tvec
          : ioq_pc[ioq_head] + (ioq_c[ioq_head] ? 2 : 4))
      : ioq_trap[ioq_head]
          ? csr_bcast.tvec
          : ioq_pc[ioq_head] + (ioq_c[ioq_head] ? 2 : 4);
  assign exu_ioq_bcast.result   = (ioq_atom[ioq_head] && ioq_alu[ioq_head] == `RAPT_ATO_SC__)
      ? (reservation_match ? 0 : 1)
      : (ioq_ren[ioq_head] ? head_rdata : ioq_vk[ioq_head]);
  assign exu_ioq_bcast.dest = ioq_dest[ioq_head];
  assign exu_ioq_bcast.prd = ioq_prd[ioq_head];
  assign exu_ioq_bcast.rd = ioq_rd[ioq_head];
  assign exu_ioq_bcast.wen      = (ioq_atom[ioq_head] && ioq_alu[ioq_head] == `RAPT_ATO_SC__)
      ? (reservation_match ? 1 : 0)
      : (ioq_wen[ioq_head]);
  assign exu_ioq_bcast.alu = ioq_atom[ioq_head] ? {1'b0, head_store_walu} : ioq_alu[ioq_head];
  assign exu_ioq_bcast.sq_waddr = csr_bcast.dmmu_en
      ? ioq_paddr[ioq_head]
      : ioq_vj[ioq_head] + ioq_imm[ioq_head];
  assign exu_ioq_bcast.sq_wdata = ioq_atom[ioq_head] ? head_amo_wdata : ioq_vk[ioq_head];
  // For AMO RW (atomic with both R and W), PMP/page fault on either side
  // is reported as a store access fault per RISC-V spec.  LR is treated as a
  // pure load; SC as a pure store (PMP store path).
  logic head_is_amo_rw;
  assign head_is_amo_rw = ioq_atom[ioq_head]
                          && (ioq_alu[ioq_head] != `RAPT_ATO_LR__)
                          && (ioq_alu[ioq_head] != `RAPT_ATO_SC__);
  assign exu_ioq_bcast.trap = ioq_ren[ioq_head]
      ? (head_trap_lsu || (head_is_amo_rw && store_bare_pmp_trap))
      : (ioq_trap[ioq_head] || store_bare_pmp_trap);
  assign exu_ioq_bcast.tval     = ioq_ren[ioq_head]
      ? ioq_eff_addr[ioq_head]
      : ioq_vj[ioq_head] + ioq_imm[ioq_head];
  assign exu_ioq_bcast.cause = ioq_ren[ioq_head]
      ? (head_is_amo_rw && (head_trap_lsu || store_bare_pmp_trap)
          ?
      `RAPT_CAUSE_STORE_ACC_FAULT
      : head_cause_lsu) : (ioq_trap[ioq_head] ? ioq_cause[ioq_head] : (store_bare_pmp_trap ?
      `RAPT_CAUSE_STORE_ACC_FAULT
      : ioq_cause[ioq_head]));
  assign exu_ioq_bcast.difftest_skip =
      (ioq_ren[ioq_head] && head_skip_lsu)
      || (ioq_wen[ioq_head] && rapt_pkg::addr_mmio(
      exu_ioq_bcast.sq_waddr
  ));

  assign ioq_valid_found = (ioq_valid[ioq_head]
      && ioq_pr1[ioq_head] == 0 && ioq_pr2[ioq_head] == 0
      && (ioq_ren[ioq_head]
          ? head_load_done
          : ioq_mmu_en[ioq_head] == 0)
      && (!ioq_wen[ioq_head] || (ioq_mmu_en[ioq_head] == 0 && exu_lsu.stq_ready)));
  assign exu_ioq_bcast.valid = ioq_valid_found;
  // MEM pipe never resolves branches nor writes CSRs (unified exu_wb_if
  // tie-offs; ROB keeps mispredict at its dispatch-init value of 0).
  assign exu_ioq_bcast.btaken = 1'b0;
  assign exu_ioq_bcast.mispredict = 1'b0;
  assign exu_ioq_bcast.csr_wen = 1'b0;
  assign exu_ioq_bcast.csr_wdata = '0;

  // Fast load-use wakeup is a narrow tag-only path.  It wakes RS operands when
  // a plain head load has actually returned, one cycle before the normal IOQ
  // writeback presents the registered data.  The registered slow writeback is
  // still the only data source; if it ever fails to confirm the tag on the next
  // cycle, the framework emits a rebusy pulse so fast-woken consumers cannot
  // issue with stale operands.  This mirrors BOOM/XiangShan's poison/cancel
  // shape without reintroducing the old cache-data -> global-CDB combo path.
  logic fast_load_pending;
  logic [PLEN-1:0] fast_load_prd_q;
  logic fast_load_fire;
  logic fast_load_confirm;
  logic fast_load_rebusy;

  assign fast_load_fire = exu_lsu.rvalid
      && exu_lsu.rready
      && (active_idx == ioq_head)
      && ioq_valid[active_idx]
      && ioq_ren[active_idx]
      && !ioq_atom[active_idx]
      && !exu_lsu.trap
      && !exu_lsu.difftest_skip
      && (ioq_rd[active_idx] != '0)
      && (ioq_prd[active_idx] != '0);
  assign fast_load_confirm = fast_load_pending
      && exu_ioq_bcast.valid
      && (exu_ioq_bcast.prd == fast_load_prd_q);
  assign fast_load_rebusy = fast_load_pending && !fast_load_confirm;

  assign load_fast.valid = fast_load_fire || fast_load_rebusy;
  assign load_fast.rebusy = fast_load_rebusy;
  assign load_fast.prd = fast_load_rebusy ? fast_load_prd_q : ioq_prd[active_idx];

  // === Sequential: enqueue / dequeue / forwarding / OoO LSU FSM ===
  logic ioq_full_r;  // Previous cycle full state (for pmu_ioq_full rising-edge detection)

  // --------------------------------------------------------------------------
  // Unified CDB view for operand forwarding.
  //
  // Value-producing writeback ports in forwarding-priority order:
  //   [0] MEM (self broadcast)   [1] ALU-A   [2] ALU-B   [3] MULDIV
  // Rename guarantees a unique producer per physical register, so at most one
  // port matches a given tag per cycle; the priority order only pins the
  // legacy mux shape. Adding a pipe = appending one slot here.
  // --------------------------------------------------------------------------
  localparam int unsigned NWB = 4;
  logic            wb_valid [NWB];
  logic [PLEN-1:0] wb_prd   [NWB];
  logic [XLEN-1:0] wb_result[NWB];
  assign wb_valid[0]  = exu_ioq_bcast.valid;
  assign wb_prd[0]    = exu_ioq_bcast.prd;
  assign wb_result[0] = exu_ioq_bcast.result;
  assign wb_valid[1]  = exu_rou.valid;
  assign wb_prd[1]    = exu_rou.prd;
  assign wb_result[1] = exu_rou.result;
  assign wb_valid[2]  = exu_rou_b.valid;
  assign wb_prd[2]    = exu_rou_b.prd;
  assign wb_result[2] = exu_rou_b.result;
  assign wb_valid[3]  = exu_wb_mul.valid;
  assign wb_prd[3]    = exu_wb_mul.prd;
  assign wb_result[3] = exu_wb_mul.result;

  // Any-port tag match (zero tag never matches).
  function automatic logic wb_hit(input logic [PLEN-1:0] pr);
    wb_hit = 1'b0;
    for (int p = 0; p < NWB; p++) begin
      wb_hit |= (pr != '0) && wb_valid[p] && (wb_prd[p] == pr);
    end
  endfunction

  // First-match value in priority order (reverse loop: slot 0 wins).
  function automatic logic [XLEN-1:0] wb_val(input logic [PLEN-1:0] pr,
                                             input logic [XLEN-1:0] dflt);
    wb_val = dflt;
    for (int p = NWB - 1; p >= 0; p--) begin
      if ((pr != '0) && wb_valid[p] && (wb_prd[p] == pr)) wb_val = wb_result[p];
    end
  endfunction

  // --------------------------------------------------------------------------
  // Same-cycle enqueue/wakeup snoop.
  //
  // A just-enqueued entry is not visible to the forwarding loop until the next
  // cycle, so wake it from same-cycle broadcasts before storing the tag/value.
  // --------------------------------------------------------------------------
  function automatic logic [PLEN-1:0] wake_pr(input logic [PLEN-1:0] pr);
    return wb_hit(pr) ? '0 : pr;
  endfunction

  function automatic logic [XLEN-1:0] wake_val(input logic [PLEN-1:0] pr,
                                               input logic [XLEN-1:0] dflt);
    return wb_val(pr, dflt);
  endfunction

  // Per-entry resident forwarding: hit flag + selected value.
  logic [IOQ_SIZE-1:0] ioq_fwd1_hit;
  logic [IOQ_SIZE-1:0] ioq_fwd2_hit;
  logic [XLEN-1:0] ioq_fwd1_val[IOQ_SIZE];
  logic [XLEN-1:0] ioq_fwd2_val[IOQ_SIZE];

  always_comb begin
    for (int i = 0; i < IOQ_SIZE; i++) begin
      ioq_fwd1_hit[i] = wb_hit(ioq_pr1[i]);
      ioq_fwd2_hit[i] = wb_hit(ioq_pr2[i]);
      ioq_fwd1_val[i] = wb_val(ioq_pr1[i], ioq_vj[i]);
      ioq_fwd2_val[i] = wb_val(ioq_pr2[i], ioq_vk[i]);
    end
  end

  always_ff @(posedge clock) begin
    if (reset || cmu_bcast.flush_pipe) begin
      ioq_ren           <= '0;
      ioq_wen           <= '0;
      ioq_mmu_en        <= '0;
      ioq_valid         <= '0;
      ioq_head          <= '0;
      ioq_tail_a        <= '0;
      ioq_complete      <= '0;
      ioq_load_trap     <= '0;
      ioq_load_skip     <= '0;
      oo_pending        <= 1'b0;
      oo_pending_idx    <= '0;
      ioq_full_r        <= 1'b0;  // A2: Initialize full state tracker
      fast_load_pending <= 1'b0;
      fast_load_prd_q   <= '0;
      // Reset payload arrays as well as valid bits so unused entries cannot
      // feed X values into store-address and ordering logic in FPGA synthesis.
      for (int i = 0; i < IOQ_SIZE; i++) begin
        ioq_pr1[i]  <= '0;
        ioq_pr2[i]  <= '0;
        ioq_vj[i]   <= '0;
        ioq_vk[i]   <= '0;
        ioq_imm[i]  <= '0;
        ioq_atom[i] <= '0;
        ioq_alu[i]  <= '0;
      end
    end else begin
      // A2: Latch current full status (rising-edge detection for pmu_ioq_full)
      ioq_full_r <= (&ioq_valid);  // Full when all entries valid
      if (fast_load_confirm || fast_load_rebusy) begin
        fast_load_pending <= 1'b0;
      end
      if (fast_load_fire) begin
        fast_load_pending <= 1'b1;
        fast_load_prd_q   <= ioq_prd[active_idx];
      end
      // ---- Enqueue slot A ----
      if (disp.accept_a) begin
        ioq_valid[ioq_tail_a]     <= 1'b1;
        ioq_pc[ioq_tail_a]        <= rou_exu.uop.pc;
        ioq_pr1[ioq_tail_a]       <= wake_pr(rou_exu.pr1);
        ioq_pr2[ioq_tail_a]       <= wake_pr(rou_exu.pr2);
        ioq_prd[ioq_tail_a]       <= rou_exu.prd;
        ioq_rd[ioq_tail_a]        <= rou_exu.uop.rd;
        ioq_c[ioq_tail_a]         <= rou_exu.uop.c;
        ioq_word[ioq_tail_a]      <= rou_exu.uop.word;
        ioq_alu[ioq_tail_a]       <= rou_exu.uop.alu;
        ioq_vj[ioq_tail_a]        <= wake_val(rou_exu.pr1, rou_exu.op1);
        ioq_vk[ioq_tail_a]        <= wake_val(rou_exu.pr2, rou_exu.op2);
        ioq_dest[ioq_tail_a]      <= rou_exu.dest;
        ioq_imm[ioq_tail_a]       <= rou_exu.uop.imm;
        ioq_wen[ioq_tail_a]       <= rou_exu.uop.wen;
        ioq_mmu_en[ioq_tail_a]    <= csr_bcast.dmmu_en;
        ioq_ren[ioq_tail_a]       <= rou_exu.uop.ren;
        ioq_atom[ioq_tail_a]      <= rou_exu.uop.atom;
        ioq_trap[ioq_tail_a]      <= rou_exu.uop.trap;
        ioq_complete[ioq_tail_a]  <= 1'b0;
        ioq_load_trap[ioq_tail_a] <= 1'b0;
        ioq_load_skip[ioq_tail_a] <= 1'b0;
      end
`ifdef RAPT_DUAL_ISSUE
      // ---- Enqueue slot B paired with A (uses ioq_tail_a+1) ----
      if (disp.accept_b_paired) begin
        ioq_valid[ioq_tail_b]     <= 1'b1;
        ioq_pc[ioq_tail_b]        <= rou_exu.uop_b.pc;
        ioq_pr1[ioq_tail_b]       <= wake_pr(rou_exu.pr1_b);
        ioq_pr2[ioq_tail_b]       <= wake_pr(rou_exu.pr2_b);
        ioq_prd[ioq_tail_b]       <= rou_exu.prd_b;
        ioq_rd[ioq_tail_b]        <= rou_exu.uop_b.rd;
        ioq_c[ioq_tail_b]         <= rou_exu.uop_b.c;
        ioq_word[ioq_tail_b]      <= rou_exu.uop_b.word;
        ioq_alu[ioq_tail_b]       <= rou_exu.uop_b.alu;
        ioq_vj[ioq_tail_b]        <= wake_val(rou_exu.pr1_b, rou_exu.op1_b);
        ioq_vk[ioq_tail_b]        <= wake_val(rou_exu.pr2_b, rou_exu.op2_b);
        ioq_dest[ioq_tail_b]      <= rou_exu.dest_b;
        ioq_imm[ioq_tail_b]       <= rou_exu.uop_b.imm;
        ioq_wen[ioq_tail_b]       <= rou_exu.uop_b.wen;
        ioq_mmu_en[ioq_tail_b]    <= csr_bcast.dmmu_en;
        ioq_ren[ioq_tail_b]       <= rou_exu.uop_b.ren;
        ioq_atom[ioq_tail_b]      <= rou_exu.uop_b.atom;
        ioq_trap[ioq_tail_b]      <= rou_exu.uop_b.trap;
        ioq_complete[ioq_tail_b]  <= 1'b0;
        ioq_load_trap[ioq_tail_b] <= 1'b0;
        ioq_load_skip[ioq_tail_b] <= 1'b0;
      end
      // ---- Enqueue slot B alone (A went to RS, uses ioq_tail_a) ----
      if (disp.accept_b_alone) begin
        ioq_valid[ioq_tail_a]     <= 1'b1;
        ioq_pc[ioq_tail_a]        <= rou_exu.uop_b.pc;
        ioq_pr1[ioq_tail_a]       <= wake_pr(rou_exu.pr1_b);
        ioq_pr2[ioq_tail_a]       <= wake_pr(rou_exu.pr2_b);
        ioq_prd[ioq_tail_a]       <= rou_exu.prd_b;
        ioq_rd[ioq_tail_a]        <= rou_exu.uop_b.rd;
        ioq_c[ioq_tail_a]         <= rou_exu.uop_b.c;
        ioq_word[ioq_tail_a]      <= rou_exu.uop_b.word;
        ioq_alu[ioq_tail_a]       <= rou_exu.uop_b.alu;
        ioq_vj[ioq_tail_a]        <= wake_val(rou_exu.pr1_b, rou_exu.op1_b);
        ioq_vk[ioq_tail_a]        <= wake_val(rou_exu.pr2_b, rou_exu.op2_b);
        ioq_dest[ioq_tail_a]      <= rou_exu.dest_b;
        ioq_imm[ioq_tail_a]       <= rou_exu.uop_b.imm;
        ioq_wen[ioq_tail_a]       <= rou_exu.uop_b.wen;
        ioq_mmu_en[ioq_tail_a]    <= csr_bcast.dmmu_en;
        ioq_ren[ioq_tail_a]       <= rou_exu.uop_b.ren;
        ioq_atom[ioq_tail_a]      <= rou_exu.uop_b.atom;
        ioq_trap[ioq_tail_a]      <= rou_exu.uop_b.trap;
        ioq_complete[ioq_tail_a]  <= 1'b0;
        ioq_load_trap[ioq_tail_a] <= 1'b0;
        ioq_load_skip[ioq_tail_a] <= 1'b0;
      end
      // Tail pointer advance: 0 / 1 / 2 entries enqueued this cycle.
      if (disp.accept_a && disp.accept_b_paired) begin
        ioq_tail_a <= ioq_tail_a + 2'd2;
      end else if (disp.accept_a || disp.accept_b_alone) begin
        ioq_tail_a <= ioq_tail_a + 1'b1;
      end
`else
      if (disp.accept_a) ioq_tail_a <= ioq_tail_a + 1'b1;
`endif

      // ---- Store MMU response latch ----
      if (exu_l1d.ready && ioq_mmu_en[ioq_head]) begin
        ioq_paddr[ioq_head]  <= exu_l1d.paddr;
        ioq_mmu_en[ioq_head] <= 1'b0;
        ioq_trap[ioq_head]   <= exu_l1d.trap;
        ioq_cause[ioq_head]  <= exu_l1d.cause;
      end

      // ---- Head retire ----
      if (ioq_valid_found) begin
        ioq_wen[ioq_head]    <= 1'b0;
        ioq_mmu_en[ioq_head] <= 1'b0;
        ioq_trap[ioq_head]   <= 1'b0;
        ioq_ren[ioq_head]    <= 1'b0;
        ioq_valid[ioq_head]  <= 1'b0;
        ioq_head             <= ioq_head + 1'b1;
      end

      // ---- OoO LSU FSM (per-entry one-hot: avoid multi-write with head retire) ----
      if (exu_lsu.rvalid && exu_lsu.rready) begin
        ioq_rdata[active_idx]      <= exu_lsu.rdata;
        // Suppress completion/trap/skip write when the same entry is also
        // being retired this cycle (head-retire clear below takes priority).
        // This avoids a Vivado-addressed-WAW hazard (R1 pattern).
        if (active_idx != ioq_head || !ioq_valid_found) begin
          ioq_complete[active_idx]   <= 1'b1;
          ioq_load_trap[active_idx]  <= exu_lsu.trap;
          ioq_load_cause[active_idx] <= exu_lsu.cause;
          ioq_load_skip[active_idx]  <= exu_lsu.difftest_skip;
        end
        oo_pending                 <= 1'b0;
      end else if (!oo_pending && exu_lsu.rvalid && !exu_lsu.rready) begin
        oo_pending     <= 1'b1;
        oo_pending_idx <= active_idx;
      end
`ifdef RAPT_LSU_HUM
      // ---- B-channel completion (hit-under-miss) ----
      // Distinct from the A entry by construction (selection skips
      // oo_pending_idx) and from the retiring head (B only targets
      // !complete entries; retire requires complete).  The guard makes the
      // exclusion explicit for synthesis (R1 discipline).
      if (exu_lsu.rvalid_b && exu_lsu.rready_b) begin
        if (b_issue_idx != active_idx
            && !(ioq_valid_found && b_issue_idx == ioq_head)) begin
          ioq_rdata[b_issue_idx]      <= exu_lsu.rdata_b;
          ioq_complete[b_issue_idx]   <= 1'b1;
          ioq_load_trap[b_issue_idx]  <= 1'b0;
          ioq_load_cause[b_issue_idx] <= '0;
          ioq_load_skip[b_issue_idx]  <= 1'b0;
        end
      end
`endif
      // Clear per-entry completion when head retires (NBA after live latch)
      if (ioq_valid_found) begin
        ioq_complete[ioq_head]  <= 1'b0;
        ioq_load_trap[ioq_head] <= 1'b0;
        ioq_load_skip[ioq_head] <= 1'b0;
      end

      // ---- Operand forwarding: any CDB port (unique-producer invariant) ----
      for (bit [XLEN-1:0] i = 0; i < IOQ_SIZE; i++) begin
        if (ioq_valid[i]) begin
          if (|ioq_pr1[i]) begin
            if (ioq_fwd1_hit[i]) begin
              ioq_vj[i]  <= ioq_fwd1_val[i];
              ioq_pr1[i] <= '0;
            end
          end
          if (|ioq_pr2[i]) begin
            if (ioq_fwd2_hit[i]) begin
              ioq_vk[i]  <= ioq_fwd2_val[i];
              ioq_pr2[i] <= '0;
            end
          end
        end
      end
    end
  end

  // A2: PMU: one-cycle pulse on IOQ full rising edge
  assign pmu_ioq_full = (&ioq_valid) && !ioq_full_r;

endmodule
