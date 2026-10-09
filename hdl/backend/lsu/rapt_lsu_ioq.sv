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
//   * One held lookup; cacheable misses may park in MSHRs and replay after wake
//   * Atomics and uncached MMIO loads serialize at head only
//   * Stores always wait at head (no speculative writes)
/* verilator lint_off PINCONNECTEMPTY */
module rapt_lsu_ioq #(
    parameter rapt_pkg::core_config_t Cfg               = rapt_pkg::CoreConfig,
    parameter type                    SlotT             = rapt_pkg::dispatch_slot_t,
    parameter int unsigned            NumSlots          = Cfg.dispatch_width,
    parameter int unsigned            NumCompletions    = Cfg.completion_ports,
    parameter type                    CompletionT       = rapt_pkg::completion_t,
    parameter unsigned                IOQ_SIZE          = Cfg.ioq_entries,
    parameter unsigned                ROB_SIZE          = Cfg.rob_entries,
    parameter unsigned                PLEN              = rapt_pkg::index_bits(Cfg.phys_regs),
    parameter unsigned                RLEN              = rapt_pkg::index_bits(Cfg.arch_regs),
    parameter unsigned                XLEN              = Cfg.xlen,
    parameter bit                     RegisterAddresses = 1'b1
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
    lsu_pipe_if.master exu_lsu,
    lsu_l1d_mmu_if.master exu_l1d,
    fpr_if.ioq fpr,
    output CompletionT exu_ioq_bcast,
    input logic wb_accept,
    output logic sq_handoff_valid,
    output logic sq_forward_pending,
    output logic [4:0] sq_handoff_alu,
    output logic [XLEN-1:0] sq_waddr_hi,
    output logic [XLEN-1:0] sq_waddr_third,
    output logic [2:0][1:0] sq_wpbmt,
    output rapt_pkg::mem_context_t sq_context,
    output logic sq_acquire,  // valid with accepted store completion
    load_fast_if.source load_fast,

    // A2: PMU: one-cycle pulse when IOQ becomes full
    /* verilator lint_off UNUSEDSIGNAL */
    output logic pmu_ioq_full
    /* verilator lint_on UNUSEDSIGNAL */
);
  localparam unsigned IOQLen = $clog2(IOQ_SIZE);
  // Head-relative age and next-entry indices rely on IOQLen-bit wrap-around.
  if (!(IOQ_SIZE > 1 && (IOQ_SIZE & (IOQ_SIZE - 1)) == 0)) begin : g_invalid_ioq_size
    $error("IOQ_SIZE must be a power of two greater than one");
  end
  localparam unsigned ROBLen = $clog2(ROB_SIZE);
  localparam unsigned GenBits = $bits(dispatch[0].generation);
  localparam unsigned WordOffBits = $clog2(XLEN / 8);
  localparam unsigned PageOffBits = 12;
  // A completion is architectural only while its IOQ owner survives this
  // cycle. Keep the kill decision common to load, store and early load paths.
  wire completion_kill = reset || cmu_bcast.flush_pipe;

  // === IOQ state ===
  logic [IOQ_SIZE-1:0] ioq_valid;
  // Width-stable occupancy probes for the C++ PMU. Reading ioq_valid through
  // a uint8_t silently truncated configurations with more than eight entries,
  // while comparing it with 8'hff never detected full 2/4-entry queues.
  logic pmu_ioq_any_valid  /*verilator public_flat_rd*/;
  logic pmu_ioq_all_full  /*verilator public_flat_rd*/;
  logic [IOQLen-1:0] ioq_tail_a;
  logic [IOQLen-1:0] ioq_head;

  logic [XLEN-1:0] ioq_pc[IOQ_SIZE];

  logic [PLEN-1:0] ioq_pr1[IOQ_SIZE];
  logic [PLEN-1:0] ioq_pr2[IOQ_SIZE];
  logic [PLEN-1:0] ioq_prd[IOQ_SIZE];
  logic [RLEN-1:0] ioq_rd[IOQ_SIZE];

  logic ioq_c[IOQ_SIZE];
  /* verilator lint_off UNUSEDSIGNAL */
  logic ioq_word[IOQ_SIZE];  // reserved for RV64 sub-word
  /* verilator lint_on UNUSEDSIGNAL */
  // Request ownership is also consulted by replay tracking and selection.
  logic b_req_valid_q;
  logic [IOQLen-1:0] b_req_idx_q;
  logic [$clog2(IOQ_SIZE)-1:0] active_idx;

  logic [5:0] ioq_alu[IOQ_SIZE];
  logic [XLEN-1:0] ioq_vj[IOQ_SIZE];
  logic [XLEN-1:0] ioq_vk[IOQ_SIZE];
  logic [ROBLen-1:0] ioq_dest[IOQ_SIZE];
  logic [GenBits-1:0] ioq_generation[IOQ_SIZE];
  logic [XLEN-1:0] ioq_imm[IOQ_SIZE];

  logic [IOQ_SIZE-1:0] ioq_wen;
  logic [IOQ_SIZE-1:0] ioq_mmu_en;
  rapt_pkg::mem_context_t ioq_context[IOQ_SIZE];
  rapt_pkg::mem_context_t dispatch_context;
  logic [7:0] mem_context_version_q;
  logic mem_context_invalidate;
  assign mem_context_invalidate = cmu_bcast.fence_time
      || (cmu_bcast.flush_pipe && (cmu_bcast.time_trap
          || !(cmu_bcast.ben || cmu_bcast.jen || cmu_bcast.jren
               || cmu_bcast.atomic_retired)));
  always_ff @(posedge clock) begin
    if (reset) mem_context_version_q <= '0;
    else if (mem_context_invalidate) mem_context_version_q <= mem_context_version_q + 1'b1;
  end
  assign dispatch_context = '{
          mmu_en: csr_bcast.dmmu_en,
          eff_priv:
          (
          csr_bcast.priv == `RAPT_PRIV_M && csr_bcast.mprv
          ) ?
          csr_bcast.mpp
          :
          csr_bcast.priv,
          sum: csr_bcast.sum,
          mxr: csr_bcast.mxr,
          pbmte: csr_bcast.menvcfg_pbmte,
          asid: csr_bcast.satp_asid,
          version: mem_context_version_q
      };
  logic [IOQ_SIZE-1:0] ioq_trap;
  logic [IOQ_SIZE-1:0] ioq_mmu_fault;
  logic [    XLEN-1:0] ioq_store_tval[IOQ_SIZE];
  logic [    XLEN-1:0] ioq_cause     [IOQ_SIZE];
  logic [    XLEN-1:0] ioq_paddr     [IOQ_SIZE];
  logic [    XLEN-1:0] ioq_paddr_hi  [IOQ_SIZE];
  logic [1:0] ioq_pbmt[IOQ_SIZE], ioq_pbmt_hi[IOQ_SIZE];
  logic [IOQ_SIZE-1:0] ioq_mmu_second;
  logic [IOQ_SIZE-1:0] ioq_ren;
  logic [IOQ_SIZE-1:0] ioq_atom;
  logic [IOQ_SIZE-1:0] ioq_acquire;
  logic [IOQ_SIZE-1:0] ioq_release;
  logic [IOQ_SIZE-1:0] ioq_fp_valid;
  logic [         5:0] ioq_fp_op            [IOQ_SIZE];
  logic [         4:0] ioq_fp_rd            [IOQ_SIZE];
  logic [         4:0] ioq_fp_rs2           [IOQ_SIZE];

  // OoO load completion tracking
  logic [IOQ_SIZE-1:0] ioq_complete;
  logic [IOQ_SIZE-1:0] ioq_load_trap;
  logic [IOQ_SIZE-1:0] ioq_load_skip;
  logic [    XLEN-1:0] ioq_rdata            [IOQ_SIZE];
  logic [        63:0] ioq_fp_rdata64       [IOQ_SIZE];
  logic [    XLEN-1:0] ioq_load_cause       [IOQ_SIZE];
  logic [    XLEN-1:0] ioq_load_tval        [IOQ_SIZE];

  logic                oo_pending;
  logic [  IOQLen-1:0] oo_pending_idx;
  logic [  IOQLen-1:0] ioq_issue_idx;
  logic                ioq_issue_found;
  logic [IOQ_SIZE-1:0] ioq_load_issue_vec;
  logic [IOQ_SIZE-1:0] ioq_older_memory_blk;
  logic [IOQ_SIZE-1:0] ioq_fwd1_hit;
  logic [IOQ_SIZE-1:0] ioq_fwd2_hit;
  logic [    XLEN-1:0] ioq_fwd1_val         [IOQ_SIZE];
  logic [    XLEN-1:0] ioq_fwd2_val         [IOQ_SIZE];

  // Registered A-channel request stage. This is the single timing boundary
  // between a stored base operand (plus combinational AGU/overlap/select)
  // and a stable L1D request. Nonzero offsets capture the sum on the same
  // edge. Zero-offset/atomic addresses skip the adder.
  logic                load_req_valid_q;
  logic [IOQ_SIZE-1:0] ioq_needs_ordered;
  logic [IOQ_SIZE-1:0] ioq_miss_wait;
  always_ff @(posedge clock) begin
    if (reset || cmu_bcast.flush_pipe) ioq_miss_wait <= '0;
    else begin
      if (exu_lsu.miss_wake) ioq_miss_wait <= '0;
      if (exu_lsu.rvalid && exu_lsu.rmiss) ioq_miss_wait[active_idx] <= !exu_lsu.miss_wake;
    end
  end
  logic                   [IOQLen-1:0] load_req_idx_q;
  logic                   [  XLEN-1:0] load_req_addr_q;
  logic                   [       4:0] load_req_alu_q;
  logic                                load_req_atomic_q;
  logic                                load_req_release_q;
  logic                                load_req_ordered_q;
  logic                   [  XLEN-1:0] load_req_pc_q;
  rapt_pkg::mem_context_t              load_req_context_q;
  logic                                load_req_fp64_q;
  logic                   [  PLEN-1:0] load_req_prd_q;

  logic                                ioq_valid_found;
  logic                                reservation_match;

  assign pmu_ioq_any_valid = |ioq_valid;
  assign pmu_ioq_all_full  = &ioq_valid;

  int alloc_slot[IOQ_SIZE];
  int unsigned allocation_count;
  // Admission credit is updated at the same edge as queue ownership.  In
  // particular, a load response can only change the next cycle's credit;
  // it cannot feed back through DPU/ROU dispatch in its completion cycle.
  // This count includes every accepted entry, so no speculative skid slot is
  // needed and dual-slot dispatch still sustains one accepted prefix/cycle.
  logic [IOQLen:0] ioq_free_q;
  for (genvar r = 0; r < NumSlots; r++) begin : g_disp_ready
    assign disp.ready[r] = ioq_free_q > (IOQLen + 1)'(r);
  end
  always_ff @(posedge clock) begin
    if (reset || cmu_bcast.flush_pipe) ioq_free_q <= (IOQLen + 1)'(IOQ_SIZE);
    else
      ioq_free_q <= ioq_free_q + (IOQLen + 1)'(ioq_valid_found) - (IOQLen + 1)'(allocation_count);
  end
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
  // Prepared virtual addresses are owned by queue entries. An unprepared
  // older store blocks loads; both load issue channels require addr_ready.
  logic [XLEN-1:0] ioq_eff_addr[IOQ_SIZE];
  logic [IOQ_SIZE-1:0] ioq_addr_ready;
  for (genvar e = 0; e < IOQ_SIZE; e++) begin : g_address
    if (RegisterAddresses) begin : g_registered
      // Ordinary addresses pass through one preparation register before
      // dependence checking and request selection. Atomic addresses use the
      // base directly because their effective offset is always zero.
      logic prepared;
      logic [XLEN-1:0] prepared_addr;
      // Keep the address adder behind the preparation register. Unprepared
      // entries cannot issue or prove a store disjoint from a younger load.
      assign ioq_eff_addr[e]   = ioq_atom[e] ? ioq_vj[e] : (prepared ? prepared_addr : '0);
      assign ioq_addr_ready[e] = ioq_valid[e] && ioq_pr1[e] == '0 && (ioq_atom[e] || prepared);
      always_ff @(posedge clock) begin
        if (reset || cmu_bcast.flush_pipe || (ioq_valid_found && ioq_head == IOQLen'(e))) begin
          prepared <= 1'b0;
        end else if (alloc_slot[e] >= 0) begin
          // Ready dispatch operands can enter the address register directly;
          // do not spend an otherwise idle resident cycle rediscovering that
          // the base tag was already clear at allocation.
          if (!dispatch[alloc_slot[e]].uop.execute.memory.atomic
              && (dispatch[alloc_slot[e]].pr1 == '0
                  || wb_hit(
                  dispatch[alloc_slot[e]].pr1
              ))) begin
            // The enqueue snoop clears pr1 on this edge. Prepare the same
            // forwarded base so that this load is eligible next cycle.
            prepared_addr <= wake_val(
                dispatch[alloc_slot[e]].pr1, dispatch[alloc_slot[e]].op1
            ) + dispatch[alloc_slot[e]].uop.imm;
            prepared <= 1'b1;
          end else begin
            prepared <= 1'b0;
          end
        end else if (ioq_valid[e] && !ioq_atom[e] && !prepared
          && (ioq_pr1[e] == '0 || ioq_fwd1_hit[e])) begin
          // Capture on the wake edge as well. This remains a registered
          // CDB-to-address boundary and removes the extra post-wakeup bubble.
          prepared_addr <= (ioq_fwd1_hit[e] ? ioq_fwd1_val[e] : ioq_vj[e]) + ioq_imm[e];
          prepared <= 1'b1;
        end
      end
    end else begin : g_combinational
      assign ioq_eff_addr[e]   = ioq_atom[e] ? ioq_vj[e] : ioq_vj[e] + ioq_imm[e];
      assign ioq_addr_ready[e] = ioq_valid[e] && ioq_pr1[e] == '0;
    end
  end
  logic [1:0] ioq_span_words[IOQ_SIZE];
  logic [IOQ_SIZE-1:0] ioq_overlap[IOQ_SIZE];
  rapt_ioq_overlap #(
      .Xlen(XLEN),
      .Entries(IOQ_SIZE),
      .WordOffBits(WordOffBits),
      .PageOffBits(PageOffBits)
  ) overlap_check (
      .addr(ioq_eff_addr),
      .span(ioq_span_words),
      .page_only(ioq_context[ioq_head].mmu_en),
      .overlap(ioq_overlap)
  );
  always_comb begin
    for (int i = 0; i < IOQ_SIZE; i++) begin
      automatic logic [3:0] size_m1;
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

  // Sample disambiguation after a load has a stable prepared address.
  logic [IOQ_SIZE-1:0] ioq_older_memory_blk_comb;
  always_comb begin
    for (int i = 0; i < IOQ_SIZE; i++) begin
      ioq_older_memory_blk_comb[i] = 1'b0;
      for (int j = 0; j < IOQ_SIZE; j++) begin
        automatic logic [$clog2(IOQ_SIZE):0] age_i;
        automatic logic [$clog2(IOQ_SIZE):0] age_j;
        age_i = ({1'b0, i[$clog2(IOQ_SIZE)-1:0]} - {1'b0, ioq_head}) &
            ((1 << $clog2(IOQ_SIZE)) - 1);
        age_j = ({1'b0, j[$clog2(IOQ_SIZE)-1:0]} - {1'b0, ioq_head}) &
            ((1 << $clog2(IOQ_SIZE)) - 1);
        // Any acquire atomic is a read-side barrier: a younger load must not
        // retain data sampled before the atomic completes. Gate both A and B
        // issue until the older acquire leaves the IOQ. Store-side ordering
        // and drain rules remain independent of this issue gate.
        if (ioq_valid[j] && ioq_atom[j] && ioq_acquire[j] && age_j < age_i)
          ioq_older_memory_blk_comb[i] = 1'b1;
        if (ioq_valid[j] && ioq_wen[j] && age_j < age_i) begin
          // Compare all touched words, not just the starting words. Under
          // translation only disjoint page-offset footprints prove non-aliasing.
          if (!ioq_addr_ready[j] || ioq_alu[j][4:0] ==
              `RAPT_CBO_ZERO_WALU
              || (ioq_valid[i] && ioq_overlap[j][i])) begin
            ioq_older_memory_blk_comb[i] = 1'b1;
          end
        end
      end
    end
  end

  // A completed younger load waits for a sampled older-store blocker before
  // early completion. Ordinary load request issue keeps the live check to
  // preserve throughput.
  logic [IOQ_SIZE-1:0] early_bcast_memory_blk;
  begin : g_overlap_stage
    logic [IOQ_SIZE-1:0] blocked_q, ready_q;
    logic page_only_q;
    always_ff @(posedge clock) begin
      if (reset || cmu_bcast.flush_pipe) begin
        ready_q <= '0;
        page_only_q <= 1'b0;
      end else begin
        page_only_q <= ioq_context[ioq_head].mmu_en;
        for (int e = 0; e < IOQ_SIZE; e++) begin
          blocked_q[e] <= ioq_older_memory_blk_comb[e];
          // Reused slots and newly prepared addresses need a fresh sample.
          ready_q[e]   <= ioq_valid[e] && ioq_addr_ready[e] && alloc_slot[e] < 0;
        end
      end
    end
    for (genvar e = 0; e < IOQ_SIZE; e++) begin : g_entry
      assign early_bcast_memory_blk[e] = !ready_q[e]
          || page_only_q != ioq_context[ioq_head].mmu_en || blocked_q[e];
    end
  end
  assign ioq_older_memory_blk = ioq_older_memory_blk_comb;

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
      ioq_load_issue_vec[i] = ioq_addr_ready[i] && !ioq_miss_wait[i] && ioq_ren[i]
          && (ioq_pr1[i] == 0)
          && !ioq_complete[i]
          && (ioq_pr2[i] == 0)
          && !ioq_atom[i]
          && !ioq_older_memory_blk[i]
          && (!ioq_needs_ordered[i] || (i == int'(ioq_head) && ioq_at_rob_head))
          && (!(ioq_context[i].pbmte && ioq_context[i].mmu_en)
              || (i == int'(ioq_head) && ioq_at_rob_head))
          && (ioq_context[i].mmu_en
              || (ioq_valid[i] && rapt_pkg::addr_cacheable(ioq_eff_addr[i])) ||
          (i[$clog2(IOQ_SIZE)-1:0] == ioq_head && ioq_at_rob_head));
    end
  end

  always_comb begin
    ioq_issue_idx   = ioq_head;
    ioq_issue_found = 1'b0;
    for (int k = 0; k < IOQ_SIZE; k++) begin
      automatic logic [$clog2(IOQ_SIZE)-1:0] idx;
      automatic logic request_pending;
      idx = ioq_head + k[$clog2(IOQ_SIZE)-1:0];
      request_pending = load_req_valid_q && idx == load_req_idx_q;
`ifdef RAPT_LSU_HUM
      request_pending |= b_req_valid_q && idx == b_req_idx_q;
`endif
      if (!ioq_issue_found && ioq_load_issue_vec[idx] && !request_pending) begin
        ioq_issue_idx   = idx;
        ioq_issue_found = 1'b1;
      end
    end
  end

  // Atomics preempt ordinary loads at the request-stage input.  Completed
  // atomics must not be restaged during the cycle before head writeback.
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
      && ioq_addr_ready[ioq_head]
      && !ioq_complete[ioq_head]
      && head_store_addr_valid_q
      // AMO reads follow a successful write-side translation/PMP check.
      && (!ioq_wen[ioq_head] || (head_store_check_valid_q && !head_store_check_fault_q))
      && ioq_pr1[ioq_head] == 0 && ioq_pr2[ioq_head] == 0;

  logic [IOQLen-1:0] load_req_sel_idx;
  logic [XLEN-1:0] load_req_sel_addr;
  logic load_req_sel_valid;
  logic [IOQLen-1:0] wake_next_idx;
  logic [XLEN-1:0] wake_next_addr;
  logic wake_next_req_valid;
  logic dispatch_memory_found;
  logic dispatch_load_found;
  logic [XLEN-1:0] dispatch_load_addr;
  logic [XLEN-1:0] dispatch_load_pc;
  logic [4:0] dispatch_load_alu;
  logic dispatch_load_fp64;
  logic [PLEN-1:0] dispatch_load_prd;
  always_comb begin
    dispatch_memory_found = 1'b0;
    dispatch_load_found = 1'b0;
    dispatch_load_addr = '0;
    dispatch_load_pc = '0;
    dispatch_load_alu = '0;
    dispatch_load_fp64 = 1'b0;
    dispatch_load_prd = '0;
    for (int s = 0; s < NumSlots; s++) begin
      automatic logic [XLEN-1:0] candidate_addr;
      // Only a base captured before the current completion broadcast may
      // use this allocation-edge AGU. Freshly woken operands use the resident
      // address stage, keeping completion -> dispatch -> add out of this path.
      candidate_addr = dispatch[s].stable_op1 + dispatch[s].uop.imm;
      if (!dispatch_memory_found
          && !(|ioq_valid) && disp.accept[s]
          && dispatch[s].uop.execute.memory.load
          && !dispatch[s].uop.execute.memory.store
          && !dispatch[s].uop.execute.memory.atomic
          && dispatch[s].stable_op1_valid
          && dispatch[s].pr1 == '0 && dispatch[s].pr2 == '0
          && !dispatch[s].uop.trap && !dispatch_context.mmu_en
          && rapt_pkg::addr_cacheable(
              candidate_addr
          )) begin
        dispatch_load_found = 1'b1;
        dispatch_load_addr = candidate_addr;
        dispatch_load_pc = dispatch[s].uop.pc;
        dispatch_load_alu = (dispatch[s].uop.execute.fp.valid
            && dispatch[s].uop.execute.fp.op == `RAPT_FP_OP_FLD)
            ?
        `RAPT_ALU_LD__
        : (dispatch[s].uop.execute.fp.valid && dispatch[s].uop.execute.fp.op == `RAPT_FP_OP_FLW) ?
            `RAPT_ALU_LW__ : dispatch[s].uop.execute.int_op.alu[4:0];
        dispatch_load_fp64 = dispatch[s].uop.execute.fp.valid
            && dispatch[s].uop.execute.fp.op == `RAPT_FP_OP_FLD;
        dispatch_load_prd = dispatch[s].prd;
      end
      if (disp.accept[s]) dispatch_memory_found = 1'b1;
    end
  end
  // A returning completion may wake another IOQ load on this edge. Its
  // forwarded base and immediate can enter the existing request register
  // directly, alongside the prepared-address register, instead of waiting
  // another cycle for the resident tag to clear. Selection and ordering
  // checks below decide which forwarded request may enter the stage.
  begin : g_forward_request
    // Compute each resident candidate and its store blockers in parallel.
    // Age selection consumes only eligibility bits; no selected address feeds
    // another wide comparison. Keep the oldest eligible candidate even when
    // blocked, preserving the existing request order and cycle behavior.
    localparam int PickLeaves = 1 << IOQLen;
    wire [IOQLen-1:0] age[IOQ_SIZE];
    wire [XLEN-1:0] forward_addr[2*IOQ_SIZE];
    wire [1:0] forward_span[2*IOQ_SIZE];
    wire [2*IOQ_SIZE-1:0] forward_overlap[2*IOQ_SIZE];
    wire [IOQ_SIZE-1:0] eligible, selected, blocked, forward_cacheable;
    wire [XLEN+IOQLen-1:0] pick_tree[2*PickLeaves];
    rapt_ioq_overlap #(
        .Xlen(XLEN),
        .Entries(2*IOQ_SIZE),
        .WordOffBits(WordOffBits),
        .PageOffBits(PageOffBits)
    ) forward_overlap_check (
        .addr(forward_addr),
        .span(forward_span),
        // Blocking is conservative: an alias of the page offset just sends
        // the load through the ordinary request path. Only the low address
        // bits of the forwarded sum reach this decision.
        .page_only(1'b1),
        .overlap(forward_overlap)
    );
    for (genvar e = 0; e < IOQ_SIZE; e++) begin : g_candidate
      wire [IOQ_SIZE-1:0] older_eligible, older_blocked;
      assign age[e] = IOQLen'(e) - ioq_head;
      wire [XLEN-1:0] request_base = fwd_req_val(ioq_pr1[e], ioq_vj[e]);
      assign forward_addr[e] = request_base + ioq_imm[e];
      assign forward_span[e] = 2'((4'(forward_addr[e][WordOffBits-1:0])
          + ((4'd1 << ioq_alu[e][1:0]) - 4'd1)) >> WordOffBits);
      assign forward_addr[IOQ_SIZE+e] = ioq_eff_addr[e];
      assign forward_span[IOQ_SIZE+e] = ioq_span_words[e];
      assign eligible[e] = !ioq_issue_found && !head_is_atomic_ready
          && ioq_valid[e] && ioq_ren[e] && !ioq_wen[e] && !ioq_atom[e] && !ioq_fp_valid[e]
          && !ioq_complete[e] && !ioq_trap[e] && !ioq_miss_wait[e]
          && !ioq_needs_ordered[e] && !ioq_context[e].mmu_en
          && ioq_pr1[e] != '0 && fwd_req_hit(ioq_pr1[e]) && ioq_pr2[e] == '0
          && !(load_req_valid_q && load_req_idx_q == IOQLen'(e))
          && !(b_req_valid_q && b_req_idx_q == IOQLen'(e));
      // The formed address only qualifies the chosen candidate. Choosing
      // among tag-eligible entries keeps the address adder, cacheability and
      // store-overlap checks off the index and payload selection.
      // Qualify the base instead of the sum: any 12-bit offset from a base
      // inside the shrunken PMEM window stays cacheable. Bases near region
      // edges simply use the ordinary request path.
      assign forward_cacheable[e] = rapt_pkg::addr_pmem_offset_safe(request_base);
      for (genvar o = 0; o < IOQ_SIZE; o++) begin : g_older
        assign older_eligible[o] = age[o] < age[e] && eligible[o];
        assign older_blocked[o] = ioq_valid[o] && age[o] < age[e]
            && (ioq_atom[o] || (ioq_wen[o]
                && (!ioq_addr_ready[o] || ioq_context[o].mmu_en
                    || ioq_alu[o][4:0] == `RAPT_CBO_ZERO_WALU
                    || forward_overlap[e][IOQ_SIZE+o])));
      end
      assign selected[e] = eligible[e] && !(|older_eligible);
      assign blocked[e] = |older_blocked;
      assign pick_tree[PickLeaves+e] =
          {(XLEN+IOQLen){selected[e]}} & {IOQLen'(e), forward_addr[e]};
    end
    for (genvar e = IOQ_SIZE; e < PickLeaves; e++) begin : g_pad
      assign pick_tree[PickLeaves+e] = '0;
    end
    for (genvar node = 1; node < PickLeaves; node++) begin : g_select_tree
      assign pick_tree[node] = pick_tree[2*node] | pick_tree[2*node+1];
    end
    assign wake_next_idx = (|eligible) ? pick_tree[1][XLEN+:IOQLen] : ioq_head;
    assign wake_next_addr = pick_tree[1][XLEN-1:0];
    assign wake_next_req_valid = |(selected & ~blocked & forward_cacheable);
    wire selected_onehot = $onehot0(selected);
    `RAPT_SVA_IMPLY(clock, reset, FORWARDED_REQUEST_ONEHOT, !cmu_bcast.flush_pipe, selected_onehot)
  end
  logic [IOQLen-1:0] resident_req_idx;
  assign resident_req_idx = head_is_atomic_ready ? ioq_head : ioq_issue_idx;
  assign load_req_sel_idx = (head_is_atomic_ready || ioq_issue_found)
      ? resident_req_idx : wake_next_idx;
  // Resident and forwarding candidates are mutually exclusive. Select the
  // payload with the same early owner decision as load_req_sel_idx; late
  // overlap/cacheability checks qualify only the request's valid bit.
  assign load_req_sel_addr = (head_is_atomic_ready || ioq_issue_found)
      ? ioq_eff_addr[resident_req_idx] : wake_next_addr;
  // Keep resident validation independent of the forwarded candidate index.
  // A forwarded address has already passed its own checks; feeding its index
  // through the resident mux needlessly repeats those checks on the late path.
  assign load_req_sel_valid = wake_next_req_valid || ((head_is_atomic_ready || ioq_issue_found)
      && !(load_req_valid_q && resident_req_idx == load_req_idx_q)
      && (!ioq_needs_ordered[resident_req_idx]
          || (resident_req_idx == ioq_head && ioq_at_rob_head))
      && (!(ioq_context[resident_req_idx].pbmte && ioq_context[resident_req_idx].mmu_en)
          || (resident_req_idx == ioq_head && ioq_at_rob_head))
      && !ioq_miss_wait[resident_req_idx]
      && ioq_addr_ready[resident_req_idx]
      && (ioq_pr1[resident_req_idx] == 0)
      && ioq_ren[resident_req_idx]
      && !ioq_complete[resident_req_idx]
      && ioq_pr1[resident_req_idx] == 0 && ioq_pr2[resident_req_idx] == 0
      && (ioq_context[resident_req_idx].mmu_en
          || rapt_pkg::addr_cacheable(
      ioq_eff_addr[resident_req_idx]
  ) || (resident_req_idx == ioq_head && ioq_at_rob_head)));

  assign active_idx = load_req_idx_q;

  // === LSU output ===
  // All fields come from the same register bank and remain stable until the
  // response handshake.  This is a deliberate one-cycle issue pipeline.
  assign exu_lsu.rvalid = load_req_valid_q;
  assign exu_lsu.raddr = load_req_addr_q;
  assign exu_lsu.rcontext = load_req_context_q;
  assign exu_lsu.ralu = load_req_alu_q;
  assign exu_lsu.fp_rdata64_req = load_req_fp64_q;
  assign exu_lsu.atomic_lock = load_req_atomic_q;
  assign exu_lsu.atomic_release = load_req_release_q;
  assign exu_lsu.ordered = load_req_ordered_q;
  assign exu_lsu.pc = load_req_pc_q;

  assign fpr.ioq_raddr = ioq_fp_rs2[ioq_head];
  // The fixed IOQ FPR port reads at the clock edge. A new head, or a cycle
  // occupied by an FPR write, must wait for its own sampled store operand.
  wire head_fpr_ready = !(ioq_fp_valid[ioq_head] && ioq_wen[ioq_head]) || fpr.ioq_rvalid;

  // === Best-effort B lookahead issue (RAPT_LSU_HUM) ===
  // While A owns a request, offer the next eligible load (in age order,
  // skipping both pending owners) on B. Besides hit-under-miss, L1D can use
  // this request to pre-read the data SRAM on A's hit-response cycle. B is
  // best-effort: it completes only on a clean L1D hit or SQ forward; anything
  // else remains in the IOQ and retries through A later.
  // Register the candidate before the SQ/PMP/cache probe, as on A: otherwise
  // address generation, disambiguation, selection and cache admission form
  // one combinational path. Hold its identity and payload until B completes
  // or the A miss ends. ioq_load_issue_vec enforces operand readiness,
  // non-atomic issue and older-store disambiguation before capture.
  logic early_bcast_select, early_bcast_issue;
  logic [IOQLen-1:0] early_bcast_idx;
`ifdef RAPT_LSU_HUM
  logic [$clog2(IOQ_SIZE)-1:0] b_issue_idx;
  logic b_issue_found;
  logic [XLEN-1:0] b_req_addr_q;
  rapt_pkg::mem_context_t b_req_context_q;
  logic [4:0] b_req_alu_q;
  logic a_req_holds;
  assign a_req_holds = load_req_valid_q && !(exu_lsu.rready || exu_lsu.rretry || exu_lsu.rmiss);
  always_comb begin
    b_issue_idx   = ioq_head;
    b_issue_found = 1'b0;
    for (int k = 0; k < IOQ_SIZE; k++) begin
      automatic logic [$clog2(IOQ_SIZE)-1:0] idx;
      idx = ioq_head + k[$clog2(IOQ_SIZE)-1:0];
      if (!b_issue_found && ioq_load_issue_vec[idx] && ioq_addr_ready[idx]
          && !(load_req_valid_q && idx == load_req_idx_q)
          && !(b_req_valid_q && idx == b_req_idx_q) && !ioq_atom[idx]
          // B has no FP64 response payload/capture. Keep FLD on A in both
          // XLENs rather than completing it with an unwritten FPR payload.
          && !(ioq_fp_valid[idx] && ioq_fp_op[idx] == `RAPT_FP_OP_FLD)) begin
        b_issue_idx   = idx;
        b_issue_found = 1'b1;
      end
    end
  end
  always_ff @(posedge clock) begin
    if (reset || cmu_bcast.flush_pipe) begin
      b_req_valid_q <= 1'b0;
    end else if (b_req_valid_q) begin
      if (exu_lsu.rready_b || exu_lsu.rretry_b) begin
        b_req_valid_q <= 1'b0;
        if (a_req_holds && b_issue_found) begin
          b_req_valid_q <= 1'b1;
          b_req_idx_q <= b_issue_idx;
          b_req_addr_q <= ioq_eff_addr[b_issue_idx];
          b_req_context_q <= ioq_context[b_issue_idx];
          b_req_alu_q <= ioq_alu[b_issue_idx][4:0];
        end
      end
    end else if (a_req_holds && b_issue_found) begin
      b_req_valid_q <= 1'b1;
      b_req_idx_q <= b_issue_idx;
      b_req_addr_q <= ioq_eff_addr[b_issue_idx];
      b_req_context_q <= ioq_context[b_issue_idx];
      b_req_alu_q <= ioq_alu[b_issue_idx][4:0];
    end
  end
  assign exu_lsu.rvalid_b = b_req_valid_q;
  assign exu_lsu.raddr_b = b_req_addr_q;
  assign exu_lsu.rcontext_b = b_req_context_q;
  assign exu_lsu.ralu_b = b_req_alu_q;
  // Antecedent extracted so the SVA macro argument stays short and the
  // formatter cannot rejoin it past the column limit.
  logic ioq_b_request_stable;
  assign ioq_b_request_stable = exu_lsu.rvalid_b && !exu_lsu.rready_b && !exu_lsu.rretry_b
      && !(exu_lsu.rvalid && (exu_lsu.rready || exu_lsu.rretry || exu_lsu.rmiss));
  `RAPT_SVA_NEXT(clock, reset || cmu_bcast.flush_pipe, IOQ_B_REQUEST_STABLE, ioq_b_request_stable,
                 exu_lsu.rvalid_b && $stable({b_req_idx_q, b_req_addr_q, b_req_alu_q}))
  `RAPT_SVA_IMPLY(clock, reset, IOQ_AB_OWNERS_DISTINCT, load_req_valid_q && b_req_valid_q,
                  load_req_idx_q != b_req_idx_q)
`else
  assign b_req_valid_q = 1'b0;
  assign b_req_idx_q = '0;
  assign exu_lsu.rvalid_b = 1'b0;
  assign exu_lsu.raddr_b = '0;
  assign exu_lsu.rcontext_b = '0;
  assign exu_lsu.ralu_b = '0;
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
  logic [XLEN-1:12] head_store_hi_page_q;
  logic [3:0] head_store_size;
  logic [3:0] head_store_size_sel;
  logic head_store_cross_page;
  logic [12:0] head_store_page_end;
  always_comb begin
    unique case (head_store_walu_sel)
      `RAPT_SB_WSTRB:                           head_store_size_sel = 4'd1;
      `RAPT_SH_WSTRB:                           head_store_size_sel = 4'd2;
      `RAPT_SW_WSTRB:                           head_store_size_sel = 4'd4;
      `RAPT_SD_WSTRB:                           head_store_size_sel = 4'd8;
      `RAPT_CBO_ZERO_WALU, `RAPT_CBO_MGMT_WALU: head_store_size_sel = 4'd1;
      default:                                  head_store_size_sel = 4'd4;
    endcase
    if ((XLEN == 32) && ioq_fp_valid[ioq_head] && ioq_fp_op[ioq_head] == `RAPT_FP_OP_FSD)
      head_store_size_sel = 4'd8;
  end
  // Addresses are already prepared per IOQ entry. Reuse that stable value
  // at the head rather than recomputing and registering it a second time.
  // Permission/translation checking and its result register remain intact.
  assign head_store_addr_valid_q = !reset && !cmu_bcast.flush_pipe
      && ioq_valid[ioq_head] && ioq_addr_ready[ioq_head]
      && (ioq_wen[ioq_head] || ioq_atom[ioq_head])
      && ioq_pr1[ioq_head] == 0 && ioq_pr2[ioq_head] == 0;
  assign head_store_vaddr = ioq_eff_addr[ioq_head];
  assign head_store_walu = head_store_walu_sel;
  assign head_store_size = head_store_size_sel;
  assign head_store_last_vaddr = head_store_vaddr + XLEN'(head_store_size - 1'b1);
  // Stores are at most eight bytes: only the page-offset carry decides
  // whether a second translation is needed, including virtual-address wrap.
  assign head_store_page_end = {1'b0, head_store_vaddr[11:0]} + 13'(head_store_size) - 13'd1;
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
  assign head_data_pma_check = ioq_wen[ioq_head] && ioq_context[ioq_head].mmu_en
      && !ioq_mmu_en[ioq_head] && !head_is_cbo_mgmt;
  assign head_data_pma_lo_offset = !rapt_pkg::addr_device_width_capable(
      ioq_paddr[ioq_head], head_store_size - 4'd1
  ) ? 4'd0 : rapt_pkg::addr_data_span_fault_offset(
      ioq_paddr[ioq_head], head_store_lo_bytes - 4'd1, 1'b1
  );
  assign head_data_pma_hi_offset = !rapt_pkg::addr_device_width_capable(
      ioq_paddr_hi[ioq_head], head_store_size - 4'd1
  ) ? 4'd0 : rapt_pkg::addr_data_span_fault_offset(
      ioq_paddr_hi[ioq_head], head_store_hi_bytes - 4'd1, 1'b1
  );
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
      ioq_context[ioq_head].mmu_en ? ioq_paddr[ioq_head] : head_store_vaddr, head_store_size - 4'd1
  );
  // Permission to store one byte does not imply permission to clear a block.
  // Check only the resolved physical address, before allocating the SQ owner
  // that would expand this operation into multiple committed writes.
  assign head_zero_pma_fault = ioq_wen[ioq_head] && !ioq_mmu_en[ioq_head] && head_store_walu ==
      `RAPT_CBO_ZERO_WALU
      && !rapt_pkg::addr_zero_capable(
          ioq_context[ioq_head].mmu_en ? ioq_paddr[ioq_head] : head_store_vaddr
      );

  // === MMU for Store at head ===
  assign exu_l1d.mmu_en = (ioq_wen[ioq_head]
      && head_store_addr_valid_q
      && ioq_mmu_en[ioq_head]
      && ioq_pr1[ioq_head] == 0 && ioq_pr2[ioq_head] == 0);
  assign exu_l1d.mem_context = ioq_context[ioq_head];
  // The first-page response already separates the two translation requests.
  // Save its second-page address on that edge; the valid bit owns this payload.
  always_ff @(posedge clock) begin
    if (!reset && !cmu_bcast.flush_pipe && exu_l1d.ready && ioq_mmu_en[ioq_head] &&
        !ioq_mmu_second[ioq_head] && head_store_cross_page && !exu_l1d.trap) begin
      head_store_hi_page_q <= head_store_hi_vaddr[XLEN-1:12];
    end
  end

  assign exu_l1d.vaddr = ioq_mmu_second[ioq_head] ? {head_store_hi_page_q, 12'b0}
                                                               : head_store_vaddr;
  assign exu_l1d.walu = head_store_walu;
  assign exu_l1d.misaligned = |(head_store_vaddr & XLEN'(head_store_size - 1'b1));
  assign exu_l1d.cmo_mgmt = head_is_cbo_mgmt;
  assign exu_l1d.valid = head_store_addr_valid_q && ioq_wen[ioq_head];

  // The permission checker is registered before store completion. It
  // prechecks the oldest ready plain store ahead of the head; the checker
  // remains single-copy and its result remains registered.
  logic [IOQLen-1:0] store_check_idx;
  logic [XLEN-1:0] store_check_vaddr;
  logic [4:0] store_check_walu;
  logic [3:0] store_check_size;
  logic store_check_addr_valid, store_check_cmo_mgmt;
  // Select the next resident store from registered queue/check state, not
  // from the live head completion.  An L1D response may decide whether the
  // checked result becomes the next head at this edge, but it cannot steer
  // that response through the PMP/PMA CAM and tval adder first.
  logic [IOQ_SIZE-1:0] store_prechecked, store_prefault;
  logic [3:0] store_preoffset[IOQ_SIZE];
  logic store_check_selected;
  begin : g_precheck_select
    always_comb begin
      store_check_idx = ioq_head;
      store_check_selected = 1'b0;
      // The head owns atomic, CBO and translated-store fault sequencing.
      if (head_store_addr_valid_q && ioq_wen[ioq_head]
        && !head_store_check_valid_q && !ioq_mmu_en[ioq_head]) begin
        store_check_selected = 1'b1;
      end
      for (int age = 0; age < IOQ_SIZE; age++) begin
        automatic logic [IOQLen-1:0] idx;
        idx = ioq_head + IOQLen'(age);
        if (!store_check_selected && ioq_valid[idx] && ioq_wen[idx]
          && !ioq_atom[idx] && !ioq_context[idx].mmu_en
          && !ioq_mmu_en[idx] && ioq_addr_ready[idx] && !store_prechecked[idx]
          && ioq_alu[idx][4:0] !=
            `RAPT_CBO_ZERO_WALU
            && ioq_alu[idx][4:0] !=
            `RAPT_CBO_MGMT_WALU
            && rapt_pkg::addr_cacheable(
                ioq_eff_addr[idx]
            )) begin
          store_check_selected = 1'b1;
          store_check_idx = idx;
        end
      end
    end
  end
  assign store_check_vaddr = ioq_eff_addr[store_check_idx];
`ifdef RAPT_RV64
  assign store_check_walu = ioq_atom[store_check_idx]
      ? (ioq_word[store_check_idx] ? `RAPT_SW_WSTRB : `RAPT_SD_WSTRB)
      : ioq_alu[store_check_idx][4:0];
`else
  assign store_check_walu = ioq_atom[store_check_idx]
      ? `RAPT_SW_WSTRB : ioq_alu[store_check_idx][4:0];
`endif
  always_comb begin
    unique case (store_check_walu)
      `RAPT_SB_WSTRB: store_check_size = 4'd1;
      `RAPT_SH_WSTRB: store_check_size = 4'd2;
      `RAPT_SW_WSTRB: store_check_size = 4'd4;
      `RAPT_SD_WSTRB: store_check_size = 4'd8;
      `RAPT_CBO_ZERO_WALU, `RAPT_CBO_MGMT_WALU: store_check_size = 4'd1;
      default: store_check_size = 4'd4;
    endcase
    if ((XLEN == 32) && ioq_fp_valid[store_check_idx]
        && ioq_fp_op[store_check_idx] == `RAPT_FP_OP_FSD)
      store_check_size = 4'd8;
  end
  assign store_check_addr_valid = store_check_selected;
  assign store_check_cmo_mgmt = store_check_walu == `RAPT_CBO_MGMT_WALU;

  rapt_ioq_store_check #(
      .XLEN(XLEN)
  ) u_store_check (
      .store_context(ioq_context[store_check_idx]),
      .pmp_state(pmp_state),
      .store_addr(store_check_vaddr),
      .store_size_m1(store_check_size - 4'd1),
      .store_valid(store_check_addr_valid),
      .store_mmu(ioq_mmu_en[store_check_idx]),
      .cmo_mgmt(store_check_cmo_mgmt),
      .store_bare_fault_offset(store_bare_fault_offset),
      .store_bare_pmp_trap(store_bare_pmp_trap)
  );

  // Exact LR byte set. A smaller SC may target any naturally aligned
  // subrange, but no SC byte may extend beyond the most recent LR.
  logic [XLEN-1:0] sc_paddr;
  logic [3:0] sc_size_m1;
  logic reservation_match_live, sc_decision_ready;
  wire head_is_sc = ioq_valid[ioq_head] && ioq_atom[ioq_head]
      && ioq_alu[ioq_head] == `RAPT_ATO_SC__;
  assign sc_paddr = ioq_context[ioq_head].mmu_en ? ioq_paddr[ioq_head]
      : (ioq_vj[ioq_head] + ioq_imm[ioq_head]);
  assign sc_size_m1 = (ioq_word[ioq_head] || XLEN == 32) ? 4'd3 : 4'd7;
  assign reservation_match_live = exu_l1d.reservation_valid
      && sc_paddr >= exu_l1d.reservation
      && ({1'b0, sc_paddr} + (XLEN+1)'(sc_size_m1))
          <= ({1'b0, exu_l1d.reservation} + (XLEN+1)'(exu_l1d.reservation_size_m1));
  begin : g_sc_decision_stage
    logic valid_q, match_q;
    logic [IOQLen-1:0] head_q;
    wire address_ready = head_is_sc && ioq_pr1[ioq_head] == '0
        && ioq_pr2[ioq_head] == '0 && !ioq_mmu_en[ioq_head]
        && head_store_check_valid_q;
    // Atomics only execute at the head, so a younger LR cannot replace this
    // reservation. External write notifications block completion immediately
    // and discard the sampled decision. Resample after their invalidations
    // have drained, even when SQ backpressure kept this SC at the head.
    always_ff @(posedge clock) begin
      if (completion_kill || ioq_valid_found || exu_l1d.reservation_blocked) begin
        valid_q <= 1'b0;
      end else begin
        valid_q <= address_ready;
        if (address_ready) begin
          head_q <= ioq_head;
          match_q <= reservation_match_live;
        end
      end
    end
    assign sc_decision_ready = valid_q && head_q == ioq_head;
    assign reservation_match = match_q;
    `RAPT_SVA_IMPLY(clock, completion_kill, IOQ_SC_DECISION_CURRENT, head_is_sc && ioq_valid_found,
                    sc_decision_ready && reservation_match == reservation_match_live)
    `RAPT_SVA_NEXT(clock, completion_kill, IOQ_SC_NOTIFICATION_RECHECK,
                   exu_l1d.reservation_blocked, !valid_q)
  end

  // === Head completion resolution ===
  logic head_load_done, head_load_live, head_load_live_b;
  logic [XLEN-1:0] head_rdata;
  logic [63:0] head_fp_rdata64;
  logic head_trap_lsu;
  logic [XLEN-1:0] head_cause_lsu, head_tval_lsu;
  logic head_skip_lsu;
  // Without a response stage, an ordered plain head load can complete
  // directly. With the stage enabled, completion uses captured IOQ state. Store/AMO handoff to the SQ uses an independent,
  // store-only path below, so this response cannot feed back through the SQ
  // forwarding CAM into LSU rready. Atomics retain captured completion.
  assign head_load_live = !`RAPT_IOQ_LOAD_RESPONSE_STAGE && load_req_valid_q && active_idx == ioq_head
      && ioq_ren[ioq_head] && !ioq_wen[ioq_head] && !ioq_atom[ioq_head]
      && exu_lsu.rvalid && exu_lsu.rready;
`ifdef RAPT_LSU_HUM
  assign head_load_live_b = !`RAPT_IOQ_LOAD_RESPONSE_STAGE && b_req_valid_q && b_req_idx_q == ioq_head
      && ioq_ren[ioq_head] && !ioq_wen[ioq_head] && !ioq_atom[ioq_head]
      && exu_lsu.rvalid_b && exu_lsu.rready_b;
`else
  assign head_load_live_b = 1'b0;
`endif
  assign head_load_done = head_load_live || head_load_live_b || ioq_complete[ioq_head];
  assign head_rdata = head_load_live ? exu_lsu.rdata
      : head_load_live_b ? exu_lsu.rdata_b : ioq_rdata[ioq_head];
  assign head_fp_rdata64 = head_load_live ? exu_lsu.fp_rdata64 : ioq_fp_rdata64[ioq_head];
  assign head_trap_lsu = head_load_live ? exu_lsu.trap
      : head_load_live_b ? 1'b0 : ioq_load_trap[ioq_head];
  assign head_cause_lsu = head_load_live ? exu_lsu.cause
      : head_load_live_b ? '0 : ioq_load_cause[ioq_head];
  assign head_tval_lsu = head_load_live ? exu_lsu.tval
      : head_load_live_b ? '0 : ioq_load_tval[ioq_head];
  assign head_skip_lsu = head_load_live ? exu_lsu.difftest_skip
      : head_load_live_b ? 1'b0 : ioq_load_skip[ioq_head];

  // AMO write data: computed from head_rdata (correct live/captured mux)
  // instead of ioq_data which uses stale exu_lsu.rdata on non-live writeback.
  logic [XLEN-1:0] head_amo_wdata;
  logic head_amo_less_signed, head_amo_less_unsigned;
  // AMO.W comparisons use only the low 32 bits of both operands. In RV64,
  // load data is sign-extended but rs2 may contain arbitrary upper bits.
  assign head_amo_less_signed = ioq_word[ioq_head] ? $signed(
      head_rdata[31:0]
  ) < $signed(
      ioq_vk[ioq_head][31:0]
  ) : $signed(
      head_rdata
  ) < $signed(
      ioq_vk[ioq_head]
  );
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
      `RAPT_ATO_MIN_: head_amo_wdata = head_amo_less_signed ? head_rdata : ioq_vk[ioq_head];
      `RAPT_ATO_MAX_: head_amo_wdata = head_amo_less_signed ? ioq_vk[ioq_head] : head_rdata;
      `RAPT_ATO_MINU: head_amo_wdata = head_amo_less_unsigned ? head_rdata : ioq_vk[ioq_head];
      `RAPT_ATO_MAXU: head_amo_wdata = head_amo_less_unsigned ? ioq_vk[ioq_head] : head_rdata;
      default: head_amo_wdata = 'b0;
    endcase
  end

  // === Writeback (IOQ -> ROB) ===
  logic [IOQ_SIZE-1:0] ioq_early_bcasted;
  logic early_bcast_found;
  logic [IOQLen-1:0] bcast_idx;
  logic head_bcast_valid;
  logic head_nonatomic_ready;
  logic head_atomic_ready;
  // Sample older ordered effects before selecting a younger completed load.
  // A new entry cannot complete on its allocation edge; after an older entry
  // retires, a stale blocked bit only delays the younger broadcast one cycle.
  logic [IOQ_SIZE-1:0] early_order_block_comb, early_order_block_q;
  begin : g_early_order_stage
    always_comb begin
      logic older_ordered;
      older_ordered = 1'b0;
      early_order_block_comb = '0;
      for (int age = 0; age < IOQ_SIZE; age++) begin
        logic [IOQLen-1:0] idx;
        idx = IOQLen'((int'(ioq_head) + age) % IOQ_SIZE);
        early_order_block_comb[idx] = older_ordered;
        if (ioq_valid[idx] && (ioq_atom[idx] || ioq_trap[idx] || ioq_load_trap[idx]
            || ioq_load_skip[idx]))
          older_ordered = 1'b1;
      end
    end
    always_ff @(posedge clock) begin
      if (reset || cmu_bcast.flush_pipe) early_order_block_q <= '1;
      else early_order_block_q <= early_order_block_comb;
    end
  end
  // A completed younger scalar load may update its ROB owner while it still
  // waits for ordered IOQ removal. The memory CDB remains one packet/cycle;
  // a ready head always wins, and a previously broadcast head just pops.
  // Per-entry early-completion eligibility excluding the live response.
  // Every input is registered, so the age scan below finishes before the
  // L1D/SQ response (rready, trap) arrives. The live A/B responses are then
  // separate candidates whose ages are also known early; the final oldest
  // choice is a small late mux instead of a response-dependent age scan.
  logic [IOQ_SIZE-1:0] early_static;
  always_comb begin
    logic older_transient_effect;
    older_transient_effect = 1'b0;
    early_static = '0;
    for (int age = 0; age < IOQ_SIZE; age++) begin
      logic [IOQLen-1:0] idx;
      idx = IOQLen'((int'(ioq_head) + age) % IOQ_SIZE);
      early_static[idx] = age != 0
          && !(early_order_block_q[idx] || older_transient_effect)
          && ioq_valid[idx] && !early_bcast_memory_blk[idx]
          && !ioq_early_bcasted[idx] && ioq_ren[idx] && !ioq_wen[idx] && !ioq_atom[idx]
          && !ioq_load_trap[idx] && !ioq_load_skip[idx] && !ioq_fp_valid[idx];
      // Faults and skip outcomes can arrive after the registered prefix was
      // sampled. Keep their ordering guard live for that one-cycle window.
      if (ioq_valid[idx] && (ioq_trap[idx] || ioq_load_trap[idx] || ioq_load_skip[idx]))
        older_transient_effect = 1'b1;
    end
  end
  // Oldest registered-complete candidate.
  logic early_found_r;
  logic [IOQLen-1:0] early_idx_r;
  always_comb begin
    early_found_r = 1'b0;
    early_idx_r = ioq_head;
    for (int age = 0; age < IOQ_SIZE; age++) begin
      logic [IOQLen-1:0] idx;
      idx = IOQLen'((int'(ioq_head) + age) % IOQ_SIZE);
      if (!early_found_r && early_static[idx] && ioq_complete[idx]) begin
        early_found_r = 1'b1;
        early_idx_r = idx;
      end
    end
  end
  localparam bit LiveEarly = !`RAPT_IOQ_LOAD_RESPONSE_STAGE;
  logic early_a_static, early_b_static, early_a_live, early_b_live;
  logic [IOQLen-1:0] early_age_r, early_age_a, early_age_b;
  logic early_pick_a, early_pick_b;
  assign early_a_static = LiveEarly && load_req_valid_q && early_static[active_idx];
  assign early_a_live = early_a_static && exu_lsu.rready && !exu_lsu.trap
      && !exu_lsu.difftest_skip;
  assign early_age_r = early_idx_r - ioq_head;
  assign early_age_a = active_idx - ioq_head;
`ifdef RAPT_LSU_HUM
  assign early_b_static = LiveEarly && b_req_valid_q && early_static[b_req_idx_q];
  assign early_b_live = early_b_static && exu_lsu.rready_b;
  assign early_age_b = b_req_idx_q - ioq_head;
`else
  assign early_b_static = 1'b0;
  assign early_b_live = 1'b0;
  assign early_age_b = '0;
`endif
  // Age comparisons use registered indices only; the live bits arrive last.
  wire early_a_before_r = !early_found_r || early_age_a <= early_age_r;
  wire early_b_before_r = !early_found_r || early_age_b <= early_age_r;
  wire early_a_before_b = early_age_a < early_age_b;
  assign early_pick_a = early_a_live && early_a_before_r && (!early_b_live || early_a_before_b);
  assign early_pick_b = early_b_live && early_b_before_r && (!early_a_live || !early_a_before_b);
  assign early_bcast_found = early_found_r || early_a_live || early_b_live;
  logic [IOQLen-1:0] early_b_idx;
`ifdef RAPT_LSU_HUM
  assign early_b_idx = b_req_idx_q;
`else
  assign early_b_idx = early_idx_r;
`endif
  assign early_bcast_idx = early_pick_a ? active_idx : early_pick_b ? early_b_idx : early_idx_r;
  assign head_bcast_valid = ioq_valid_found && !ioq_early_bcasted[ioq_head];
  // An atomic head blocks every younger early broadcast. The non-atomic
  // readiness predicate is equivalent to head_bcast_valid in this case,
  // without an SC reservation comparison on the completion payload mux.
  // The registered prefix already blocks younger work behind an atomic head.
  // New entries cannot complete before the prefix has sampled their order.
  assign early_bcast_select =
      !(head_nonatomic_ready && !ioq_early_bcasted[ioq_head]) && early_bcast_found;
  // Cancellation suppresses the transfer, while the unqualified choice keeps
  // retirement/flush control out of the completion payload mux and ALU wake.
  assign early_bcast_issue = early_bcast_select && !completion_kill;
  assign bcast_idx = early_bcast_select ? early_bcast_idx : ioq_head;
  // Candidate payloads are read with registered indices; the late early/A/B
  // picks only steer a final small mux.
  `define RAPT_IOQ_BCAST_PICK(arr) \
  (!early_bcast_select ? arr[ioq_head] : early_pick_a ? arr[active_idx] \
      : early_pick_b ? arr[early_b_idx] : arr[early_idx_r])
  `define RAPT_IOQ_EARLY_PICK(arr) \
  (early_pick_a ? arr[active_idx] : early_pick_b ? arr[early_b_idx] : arr[early_idx_r])
  wire early_bcast_live_a = early_bcast_select && early_pick_a;
  wire early_bcast_live_b = early_bcast_select && early_pick_b;
  always_ff @(posedge clock) begin
    if (reset || cmu_bcast.flush_pipe) ioq_early_bcasted <= '0;
    else begin
      if (early_bcast_issue && wb_accept) ioq_early_bcasted[early_bcast_idx] <= 1'b1;
      if (ioq_valid_found) ioq_early_bcasted[ioq_head] <= 1'b0;
      for (int i = 0; i < IOQ_SIZE; i++) begin
        if (alloc_slot[i] >= 0) ioq_early_bcasted[i] <= 1'b0;
      end
    end
  end
  assign sq_acquire = ioq_acquire[ioq_head];
  assign sq_context = ioq_context[ioq_head];
  assign exu_ioq_bcast.pc = `RAPT_IOQ_BCAST_PICK(ioq_pc);
  assign exu_ioq_bcast.npc = exu_ioq_bcast.trap ? csr_bcast.tvec
      : `RAPT_IOQ_BCAST_PICK(ioq_pc) + (`RAPT_IOQ_BCAST_PICK(ioq_c) ? 2 : 4);
  assign exu_ioq_bcast.result = early_bcast_select
      ? (early_bcast_live_a ? exu_lsu.rdata
        : early_bcast_live_b ? exu_lsu.rdata_b : ioq_rdata[early_idx_r])
      : (ioq_atom[ioq_head] && ioq_alu[ioq_head] == `RAPT_ATO_SC__)
      ? (reservation_match ? 0 : 1)
      : (ioq_ren[ioq_head] ? head_rdata : ioq_vk[ioq_head]);
  assign exu_ioq_bcast.dest = `RAPT_IOQ_BCAST_PICK(ioq_dest);
  assign exu_ioq_bcast.generation = `RAPT_IOQ_BCAST_PICK(ioq_generation);
  assign exu_ioq_bcast.prd = `RAPT_IOQ_BCAST_PICK(ioq_prd);
  assign exu_ioq_bcast.rd = `RAPT_IOQ_BCAST_PICK(ioq_rd);
  assign exu_ioq_bcast.wen = early_bcast_select ? 1'b0
      : (head_is_cbo_mgmt || exu_ioq_bcast.trap
      || (ioq_wen[ioq_head] && !head_store_check_valid_q)) ? 1'b0
      : (ioq_atom[ioq_head] && ioq_alu[ioq_head] == `RAPT_ATO_SC__)
      ? (reservation_match ? 1 : 0)
      : (ioq_wen[ioq_head]);
  assign exu_ioq_bcast.alu = early_bcast_select ? `RAPT_IOQ_EARLY_PICK(ioq_alu)
      : ioq_atom[ioq_head] ? {1'b0, head_store_walu} : ioq_alu[ioq_head];
  assign exu_ioq_bcast.sq_waddr = early_bcast_select ? `RAPT_IOQ_EARLY_PICK(ioq_eff_addr)
      : ioq_context[ioq_head].mmu_en
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
    assign store_beat_paddr[beat] = ioq_context[ioq_head].mmu_en
        ? {second_page ? ioq_paddr_hi[ioq_head][XLEN-1:12] : ioq_paddr[ioq_head][XLEN-1:12],
           store_beat_vaddr[beat][11:0]} : store_beat_vaddr[beat];
    assign sq_wpbmt[beat] = ioq_context[ioq_head].mmu_en
        ? (second_page ? ioq_pbmt_hi[ioq_head] : ioq_pbmt[ioq_head]) : 2'b00;
  end
  assign sq_waddr_hi = store_beat_paddr[1];
  assign sq_waddr_third = store_beat_paddr[2];
  assign exu_ioq_bcast.sq_wdata = early_bcast_select ? `RAPT_IOQ_EARLY_PICK(ioq_vk)
      : ioq_atom[ioq_head] ? head_amo_wdata
      : ((ioq_fp_valid[ioq_head] && ioq_fp_op[ioq_head] == `RAPT_FP_OP_FSW)
        ? fpr.ioq_rdata[XLEN-1:0]
        : ((ioq_fp_valid[ioq_head] && ioq_fp_op[ioq_head] == `RAPT_FP_OP_FSD)
          ? fpr.ioq_rdata[XLEN-1:0]
          : ((ioq_fp_valid[ioq_head] && ioq_fp_op[ioq_head] ==
      `RAPT_FP_OP_ZFHMIN
      && ioq_wen[ioq_head]) ? fpr.ioq_rdata[XLEN-1:0] : ioq_vk[ioq_head])));
  assign exu_ioq_bcast.sq_wdata64 = early_bcast_select ? '0 : fpr.ioq_rdata;
  assign exu_ioq_bcast.sq_fp64 = !early_bcast_select && ioq_fp_valid[ioq_head]
      && ioq_fp_op[ioq_head] == `RAPT_FP_OP_FSD;
  assign fpr.ioq_wvalid = wb_accept && exu_ioq_bcast.valid && !early_bcast_issue
      && ioq_fp_valid[ioq_head] && (ioq_fp_op[ioq_head] ==
      `RAPT_FP_OP_FLW
      || ioq_fp_op[ioq_head] ==
      `RAPT_FP_OP_FLD
      || (ioq_fp_op[ioq_head] == `RAPT_FP_OP_ZFHMIN && ioq_ren[ioq_head])) && !head_trap_lsu;
  assign fpr.ioq_waddr = ioq_fp_rd[ioq_head];
  assign fpr.ioq_wdata = (ioq_fp_op[ioq_head] == `RAPT_FP_OP_FLD)
      ? head_fp_rdata64
      : (ioq_fp_op[ioq_head] == `RAPT_FP_OP_ZFHMIN)
        ? {48'hffff_ffff_ffff, head_rdata[15:0]}
        : {32'hffff_ffff, head_rdata[31:0]};
  // AMOs report store/AMO exceptions while retaining page/access/alignment
  // classification. A rejected write translation completes without a read.
  logic head_is_amo_rw;
  logic head_store_fault;
  logic head_store_fault_d;
  logic [XLEN-1:0] head_amo_load_cause;
  typedef struct packed {
    logic valid;
    logic [XLEN-1:0] cause;
    logic [XLEN-1:0] tval;
  } ioq_exception_t;
  ioq_exception_t head_exception;
  assign head_is_amo_rw = ioq_atom[ioq_head]
                          && (ioq_alu[ioq_head] != `RAPT_ATO_LR__)
                          && (ioq_alu[ioq_head] != `RAPT_ATO_SC__);
  assign head_store_fault_d = ioq_wen[ioq_head]
      && (ioq_trap[ioq_head] || store_bare_pmp_trap
          || head_atomic_pma_fault || head_zero_pma_fault || head_data_pma_fault);
  assign head_store_fault = head_store_check_valid_q && head_store_check_fault_q;
  // Do not feed PMP/PMA decoding into atomic issue, completion arbitration,
  // other execution units and operand wakeup in the same cycle.
  begin : g_precheck_state
    logic legacy_check_valid, legacy_check_fault;
    logic [XLEN-1:0] legacy_check_cause, legacy_check_tval;
    assign head_store_check_valid_q = legacy_check_valid || store_prechecked[ioq_head];
    assign head_store_check_fault_q = store_prechecked[ioq_head]
      ? store_prefault[ioq_head] : legacy_check_fault;
    assign head_store_check_cause_q = store_prechecked[ioq_head]
      ? `RAPT_CAUSE_STORE_ACC_FAULT : legacy_check_cause;
    assign head_store_check_tval_q = store_prechecked[ioq_head]
      ? ioq_eff_addr[ioq_head] + XLEN'(store_preoffset[ioq_head]) : legacy_check_tval;
    for (genvar e = 0; e < IOQ_SIZE; e++) begin : g_store_precheck
      always_ff @(posedge clock) begin
        if (reset || cmu_bcast.flush_pipe || alloc_slot[e] >= 0
          || (ioq_valid_found && ioq_head == IOQLen'(e))) begin
          store_prechecked[e] <= 1'b0;
        end else if (store_check_selected && store_check_idx == IOQLen'(e)
          && !ioq_atom[e] && !ioq_context[e].mmu_en && !ioq_mmu_en[e]
          && !ioq_trap[e] && ioq_alu[e][4:0] !=
            `RAPT_CBO_ZERO_WALU
            && ioq_alu[e][4:0] !=
            `RAPT_CBO_MGMT_WALU
            && rapt_pkg::addr_cacheable(
                ioq_eff_addr[e]
            )) begin
          store_prechecked[e] <= 1'b1;
          store_prefault[e]   <= store_bare_pmp_trap;
          store_preoffset[e]  <= store_bare_fault_offset;
        end
      end
    end
    always_ff @(posedge clock) begin
      if (reset || cmu_bcast.flush_pipe) begin
        legacy_check_valid <= 1'b0;
      end else if (ioq_valid_found) begin
        legacy_check_valid <= 1'b0;
      end else if (!legacy_check_valid && head_store_addr_valid_q
        && store_check_selected && store_check_idx == ioq_head
        && ioq_valid[ioq_head] && ioq_wen[ioq_head] && !ioq_mmu_en[ioq_head]) begin
        legacy_check_valid <= 1'b1;
        legacy_check_fault <= head_store_fault_d;
        legacy_check_cause <= ioq_trap[ioq_head]
          ? ioq_cause[ioq_head] : `RAPT_CAUSE_STORE_ACC_FAULT;
        legacy_check_tval <= ioq_mmu_fault[ioq_head] ? ioq_store_tval[ioq_head]
          : head_data_pma_fault_hi ? head_store_hi_vaddr + XLEN'(head_data_pma_hi_offset)
          : head_data_pma_fault ? head_store_vaddr + XLEN'(head_data_pma_lo_offset)
          : store_bare_pmp_trap ? head_store_vaddr + XLEN'(store_bare_fault_offset)
          : ioq_eff_addr[ioq_head];
      end
    end
  end
  always_comb begin
    case (head_cause_lsu)
      `RAPT_CAUSE_LOAD_PAGE_FAULT: head_amo_load_cause = `RAPT_CAUSE_STORE_PAGE_FAULT;
      `RAPT_CAUSE_LOAD_MISALIGNED: head_amo_load_cause = `RAPT_CAUSE_STORE_MISALIGNED;
      default: head_amo_load_cause = `RAPT_CAUSE_STORE_ACC_FAULT;
    endcase
  end
  // Both kinds of memory operation publish the same exception contract.
  // A failed store-side permission check wins over an AMO read fault; a
  // younger early-broadcast load has already passed the clean-hit filter.
  always_comb begin
    head_exception = '0;
    if (head_store_fault) begin
      head_exception.valid = 1'b1;
      head_exception.cause = head_store_check_cause_q;
      head_exception.tval  = head_store_check_tval_q;
    end else if (ioq_ren[ioq_head] && head_trap_lsu) begin
      head_exception.valid = 1'b1;
      head_exception.cause = head_is_amo_rw ? head_amo_load_cause : head_cause_lsu;
      head_exception.tval  = head_tval_lsu;
    end
  end
  assign exu_ioq_bcast.trap = !early_bcast_select && head_exception.valid;
  assign exu_ioq_bcast.cause = early_bcast_select ? '0 : head_exception.cause;
  assign exu_ioq_bcast.tval = early_bcast_select ? `RAPT_IOQ_EARLY_PICK(ioq_eff_addr)
      : head_exception.valid ? head_exception.tval : ioq_eff_addr[ioq_head];
  // Rejected accesses have no device side effect to synchronize. Preserve
  // reference execution for their precise exception and destination checks.
  assign exu_ioq_bcast.difftest_skip = !early_bcast_select && !exu_ioq_bcast.trap && (
      (ioq_ren[ioq_head] && head_skip_lsu)
      || (ioq_wen[ioq_head] && !head_is_cbo_mgmt && rapt_pkg::addr_mmio(
      exu_ioq_bcast.sq_waddr
  )));

  // Keep ordinary and atomic head admission separate. The shared completion
  // outlet still arbitrates one packet, while only the atomic branch sees
  // reservation state and the special AMO write-fault rule.
  wire head_common_ready = ioq_valid[ioq_head] && ioq_pr1[ioq_head] == '0
      && ioq_pr2[ioq_head] == '0 && (!ioq_wen[ioq_head] || head_store_check_valid_q)
      && (!ioq_wen[ioq_head] || (ioq_mmu_en[ioq_head] == 0 && exu_lsu.stq_ready))
      && head_fpr_ready;
  assign head_nonatomic_ready = head_common_ready
      && (ioq_ren[ioq_head] ? head_load_done : ioq_mmu_en[ioq_head] == 0);
  assign head_atomic_ready = head_common_ready
      && !(ioq_alu[ioq_head] == `RAPT_ATO_SC__
          && (exu_l1d.reservation_blocked || !sc_decision_ready))
      && (ioq_ren[ioq_head] ? (head_load_done || (head_is_amo_rw && head_store_fault))
          : ioq_mmu_en[ioq_head] == 0);
  assign ioq_valid_found = ioq_atom[ioq_head] ? head_atomic_ready : head_nonatomic_ready;
  assign exu_ioq_bcast.valid = !completion_kill && (head_bcast_valid || early_bcast_select);
  // SQ forwarding must see a store that is handed off on this edge so a
  // younger load cannot observe an older resident value. Keep this predicate
  // independent of live load response signals to avoid a combinational
  // bcast->SQ-forward->rready->bcast cycle.
  // The forwarding CAM only needs an impending store's conflict hint. Keep
  // it independent of cancellation and live reservation notifications. A
  // stale hint can only stall a load; it cannot allocate an SQ entry or write
  // memory. Notifications invalidate the sampled SC decision on the next
  // edge, while actual handoff and completion are blocked immediately.
  assign sq_handoff_valid = !completion_kill && sq_forward_pending
      && !(head_is_sc && exu_l1d.reservation_blocked);
  assign sq_forward_pending = ioq_valid[ioq_head]
      && ioq_wen[ioq_head]
      && head_fpr_ready
      && ioq_pr1[ioq_head] == 0 && ioq_pr2[ioq_head] == 0
      && head_store_check_valid_q
      && !head_store_fault
      && (ioq_ren[ioq_head] ? ioq_complete[ioq_head] : ioq_mmu_en[ioq_head] == 0)
      && ioq_mmu_en[ioq_head] == 0
      && exu_lsu.stq_ready
      && !head_is_cbo_mgmt
      && !(ioq_atom[ioq_head] && ioq_alu[ioq_head] ==
      `RAPT_ATO_SC__
      && (!sc_decision_ready || !reservation_match));
  assign sq_handoff_alu = ioq_atom[ioq_head] ? head_store_walu : ioq_alu[ioq_head][4:0];
  assign exu_l1d.reservation_clear = !completion_kill && wb_accept && ioq_valid_found
      && ioq_atom[ioq_head] && ioq_alu[ioq_head] == `RAPT_ATO_SC__;
  // MEM pipe never resolves branches nor writes CSRs (uniform completion
  // tie-offs; ROB keeps mispredict at its dispatch-init value of 0).
  assign exu_ioq_bcast.btaken = 1'b0;
  assign exu_ioq_bcast.mispredict = 1'b0;
  assign exu_ioq_bcast.csr_wen = 1'b0;
  assign exu_ioq_bcast.csr_wdata = '0;
  assign exu_ioq_bcast.fp_flags_valid = 1'b0;
  assign exu_ioq_bcast.fp_flags = '0;

  // Integer queues wake from the accepted, registered completion path; the
  // speculative fast load-use wake pair is not produced.
  assign load_fast.valid = 1'b0;
  assign load_fast.rebusy = 1'b0;
  assign load_fast.prd = '0;
  assign load_fast.dest = '0;
  assign load_fast.generation = '0;
  assign load_fast.rd = '0;

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

  // Sources allowed to feed the registered request stage on their wake edge:
  // integer results, not the memory port. A load result would otherwise close
  // the request register through the L1D response, SQ forwarding and early
  // completion in one cycle; pointer chasing uses the resident path.
  localparam int unsigned MemoryPort = NWB - 2;
  function automatic logic fwd_req_port(input int p);
    return p != int'(MemoryPort);
  endfunction
  function automatic logic fwd_req_hit(input logic [PLEN-1:0] pr);
    fwd_req_hit = 1'b0;
    for (int p = 0; p < NWB; p++)
    if (fwd_req_port(p)) fwd_req_hit |= (pr != '0) && wb_valid[p] && (wb_prd[p] == pr);
  endfunction
  function automatic logic [XLEN-1:0] fwd_req_val(input logic [PLEN-1:0] pr,
                                                  input logic [XLEN-1:0] dflt);
    fwd_req_val = dflt;
    for (int p = NWB - 1; p >= 0; p--)
    if (fwd_req_port(p) && (pr != '0) && wb_valid[p] && (wb_prd[p] == pr))
      fwd_req_val = wb_result[p];
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
      ioq_ren                <= '0;
      ioq_wen                <= '0;
      ioq_mmu_en             <= '0;
      ioq_mmu_second         <= '0;
      ioq_valid              <= '0;
      ioq_head               <= '0;
      ioq_tail_a             <= '0;
      ioq_complete           <= '0;
      ioq_needs_ordered      <= '0;
      ioq_load_trap          <= '0;
      ioq_mmu_fault          <= '0;
      ioq_load_skip          <= '0;
      oo_pending             <= 1'b0;
      oo_pending_idx         <= '0;
      load_req_valid_q       <= 1'b0;
      load_req_context_q     <= '0;
      load_req_idx_q         <= '0;
      ioq_full_r             <= 1'b0;  // A2: Initialize full state tracker
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

      // ---- Registered load-request pipeline ----
      // An occupied stage is held verbatim until the LSU response handshake.
      // The selector excludes both in-flight owners, so a response can
      // replace the stage on the same edge without reissuing the old entry.
      if (!load_req_valid_q || exu_lsu.rready || exu_lsu.rretry || exu_lsu.rmiss) begin
        // The payload is captured whenever the stage is free; only the valid
        // bit waits for the late forwarded-address qualification.
        load_req_valid_q <= dispatch_load_found || load_req_sel_valid;
        if (dispatch_load_found) begin
          // The first allocation into a registered-empty IOQ owns ioq_tail_a.
          // Capture its stable-base request on the allocation edge. An owner
          // retiring on this edge cannot reopen this bypass combinationally.
          load_req_valid_q <= 1'b1;
          load_req_idx_q <= ioq_tail_a;
          load_req_addr_q <= dispatch_load_addr;
          load_req_context_q <= dispatch_context;
          load_req_alu_q <= dispatch_load_alu;
          load_req_atomic_q <= 1'b0;
          load_req_release_q <= 1'b0;
          load_req_ordered_q <= 1'b0;
          load_req_pc_q <= dispatch_load_pc;
          load_req_fp64_q <= dispatch_load_fp64;
          load_req_prd_q <= dispatch_load_prd;
        end else begin
          load_req_idx_q <= load_req_sel_idx;
          load_req_addr_q <= load_req_sel_addr;
          load_req_context_q <= ioq_context[load_req_sel_idx];
          load_req_alu_q   <= ioq_atom[load_req_sel_idx]
              ? (ioq_word[load_req_sel_idx] ? `RAPT_ALU_LW__ : `RAPT_ALU_LD__)
              : ((ioq_fp_valid[load_req_sel_idx]
                    && ioq_fp_op[load_req_sel_idx] == `RAPT_FP_OP_FLD)
                  ?
          `RAPT_ALU_LD__
          : ((ioq_fp_valid[load_req_sel_idx] && ioq_fp_op[load_req_sel_idx] == `RAPT_FP_OP_FLW) ?
             `RAPT_ALU_LW__ : ioq_alu[load_req_sel_idx][4:0]));
          load_req_atomic_q <= ioq_atom[load_req_sel_idx]
              && ioq_alu[load_req_sel_idx] == `RAPT_ATO_LR__;
          load_req_release_q <= ioq_release[load_req_sel_idx];
          load_req_ordered_q <= (load_req_sel_idx == ioq_head) && ioq_at_rob_head;
          load_req_pc_q <= ioq_pc[load_req_sel_idx];
          load_req_fp64_q <= ioq_fp_valid[load_req_sel_idx]
              && ioq_fp_op[load_req_sel_idx] == `RAPT_FP_OP_FLD;
          load_req_prd_q <= ioq_prd[load_req_sel_idx];
        end
      end
      // Promote a held translation as soon as both heads catch up. If L1D
      // discovers a device before then, rretry releases this request and
      // ioq_needs_ordered prevents it from blocking older ready loads again.
      if (load_req_valid_q && !(exu_lsu.rready || exu_lsu.rretry || exu_lsu.rmiss)
          && (load_req_idx_q == ioq_head) && ioq_at_rob_head)
        load_req_ordered_q <= 1'b1;
      // ---- Static per-entry enqueue mux (B > A on any selector alias) ----
      for (int i = 0; i < IOQ_SIZE; i++) begin
        if (alloc_slot[i] >= 0) begin
          ioq_valid[i] <= 1'b1;
          ioq_pc[i] <= dispatch[alloc_slot[i]].uop.pc;
          ioq_pr1[i] <= wake_pr(dispatch[alloc_slot[i]].pr1);
          ioq_pr2[i] <= wake_pr(dispatch[alloc_slot[i]].pr2);
          ioq_prd[i] <= dispatch[alloc_slot[i]].prd;
          ioq_rd[i] <= dispatch[alloc_slot[i]].uop.rd;
          ioq_c[i] <= dispatch[alloc_slot[i]].uop.c;
          ioq_word[i] <= dispatch[alloc_slot[i]].uop.execute.int_op.word;
          ioq_alu[i] <= dispatch[alloc_slot[i]].uop.execute.int_op.alu;
          ioq_vj[i] <= wake_val(dispatch[alloc_slot[i]].pr1, dispatch[alloc_slot[i]].op1);
          ioq_vk[i] <= wake_val(dispatch[alloc_slot[i]].pr2, dispatch[alloc_slot[i]].op2);
          ioq_dest[i] <= dispatch[alloc_slot[i]].dest;
          ioq_generation[i] <= dispatch[alloc_slot[i]].generation;
          ioq_imm[i] <= dispatch[alloc_slot[i]].uop.imm;
          ioq_wen[i] <= dispatch[alloc_slot[i]].uop.execute.memory.store;
          ioq_mmu_en[i] <= dispatch_context.mmu_en;
          ioq_context[i] <= dispatch_context;
          ioq_mmu_second[i] <= 1'b0;
          ioq_pbmt[i] <= 2'b00;
          ioq_pbmt_hi[i] <= 2'b00;
          ioq_ren[i] <= dispatch[alloc_slot[i]].uop.execute.memory.load;
          ioq_atom[i] <= dispatch[alloc_slot[i]].uop.execute.memory.atomic;
          ioq_release[i] <= dispatch[alloc_slot[i]].uop.execute.memory.atomic
              && dispatch[alloc_slot[i]].uop.inst[25];
          ioq_acquire[i] <= dispatch[alloc_slot[i]].uop.execute.memory.atomic
              && dispatch[alloc_slot[i]].uop.inst[26];
          ioq_fp_valid[i] <= dispatch[alloc_slot[i]].uop.execute.fp.valid;
          ioq_fp_op[i] <= dispatch[alloc_slot[i]].uop.execute.fp.op;
          ioq_fp_rd[i] <= dispatch[alloc_slot[i]].uop.inst[11:7];
          ioq_fp_rs2[i] <= dispatch[alloc_slot[i]].uop.inst[24:20];
          ioq_trap[i] <= dispatch[alloc_slot[i]].uop.trap;
          ioq_mmu_fault[i] <= 1'b0;
          ioq_complete[i] <= 1'b0;
          ioq_needs_ordered[i] <= 1'b0;
          ioq_load_trap[i] <= 1'b0;
          ioq_load_skip[i] <= 1'b0;
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
          ioq_trap[i] <= exu_l1d.trap;
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

        if (exu_lsu.rvalid && exu_lsu.rretry && i == int'(active_idx)) begin
          ioq_needs_ordered[i] <= 1'b1;
        end

        if (exu_lsu.rvalid && exu_lsu.rready && i == int'(active_idx)) begin
          ioq_rdata[i] <= exu_lsu.rdata;
          if (ioq_fp_valid[i] && ioq_fp_op[i] == `RAPT_FP_OP_FLD)
            ioq_fp_rdata64[i] <= exu_lsu.fp_rdata64;
          if (active_idx != ioq_head || !ioq_valid_found) begin
            ioq_complete[i]   <= 1'b1;
            ioq_load_trap[i]  <= exu_lsu.trap;
            ioq_load_cause[i] <= exu_lsu.cause;
            ioq_load_tval[i]  <= exu_lsu.tval;
            ioq_load_skip[i]  <= exu_lsu.difftest_skip;
          end
        end
