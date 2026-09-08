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
    parameter rapt_pkg::core_config_t Cfg = rapt_pkg::CoreConfig,
    parameter type SlotT = rapt_pkg::dispatch_slot_t,
    parameter int unsigned NumSlots = Cfg.dispatch_width,
    parameter int unsigned NumCompletions = Cfg.completion_ports,
    parameter type CompletionT = rapt_pkg::completion_t,
    parameter unsigned IOQ_SIZE = Cfg.ioq_entries,
    parameter unsigned ROB_SIZE = Cfg.rob_entries,
    parameter unsigned PLEN     = rapt_pkg::index_bits(Cfg.phys_regs),
    parameter unsigned RLEN     = rapt_pkg::index_bits(Cfg.arch_regs),
    parameter unsigned XLEN     = Cfg.xlen
) (
    input CompletionT completion[NumCompletions],
    input clock,
    input reset,

    cmu_bcast_if.in cmu_bcast,
    csr_bcast_if.in csr_bcast,
    pmp_state_if.in pmp_state,

    // Dispatch source (read-only view of rou_exu, drive accepts via disp.io)
    input SlotT dispatch[NumSlots],
    dpu_ioq_if.ioq disp,

    // Forwarding sources (other writeback buses)

    // Outputs to memory subsystem & ROB writeback
    lsu_pipe_if.master    exu_lsu,
    lsu_l1d_mmu_if.master exu_l1d,
    fpr_if.ioq            fpr,
    output CompletionT exu_ioq_bcast,
    input logic wb_accept,
    output logic [XLEN-1:0] sq_waddr_hi,
    output logic [XLEN-1:0] sq_waddr_third,
    output logic [2:0][1:0] sq_wpbmt,
    output logic sq_acquire, // valid with accepted store completion
    load_fast_if.source   load_fast,

    // A2: PMU: one-cycle pulse when IOQ becomes full
    /* verilator lint_off UNUSEDSIGNAL */
    output logic pmu_ioq_full
    /* verilator lint_on UNUSEDSIGNAL */
);
  localparam unsigned IOQLen = $clog2(IOQ_SIZE);
  localparam unsigned ROBLen = $clog2(ROB_SIZE);
  localparam unsigned GenBits = $bits(dispatch[0].generation);
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
  logic [GenBits-1:0] ioq_generation    [IOQ_SIZE];
  logic [    XLEN-1:0] ioq_imm          [IOQ_SIZE];

  logic [IOQ_SIZE-1:0] ioq_wen;
  logic [IOQ_SIZE-1:0] ioq_mmu_en;
  logic [IOQ_SIZE-1:0] ioq_trap;
  logic [IOQ_SIZE-1:0] ioq_mmu_fault;
  logic [XLEN-1:0] ioq_store_tval[IOQ_SIZE];
  logic [    XLEN-1:0] ioq_cause        [IOQ_SIZE];
  logic [    XLEN-1:0] ioq_paddr        [IOQ_SIZE];
  logic [    XLEN-1:0] ioq_paddr_hi     [IOQ_SIZE];
  logic [1:0] ioq_pbmt[IOQ_SIZE], ioq_pbmt_hi[IOQ_SIZE];
  logic [IOQ_SIZE-1:0] ioq_mmu_second;
  logic [IOQ_SIZE-1:0] ioq_ren;
  logic [IOQ_SIZE-1:0] ioq_atom;
  logic [IOQ_SIZE-1:0] ioq_acquire;
  logic [IOQ_SIZE-1:0] ioq_release;
  logic [IOQ_SIZE-1:0] ioq_fp_valid;
  logic [         5:0] ioq_fp_op        [IOQ_SIZE];
  logic [         4:0] ioq_fp_rd        [IOQ_SIZE];
  logic [         4:0] ioq_fp_rs2       [IOQ_SIZE];
  logic [IOQ_SIZE-1:0] ioq_fp_dep2_busy;
  logic [  ROBLen-1:0] ioq_fp_dep2      [IOQ_SIZE];
  logic [GenBits-1:0] ioq_fp_dep2_generation[IOQ_SIZE];

  function automatic logic fp_wb_hit(input logic [ROBLen-1:0] dep,
                                     input logic [GenBits-1:0] generation);
    fp_wb_hit = 1'b0;
    for (int p = 0; p < NumCompletions; p++)
    fp_wb_hit |= completion[p].valid && completion[p].dest == dep
        && completion[p].generation == generation;
  endfunction

  // OoO load completion tracking
  logic [IOQ_SIZE-1:0] ioq_complete;
  logic [IOQ_SIZE-1:0] ioq_load_trap;
  logic [IOQ_SIZE-1:0] ioq_load_skip;
  logic [    XLEN-1:0] ioq_rdata           [IOQ_SIZE];
  logic [        63:0] ioq_fp_rdata64      [IOQ_SIZE];
  logic [    XLEN-1:0] ioq_load_cause      [IOQ_SIZE];
  logic [XLEN-1:0] ioq_load_tval[IOQ_SIZE];

  logic                oo_pending;
  logic [  IOQLen-1:0] oo_pending_idx;
  logic [  IOQLen-1:0] ioq_issue_idx;
  logic                ioq_issue_found;
  logic [IOQ_SIZE-1:0] ioq_load_issue_vec;
  logic [IOQ_SIZE-1:0] ioq_older_memory_blk;

  // Registered A-channel request stage.  Besides holding the request stable
  // across LSU backpressure, this is the timing boundary between the IOQ's
  // age/hazard arbitration and the L1D/PMP/fast-wakeup response cone.
  logic                load_req_valid_q;
  logic [  IOQLen-1:0] load_req_idx_q;
  logic [    XLEN-1:0] load_req_addr_q;
  logic [         4:0] load_req_alu_q;
  logic                load_req_atomic_q;
  logic                load_req_release_q;
  logic                load_req_ordered_q;
  logic [    XLEN-1:0] load_req_pc_q;
  logic                load_req_fp64_q;
  logic                load_req_fast_eligible_q;
  logic [    PLEN-1:0] load_req_prd_q;

  logic                ioq_valid_found;
  logic                reservation_match;

  assign pmu_ioq_any_valid = |ioq_valid;
  assign pmu_ioq_all_full  = &ioq_valid;

  int alloc_slot[IOQ_SIZE];
  int unsigned allocation_count;
  for (genvar r = 0; r < NumSlots; r++)
    assign disp.ready[r] = !ioq_valid[(int'(ioq_tail_a)+r)%IOQ_SIZE];
  always_comb begin
    allocation_count = 0;
    for (int e = 0; e < IOQ_SIZE; e++) alloc_slot[e] = -1;
    for (int s = 0; s < NumSlots; s++)
    if (disp.accept[s]) begin
      alloc_slot[(int'(ioq_tail_a)+allocation_count)%IOQ_SIZE] = s;
      allocation_count++;
    end
  end


  // === IOQ effective address & older-store blocker ===
  // ioq_eff_addr is meaningful only for valid entries (all readers gate with
  // ioq_valid/complete; see older-store blocker and issue vectors below).
  logic [XLEN-1:0] ioq_eff_addr[IOQ_SIZE];
  logic [1:0] ioq_span_words[IOQ_SIZE];
  function automatic logic memory_words_overlap(
      input logic [XLEN-1:0] a, b, input logic [1:0] a_span, b_span, input logic page_only);
    logic [XLEN-WordOffBits-1:0] ab, ba;
    logic [PageOffBits-WordOffBits-1:0] page_ab, page_ba;
    ab = a[XLEN-1:WordOffBits] - b[XLEN-1:WordOffBits];
    ba = b[XLEN-1:WordOffBits] - a[XLEN-1:WordOffBits];
    page_ab = a[PageOffBits-1:WordOffBits] - b[PageOffBits-1:WordOffBits];
    page_ba = b[PageOffBits-1:WordOffBits] - a[PageOffBits-1:WordOffBits];
    // Either access may straddle a word/page boundary. Modular distances
    // preserve aliases across page-offset wrap without assuming contiguous PA.
    return page_only
        ? (page_ab <= (PageOffBits-WordOffBits)'(b_span)
           || page_ba <= (PageOffBits-WordOffBits)'(a_span))
        : (ab <= (XLEN-WordOffBits)'(b_span)
           || ba <= (XLEN-WordOffBits)'(a_span));
  endfunction
  always_comb begin
    for (int i = 0; i < IOQ_SIZE; i++) begin
      automatic logic [3:0] size_m1;
      ioq_eff_addr[i] = ioq_atom[i] ? ioq_vj[i] : ioq_vj[i] + ioq_imm[i];
      size_m1 = (4'd1 << ioq_alu[i][1:0]) - 4'd1;
      if (ioq_wen[i]) begin
        case (ioq_alu[i][4:0])
          `RAPT_SB_WSTRB: size_m1 = 0;
          `RAPT_SH_WSTRB: size_m1 = 1;
          `RAPT_SD_WSTRB: size_m1 = 7;
          default: size_m1 = 3;
        endcase
      end
      if (ioq_atom[i]) size_m1 = (XLEN == 32 || ioq_word[i]) ? 4'd3 : 4'd7;
      if (ioq_fp_valid[i] && (ioq_fp_op[i] == (`RAPT_FP_OP_FSD) || ioq_fp_op[i] == `RAPT_FP_OP_FLD))
        size_m1 = 7;
      ioq_span_words[i] = 2'((4'(ioq_eff_addr[i][WordOffBits-1:0]) + size_m1) >> WordOffBits);
    end
  end

  always_comb begin
    for (int i = 0; i < IOQ_SIZE; i++) begin
      ioq_older_memory_blk[i] = 1'b0;
      for (int j = 0; j < IOQ_SIZE; j++) begin
        automatic logic [$clog2(IOQ_SIZE):0] age_i;
        automatic logic [$clog2(IOQ_SIZE):0] age_j;
        age_i = ({1'b0, i[$clog2(IOQ_SIZE)-1:0]} - {1'b0, ioq_head}) &
            ((1 << $clog2(IOQ_SIZE)) - 1);
        age_j = ({1'b0, j[$clog2(IOQ_SIZE)-1:0]} - {1'b0, ioq_head}) &
            ((1 << $clog2(IOQ_SIZE)) - 1);
        // A younger load must not retain a value sampled before an LR.aq.
        // Hold both ordinary and hit-under-miss issue until that LR leaves
        // the IOQ after its load response. The shared issue vector gates A/B.
        // AMO/SC acquire requires ordering through the store drain as well;
        // this read-side barrier is specifically the LR acquire contract.
        if (ioq_valid[j] && ioq_acquire[j] && ioq_alu[j] == `RAPT_ATO_LR__ && age_j < age_i)
          ioq_older_memory_blk[i] = 1'b1;
        if (ioq_valid[j] && ioq_wen[j] && age_j < age_i) begin
          // Compare all touched words, not just the starting words. Under
          // translation only disjoint page-offset footprints prove non-aliasing.
          if (|ioq_pr1[j] || ioq_alu[j][4:0] ==
              `RAPT_CBO_ZERO_WALU
              || (ioq_valid[i] && memory_words_overlap(
                  ioq_eff_addr[j],
                  ioq_eff_addr[i],
                  ioq_span_words[j],
                  ioq_span_words[i],
                  csr_bcast.dmmu_en
              ))) begin
            ioq_older_memory_blk[i] = 1'b1;
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
  logic translated_ordered;
  assign translated_ordered = csr_bcast.menvcfg_pbmte && csr_bcast.dmmu_en;

  always_comb begin
    for (int i = 0; i < IOQ_SIZE; i++) begin
      ioq_load_issue_vec[i] = ioq_valid[i] && ioq_ren[i]
          && !ioq_complete[i]
          && (ioq_pr1[i] == 0) && (ioq_pr2[i] == 0)
          && !ioq_atom[i]
          && !ioq_older_memory_blk[i]
          && (!translated_ordered || (i == int'(ioq_head) && ioq_at_rob_head))
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
  logic head_store_addr_valid_q, head_store_check_valid_q;
  logic head_store_check_fault_q;
  logic [XLEN-1:0] head_store_check_tval_q, head_store_check_cause_q;
  logic store_bare_pmp_trap;
  logic head_atomic_pma_fault;
  logic head_zero_pma_fault;
  logic head_data_pma_fault, head_data_pma_fault_hi;
  logic [3:0] store_bare_fault_offset;
  assign head_is_atomic_ready = ioq_valid[ioq_head] && ioq_atom[ioq_head]
      && !ioq_complete[ioq_head]
      && head_store_addr_valid_q
      // AMO reads follow a successful write-side translation/PMP check.
      && (!ioq_wen[ioq_head] || (head_store_check_valid_q && !head_store_check_fault_q))
      && ioq_pr1[ioq_head] == 0 && ioq_pr2[ioq_head] == 0;

  logic [IOQLen-1:0] load_req_sel_idx;
  logic [XLEN-1:0] load_req_sel_addr;
  logic load_req_sel_valid;
  assign load_req_sel_idx = head_is_atomic_ready ? ioq_head : ioq_issue_idx;
  assign load_req_sel_addr = ioq_atom[load_req_sel_idx]
      ? ioq_vj[load_req_sel_idx]
      : ioq_vj[load_req_sel_idx] + ioq_imm[load_req_sel_idx];
  assign load_req_sel_valid = (head_is_atomic_ready || ioq_issue_found)
      && (!translated_ordered || (load_req_sel_idx == ioq_head && ioq_at_rob_head))
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
  assign exu_lsu.atomic_release = load_req_release_q;
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
  // RAPT_ATO_* opcodes in ioq_alu. Convert AMO/SC width from uop.execute.int_op.word.
  logic [4:0] head_store_walu;
  logic [4:0] head_store_walu_sel;
`ifdef RAPT_RV64
  assign head_store_walu_sel = ioq_atom[ioq_head]
        ? (ioq_word[ioq_head] ? `RAPT_SW_WSTRB : `RAPT_SD_WSTRB)
        : ioq_alu[ioq_head][4:0];
`else
  assign head_store_walu_sel = ioq_atom[ioq_head] ? `RAPT_SW_WSTRB : ioq_alu[ioq_head][4:0];
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
  logic [3:0] head_store_size_sel;
  logic head_store_cross_page;
  logic [12:0] head_store_page_end;
  always_comb begin
    unique case (head_store_walu_sel)
      `RAPT_SB_WSTRB: head_store_size_sel = 4'd1;
      `RAPT_SH_WSTRB: head_store_size_sel = 4'd2;
      `RAPT_SW_WSTRB: head_store_size_sel = 4'd4;
      `RAPT_SD_WSTRB: head_store_size_sel = 4'd8;
      `RAPT_CBO_ZERO_WALU,
      `RAPT_CBO_MGMT_WALU: head_store_size_sel = 4'd1;
      default:        head_store_size_sel = 4'd4;
    endcase
    if ((XLEN == 32) && ioq_fp_valid[ioq_head] && ioq_fp_op[ioq_head] == `RAPT_FP_OP_FSD)
      head_store_size_sel = 4'd8;
  end
  // The resident head owns these fields through translation, access checking
  // and completion. Capture LR metadata too, since its completion uses the
  // same atomic width encoding. Flush/head removal invalidate both stages.
  always_ff @(posedge clock) begin
    if (reset || cmu_bcast.flush_pipe || ioq_valid_found) begin
      head_store_addr_valid_q <= 1'b0;
    end else if (!head_store_addr_valid_q && ioq_valid[ioq_head]
        && (ioq_wen[ioq_head] || ioq_atom[ioq_head])
        && ioq_pr1[ioq_head] == 0 && ioq_pr2[ioq_head] == 0) begin
      head_store_addr_valid_q <= 1'b1;
      head_store_vaddr <= ioq_vj[ioq_head] + ioq_imm[ioq_head];
      head_store_walu <= head_store_walu_sel;
      head_store_size <= head_store_size_sel;
    end
  end
  assign head_store_last_vaddr = head_store_vaddr + XLEN'(head_store_size - 1'b1);
  // Stores are at most eight bytes: only the page-offset carry decides
  // whether a second translation is needed, including virtual-address wrap.
  assign head_store_page_end = {1'b0, head_store_vaddr[11:0]}
      + 13'(head_store_size) - 13'd1;
  assign head_store_cross_page = head_store_page_end[12];
  assign head_store_hi_vaddr = {head_store_last_vaddr[XLEN-1:12], 12'b0};
  // Validate each resolved physical fragment, not a fictitious contiguous PA
  // range spanning independently translated virtual pages. Translation and
  // PMP faults retain priority; no speculative SQ entry is allocated here.
  logic [3:0] head_store_lo_bytes, head_store_hi_bytes;
  logic head_data_pma_check, head_data_pma_lo_ok, head_data_pma_hi_ok;
  logic [3:0] head_data_pma_lo_offset, head_data_pma_hi_offset;
  assign head_store_lo_bytes = head_store_cross_page
      ? 4'(13'd4096 - {1'b0, head_store_vaddr[11:0]}) : head_store_size;
  assign head_store_hi_bytes = head_store_size - head_store_lo_bytes;
  assign head_data_pma_check = ioq_wen[ioq_head] && csr_bcast.dmmu_en
      && !ioq_mmu_en[ioq_head] && !head_is_cbo_mgmt;
  assign head_data_pma_lo_offset = !rapt_pkg::addr_device_width_capable(
      ioq_paddr[ioq_head], head_store_size - 4'd1) ? 4'd0 : rapt_pkg::addr_data_span_fault_offset(
      ioq_paddr[ioq_head], head_store_lo_bytes - 4'd1, 1'b1);
  assign head_data_pma_hi_offset = !rapt_pkg::addr_device_width_capable(
      ioq_paddr_hi[ioq_head], head_store_size - 4'd1) ? 4'd0 : rapt_pkg::addr_data_span_fault_offset(
      ioq_paddr_hi[ioq_head], head_store_hi_bytes - 4'd1, 1'b1);
  assign head_data_pma_lo_ok = head_data_pma_lo_offset == 8;
  assign head_data_pma_hi_ok = !head_store_cross_page || head_data_pma_hi_offset == 8;
  assign head_data_pma_fault = head_data_pma_check
      && (!head_data_pma_lo_ok || !head_data_pma_hi_ok);
  assign head_data_pma_fault_hi = head_data_pma_check
      && head_data_pma_lo_ok && !head_data_pma_hi_ok;
  // AMO/SC write translation must finish before checking physical capability.
  // Even an SC with no matching reservation follows this access-fault policy.
  assign head_atomic_pma_fault = ioq_atom[ioq_head] && ioq_wen[ioq_head]
      && !ioq_mmu_en[ioq_head]
      && !rapt_pkg::addr_atomic_capable(
          csr_bcast.dmmu_en ? ioq_paddr[ioq_head] : head_store_vaddr,
          head_store_size - 4'd1);
  // Permission to store one byte does not imply permission to clear a block.
  // Check only the resolved physical address, before allocating the SQ owner
  // that would expand this operation into multiple committed writes.
  assign head_zero_pma_fault = ioq_wen[ioq_head] && !ioq_mmu_en[ioq_head]
      && head_store_walu == `RAPT_CBO_ZERO_WALU
      && !rapt_pkg::addr_zero_capable(
          csr_bcast.dmmu_en ? ioq_paddr[ioq_head] : head_store_vaddr);

  // === MMU for Store at head ===
  assign exu_l1d.mmu_en = (ioq_wen[ioq_head]
      && head_store_addr_valid_q
      && ioq_mmu_en[ioq_head]
      && ioq_pr1[ioq_head] == 0 && ioq_pr2[ioq_head] == 0);
  assign exu_l1d.vaddr = ioq_mmu_second[ioq_head]
      ? head_store_hi_vaddr : head_store_vaddr;
  assign exu_l1d.walu = head_store_walu;
  assign exu_l1d.misaligned = |(head_store_vaddr & XLEN'(head_store_size - 1'b1));
  assign exu_l1d.cmo_mgmt = head_is_cbo_mgmt;
  assign exu_l1d.valid = head_store_addr_valid_q && ioq_wen[ioq_head];

  rapt_ioq_store_check #(
      .XLEN(XLEN)
  ) u_store_check (
      .csr_bcast(csr_bcast),
      .pmp_state(pmp_state),
      .store_addr(head_store_vaddr),
      .store_size_m1(head_store_size - 4'd1),
      .store_valid(head_store_addr_valid_q && ioq_wen[ioq_head]),
      .store_mmu(ioq_mmu_en[ioq_head]),
      .cmo_mgmt(head_is_cbo_mgmt),
      .store_bare_fault_offset(store_bare_fault_offset),
      .store_bare_pmp_trap(store_bare_pmp_trap)
  );

  // Exact LR byte set. A smaller SC may target any naturally aligned
  // subrange, but no SC byte may extend beyond the most recent LR.
  logic [XLEN-1:0] sc_paddr;
  logic [3:0] sc_size_m1;
  assign sc_paddr = csr_bcast.dmmu_en ? ioq_paddr[ioq_head]
      : (ioq_vj[ioq_head] + ioq_imm[ioq_head]);
  assign sc_size_m1 = (ioq_word[ioq_head] || XLEN == 32) ? 4'd3 : 4'd7;
  assign reservation_match = exu_l1d.reservation_valid
      && sc_paddr >= exu_l1d.reservation
      && ({1'b0, sc_paddr} + (XLEN+1)'(sc_size_m1))
          <= ({1'b0, exu_l1d.reservation} + (XLEN+1)'(exu_l1d.reservation_size_m1));

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
  logic head_amo_less_signed, head_amo_less_unsigned;
  // AMO.W comparisons use only the low 32 bits of both operands. In RV64,
  // load data is sign-extended but rs2 may contain arbitrary upper bits.
  assign head_amo_less_signed = ioq_word[ioq_head]
      ? $signed(head_rdata[31:0]) < $signed(ioq_vk[ioq_head][31:0])
      : $signed(head_rdata) < $signed(ioq_vk[ioq_head]);
  assign head_amo_less_unsigned = ioq_word[ioq_head]
      ? head_rdata[31:0] < ioq_vk[ioq_head][31:0]
      : head_rdata < ioq_vk[ioq_head];
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
      head_amo_wdata = head_amo_less_signed ? head_rdata : ioq_vk[ioq_head];
      `RAPT_ATO_MAX_:
      head_amo_wdata = head_amo_less_signed ? ioq_vk[ioq_head] : head_rdata;
      `RAPT_ATO_MINU:
      head_amo_wdata = head_amo_less_unsigned ? head_rdata : ioq_vk[ioq_head];
      `RAPT_ATO_MAXU:
      head_amo_wdata = head_amo_less_unsigned ? ioq_vk[ioq_head] : head_rdata;
      default: head_amo_wdata = 'b0;
    endcase
  end

  // === Writeback (IOQ -> ROB) ===
  assign sq_acquire = ioq_acquire[ioq_head];
  assign exu_ioq_bcast.pc = ioq_pc[ioq_head];
  assign exu_ioq_bcast.npc = exu_ioq_bcast.trap ? csr_bcast.tvec
      : ioq_pc[ioq_head] + (ioq_c[ioq_head] ? 2 : 4);
  assign exu_ioq_bcast.result   = (ioq_atom[ioq_head] && ioq_alu[ioq_head] == `RAPT_ATO_SC__)
      ? (reservation_match ? 0 : 1)
      : (ioq_ren[ioq_head] ? head_rdata : ioq_vk[ioq_head]);
  assign exu_ioq_bcast.dest = ioq_dest[ioq_head];
  assign exu_ioq_bcast.generation = ioq_generation[ioq_head];
  assign exu_ioq_bcast.prd = ioq_prd[ioq_head];
  assign exu_ioq_bcast.rd = ioq_rd[ioq_head];
  assign exu_ioq_bcast.wen      = (head_is_cbo_mgmt || exu_ioq_bcast.trap
      || (ioq_wen[ioq_head] && !head_store_check_valid_q)) ? 1'b0
      : (ioq_atom[ioq_head] && ioq_alu[ioq_head] == `RAPT_ATO_SC__)
      ? (reservation_match ? 1 : 0)
      : (ioq_wen[ioq_head]);
  assign exu_ioq_bcast.alu = ioq_atom[ioq_head] ? {1'b0, head_store_walu} : ioq_alu[ioq_head];
  assign exu_ioq_bcast.sq_waddr = csr_bcast.dmmu_en
      ? ioq_paddr[ioq_head]
      : head_store_vaddr;
  // The next aligned beat need not be on the second page: an unaligned
  // RV32 FSD can span three words with only its third word crossing pages.
  logic [XLEN-1:0] store_beat_vaddr[3];
  logic [XLEN-1:0] store_beat_paddr[3];
  for (genvar beat = 0; beat < 3; beat++) begin : gen_store_beat_translation
    localparam int unsigned BeatOffset = beat * (XLEN / 8);
    assign store_beat_vaddr[beat] = {head_store_vaddr[XLEN-1:$clog2(
        XLEN/8
    )], {$clog2(
        XLEN / 8
    ) {1'b0}}} + XLEN'(BeatOffset);
    logic second_page;
    assign second_page = store_beat_vaddr[beat][XLEN-1:12] != head_store_vaddr[XLEN-1:12];
    assign store_beat_paddr[beat] = csr_bcast.dmmu_en
        ? {second_page ? ioq_paddr_hi[ioq_head][XLEN-1:12] : ioq_paddr[ioq_head][XLEN-1:12],
           store_beat_vaddr[beat][11:0]} : store_beat_vaddr[beat];
    assign sq_wpbmt[beat] = csr_bcast.dmmu_en
        ? (second_page ? ioq_pbmt_hi[ioq_head] : ioq_pbmt[ioq_head]) : 2'b00;
  end
  assign sq_waddr_hi = store_beat_paddr[1];
  assign sq_waddr_third = store_beat_paddr[2];
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
  assign fpr.ioq_wvalid = wb_accept && exu_ioq_bcast.valid
      && ioq_fp_valid[ioq_head] && (ioq_fp_op[ioq_head] ==
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
  // AMOs report store/AMO exceptions while retaining page/access/alignment
  // classification. A rejected write translation completes without a read.
  logic head_is_amo_rw;
  logic head_store_fault;
  logic head_store_fault_d;
  logic [XLEN-1:0] head_amo_load_cause;
  assign head_is_amo_rw = ioq_atom[ioq_head]
                          && (ioq_alu[ioq_head] != `RAPT_ATO_LR__)
                          && (ioq_alu[ioq_head] != `RAPT_ATO_SC__);
  assign head_store_fault_d = ioq_wen[ioq_head]
      && (ioq_trap[ioq_head] || store_bare_pmp_trap
          || head_atomic_pma_fault || head_zero_pma_fault || head_data_pma_fault);
  assign head_store_fault = head_store_check_valid_q && head_store_check_fault_q;
  // Do not feed PMP/PMA decoding into atomic issue, completion arbitration,
  // other execution units and operand wakeup in the same cycle.
  always_ff @(posedge clock) begin
    if (reset || cmu_bcast.flush_pipe || ioq_valid_found) begin
      head_store_check_valid_q <= 1'b0;
    end else if (!head_store_check_valid_q && head_store_addr_valid_q
        && ioq_valid[ioq_head] && ioq_wen[ioq_head] && !ioq_mmu_en[ioq_head]) begin
      head_store_check_valid_q <= 1'b1;
      head_store_check_fault_q <= head_store_fault_d;
      head_store_check_cause_q <= ioq_trap[ioq_head]
          ? ioq_cause[ioq_head] : `RAPT_CAUSE_STORE_ACC_FAULT;
      head_store_check_tval_q <= ioq_mmu_fault[ioq_head] ? ioq_store_tval[ioq_head]
          : head_data_pma_fault_hi ? head_store_hi_vaddr + XLEN'(head_data_pma_hi_offset)
          : head_data_pma_fault ? head_store_vaddr + XLEN'(head_data_pma_lo_offset)
          : store_bare_pmp_trap ? head_store_vaddr + XLEN'(store_bare_fault_offset)
          : ioq_eff_addr[ioq_head];
    end
  end
  always_comb begin
    case (head_cause_lsu)
      `RAPT_CAUSE_LOAD_PAGE_FAULT: head_amo_load_cause = `RAPT_CAUSE_STORE_PAGE_FAULT;
      `RAPT_CAUSE_LOAD_MISALIGNED: head_amo_load_cause = `RAPT_CAUSE_STORE_MISALIGNED;
      default: head_amo_load_cause = `RAPT_CAUSE_STORE_ACC_FAULT;
    endcase
  end
  assign exu_ioq_bcast.trap = head_store_fault
      || (ioq_ren[ioq_head] && head_trap_lsu);
  assign exu_ioq_bcast.tval = head_store_fault
      ? head_store_check_tval_q
      : ((ioq_ren[ioq_head] && head_trap_lsu)
          ? ioq_load_tval[ioq_head] : ioq_eff_addr[ioq_head]);
  assign exu_ioq_bcast.cause = head_store_fault
      ? head_store_check_cause_q
      : (head_is_amo_rw ? head_amo_load_cause : head_cause_lsu);
  // Rejected accesses have no device side effect to synchronize. Preserve
  // reference execution for their precise exception and destination checks.
  assign exu_ioq_bcast.difftest_skip = !exu_ioq_bcast.trap && (
      (ioq_ren[ioq_head] && head_skip_lsu)
      || (ioq_wen[ioq_head] && !head_is_cbo_mgmt && rapt_pkg::addr_mmio(
      exu_ioq_bcast.sq_waddr
  )));

  assign ioq_valid_found = (!(ioq_atom[ioq_head] && ioq_alu[ioq_head] == `RAPT_ATO_SC__
          && exu_l1d.reservation_blocked) && ioq_valid[ioq_head]
      && ioq_pr1[ioq_head] == 0 && ioq_pr2[ioq_head] == 0
      && !ioq_fp_dep2_busy[ioq_head]
      && (!ioq_wen[ioq_head] || head_store_check_valid_q)
      && (ioq_ren[ioq_head]
          ? (head_load_done || (head_is_amo_rw && head_store_fault))
          : ioq_mmu_en[ioq_head] == 0)
      && (!ioq_wen[ioq_head] || (ioq_mmu_en[ioq_head] == 0 && exu_lsu.stq_ready)));
  assign exu_ioq_bcast.valid = ioq_valid_found;
  assign exu_l1d.reservation_clear = wb_accept && ioq_valid_found
      && ioq_atom[ioq_head] && ioq_alu[ioq_head] == `RAPT_ATO_SC__;
  // MEM pipe never resolves branches nor writes CSRs (uniform completion
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
  logic [ROBLen-1:0] fast_load_dest_q;
  logic [GenBits-1:0] fast_load_generation_q;
  logic [RLEN-1:0] fast_load_rd_q;
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
  assign load_fast.dest = fast_load_rebusy ? fast_load_dest_q : ioq_dest[load_req_idx_q];
  assign load_fast.generation = fast_load_rebusy
      ? fast_load_generation_q : ioq_generation[load_req_idx_q];
  assign load_fast.rd = fast_load_rebusy ? fast_load_rd_q : ioq_rd[load_req_idx_q];

  // === Sequential: enqueue / dequeue / forwarding / OoO LSU FSM ===
  logic ioq_full_r;  // Previous cycle full state (for pmu_ioq_full rising-edge detection)

  // --------------------------------------------------------------------------
  // Unified CDB view for operand forwarding.
  //
  // Value-producing writeback ports in forwarding-priority order:
  // All sources use one typed completion array.
  localparam int unsigned NWB = NumCompletions;
  logic            wb_valid [NWB];
  logic [PLEN-1:0] wb_prd   [NWB];
  logic [XLEN-1:0] wb_result[NWB];
  for (genvar p = 0; p < NWB; p++) begin : g_completion_view
    assign wb_valid[p] = completion[p].valid;
    assign wb_prd[p] = completion[p].prd;
    assign wb_result[p] = completion[p].result;
  end

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
      ioq_mmu_fault     <= '0;
      ioq_load_skip     <= '0;
      ioq_fp_dep2_busy  <= '0;
      oo_pending        <= 1'b0;
      oo_pending_idx    <= '0;
      load_req_valid_q  <= 1'b0;
      load_req_idx_q    <= '0;
      ioq_full_r        <= 1'b0;  // A2: Initialize full state tracker
      fast_load_pending <= 1'b0;
      fast_load_prd_q   <= '0;
      fast_load_dest_q  <= '0;
      fast_load_generation_q <= '0;
      fast_load_rd_q    <= '0;
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
        fast_load_dest_q  <= ioq_dest[load_req_idx_q];
        fast_load_generation_q <= ioq_generation[load_req_idx_q];
        fast_load_rd_q    <= ioq_rd[load_req_idx_q];
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
          load_req_release_q <= ioq_release[load_req_sel_idx];
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
        if (alloc_slot[i] >= 0) begin
          ioq_valid[i]        <= 1'b1;
          ioq_pc[i]           <= dispatch[alloc_slot[i]].uop.pc;
          ioq_pr1[i]          <= wake_pr(dispatch[alloc_slot[i]].pr1);
          ioq_pr2[i]          <= wake_pr(dispatch[alloc_slot[i]].pr2);
          ioq_prd[i]          <= dispatch[alloc_slot[i]].prd;
          ioq_rd[i]           <= dispatch[alloc_slot[i]].uop.rd;
          ioq_c[i]            <= dispatch[alloc_slot[i]].uop.c;
          ioq_word[i]         <= dispatch[alloc_slot[i]].uop.execute.int_op.word;
          ioq_alu[i]          <= dispatch[alloc_slot[i]].uop.execute.int_op.alu;
          ioq_vj[i]           <= wake_val(dispatch[alloc_slot[i]].pr1, dispatch[alloc_slot[i]].op1);
          ioq_vk[i]           <= wake_val(dispatch[alloc_slot[i]].pr2, dispatch[alloc_slot[i]].op2);
          ioq_dest[i]         <= dispatch[alloc_slot[i]].dest;
          ioq_generation[i]   <= dispatch[alloc_slot[i]].generation;
          ioq_imm[i]          <= dispatch[alloc_slot[i]].uop.imm;
          ioq_wen[i]          <= dispatch[alloc_slot[i]].uop.execute.memory.store;
          ioq_mmu_en[i]       <= csr_bcast.dmmu_en;
          ioq_mmu_second[i]   <= 1'b0;
          ioq_pbmt[i]         <= 2'b00;
          ioq_pbmt_hi[i]      <= 2'b00;
          ioq_ren[i]          <= dispatch[alloc_slot[i]].uop.execute.memory.load;
          ioq_atom[i]         <= dispatch[alloc_slot[i]].uop.execute.memory.atomic;
          ioq_release[i] <= dispatch[alloc_slot[i]].uop.execute.memory.atomic
              && dispatch[alloc_slot[i]].uop.inst[25];
          ioq_acquire[i] <= dispatch[alloc_slot[i]].uop.execute.memory.atomic
              && dispatch[alloc_slot[i]].uop.inst[26];
          ioq_fp_valid[i]     <= dispatch[alloc_slot[i]].uop.execute.fp.valid;
          ioq_fp_op[i]        <= dispatch[alloc_slot[i]].uop.execute.fp.op;
          ioq_fp_rd[i]        <= dispatch[alloc_slot[i]].uop.inst[11:7];
          ioq_fp_rs2[i]       <= dispatch[alloc_slot[i]].uop.inst[24:20];
          ioq_fp_dep2_busy[i] <= dispatch[alloc_slot[i]].dep_valid[1]
              && !fp_wb_hit(dispatch[alloc_slot[i]].dep_tag[1],
                            dispatch[alloc_slot[i]].dep_generation[1]);
          ioq_fp_dep2[i]      <= dispatch[alloc_slot[i]].dep_tag[1];
          ioq_fp_dep2_generation[i] <= dispatch[alloc_slot[i]].dep_generation[1];
          ioq_trap[i]         <= dispatch[alloc_slot[i]].uop.trap;
          ioq_mmu_fault[i]    <= 1'b0;
          ioq_complete[i]     <= 1'b0;
          ioq_load_trap[i]    <= 1'b0;
          ioq_load_skip[i]    <= 1'b0;
        end

        // Preserve the original NBA priority while keeping every IOQ array
        // update on this single static entry selector.
        if (exu_l1d.ready && ioq_mmu_en[ioq_head] && i == int'(ioq_head)) begin
          if (ioq_mmu_second[i]) begin
            ioq_paddr_hi[i]   <= exu_l1d.paddr;
            ioq_pbmt_hi[i]    <= exu_l1d.pbmt;
            ioq_mmu_second[i] <= 1'b0;
            ioq_mmu_en[i]     <= 1'b0;
          end else begin
            ioq_paddr[i] <= exu_l1d.paddr;
            ioq_pbmt[i]  <= exu_l1d.pbmt;
            if (head_store_cross_page && !exu_l1d.trap) begin
              ioq_mmu_second[i] <= 1'b1;
            end else begin
              ioq_mmu_en[i] <= 1'b0;
            end
          end
          ioq_trap[i]  <= exu_l1d.trap;
          ioq_cause[i] <= exu_l1d.cause;
          ioq_mmu_fault[i] <= exu_l1d.trap;
          ioq_store_tval[i] <= exu_l1d.vaddr;
        end

        if (ioq_valid_found && i == int'(ioq_head)) begin
          ioq_wen[i]    <= 1'b0;
          ioq_mmu_en[i] <= 1'b0;
          ioq_mmu_second[i] <= 1'b0;
          ioq_trap[i]   <= 1'b0;
          ioq_ren[i]    <= 1'b0;
          ioq_valid[i]  <= 1'b0;
        end

        if (ioq_valid[i] && ioq_fp_dep2_busy[i] && fp_wb_hit(
                ioq_fp_dep2[i], ioq_fp_dep2_generation[i]
            )) begin
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
            ioq_load_tval[i] <= exu_lsu.tval;
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
      ioq_tail_a <= IOQLen'((int'(ioq_tail_a) + allocation_count) % IOQ_SIZE);

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

  assign exu_ioq_bcast.updates = '{memory:1'b1, exception:1'b1, default:'0};
  assign load_fast.confirmed = exu_ioq_bcast.valid;
  assign load_fast.confirmed_prd = exu_ioq_bcast.prd;
  assign load_fast.confirmed_dest = exu_ioq_bcast.dest;
  assign load_fast.confirmed_generation = exu_ioq_bcast.generation;
  assign load_fast.confirmed_rd = exu_ioq_bcast.rd;
  assign load_fast.result = exu_ioq_bcast.result;
  `RAPT_SVA_IMPLY(clock, reset, IOQ_STORE_COMPLETION_CHECKED,
                  exu_ioq_bcast.valid && ioq_wen[ioq_head], head_store_check_valid_q)
  `RAPT_SVA_IMPLY(clock, reset, IOQ_STORE_MMU_ADDRESS_CAPTURED, exu_l1d.mmu_en,
                  head_store_addr_valid_q)
  `RAPT_SVA_NEXT(clock, reset, IOQ_STORE_STAGES_FLUSH_CLEAR, cmu_bcast.flush_pipe,
                 !head_store_addr_valid_q && !head_store_check_valid_q)
endmodule
/* verilator lint_on PINCONNECTEMPTY */
