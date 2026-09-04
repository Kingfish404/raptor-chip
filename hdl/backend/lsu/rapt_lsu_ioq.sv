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
/* verilator lint_off PINCONNECTEMPTY */
module rapt_lsu_ioq #(
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
    pmp_state_if.in pmp_state,

    // Dispatch source (read-only view of rou_exu, drive accepts via disp.io)
    rou_exu_if.monitor rou_exu,
    dpu_ioq_if.ioq disp,

    // Forwarding sources (other writeback buses)
    cdb_if.in exu_rou,
    cdb_if.in exu_rou_b,
    cdb_if.in exu_wb_mul,

    // Outputs to memory subsystem & ROB writeback
    lsu_pipe_if.master    exu_lsu,
    lsu_l1d_mmu_if.master exu_l1d,
    fpr_if.ioq            fpr,
    cdb_if.out            exu_ioq_bcast,
    output logic [XLEN-1:0] sq_waddr_hi,
    load_fast_if.source   load_fast,

    // A2: PMU: one-cycle pulse when IOQ becomes full
    /* verilator lint_off UNUSEDSIGNAL */
    output logic pmu_ioq_full
    /* verilator lint_on UNUSEDSIGNAL */
);
  localparam unsigned IOQLen = $clog2(IOQ_SIZE);
  localparam unsigned ROBLen = $clog2(ROB_SIZE);
  localparam unsigned WordOffBits = $clog2(XLEN / 8);
  localparam unsigned PageOffBits = 12;

  // === IOQ state ===
  logic [IOQ_SIZE-1:0] ioq_valid;
  // Width-stable occupancy probes for the C++ PMU. Reading ioq_valid through
  // a uint8_t silently truncated configurations with more than eight entries,
  // while comparing it with 8'hff never detected full 2/4-entry queues.
  logic pmu_ioq_any_valid /*verilator public_flat_rd*/;
  logic pmu_ioq_all_full  /*verilator public_flat_rd*/;
  logic [  IOQLen-1:0] ioq_tail_a;
  logic [  IOQLen-1:0] ioq_head;

  logic [    XLEN-1:0] ioq_pc           [IOQ_SIZE];

  logic [    PLEN-1:0] ioq_pr1          [IOQ_SIZE];
  logic [    PLEN-1:0] ioq_pr2          [IOQ_SIZE];
  logic [    PLEN-1:0] ioq_prd          [IOQ_SIZE];
  logic [    RLEN-1:0] ioq_rd           [IOQ_SIZE];

  logic                ioq_c            [IOQ_SIZE];
  /* verilator lint_off UNUSEDSIGNAL */
  logic                ioq_word         [IOQ_SIZE];  // reserved for RV64 sub-word
  /* verilator lint_on UNUSEDSIGNAL */
  logic [         5:0] ioq_alu          [IOQ_SIZE];
  logic [    XLEN-1:0] ioq_vj           [IOQ_SIZE];
  logic [    XLEN-1:0] ioq_vk           [IOQ_SIZE];
  logic [  ROBLen-1:0] ioq_dest         [IOQ_SIZE];
  logic [    XLEN-1:0] ioq_imm          [IOQ_SIZE];

  logic [IOQ_SIZE-1:0] ioq_wen;
  logic [IOQ_SIZE-1:0] ioq_mmu_en;
  logic [IOQ_SIZE-1:0] ioq_trap;
  logic [    XLEN-1:0] ioq_cause        [IOQ_SIZE];
  logic [    XLEN-1:0] ioq_paddr        [IOQ_SIZE];
  logic [    XLEN-1:0] ioq_paddr_hi     [IOQ_SIZE];
  logic [IOQ_SIZE-1:0] ioq_mmu_second;
  logic [IOQ_SIZE-1:0] ioq_ren;
  logic [IOQ_SIZE-1:0] ioq_atom;
  logic [IOQ_SIZE-1:0] ioq_fp_valid;
  logic [         5:0] ioq_fp_op        [IOQ_SIZE];
  logic [         4:0] ioq_fp_rd        [IOQ_SIZE];
  logic [         4:0] ioq_fp_rs2       [IOQ_SIZE];
  logic [IOQ_SIZE-1:0] ioq_fp_dep2_busy;
  logic [  ROBLen-1:0] ioq_fp_dep2      [IOQ_SIZE];

  function automatic logic fp_wb_hit(input logic [ROBLen-1:0] dep);
    return (exu_rou.valid && exu_rou.dest == dep)
      || (exu_rou_b.valid && exu_rou_b.dest == dep)
      || (exu_wb_mul.valid && exu_wb_mul.dest == dep)
      || (exu_ioq_bcast.valid && exu_ioq_bcast.dest == dep);
  endfunction

  // OoO load completion tracking
  logic [IOQ_SIZE-1:0] ioq_complete;
  logic [IOQ_SIZE-1:0] ioq_load_trap;
  logic [IOQ_SIZE-1:0] ioq_load_skip;
  logic [    XLEN-1:0] ioq_rdata           [IOQ_SIZE];
  logic [        63:0] ioq_fp_rdata64      [IOQ_SIZE];
  logic [    XLEN-1:0] ioq_load_cause      [IOQ_SIZE];

  logic                oo_pending;
  logic [  IOQLen-1:0] oo_pending_idx;
  logic [  IOQLen-1:0] ioq_issue_idx;
  logic                ioq_issue_found;
  logic [IOQ_SIZE-1:0] ioq_load_issue_vec;
  logic [IOQ_SIZE-1:0] ioq_older_store_blk;

  // Registered A-channel request stage.  Besides holding the request stable
  // across LSU backpressure, this is the timing boundary between the IOQ's
  // age/hazard arbitration and the L1D/PMP/fast-wakeup response cone.
  logic                load_req_valid_q;
  logic [  IOQLen-1:0] load_req_idx_q;
  logic [    XLEN-1:0] load_req_addr_q;
  logic [         4:0] load_req_alu_q;
  logic                load_req_atomic_q;
  logic                load_req_ordered_q;
  logic [    XLEN-1:0] load_req_pc_q;
  logic                load_req_fp64_q;
  logic                load_req_fast_eligible_q;
  logic [    PLEN-1:0] load_req_prd_q;

  logic                ioq_valid_found;
  logic                reservation_match;

  assign pmu_ioq_any_valid = |ioq_valid;
  assign pmu_ioq_all_full  = &ioq_valid;

  // === Status outputs to top-level dispatch ===
  logic [  IOQLen-1:0] ioq_tail_b;
  assign ioq_tail_b   = ioq_tail_a + 1'b1;
  assign disp.ready   = (ioq_valid[ioq_tail_a] == 1'b0);
  assign disp.ready_b = (ioq_valid[ioq_tail_b] == 1'b0);

  function automatic logic disp_b_selects_entry(input int entry);
`ifdef RAPT_DUAL_ISSUE
    return (disp.accept_b_paired && entry == int'(ioq_tail_b))
        || (disp.accept_b_alone && entry == int'(ioq_tail_a));
`else
    return 1'b0;
`endif
  endfunction

  // === IOQ effective address & older-store blocker ===
  // ioq_eff_addr is meaningful only for valid entries (all readers gate with
  // ioq_valid/complete; see older-store blocker and issue vectors below).
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
          // Translation preserves the 4 KiB page offset. Even before either
          // VPN has been translated, different word offsets therefore prove
          // that the accesses cannot alias. Same-offset accesses on different
          // virtual pages remain conservatively blocked until the store leaves
          // the IOQ; exact physical disambiguation is performed downstream.
          if (|ioq_pr1[j]
              || (ioq_valid[i]
                  && (csr_bcast.dmmu_en
                    ? (ioq_eff_addr[j][PageOffBits-1:WordOffBits]
                       == ioq_eff_addr[i][PageOffBits-1:WordOffBits])
                    : (ioq_eff_addr[j][XLEN-1:WordOffBits]
                       == ioq_eff_addr[i][XLEN-1:WordOffBits])))) begin
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
              || (ioq_valid[i] && rapt_pkg::addr_cacheable(ioq_eff_addr[i])) ||
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

  // Atomics preempt ordinary loads at the request-stage input.  Completed
  // atomics must not be restaged during the cycle before head writeback.
  logic [$clog2(IOQ_SIZE)-1:0] active_idx;
  logic head_is_atomic_ready;
  assign head_is_atomic_ready = ioq_valid[ioq_head] && ioq_atom[ioq_head]
      && !ioq_complete[ioq_head]
      && ioq_pr1[ioq_head] == 0 && ioq_pr2[ioq_head] == 0;

  logic [IOQLen-1:0] load_req_sel_idx;
  logic [XLEN-1:0] load_req_sel_addr;
  logic load_req_sel_valid;
  assign load_req_sel_idx = head_is_atomic_ready ? ioq_head : ioq_issue_idx;
  assign load_req_sel_addr = ioq_atom[load_req_sel_idx]
      ? ioq_vj[load_req_sel_idx]
      : ioq_vj[load_req_sel_idx] + ioq_imm[load_req_sel_idx];
  assign load_req_sel_valid = (head_is_atomic_ready || ioq_issue_found)
      && ioq_valid[load_req_sel_idx]
      && ioq_ren[load_req_sel_idx]
      && !ioq_complete[load_req_sel_idx]
      && ioq_pr1[load_req_sel_idx] == 0 && ioq_pr2[load_req_sel_idx] == 0
      && (csr_bcast.dmmu_en
          || rapt_pkg::addr_cacheable(load_req_sel_addr)
          || (load_req_sel_idx == ioq_head && ioq_at_rob_head));

  assign active_idx = load_req_idx_q;

  // === LSU output ===
  // All fields come from the same register bank and remain stable until the
  // response handshake.  This is a deliberate one-cycle issue pipeline.
  assign exu_lsu.rvalid         = load_req_valid_q;
  assign exu_lsu.raddr          = load_req_addr_q;
  assign exu_lsu.ralu           = load_req_alu_q;
  assign exu_lsu.fp_rdata64_req = load_req_fp64_q;
  assign exu_lsu.atomic_lock    = load_req_atomic_q;
  assign exu_lsu.ordered        = load_req_ordered_q;
  assign exu_lsu.pc             = load_req_pc_q;

  assign fpr.ioq_raddr = ioq_fp_rs2[ioq_head];

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
  logic head_is_cbo_mgmt;
  assign head_is_cbo_mgmt = head_store_walu == `RAPT_CBO_MGMT_WALU;

  // A misaligned store may touch two virtual pages whose physical pages are
  // not contiguous.  Translate the second page before the store is allowed
  // to leave the IOQ, so a fault remains precise and the SQ has both PAs.
  logic [XLEN-1:0] head_store_vaddr;
  logic [XLEN-1:0] head_store_last_vaddr;
  logic [XLEN-1:0] head_store_hi_vaddr;
  logic [3:0] head_store_size;
  logic head_store_cross_page;
  assign head_store_vaddr = ioq_vj[ioq_head] + ioq_imm[ioq_head];
  always_comb begin
    unique case (head_store_walu)
      `RAPT_SB_WSTRB: head_store_size = 4'd1;
      `RAPT_SH_WSTRB: head_store_size = 4'd2;
      `RAPT_SW_WSTRB: head_store_size = 4'd4;
      `RAPT_SD_WSTRB: head_store_size = 4'd8;
      `RAPT_CBO_ZERO_WALU,
      `RAPT_CBO_MGMT_WALU: head_store_size = 4'd1;
      default:        head_store_size = 4'd4;
    endcase
    if ((XLEN == 32) && ioq_fp_valid[ioq_head]
        && ioq_fp_op[ioq_head] == `RAPT_FP_OP_FSD)
      head_store_size = 4'd8;
  end
  assign head_store_last_vaddr = head_store_vaddr + XLEN'(head_store_size - 1'b1);
  assign head_store_cross_page =
      head_store_vaddr[XLEN-1:12] != head_store_last_vaddr[XLEN-1:12];
  assign head_store_hi_vaddr = {head_store_last_vaddr[XLEN-1:12], 12'b0};

  // === MMU for Store at head ===
  assign exu_l1d.mmu_en = (ioq_wen[ioq_head]
      && ioq_mmu_en[ioq_head]
      && ioq_pr1[ioq_head] == 0 && ioq_pr2[ioq_head] == 0);
  assign exu_l1d.vaddr = ioq_mmu_second[ioq_head]
      ? head_store_hi_vaddr : head_store_vaddr;
  assign exu_l1d.walu = head_store_walu;
  assign exu_l1d.cmo_mgmt = head_is_cbo_mgmt;
  assign exu_l1d.valid = (ioq_wen[ioq_head] && ioq_pr1[ioq_head] == 0 && ioq_pr2[ioq_head] == 0);

  // === PMP check for bare-mode (non-MMU) stores at head ===
  // MMU-mode stores are PMP-checked in L1D on the translated paddr.
  // Bare-mode stores never reach L1D's MMU handshake, so check here on
  // the virtual==physical address.  MPRV is ignored for bare mode since
  // paging is off (SATP=0) in the most common arch-test setups; MSTATUS.
  // MPRV still takes effect on effective privilege for memory accesses.
  logic [1:0] ioq_store_eff_priv;
  logic       pmp_store_bare_fault;
  logic       pmp_load_bare_fault;
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
      `RAPT_CBO_ZERO_WALU,
      `RAPT_CBO_MGMT_WALU: store_bare_size_m1 = 4'd0;
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
      .pmp_raw_addr  (pmp_state.pmp_raw_addr),
      .pmp_napot_mask(pmp_state.pmp_napot_mask),
      .pmp_cfg_r     (pmp_state.pmp_cfg_r),
      .pmp_cfg_w     (pmp_state.pmp_cfg_w),
      .pmp_cfg_x     (pmp_state.pmp_cfg_x),
      .pmp_cfg_l     (pmp_state.pmp_cfg_l),
      .pmp_mode_off  (pmp_state.pmp_mode_off),
      .pmp_mode_tor  (pmp_state.pmp_mode_tor),
      .pmp_mode_na4  (pmp_state.pmp_mode_na4),
      .pmp_mode_napot(pmp_state.pmp_mode_napot),
      .fault         (pmp_store_bare_fault),
      .fault_lo_o    ()
  );
  // Zicbom management operations are permitted when either an ordinary load
  // or an ordinary store is permitted.  Keep the two PMP predicates separate
  // so a read-only or write-only region is accepted as required.
  rapt_pmp u_pmp_load_for_cbo (
      .addr          (ioq_vj[ioq_head] + ioq_imm[ioq_head]),
      .size_m1       (store_bare_size_m1),
      .priv          (ioq_store_eff_priv),
      .op_r          (1'b1),
      .op_w          (1'b0),
      .op_x          (1'b0),
      .pmp_raw_addr  (pmp_state.pmp_raw_addr),
      .pmp_napot_mask(pmp_state.pmp_napot_mask),
      .pmp_cfg_r     (pmp_state.pmp_cfg_r),
      .pmp_cfg_w     (pmp_state.pmp_cfg_w),
      .pmp_cfg_x     (pmp_state.pmp_cfg_x),
      .pmp_cfg_l     (pmp_state.pmp_cfg_l),
      .pmp_mode_off  (pmp_state.pmp_mode_off),
      .pmp_mode_tor  (pmp_state.pmp_mode_tor),
      .pmp_mode_na4  (pmp_state.pmp_mode_na4),
      .pmp_mode_napot(pmp_state.pmp_mode_napot),
      .fault         (pmp_load_bare_fault),
      .fault_lo_o    ()
  );
  logic store_bare_pmp_trap;
  assign store_bare_pmp_trap = ioq_wen[ioq_head]
                               && !ioq_mmu_en[ioq_head]
                               && !csr_bcast.dmmu_en
                               && ((head_is_cbo_mgmt
                                      ? (pmp_store_bare_fault && pmp_load_bare_fault)
                                      : pmp_store_bare_fault)
                                   || !rapt_pkg::addr_mapped(
      ioq_vj[ioq_head] + ioq_imm[ioq_head]
  ));

  assign reservation_match = exu_l1d.reservation_valid
      && exu_l1d.reservation == (csr_bcast.dmmu_en
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
  assign exu_ioq_bcast.wen      = head_is_cbo_mgmt ? 1'b0
      : (ioq_atom[ioq_head] && ioq_alu[ioq_head] == `RAPT_ATO_SC__)
      ? (reservation_match ? 1 : 0)
      : (ioq_wen[ioq_head]);
  assign exu_ioq_bcast.alu = ioq_atom[ioq_head] ? {1'b0, head_store_walu} : ioq_alu[ioq_head];
  assign exu_ioq_bcast.sq_waddr = csr_bcast.dmmu_en
      ? ioq_paddr[ioq_head]
      : ioq_vj[ioq_head] + ioq_imm[ioq_head];
  assign sq_waddr_hi = (csr_bcast.dmmu_en && head_store_cross_page)
      ? ioq_paddr_hi[ioq_head]
      : {exu_ioq_bcast.sq_waddr[XLEN-1:$clog2(XLEN/8)], {$clog2(XLEN/8){1'b0}}}
        + XLEN'(XLEN/8);
  assign exu_ioq_bcast.sq_wdata = ioq_atom[ioq_head] ? head_amo_wdata
      : ((ioq_fp_valid[ioq_head] && ioq_fp_op[ioq_head] == `RAPT_FP_OP_FSW)
        ? fpr.ioq_rdata[XLEN-1:0]
        : ((ioq_fp_valid[ioq_head] && ioq_fp_op[ioq_head] == `RAPT_FP_OP_FSD)
          ? fpr.ioq_rdata[XLEN-1:0]
          : ((ioq_fp_valid[ioq_head] && ioq_fp_op[ioq_head] == `RAPT_FP_OP_ZFHMIN
              && ioq_wen[ioq_head])
            ? fpr.ioq_rdata[XLEN-1:0] : ioq_vk[ioq_head])));
  assign exu_ioq_bcast.sq_wdata64 = fpr.ioq_rdata;
  assign exu_ioq_bcast.sq_fp64 = ioq_fp_valid[ioq_head] && ioq_fp_op[ioq_head] == `RAPT_FP_OP_FSD;
  assign fpr.ioq_wvalid = exu_ioq_bcast.valid && ioq_fp_valid[ioq_head] && (ioq_fp_op[ioq_head] ==
      `RAPT_FP_OP_FLW
      || ioq_fp_op[ioq_head] == `RAPT_FP_OP_FLD
      || (ioq_fp_op[ioq_head] == `RAPT_FP_OP_ZFHMIN && ioq_ren[ioq_head]))
      && !head_trap_lsu;
  assign fpr.ioq_waddr = ioq_fp_rd[ioq_head];
  assign fpr.ioq_wdata = (ioq_fp_op[ioq_head] == `RAPT_FP_OP_FLD)
      ? ioq_fp_rdata64[ioq_head]
      : (ioq_fp_op[ioq_head] == `RAPT_FP_OP_ZFHMIN)
        ? {48'hffff_ffff_ffff, head_rdata[15:0]}
        : {32'hffff_ffff, head_rdata[31:0]};
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
      || (ioq_wen[ioq_head] && !head_is_cbo_mgmt && rapt_pkg::addr_mmio(
      exu_ioq_bcast.sq_waddr
  ));

  assign ioq_valid_found = (ioq_valid[ioq_head]
      && ioq_pr1[ioq_head] == 0 && ioq_pr2[ioq_head] == 0
      && !ioq_fp_dep2_busy[ioq_head]
      && (ioq_ren[ioq_head]
          ? head_load_done
          : ioq_mmu_en[ioq_head] == 0)
      && (!ioq_wen[ioq_head] || (ioq_mmu_en[ioq_head] == 0 && exu_lsu.stq_ready)));
  assign exu_ioq_bcast.valid = ioq_valid_found;
  assign exu_l1d.reservation_clear = ioq_valid_found
      && ioq_atom[ioq_head] && ioq_alu[ioq_head] == `RAPT_ATO_SC__;
  // MEM pipe never resolves branches nor writes CSRs (unified cdb_if
  // tie-offs; ROB keeps mispredict at its dispatch-init value of 0).
  assign exu_ioq_bcast.btaken = 1'b0;
  assign exu_ioq_bcast.mispredict = 1'b0;
  assign exu_ioq_bcast.csr_wen = 1'b0;
  assign exu_ioq_bcast.csr_wdata = '0;
  assign exu_ioq_bcast.fp_flags_valid = 1'b0;
  assign exu_ioq_bcast.fp_flags = '0;

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

  assign fast_load_fire = load_req_valid_q
      && exu_lsu.rready
      && (load_req_idx_q == ioq_head)
      && load_req_fast_eligible_q
      && !exu_lsu.trap
      && !exu_lsu.difftest_skip
      && (load_req_prd_q != '0);
  assign fast_load_confirm = fast_load_pending
      && exu_ioq_bcast.valid
      && (exu_ioq_bcast.prd == fast_load_prd_q);
  assign fast_load_rebusy = fast_load_pending && !fast_load_confirm;

  assign load_fast.valid = fast_load_fire || fast_load_rebusy;
  assign load_fast.rebusy = fast_load_rebusy;
  assign load_fast.prd = fast_load_rebusy ? fast_load_prd_q : load_req_prd_q;

  // === Sequential: enqueue / dequeue / forwarding / OoO LSU FSM ===
  logic ioq_full_r;  // Previous cycle full state (for pmu_ioq_full rising-edge detection)

  // --------------------------------------------------------------------------
  // Unified CDB view for operand forwarding.
  //
  // Value-producing writeback ports in forwarding-priority order:
  //   [0] MEM (self broadcast)   [1] ALU-CSR   [2] ALU   [3] MULDIV
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
      ioq_mmu_second    <= '0;
      ioq_valid         <= '0;
      ioq_head          <= '0;
      ioq_tail_a        <= '0;
      ioq_complete      <= '0;
      ioq_load_trap     <= '0;
      ioq_load_skip     <= '0;
      ioq_fp_dep2_busy  <= '0;
      oo_pending        <= 1'b0;
      oo_pending_idx    <= '0;
      load_req_valid_q  <= 1'b0;
      load_req_idx_q    <= '0;
      ioq_full_r        <= 1'b0;  // A2: Initialize full state tracker
      fast_load_pending <= 1'b0;
      fast_load_prd_q   <= '0;
      // Payload arrays (pc/vj/vk/imm/cause/rdata/...) are intentionally NOT
      // reset: every read is gated by ioq_valid[] / ioq_complete[] / the busy
      // bits, so the data flops are don't-care (same principle as rapt_prf).
      // pr1/pr2 likewise stay unreset: the older-store blocker reads them
      // inside ioq_valid[j] && ioq_wen[j], issue/head/valid_found checks are
      // valid-gated, and the resident forwarding flags are only consumed in
      // the `if (ioq_valid[i])` wakeup branch.  Every allocation rewrites
      // the pair before ioq_valid[i] is set.
    end else begin
      // A2: Latch current full status (rising-edge detection for pmu_ioq_full)
      ioq_full_r <= (&ioq_valid);  // Full when all entries valid
      if (fast_load_confirm || fast_load_rebusy) begin
        fast_load_pending <= 1'b0;
      end
      if (fast_load_fire) begin
        fast_load_pending <= 1'b1;
        fast_load_prd_q   <= load_req_prd_q;
      end

      // ---- Registered load-request pipeline ----
      // An occupied stage is held verbatim until the LSU response handshake.
      // Deliberately do not refill it on the handshake edge: ioq_complete for
      // the returning entry is written on that same edge, so the one-cycle
      // bubble also prevents the just-completed entry from being reselected.
      if (!load_req_valid_q) begin
        if (load_req_sel_valid) begin
          load_req_valid_q <= 1'b1;
          load_req_idx_q   <= load_req_sel_idx;
          load_req_addr_q  <= load_req_sel_addr;
          load_req_alu_q   <= ioq_atom[load_req_sel_idx]
              ? (ioq_word[load_req_sel_idx] ? `RAPT_ALU_LW__ : `RAPT_ALU_LD__)
              : ((ioq_fp_valid[load_req_sel_idx]
                    && ioq_fp_op[load_req_sel_idx] == `RAPT_FP_OP_FLD)
                  ? `RAPT_ALU_LD__
                  : ((ioq_fp_valid[load_req_sel_idx]
                        && ioq_fp_op[load_req_sel_idx] == `RAPT_FP_OP_FLW)
                      ? `RAPT_ALU_LW__ : ioq_alu[load_req_sel_idx][4:0]));
          load_req_atomic_q <= ioq_atom[load_req_sel_idx]
              && ioq_alu[load_req_sel_idx] == `RAPT_ATO_LR__;
          load_req_ordered_q <= (load_req_sel_idx == ioq_head) && ioq_at_rob_head;
          load_req_pc_q <= ioq_pc[load_req_sel_idx];
          load_req_fp64_q <= ioq_fp_valid[load_req_sel_idx]
              && ioq_fp_op[load_req_sel_idx] == `RAPT_FP_OP_FLD;
          load_req_fast_eligible_q <= !ioq_atom[load_req_sel_idx]
              && (ioq_rd[load_req_sel_idx] != '0);
          load_req_prd_q <= ioq_prd[load_req_sel_idx];
        end
      end else if (exu_lsu.rready) begin
        load_req_valid_q <= 1'b0;
      end
      // A translated MMU load can turn out to be MMIO even though its virtual
      // address looked like an ordinary kernel mapping when it was selected
      // out of order.  L1D parks such a request until `ordered` is asserted.
      // Promote the held request once it reaches both queue heads; otherwise
      // its issue-time ordered=0 snapshot can deadlock forever in L1D LD_A.
      if (load_req_valid_q && (load_req_idx_q == ioq_head) && ioq_at_rob_head)
        load_req_ordered_q <= 1'b1;
      // ---- Static per-entry enqueue mux (B > A on any selector alias) ----
      for (int i = 0; i < IOQ_SIZE; i++) begin
        if (disp_b_selects_entry(i)) begin
`ifdef RAPT_DUAL_ISSUE
          ioq_valid[i]        <= 1'b1;
          ioq_pc[i]           <= rou_exu.uop_b.pc;
          ioq_pr1[i]          <= wake_pr(rou_exu.pr1_b);
          ioq_pr2[i]          <= wake_pr(rou_exu.pr2_b);
          ioq_prd[i]          <= rou_exu.prd_b;
          ioq_rd[i]           <= rou_exu.uop_b.rd;
          ioq_c[i]            <= rou_exu.uop_b.c;
          ioq_word[i]         <= rou_exu.uop_b.word;
          ioq_alu[i]          <= rou_exu.uop_b.alu;
          ioq_vj[i]           <= wake_val(rou_exu.pr1_b, rou_exu.op1_b);
          ioq_vk[i]           <= wake_val(rou_exu.pr2_b, rou_exu.op2_b);
          ioq_dest[i]         <= rou_exu.dest_b;
          ioq_imm[i]          <= rou_exu.uop_b.imm;
          ioq_wen[i]          <= rou_exu.uop_b.wen;
          ioq_mmu_en[i]       <= csr_bcast.dmmu_en;
          ioq_mmu_second[i]   <= 1'b0;
          ioq_ren[i]          <= rou_exu.uop_b.ren;
          ioq_atom[i]         <= rou_exu.uop_b.atom;
          ioq_fp_valid[i]     <= rou_exu.uop_b.fp_valid;
          ioq_fp_op[i]        <= rou_exu.uop_b.fp_op;
          ioq_fp_rd[i]        <= rou_exu.uop_b.inst[11:7];
          ioq_fp_rs2[i]       <= rou_exu.uop_b.inst[24:20];
          ioq_fp_dep2_busy[i] <= rou_exu.fp_dep2_valid_b && !fp_wb_hit(rou_exu.fp_dep2_b);
          ioq_fp_dep2[i]      <= rou_exu.fp_dep2_b;
          ioq_trap[i]         <= rou_exu.uop_b.trap;
          ioq_complete[i]     <= 1'b0;
          ioq_load_trap[i]    <= 1'b0;
          ioq_load_skip[i]    <= 1'b0;
`endif
        end else if (disp.accept_a && i == int'(ioq_tail_a)) begin
          ioq_valid[i]        <= 1'b1;
          ioq_pc[i]           <= rou_exu.uop.pc;
          ioq_pr1[i]          <= wake_pr(rou_exu.pr1);
          ioq_pr2[i]          <= wake_pr(rou_exu.pr2);
          ioq_prd[i]          <= rou_exu.prd;
          ioq_rd[i]           <= rou_exu.uop.rd;
          ioq_c[i]            <= rou_exu.uop.c;
          ioq_word[i]         <= rou_exu.uop.word;
          ioq_alu[i]          <= rou_exu.uop.alu;
          ioq_vj[i]           <= wake_val(rou_exu.pr1, rou_exu.op1);
          ioq_vk[i]           <= wake_val(rou_exu.pr2, rou_exu.op2);
          ioq_dest[i]         <= rou_exu.dest;
          ioq_imm[i]          <= rou_exu.uop.imm;
          ioq_wen[i]          <= rou_exu.uop.wen;
          ioq_mmu_en[i]       <= csr_bcast.dmmu_en;
          ioq_mmu_second[i]   <= 1'b0;
          ioq_ren[i]          <= rou_exu.uop.ren;
          ioq_atom[i]         <= rou_exu.uop.atom;
          ioq_fp_valid[i]     <= rou_exu.uop.fp_valid;
          ioq_fp_op[i]        <= rou_exu.uop.fp_op;
          ioq_fp_rd[i]        <= rou_exu.uop.inst[11:7];
          ioq_fp_rs2[i]       <= rou_exu.uop.inst[24:20];
          ioq_fp_dep2_busy[i] <= rou_exu.fp_dep2_valid && !fp_wb_hit(rou_exu.fp_dep2);
          ioq_fp_dep2[i]      <= rou_exu.fp_dep2;
          ioq_trap[i]         <= rou_exu.uop.trap;
          ioq_complete[i]     <= 1'b0;
          ioq_load_trap[i]    <= 1'b0;
          ioq_load_skip[i]    <= 1'b0;
        end

        // Preserve the original NBA priority while keeping every IOQ array
        // update on this single static entry selector.
        if (exu_l1d.ready && ioq_mmu_en[ioq_head] && i == int'(ioq_head)) begin
          if (ioq_mmu_second[i]) begin
            ioq_paddr_hi[i]   <= exu_l1d.paddr;
            ioq_mmu_second[i] <= 1'b0;
            ioq_mmu_en[i]     <= 1'b0;
          end else begin
            ioq_paddr[i] <= exu_l1d.paddr;
            if (head_store_cross_page && !exu_l1d.trap) begin
              ioq_mmu_second[i] <= 1'b1;
            end else begin
              ioq_mmu_en[i] <= 1'b0;
            end
          end
          ioq_trap[i]  <= exu_l1d.trap;
          ioq_cause[i] <= exu_l1d.cause;
        end

        if (ioq_valid_found && i == int'(ioq_head)) begin
          ioq_wen[i]    <= 1'b0;
          ioq_mmu_en[i] <= 1'b0;
          ioq_mmu_second[i] <= 1'b0;
          ioq_trap[i]   <= 1'b0;
          ioq_ren[i]    <= 1'b0;
          ioq_valid[i]  <= 1'b0;
        end

        if (ioq_valid[i] && ioq_fp_dep2_busy[i]
            && ((exu_rou.valid && exu_rou.dest == ioq_fp_dep2[i])
              || (exu_rou_b.valid && exu_rou_b.dest == ioq_fp_dep2[i])
              || (exu_wb_mul.valid && exu_wb_mul.dest == ioq_fp_dep2[i])
              || (exu_ioq_bcast.valid && exu_ioq_bcast.dest == ioq_fp_dep2[i]))) begin
          ioq_fp_dep2_busy[i] <= 1'b0;
        end

        if (exu_lsu.rvalid && exu_lsu.rready && i == int'(active_idx)) begin
          ioq_rdata[i] <= exu_lsu.rdata;
          if (ioq_fp_valid[i] && ioq_fp_op[i] == `RAPT_FP_OP_FLD)
            ioq_fp_rdata64[i] <= exu_lsu.fp_rdata64;
          if (active_idx != ioq_head || !ioq_valid_found) begin
            ioq_complete[i]   <= 1'b1;
            ioq_load_trap[i]  <= exu_lsu.trap;
            ioq_load_cause[i] <= exu_lsu.cause;
            ioq_load_skip[i]  <= exu_lsu.difftest_skip;
          end
        end
`ifdef RAPT_LSU_HUM
        if (exu_lsu.rvalid_b && exu_lsu.rready_b
            && b_issue_idx != active_idx
            && !(ioq_valid_found && b_issue_idx == ioq_head)
            && i == int'(b_issue_idx)) begin
          ioq_rdata[i]      <= exu_lsu.rdata_b;
          ioq_complete[i]   <= 1'b1;
          ioq_load_trap[i]  <= 1'b0;
          ioq_load_cause[i] <= '0;
          ioq_load_skip[i]  <= 1'b0;
        end
`endif
        if (ioq_valid_found && i == int'(ioq_head)) begin
          ioq_complete[i]  <= 1'b0;
          ioq_load_trap[i] <= 1'b0;
          ioq_load_skip[i] <= 1'b0;
        end

        if (ioq_valid[i]) begin
          if ((|ioq_pr1[i]) && ioq_fwd1_hit[i]) begin
            ioq_vj[i]  <= ioq_fwd1_val[i];
            ioq_pr1[i] <= '0;
          end
          if ((|ioq_pr2[i]) && ioq_fwd2_hit[i]) begin
            ioq_vk[i]  <= ioq_fwd2_val[i];
            ioq_pr2[i] <= '0;
          end
        end
      end
`ifdef RAPT_DUAL_ISSUE
      // Tail pointer advance: 0 / 1 / 2 entries enqueued this cycle.
      if (disp.accept_a && disp.accept_b_paired) begin
        ioq_tail_a <= ioq_tail_a + 2'd2;
      end else if (disp.accept_a || disp.accept_b_alone) begin
        ioq_tail_a <= ioq_tail_a + 1'b1;
      end
`else
      if (disp.accept_a) ioq_tail_a <= ioq_tail_a + 1'b1;
`endif

      // ---- Head retire ----
      if (ioq_valid_found) begin
        ioq_head <= ioq_head + 1'b1;
      end

      // ---- OoO LSU scalar state ----
      // `oo_pending` means the registered A request has survived at least one
      // cycle without a response; only then may the optional HUM B port probe
      // a younger load.
      if (!load_req_valid_q || (exu_lsu.rvalid && exu_lsu.rready)) begin
        oo_pending <= 1'b0;
      end else if (!oo_pending && exu_lsu.rvalid && !exu_lsu.rready) begin
        oo_pending     <= 1'b1;
        oo_pending_idx <= load_req_idx_q;
      end
    end
  end

  // A2: PMU: one-cycle pulse on IOQ full rising edge
  assign pmu_ioq_full = (&ioq_valid) && !ioq_full_r;

endmodule
/* verilator lint_on PINCONNECTEMPTY */