`ifdef RAPT_LSU_HUM
        if (exu_lsu.rvalid_b && exu_lsu.rready_b
            && b_req_idx_q != active_idx
            && !(ioq_valid_found && b_req_idx_q == ioq_head)
            && i == int'(b_req_idx_q)) begin
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
      if (!load_req_valid_q || (exu_lsu.rvalid && (exu_lsu.rready || exu_lsu.rretry || exu_lsu.rmiss))) begin
        oo_pending <= 1'b0;
      end else if (!oo_pending && exu_lsu.rvalid && !exu_lsu.rready) begin
        oo_pending     <= 1'b1;
        oo_pending_idx <= load_req_idx_q;
      end
    end
  end

  // A2: PMU: one-cycle pulse on IOQ full rising edge
  assign pmu_ioq_full = (&ioq_valid) && !ioq_full_r;

  assign exu_ioq_bcast.updates = '{memory: 1'b1, exception: 1'b1, default: '0};
  assign load_fast.confirmed = 1'b0;
  assign load_fast.confirmed_prd = '0;
  assign load_fast.confirmed_dest = '0;
  assign load_fast.confirmed_generation = '0;
  assign load_fast.confirmed_rd = '0;
  assign load_fast.result = '0;
  `RAPT_SVA_IMPLY(clock, reset, IOQ_RETRY_NOT_COMPLETION, exu_lsu.rvalid && exu_lsu.rretry,
                  !exu_lsu.rready)
  `RAPT_SVA_IMPLY(clock, reset, IOQ_REPLAY_REQUIRES_HEAD,
                  !load_req_valid_q && load_req_sel_valid && ioq_needs_ordered[load_req_sel_idx],
                  load_req_sel_idx == ioq_head && ioq_at_rob_head)
  `RAPT_SVA_IMPLY(clock, reset, IOQ_STORE_COMPLETION_CHECKED,
                  exu_ioq_bcast.valid && !early_bcast_issue && ioq_wen[ioq_head],
                  head_store_check_valid_q)
  `RAPT_SVA_IMPLY(clock, reset, IOQ_ATOMIC_BLOCKS_EARLY, ioq_valid[ioq_head] && ioq_atom[ioq_head],
                  !early_bcast_found)
  `RAPT_SVA_IMPLY(clock, reset, IOQ_FLUSH_KILLS_COMPLETION, cmu_bcast.flush_pipe,
                  !exu_ioq_bcast.valid && !sq_handoff_valid)
  `RAPT_SVA_IMPLY(clock, reset || cmu_bcast.flush_pipe, IOQ_CREDIT_MATCHES_OWNERS, 1'b1,
                  int'(ioq_free_q) + $countones(ioq_valid) == IOQ_SIZE)
  `RAPT_SVA_IMPLY(clock, reset || cmu_bcast.flush_pipe, IOQ_CREDIT_COVERS_DISPATCH, 1'b1,
                  allocation_count <= int'(ioq_free_q))
  `RAPT_SVA_IMPLY(clock, reset || cmu_bcast.flush_pipe, IOQ_SECOND_PAGE_SNAPSHOT,
                  ioq_valid[ioq_head] && ioq_wen[ioq_head] && ioq_mmu_second[ioq_head],
                  {head_store_hi_page_q, 12'b0} == head_store_hi_vaddr)
  `RAPT_SVA_IMPLY(clock, reset, IOQ_STORE_MMU_ADDRESS_CAPTURED, exu_l1d.mmu_en,
                  head_store_addr_valid_q)
  `RAPT_SVA_NEXT(clock, reset, IOQ_STORE_STAGES_FLUSH_CLEAR, cmu_bcast.flush_pipe,
                 !head_store_addr_valid_q && !head_store_check_valid_q)
  `undef RAPT_IOQ_BCAST_PICK
  `undef RAPT_IOQ_EARLY_PICK
endmodule
/* verilator lint_on PINCONNECTEMPTY */
