`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_dpi_c.svh"

/* verilator lint_off PINCONNECTEMPTY */
module rapt_lsu_sq #(
    parameter type CompletionT = rapt_pkg::completion_t,
    parameter unsigned SQ_SIZE = `RAPT_SQ_SIZE,
    parameter int XLEN = `RAPT_XLEN
) (
    input clock,

    cmu_bcast_if.in cmu_bcast,

    lsu_l1d_if.master lsu_l1d,

    lsu_pipe_if.slave exu_lsu,
    input CompletionT exu_ioq_bcast,
    input logic completion_accept,
    input logic [XLEN-1:0] sq_waddr_hi,
    input logic [XLEN-1:0] sq_waddr_third,
    input logic [2:0][1:0] sq_wpbmt,
    input logic sq_acquire,
    rou_lsu_if.in rou_lsu,

    csr_bcast_if.in csr_bcast,
    pmp_state_if.in pmp_state,

    // A2: PMU: one-cycle pulse when SQ becomes full
    /* verilator lint_off UNUSEDSIGNAL */
    output logic pmu_sq_full,
    /* verilator lint_on UNUSEDSIGNAL */

    input reset
);
  localparam int WordOffBits = $clog2(XLEN / 8);
  localparam int PageOffBits = 12;
  localparam int SQLen = $clog2(SQ_SIZE);
  localparam int ROBLen = $clog2(`RAPT_ROB_SIZE);
  localparam int CboBlockBytes = 64;
  localparam int CboBeats = CboBlockBytes / (XLEN / 8);
  localparam int CboBeatBits = $clog2(CboBeats);
`ifdef RAPT_RV64
  localparam logic [7:0] FullStoreWstrb = `RAPT_SD_WSTRB;
`else
  localparam logic [7:0] FullStoreWstrb = `RAPT_SW_WSTRB;
`endif
  localparam logic [7:0] CboBusWstrb = (XLEN == 64) ? 8'hff : 8'h0f;

  typedef enum logic [2:0] {
    LS_S_V    = 3'b000,  // present lo beat, wait for wready
    LS_S_R    = 3'b001,  // lo beat retired; aligned case completes here
    LS_S_HI_V = 3'b010,  // misaligned: present hi beat, wait for wready
    LS_S_HI_R = 3'b011, // hi beat retired; SQ entry released next cycle
    LS_S_X_V   = 3'b100, // RV32D FSD: present the third beat
    LS_S_X_R   = 3'b101, // third beat retired; SQ entry released next cycle
    LS_S_CBO_V = 3'b110, // CBO.ZERO: present remaining cache-block beats
    LS_S_CBO_R = 3'b111  // final zero beat retired; release next cycle
  } state_store_t;

  state_store_t state_store;
  logic [CboBeatBits-1:0] cbo_zero_beat;

  logic raddr_valid;
  logic [XLEN-1:0] raddr;
  logic [4:0] ralu;
  logic [XLEN-1:0] rdata_unalign;
  logic [XLEN-1:0] rdata;

  // ==========================================================================
  //  Unified Store Queue (Phase A LSU refactor)
  //
  //  ONE ring buffer holds a store from execute to drain
  //
  //  Ring order == program order (the IOQ executes stores in order):
  //      [head, cmt)  committed  - drains to L1D, survives flush
  //      [cmt, tail)  speculative- flush rolls tail back to cmt
  //
  //  Entry lifecycle (payload is written exactly ONCE, at allocation):
  //    alloc  : exu_ioq_bcast store writeback -- vaddr(tval), paddr(sq_waddr),
  //             wdata, alu, dest are all available here; tail++
  //    commit : ROB retires the store IN ORDER -> committed[cmt] <= 1, cmt++
  //             (no CAM, no payload copy, never blocks: rou_lsu.sq_ready == 1)
  //    drain  : head entry, when committed, through the state_store FSM; head++
  //    flush  : clear valid on [cmt, tail), tail <= cmt; committed entries
  //             keep draining
  //
  //  Per-array single-writer discipline (R1):
  //    payload[] : alloc only        valid[] : alloc set / drain clr / flush clr
  //    committed[]: commit set / drain clr
  //  (alloc@tail, commit@cmt, drain@head are distinct entries by construction;
  //   see assertions at the bottom.)
  // ==========================================================================
  logic [SQLen-1:0] sq_head;  // oldest committed (drain point)
  logic [SQLen-1:0] sq_cmt;   // commit boundary: [head,cmt) committed
  logic [SQLen-1:0] sq_tail;  // allocation point
  logic [SQ_SIZE-1:0] sq_valid;
  logic [SQ_SIZE-1:0] sq_committed;
  logic sq_alloc_fire;
  // Recovery can change privilege, SATP or mappings while committed stores
  // survive. Their saved VA is no longer a forwarding identity. Keep this
  // per entry so new allocations can forward without waiting for all stores.
  logic [SQ_SIZE-1:0] sq_stale_context;
  logic sq_context_invalidated;
  // Normal branch/jump and atomic retirement preserve address identity.
  // CMU suppresses their flags for synchronous traps; interrupts and fences
  // retain priority. Acquire/release ordering is enforced separately below.
  assign sq_context_invalidated = cmu_bcast.fence_time
      || (cmu_bcast.flush_pipe && (cmu_bcast.time_trap
          || !(cmu_bcast.ben || cmu_bcast.jen || cmu_bcast.jren
               || cmu_bcast.atomic_retired)));
  always_ff @(posedge clock) begin
    if (reset) sq_stale_context <= '0;
    else if (sq_context_invalidated) sq_stale_context <= sq_stale_context | sq_valid;
    else if (sq_alloc_fire) sq_stale_context[sq_tail] <= 1'b0;
  end
  logic [SQ_SIZE-1:0] sq_acquire_q;
  logic sq_has_acquire;
  assign sq_has_acquire = |(sq_valid & sq_acquire_q);
  logic [4:0] sq_alu[SQ_SIZE];
  /* verilator lint_off UNUSEDSIGNAL */
  logic [ROBLen-1:0] sq_dest[SQ_SIZE];  // ROB id: assertions/debug only
  /* verilator lint_on UNUSEDSIGNAL */
  logic [XLEN-1:0] sq_vaddr[SQ_SIZE];  // virtual : forwarding comparison
  logic [XLEN-1:0] sq_paddr[SQ_SIZE];  // physical: bus write-through
  logic [XLEN-1:0] sq_paddr_hi[SQ_SIZE]; // translated PA for a cross-page high beat
  logic [XLEN-1:0] sq_paddr_third[SQ_SIZE];
  logic [2:0][1:0] sq_pbmt[SQ_SIZE];
  logic [XLEN-1:0] sq_wdata[SQ_SIZE];
  logic [63:0] sq_wdata64[SQ_SIZE];
  logic sq_fp64[SQ_SIZE];
  // A2: SQ full state tracker (for pmu_sq_full rising-edge detection)
  logic sq_full_r;

  logic sq_alloc_ready;
  logic sq_commit_fire;
  logic sq_drain_fire;

  assign sq_alloc_fire  = completion_accept && exu_ioq_bcast.valid && exu_ioq_bcast.wen;
  assign sq_alloc_ready = !sq_valid[sq_tail];
  assign sq_commit_fire = rou_lsu.valid && rou_lsu.store;
  assign exu_lsu.stq_ready = sq_alloc_ready;

  // Commit never blocks: the entry already exists (allocated at writeback,
  // which precedes ROB_WB state and therefore commit) and marking it
  // committed consumes no new slot.  This removes the former SQ-full commit
  // stall in ROU (head0_store_ready).
  assign rou_lsu.sq_ready = 1'b1;
  // Width-stable 1-bit occupancy probes: consumed by the sim testbench
  // (quiesce/PMU) so host code never depends on SQ_SIZE's bit width.
  // sq_all_full has no RTL reader -- it exists for the PMU sq-full counter.
  logic sq_all_empty;
  logic [31:0] sq_snapshot_valid;
  logic [31:0] sq_snapshot_committed;
  logic [7:0] sq_snapshot_capacity;
  logic [7:0] sq_snapshot_head;
  /* verilator lint_off UNUSEDSIGNAL */
  logic sq_all_full;
  /* verilator lint_on UNUSEDSIGNAL */
  assign sq_all_empty = (sq_valid == '0) && (state_store == LS_S_V);
  assign sq_snapshot_valid = 32'(sq_valid);
  assign sq_snapshot_committed = 32'(sq_committed);
  assign sq_snapshot_capacity = 8'(SQ_SIZE);
  assign sq_snapshot_head = 8'(sq_head);
  assign sq_all_full  = &sq_valid;
  assign rou_lsu.sq_empty = sq_all_empty;

  // Drain source: oldest committed entry.
  logic wvalid;
  logic [XLEN-1:0] wdata;
  logic [63:0] wdata64;
  logic wfp64;
  logic [XLEN-1:0] waddr;
  logic [4:0] walu;
  assign wvalid = sq_valid[sq_head] && sq_committed[sq_head];
  assign wdata  = sq_wdata[sq_head];
  assign wdata64 = sq_wdata64[sq_head];
  assign wfp64 = sq_fp64[sq_head];
  assign waddr  = sq_paddr[sq_head];
  assign walu   = sq_alu[sq_head];

  logic [XLEN-1:0] difftest_store_addr;
  logic [XLEN-1:0] difftest_store_data;
  logic [7:0]      difftest_store_wstrb;
  // Observe the retiring resident, not the drain head or transient completion.
  // sq_cmt still names this owner when commit and flush share a clock edge.
`ifdef RAPT_RV64
  assign difftest_store_addr  = sq_paddr[sq_cmt];
  assign difftest_store_data  = sq_wdata[sq_cmt];
  assign difftest_store_wstrb = {3'b0, sq_alu[sq_cmt]};
`else
  // NEMU records the second 32-bit write of RV32 FSD, which is its final
  // vaddr_write() call for the instruction.
  assign difftest_store_addr  = sq_fp64[sq_cmt] ? sq_paddr_hi[sq_cmt] + XLEN'(sq_paddr[sq_cmt][1:0])
                                              : sq_paddr[sq_cmt];
  assign difftest_store_data  = sq_fp64[sq_cmt] ? sq_wdata64[sq_cmt][63:32]
                                              : sq_wdata[sq_cmt];
  assign difftest_store_wstrb = sq_fp64[sq_cmt] ? 8'h0f : {3'b0, sq_alu[sq_cmt]};
`endif

  task automatic report_store_diff(input logic [XLEN-1:0] addr, input logic [XLEN-1:0] data,
                                   input logic [7:0] strb, input logic [4:0] alu);
    if (alu == `RAPT_CBO_ZERO_WALU) begin
      for (int beat = 0; beat < CboBeats; beat++) begin
        `RAPT_DPI_C_NPC_DIFFTEST_MEM_DIFF({addr[XLEN-1:6], 6'b0} + XLEN'(beat * (XLEN / 8)), '0,
                                          CboBusWstrb)
      end
    end else begin
      `RAPT_DPI_C_NPC_DIFFTEST_MEM_DIFF(addr, data, strb)
    end
  endtask

  assign raddr = exu_lsu.raddr;
  assign ralu = exu_lsu.ralu;

  // Drain completion: FSM signals release of the head entry.
  assign sq_drain_fire = (state_store == LS_S_R || state_store == LS_S_HI_R
                       || state_store == LS_S_X_R || state_store == LS_S_CBO_R)
                       && sq_valid[sq_head];

  logic [SQ_SIZE-1:0] sq_alloc_oh;
  logic [SQ_SIZE-1:0] sq_commit_oh;
  logic [SQ_SIZE-1:0] sq_drain_oh;
  logic [SQ_SIZE-1:0] sq_flush_clear_oh;
  always_comb begin
    sq_alloc_oh = '0;
    sq_commit_oh = '0;
    sq_drain_oh = '0;
    sq_flush_clear_oh = '0;
    if (sq_alloc_fire && !(cmu_bcast.flush_pipe || cmu_bcast.fence_time))
      sq_alloc_oh[sq_tail] = 1'b1;
    if (sq_commit_fire) sq_commit_oh[sq_cmt] = 1'b1;
    if (sq_drain_fire) sq_drain_oh[sq_head] = 1'b1;
    if (cmu_bcast.flush_pipe || cmu_bcast.fence_time) begin
      for (int i = 0; i < SQ_SIZE; i++) begin
        if (sq_valid[i] && !sq_committed[i] && !sq_commit_oh[i]) sq_flush_clear_oh[i] = 1'b1;
      end
    end
  end

  always_ff @(posedge clock) begin
    if (reset) begin
      sq_head      <= '0;
      sq_cmt       <= '0;
      sq_tail      <= '0;
      sq_valid     <= '0;
      sq_committed <= '0;
      pmu_sq_full  <= 1'b0;
      sq_full_r    <= 1'b0;
      // SQ payload arrays (alu/dest/vaddr/paddr/wdata) are intentionally NOT
      // reset: the store FSM only reads sq_*[sq_head] for valid entries, and
      // the forwarding CAM ANDs every address comparison with sq_valid[idx],
      // so invalid entries never match or drain.  The data flops are
      // don't-care (same principle as rapt_prf); skipping them removes
      // ~SQ_SIZE*(2*XLEN+...) endpoints from the reset network.
    end else begin
      // A2: Latch current full status (rising-edge detection for pmu_sq_full)
      pmu_sq_full <= (&sq_valid) && !sq_full_r;
      sq_full_r   <= (&sq_valid);

      // ---- Allocate / commit / flush (speculative side) ----
      if (cmu_bcast.flush_pipe || cmu_bcast.fence_time) begin
        // Roll back the speculative region.  Committed entries [head,cmt)
        // are architectural state and keep draining.  AMOs are stores that
        // also serialize the pipeline, so their ROB commit can coincide with
        // the flush; preserve that commit mark while discarding younger work.
        sq_tail <= sq_cmt + SQLen'(sq_commit_fire);
        if (sq_commit_fire) begin
          sq_cmt <= sq_cmt + 1'b1;
          report_store_diff(difftest_store_addr, difftest_store_data, difftest_store_wstrb,
                            sq_alu[sq_cmt]);
        end
      end else begin
        if (sq_alloc_fire) begin
          sq_alu[sq_tail]   <= exu_ioq_bcast.alu[4:0];
          sq_acquire_q[sq_tail] <= sq_acquire;
          sq_dest[sq_tail]  <= exu_ioq_bcast.dest;
          sq_vaddr[sq_tail] <= exu_ioq_bcast.tval;      // virtual (forwarding)
          sq_paddr[sq_tail] <= exu_ioq_bcast.sq_waddr;  // physical (drain)
          sq_paddr_hi[sq_tail] <= sq_waddr_hi;
          sq_paddr_third[sq_tail] <= sq_waddr_third;
          sq_pbmt[sq_tail] <= sq_wpbmt;
          sq_wdata[sq_tail] <= exu_ioq_bcast.sq_wdata;
          sq_wdata64[sq_tail] <= exu_ioq_bcast.sq_wdata64;
          sq_fp64[sq_tail] <= exu_ioq_bcast.sq_fp64;
          sq_tail <= sq_tail + 1'b1;
        end
        if (sq_commit_fire) begin
          sq_cmt <= sq_cmt + 1'b1;
          report_store_diff(difftest_store_addr, difftest_store_data, difftest_store_wstrb,
                            sq_alu[sq_cmt]);
        end
      end

      // ---- Drain release (committed side; independent of flush) ----
      if (sq_drain_fire) begin
        sq_head <= sq_head + 1'b1;
      end

      // Static per-entry state muxes. Drain is textually last in the former
      // implementation, so it retains highest priority on any pointer alias.
      for (int i = 0; i < SQ_SIZE; i++) begin
        if (sq_drain_oh[i]) sq_valid[i] <= 1'b0;
        else if (sq_flush_clear_oh[i]) sq_valid[i] <= 1'b0;
        else if (sq_alloc_oh[i]) sq_valid[i] <= 1'b1;

        if (sq_drain_oh[i]) sq_committed[i] <= 1'b0;
        else if (sq_commit_oh[i]) sq_committed[i] <= 1'b1;
      end
    end
  end

  // ==========================================================================
  //  Load conflict detection + store-to-load forwarding (single CAM).
  //  Ring order from head == program order, so "last match scanning from
  //  head" == youngest matching store -- this replaces the former separate
  //  STQ/SQ CAMs and their STQ-over-SQ priority mux.
  // ==========================================================================
  logic load_in_sq;
  logic sq_fwd_ok;
  // A typed store cannot satisfy an untranslated load by VA forwarding:
  // the load may be an IO access whose external read has a side effect.
  // Conservatively disable forwarding while any typed store is resident.
  logic sq_has_typed_store;
  always_comb begin
    sq_has_typed_store = (csr_bcast.menvcfg_pbmte && csr_bcast.dmmu_en)
                      || (sq_alloc_fire && (|sq_wpbmt));
    for (int i = 0; i < SQ_SIZE; i++) sq_has_typed_store |= sq_valid[i] && (|sq_pbmt[i]);
  end
  logic [XLEN-1:0] sq_fwd_data;
`ifdef RAPT_LSU_HUM
  localparam int ForwardPorts = 2;
`else
  localparam int ForwardPorts = 1;
`endif
  logic [XLEN-1:0] forward_addr[ForwardPorts], forward_data[ForwardPorts];
  logic [3:0] forward_size_m1[ForwardPorts];
  logic [3:0] lsu_load_size_m1;
  logic [ForwardPorts-1:0] forward_conflict, forward_valid;
  logic [1:0] lsu_eff_priv;
  assign forward_addr[0] = raddr;
  assign forward_size_m1[0] = lsu_load_size_m1;
  assign load_in_sq = forward_conflict[0];
  assign sq_fwd_ok = forward_valid[0];
  assign sq_fwd_data = forward_data[0];
  rapt_sq_forward #(
      .Xlen(XLEN),
      .Entries(SQ_SIZE),
      .ReadPorts(ForwardPorts)
  ) u_forward (
      .head(sq_head),
      .valid(sq_valid),
      .stale_context(sq_stale_context),
      .store_addr(sq_vaddr),
      .store_data(sq_wdata),
      .store_alu(sq_alu),
      .full_store_mask(FullStoreWstrb),
      .store_fp64(sq_fp64),
      .mmu_enabled(csr_bcast.dmmu_en),
      .alloc_valid(sq_alloc_fire),
      .alloc_addr(exu_ioq_bcast.tval),
      .alloc_alu(exu_ioq_bcast.alu[4:0]),
      .alloc_fp64(exu_ioq_bcast.sq_fp64),
      .load_addr(forward_addr),
      .conflict(forward_conflict),
      .load_size_m1(forward_size_m1),
      .forward_valid(forward_valid),
      .forward_data(forward_data)
  );

  // Store-to-load forwarding hit.
  // NOTE: `fwd_hit` assignment is deferred until after `ma_span` is computed
  // below, because misaligned loads that cross a word boundary cannot be
  // satisfied by the word-granular SQ match (the high half lives in the
  // next word, which the matched store does not cover).  See assign block
  // immediately following the `ma_span` definition.
  logic fwd_hit;
  logic [XLEN-1:0] fwd_data;
  assign fwd_data = sq_fwd_data;

  // Release orders the atomic read after all older writes. IOQ head order
  // ensures resident SQ entries are older than this atomic. Keep the wait
  // before forwarding, splitting and cache admission; SQ empty includes the
  // drain FSM and is reached only after downstream write completion.
  logic atomic_release_wait;
  assign atomic_release_wait = exu_lsu.atomic_release && !sq_all_empty;
  // Atomic commit flush removes pre-commit speculation, but its successful
  // store survives in SQ. Preserve acquire through downstream completion
  // so refetched loads cannot pass that still-pending architectural write.
  assign raddr_valid = exu_lsu.rvalid && !atomic_release_wait && !sq_has_acquire;

  // ==========================================================================
  //  Misaligned load support
  //    Splits a load that crosses a word (RV32) / dword (RV64) boundary into
  //    aligned cache/bus transactions, then merges the beats before handing
  //    the result back to the EXU. Integer accesses need two beats; an
  //    unaligned RV32 FLD can span three 32-bit words.
  //    Covers LH[U] crossing (raddr[1:0]==3), LW[U] at any non-zero low-bit
  //    alignment, and (RV64) LD with raddr[2:0]!=0.
  // ==========================================================================
  localparam int OFFW = $clog2(XLEN / 8);  // 2 for RV32, 3 for RV64
  typedef enum logic [1:0] {
    MA_IDLE = 2'b00,  // normal aligned flow
    MA_HI   = 2'b01,  // lo half latched, requesting hi half
    MA_X    = 2'b10,  // RV32D unaligned FLD: request the third word
    MA_DONE = 2'b11   // all beats latched, presenting merged rdata
  } ma_state_t;
  ma_state_t ma_state;
  logic [XLEN-1:0] ma_lo_data;
  logic [XLEN-1:0] ma_hi_data;
  logic [XLEN-1:0] ma_x_data;
  logic ma_fault;
  logic ma_skip;
  logic [XLEN-1:0] ma_fault_cause;
  logic [XLEN-1:0] ma_fault_tval;

  // Detect an access that must be split into multiple aligned beats.
  logic ma_span;
  logic [4:0] ma_end_offset;
  assign ma_end_offset = 5'(raddr[OFFW-1:0]) + 5'(lsu_load_size_m1) + 5'd1;
  assign ma_span = ma_end_offset > 5'(XLEN/8);
  // A split load waits for stores overlapping ANY of its words before
  // starting. The later split beats must not sample an older SQ value.
  // Single-word forwarding cannot supply the complete split result.
  //
  // Device (MMIO) ordering: an uncacheable load must not forward from, nor
  // bypass, ANY older store still in the SQ -- not just same-address ones.
  // A device read may depend on a side effect of a prior write to a
  // DIFFERENT device register.  Observed on KU15P (SQ_SIZE=8): memspeed's
  // timer0 update CSR write sat behind 2 MiB of DDR4 stores in the SQ while
  // the timer0 value CSR read (different address, no conflict) issued
  // immediately -> read the stale latch -> start-end==0 -> __udivdi3
  // divide-by-zero ebreak -> jump to PC=0.  Zero-latency sim never exposes
  // this window.  Mirrors the IOQ's `dmmu_en ||` bypass: with the MMU on,
  // raddr is virtual and the physical cacheability is unknown here.
  logic mmio_ordered;
  assign mmio_ordered = !csr_bcast.dmmu_en && !rapt_pkg::addr_cacheable(raddr);
  logic mmio_load_blocked;
  assign mmio_load_blocked = (mmio_ordered || (csr_bcast.menvcfg_pbmte && csr_bcast.dmmu_en))
                          && !((sq_valid == '0) && (state_store == LS_S_V));
  // LR must reach L1D to establish a physical-address reservation. If an
  // older same-address store is still in the SQ, wait for it to drain rather
  // than completing LR through the ordinary load-forwarding path.
  assign fwd_hit = !exu_lsu.atomic_lock
                && !ma_span && !mmio_ordered && !sq_has_typed_store && load_in_sq && sq_fwd_ok;
  logic pmp_load_fault_lsu;
  logic pmp_load_fault_raw;
  // Virtual addresses cannot be checked against physical PMP entries.
  // Translated fragments receive their PA checks in L1D.
  assign pmp_load_fault_lsu = !csr_bcast.dmmu_en && pmp_load_fault_raw;
  // Only engage the split for requests that actually reach the cache
  // (no SQ forward/conflict).  Forwarded loads keep the single-shot path;
  // the full load footprint has already been checked against the SQ.
  logic lr_alignment_fault;
  // LR is indivisible: validate its original address before ordinary-load
  // splitting can align it down or replace its access width.
  assign lr_alignment_fault = raddr_valid && exu_lsu.atomic_lock
      && |(raddr & XLEN'(lsu_load_size_m1));
  logic ma_load_req;
  assign ma_load_req = !lr_alignment_fault && raddr_valid && ma_span && !fwd_hit && !load_in_sq && !pmp_load_fault_lsu;

  // ==========================================================================
  //  Hit-under-miss B channel (Phase A2, RAPT_LSU_HUM)
  //  Best-effort second load while the A channel waits on a miss.  Same
  //  correctness rules as A, but with no trap response or MA-split path: any load
  //  that cannot complete cleanly on B simply never gets rready_b and later
  //  retries via A.  Aligned loads only; MMIO excluded (device ordering);
  //  SQ conflicts stall B exactly like A (partial-store match blocks,
  //  full-width youngest match forwards).
  // ==========================================================================
`ifdef RAPT_LSU_HUM
  logic [XLEN-1:0] raddr_b;
  logic [4:0] ralu_b;
  assign raddr_b = exu_lsu.raddr_b;
  assign ralu_b  = exu_lsu.ralu_b;

  // B-side SQ CAM (parallel to A's; youngest match wins)
  logic load_in_sq_b;
  logic sq_fwd_ok_b;
  logic [XLEN-1:0] sq_fwd_data_b;
  assign forward_addr[1] = raddr_b;
  assign load_in_sq_b = forward_conflict[1];
  assign sq_fwd_ok_b = forward_valid[1];
  assign sq_fwd_data_b = forward_data[1];

  logic ma_span_b;
  logic ma_span_rv64_b;
`ifdef RAPT_RV64
  assign ma_span_rv64_b = ((ralu_b == `RAPT_ALU_LWU_) && (raddr_b[1:0] != 2'b00))
      || ((ralu_b == `RAPT_ALU_LD__) && (raddr_b[OFFW-1:0] != '0));
`else
  assign ma_span_rv64_b = 1'b0;
`endif
  assign ma_span_b =
       ((ralu_b == `RAPT_ALU_LH__ || ralu_b == `RAPT_ALU_LHU_) && raddr_b[1:0] == 2'b11)
    || ((ralu_b == `RAPT_ALU_LW__) && (raddr_b[1:0] != 2'b00))
    || ma_span_rv64_b;
  logic mmio_ordered_b;
  assign mmio_ordered_b = !csr_bcast.dmmu_en && !rapt_pkg::addr_cacheable(raddr_b);

  // B has no trap response. Check its own complete physical byte range
  // before either SQ forwarding or L1D admission; denied loads remain in
  // the IOQ and retry through A, which reports the architectural exception.
  // With translation enabled this address is virtual. The existing L1D
  // B contract rejects untranslated requests; do not PMP-check a VA here.
  logic [3:0] b_size_m1;
  logic b_pmp_fault, b_bare_fault;
  assign b_size_m1 = (4'd1 << ralu_b[1:0]) - 4'd1;
  assign forward_size_m1[1] = b_size_m1;
  rapt_pmp #(
      .XLEN(XLEN)
  ) u_pmp_load_b (
      .addr(raddr_b),
      .size_m1(b_size_m1),
      .priv(lsu_eff_priv),
      .op_r(1'b1),
      .op_w(1'b0),
      .op_x(1'b0),
      .pmp_raw_addr(pmp_state.pmp_raw_addr),
      .pmp_napot_mask(pmp_state.pmp_napot_mask),
      .pmp_cfg_r(pmp_state.pmp_cfg_r),
      .pmp_cfg_w(pmp_state.pmp_cfg_w),
      .pmp_cfg_x(pmp_state.pmp_cfg_x),
      .pmp_cfg_l(pmp_state.pmp_cfg_l),
      .pmp_mode_off(pmp_state.pmp_mode_off),
      .pmp_mode_tor(pmp_state.pmp_mode_tor),
      .pmp_mode_na4(pmp_state.pmp_mode_na4),
      .pmp_mode_napot(pmp_state.pmp_mode_napot),
      .fault(b_pmp_fault),
      .fault_lo_o()
  );
  assign b_bare_fault = !csr_bcast.dmmu_en && (b_pmp_fault || !rapt_pkg::addr_data_span_capable(
      raddr_b, b_size_m1, 1'b0
  ));

  logic fwd_hit_b;
  assign fwd_hit_b = exu_lsu.rvalid_b && !sq_has_acquire && !ma_span_b && !mmio_ordered_b && !sq_has_typed_store
                  && !b_bare_fault && load_in_sq_b && sq_fwd_ok_b;

  // Pass to L1D only when nothing local blocks it.
  assign lsu_l1d.rvalid_b = exu_lsu.rvalid_b && !sq_has_acquire && !fwd_hit_b && !load_in_sq_b
                         && !ma_span_b && !mmio_ordered_b && !b_bare_fault;
  assign lsu_l1d.raddr_b  = raddr_b;
  assign lsu_l1d.ralu_b   = ralu_b;

  // B load data path: align + extend (parallel to A's)
  logic [XLEN-1:0] rdata_b_unalign;
  logic [XLEN-1:0] rdata_b_al;
  logic [XLEN-1:0] rdata_b_word;
  assign rdata_b_unalign = fwd_hit_b ? sq_fwd_data_b : lsu_l1d.rdata_b;
  assign rdata_b_al = rdata_b_unalign >> (raddr_b[OFFW-1:0] * 8);
`ifdef RAPT_RV64
  assign rdata_b_word = ({XLEN{ralu_b == `RAPT_ALU_LW__}}
                          & {{XLEN-32{rdata_b_al[31]}}, rdata_b_al[31:0]})
                      | ({XLEN{ralu_b == `RAPT_ALU_LWU_}}
                          & {{XLEN-32{1'b0}}, rdata_b_al[31:0]})
                      | ({XLEN{ralu_b == `RAPT_ALU_LD__}} & rdata_b_al);
`else
  assign rdata_b_word = {XLEN{ralu_b == `RAPT_ALU_LW__}} & rdata_b_al;
`endif
  assign exu_lsu.rdata_b = (
      ({XLEN{ralu_b == `RAPT_ALU_LB__}} & {{XLEN-8{rdata_b_al[7]}}, rdata_b_al[7:0]})
    | ({XLEN{ralu_b == `RAPT_ALU_LBU_}} & {{XLEN-8{1'b0}}, rdata_b_al[7:0]})
    | ({XLEN{ralu_b == `RAPT_ALU_LH__}} & {{XLEN-16{rdata_b_al[15]}}, rdata_b_al[15:0]})
    | ({XLEN{ralu_b == `RAPT_ALU_LHU_}} & {{XLEN-16{1'b0}}, rdata_b_al[15:0]})
    | rdata_b_word
    );
  // A downstream ready cannot complete a locally blocked query. Qualify it
  // with the admitted B request, including SQ alias and alignment checks.
  assign exu_lsu.rready_b = fwd_hit_b || (lsu_l1d.rvalid_b && lsu_l1d.rready_b);
`else
  assign lsu_l1d.rvalid_b = 1'b0;
  assign lsu_l1d.raddr_b  = '0;
  assign lsu_l1d.ralu_b   = '0;
  assign exu_lsu.rdata_b  = '0;
  assign exu_lsu.rready_b = 1'b0;
  /* verilator lint_off UNUSEDSIGNAL */
  logic _unused_hum_lsu;
  assign _unused_hum_lsu = exu_lsu.rvalid_b ^ (^exu_lsu.raddr_b)
                         ^ (^exu_lsu.ralu_b) ^ lsu_l1d.rready_b
                         ^ (^lsu_l1d.rdata_b);
  /* verilator lint_on UNUSEDSIGNAL */
`endif

  // --- Pre-split PMP check on the ORIGINAL misaligned address ---
  // The MA-split path below turns a misaligned load into aligned requests;
  // L1D's PMP sees only those beat addresses and cannot
  // detect a partial-region violation that straddles a PMP boundary.
  // Check the un-split access here so partial matches trap correctly.
  assign lsu_eff_priv = (csr_bcast.priv == `RAPT_PRIV_M && csr_bcast.mprv)
                        ? csr_bcast.mpp : csr_bcast.priv;

  // ==========================================================================
  //  Misaligned store support
  //    SW/SH at `waddr[OFFW-1:0]` crossing a word (RV32) / dword (RV64)
  //    boundary is split into aligned beats.  Beat 0 is aligned down and its
  //    mask/data are shifted into the affected low lanes; this also ensures
  //    the AXI transfer itself never crosses a 4-KiB boundary.  Beat 1 drives
  //    the next aligned address with the spilled bytes shifted down to byte 0.
  // ==========================================================================
  logic ma_store_span;
  logic ma_store_third;
  logic [XLEN-1:0] ma_waddr_lo;
  logic [XLEN-1:0] ma_waddr_hi;
  logic [XLEN-1:0] ma_waddr_third;
  logic [7:0]      ma_walu_hi;
  logic [7:0]      ma_walu_lo;
  logic [7:0]      ma_walu_third;
  logic [XLEN-1:0] ma_wdata_lo;
  logic [XLEN-1:0] ma_wdata_hi;
  logic [XLEN-1:0] ma_wdata_third;

  always_comb begin
    unique case (ralu[1:0])
      2'b00:   lsu_load_size_m1 = 4'd0;
      2'b01:   lsu_load_size_m1 = 4'd1;
      2'b10:   lsu_load_size_m1 = 4'd3;
      2'b11:   lsu_load_size_m1 = 4'd7;
      default: lsu_load_size_m1 = 4'd3;
    endcase
    if (exu_lsu.fp_rdata64_req) lsu_load_size_m1 = 4'd7;
  end
  rapt_pmp #(
      .XLEN(XLEN)
  ) u_pmp_load_lsu (
      .addr   (raddr),
      .size_m1(lsu_load_size_m1),
      .priv   (lsu_eff_priv),
      .op_r   (1'b1),
      .op_w   (1'b0),
      .op_x   (1'b0),
      .pmp_raw_addr   (pmp_state.pmp_raw_addr),
      .pmp_napot_mask (pmp_state.pmp_napot_mask),
      .pmp_cfg_r      (pmp_state.pmp_cfg_r),
      .pmp_cfg_w      (pmp_state.pmp_cfg_w),
      .pmp_cfg_x      (pmp_state.pmp_cfg_x),
      .pmp_cfg_l      (pmp_state.pmp_cfg_l),
      .pmp_mode_off   (pmp_state.pmp_mode_off),
      .pmp_mode_tor   (pmp_state.pmp_mode_tor),
      .pmp_mode_na4   (pmp_state.pmp_mode_na4),
      .pmp_mode_napot (pmp_state.pmp_mode_napot),
      .fault  (pmp_load_fault_raw),
      .fault_lo_o()
  );

  // Aligned request addresses. MA_X is only used by an unaligned RV32 FLD.
  logic [XLEN-1:0] ma_raddr_lo, ma_raddr_hi, ma_raddr_x;
  logic ma_load_third;
  assign ma_raddr_lo = {raddr[XLEN-1:OFFW], {OFFW{1'b0}}};
  assign ma_raddr_hi = ma_raddr_lo + XLEN'(XLEN/8);
  assign ma_raddr_x  = ma_raddr_hi + XLEN'(XLEN/8);
  assign ma_load_third = (XLEN == 32) && exu_lsu.fp_rdata64_req
                       && (raddr[OFFW-1:0] != '0);

  // Merge aligned words so byte 0 of the result corresponds to `raddr`.
  // Integer results use hi:lo; RV32 FLD uses x:hi:lo to cover a possible
  // three-word span.
  logic [2*XLEN-1:0] ma_cat;
  logic [3*XLEN-1:0] ma_cat3;
  logic [XLEN-1:0]   ma_merged;
  logic [$clog2(2*XLEN)-1:0] ma_shift;
  assign ma_shift  = {{($clog2(2*XLEN)-OFFW-3){1'b0}}, raddr[OFFW-1:0], 3'b000};
  assign ma_cat    = {ma_hi_data, ma_lo_data};
  assign ma_cat3   = {ma_x_data, ma_hi_data, ma_lo_data};
  assign ma_merged = ma_cat[ma_shift +: XLEN];

  // Address/rvalid muxing toward the L1D interface.
  logic [XLEN-1:0] ma_req_addr;
  logic [4:0]      ma_req_alu;
`ifdef RAPT_RV64
  localparam logic [4:0] MaLoadAlu = `RAPT_ALU_LD__;
`else
  localparam logic [4:0] MaLoadAlu = `RAPT_ALU_LW__;
`endif
  assign ma_req_addr = (ma_state == MA_X)  ? ma_raddr_x
                     : (ma_state == MA_HI) ? ma_raddr_hi
                     : (ma_load_req)        ? ma_raddr_lo
                     :                        raddr;
  // Force an aligned word/dword load opcode during the split so the L1D
  // never sees a "misaligned" request.
  assign ma_req_alu = (ma_state == MA_HI || ma_state == MA_X || ma_load_req)
                    ? MaLoadAlu : ralu;
  logic [4:0] ma_beat_start, ma_check_start, ma_check_end;
  assign ma_beat_start = ma_state == MA_X ? 5'(2*XLEN/8)
                       : ma_state == MA_HI ? 5'(XLEN/8) : 5'd0;
  assign ma_check_start = ma_beat_start == 0 ? 5'(raddr[OFFW-1:0]) : ma_beat_start;
  assign ma_check_end = ma_end_offset < ma_beat_start + 5'(XLEN/8)
                       ? ma_end_offset : ma_beat_start + 5'(XLEN/8);
  assign lsu_l1d.rorig_size_m1 = lsu_load_size_m1;
  assign lsu_l1d.rcheck_valid = ma_state == MA_HI || ma_state == MA_X || ma_load_req;
  assign lsu_l1d.rcheck_offset = 3'(ma_check_start - ma_beat_start);
  assign lsu_l1d.rcheck_size_m1 = 4'(ma_check_end - ma_check_start - 5'd1);

  // ==========================================================================
  //  Load data path -- uses the split-merge result when ma_state == MA_DONE.
  // ==========================================================================
  // logic [7:0] wstrb;
  // assign wstrb = (
  //          ({8{ralu == `RAPT_ALU_SB}} & 8'h1) |
  //          ({8{ralu == `RAPT_ALU_SH}} & 8'h3) |
  //          ({8{ralu == `RAPT_ALU_SW}} & 8'hf)
  //        );

  assign rdata_unalign = (raddr_valid && fwd_hit) ? fwd_data
                      : (ma_state == MA_DONE)     ? ma_merged
                      :                             lsu_l1d.rdata;
  // For the split path the merged word already starts at byte 0, so skip the
  // single-shot alignment shift.
  assign rdata = (ma_state == MA_DONE)
               ? rdata_unalign
               : (rdata_unalign >> (raddr[OFFW-1:0] * 8));

  assign exu_lsu.fp_rdata64_valid = exu_lsu.fp_rdata64_req
                && ((ma_state == MA_DONE) || (lsu_l1d.rvalid && lsu_l1d.rready));
  assign exu_lsu.fp_rdata64 = (XLEN == 32)
            ? ma_cat3[$clog2(3*XLEN)'(ma_shift) +: 64]
            : {{(64-XLEN){1'b0}}, rdata};

  logic [XLEN-1:0] rdata_word;
`ifdef RAPT_RV64
  assign rdata_word = ({XLEN{ralu == `RAPT_ALU_LW__}} & {{XLEN-32{rdata[31]}}, rdata[31:0]})
                    | ({XLEN{ralu == `RAPT_ALU_LWU_}} & {{XLEN-32{1'b0}}, rdata[31:0]})
                    | ({XLEN{ralu == `RAPT_ALU_LD__}} & rdata);
`else
  assign rdata_word = {XLEN{ralu == `RAPT_ALU_LW__}} & rdata;
`endif
  assign exu_lsu.rdata = (
      ({XLEN{ralu == `RAPT_ALU_LB__}} & {{XLEN-8{rdata[7]}}, rdata[7:0]})
    | ({XLEN{ralu == `RAPT_ALU_LBU_}} & {{XLEN-8{1'b0}}, rdata[7:0]})
    | ({XLEN{ralu == `RAPT_ALU_LH__}} & {{XLEN-16{rdata[15]}}, rdata[15:0]})
    | ({XLEN{ralu == `RAPT_ALU_LHU_}} & {{XLEN-16{1'b0}}, rdata[15:0]})
    | rdata_word
    );
  // A split beat can raise a real page/access fault, especially when the high
  // beat crosses into a differently mapped page.  Hold that fault until the
  // original instruction completes; never expose partially merged data.
  logic ma_active;
  assign ma_active = (ma_state != MA_IDLE) || ma_load_req;
  // Raise the pre-split PMP trap on the cycle the request is seen, so the
  // IOQ retires the load as a trap without touching the cache.
  logic lsu_pmp_trap;
  assign lsu_pmp_trap = raddr_valid && ma_span && pmp_load_fault_lsu
                     && !fwd_hit && !load_in_sq
                     && (ma_state == MA_IDLE);
  assign exu_lsu.trap = (lr_alignment_fault || lsu_pmp_trap) ? 1'b1
                      : (raddr_valid && fwd_hit) ? 1'b0
                      : (ma_state == MA_DONE) ? ma_fault
                      : ma_active             ? 1'b0
                      :                         lsu_l1d.trap;
  assign exu_lsu.cause = (lr_alignment_fault || lsu_pmp_trap) ? `RAPT_CAUSE_LOAD_ACC_FAULT
                         : ((ma_state == MA_DONE) && ma_fault) ? ma_fault_cause
                                       : lsu_l1d.cause;
  // The first split beat may align below the architectural address. Later
  // faulting beats identify the actually accessed portion (e.g. next page).
  assign exu_lsu.tval = (ma_state == MA_DONE && ma_fault) ? ma_fault_tval : raddr;
  assign exu_lsu.difftest_skip = (raddr_valid && fwd_hit) ? 1'b0
                              : (ma_state == MA_DONE) ? (ma_skip && !ma_fault)
                              : ma_active             ? 1'b1
                              :                         lsu_l1d.difftest_skip;
  // rready contract:
  //  - aligned hit / forward: one-cycle rready pulse (as before)
  //  - MA split:              hold rready low during LO/HI/X beats; raise it
  //                           once merged data is parked in MA_DONE.
  //  - pre-split PMP trap:    pulse rready immediately so IOQ retires.
  assign exu_lsu.rready = lr_alignment_fault || lsu_pmp_trap
                       || (raddr_valid && fwd_hit)
                       || (ma_state == MA_DONE)
                       || (lsu_l1d.rvalid && lsu_l1d.rready
                                        && !ma_load_req && ma_state == MA_IDLE);

  always_ff @(posedge clock) begin
    if (reset) begin
      state_store <= LS_S_V;
      cbo_zero_beat <= '0;
    end else begin
      if (lsu_l1d.wvalid && lsu_l1d.wready && lsu_l1d.werr) begin
        // The store already retired. Consume its failed beat and release
        // only this owner; do not issue the remaining split/zero beats.
        // Earlier beats cannot be rolled back. Platform notification of
        // this imprecise error is separate from architectural load traps.
        cbo_zero_beat <= '0;
        state_store <= LS_S_R;
      end else
        unique case (state_store)
          LS_S_V: begin
            if (wvalid) begin
              if (lsu_l1d.wready) begin
                if (walu == `RAPT_CBO_ZERO_WALU) begin
                  // Beat zero is accepted directly from LS_S_V.  Continue over
                  // every naturally aligned XLEN-wide word in the 64-byte block.
                  cbo_zero_beat <= CboBeatBits'(1);
                  state_store <= LS_S_CBO_V;
                end else begin
                  // Lo beat accepted. If the store straddles a word/dword boundary
                  // we still owe a high beat; otherwise retire.
                  state_store <= ma_store_span ? LS_S_HI_V : LS_S_R;
                end
              end
            end
          end
          LS_S_R: begin
            state_store <= LS_S_V;
          end
          LS_S_HI_V: begin
            if (lsu_l1d.wready) begin
              state_store <= ma_store_third ? LS_S_X_V : LS_S_HI_R;
            end
          end
          LS_S_HI_R: begin
            state_store <= LS_S_V;
          end
          LS_S_X_V: begin
            if (lsu_l1d.wready) begin
              state_store <= LS_S_X_R;
            end
          end
          LS_S_X_R: begin
            state_store <= LS_S_V;
          end
          LS_S_CBO_V: begin
            if (lsu_l1d.wready) begin
              if (cbo_zero_beat == CboBeatBits'(CboBeats - 1)) begin
                state_store <= LS_S_CBO_R;
              end else begin
                cbo_zero_beat <= cbo_zero_beat + 1'b1;
              end
            end
          end
          LS_S_CBO_R: begin
            cbo_zero_beat <= '0;
            state_store <= LS_S_V;
          end
          default: begin
            state_store <= LS_S_V;
          end
        endcase
    end
  end

  assign lsu_l1d.raddr = ma_req_addr;
  assign lsu_l1d.ralu = ma_req_alu;
  assign lsu_l1d.rmisaligned = |(raddr & XLEN'(lsu_load_size_m1));
  assign lsu_l1d.rvalid = !lr_alignment_fault && ((ma_state == MA_HI) || (ma_state == MA_X)
                       || (raddr_valid && !load_in_sq
                                       && !mmio_load_blocked
                                       && (ma_state == MA_IDLE)));
  assign lsu_l1d.atomic_lock = exu_lsu.atomic_lock;
  assign lsu_l1d.ordered = exu_lsu.ordered && sq_all_empty;

  // Misalign-split FSM.
  // Beat data is read only in MA_DONE (merged result), so its flops are
  // don't-care in MA_IDLE (same principle as rapt_prf); only the FSM state
  // needs reset.
  always_ff @(posedge clock) begin
    if (reset) begin
      ma_state <= MA_IDLE;
      ma_fault <= 1'b0;
      ma_skip <= 1'b0;
      ma_fault_cause <= '0;
    end else if (cmu_bcast.flush_pipe) begin
      ma_state <= MA_IDLE;
      ma_fault <= 1'b0;
      ma_skip <= 1'b0;
    end else begin
      unique case (ma_state)
        MA_IDLE: begin
          if (ma_load_req && lsu_l1d.rready) begin
            ma_skip <= lsu_l1d.difftest_skip;
            ma_fault <= lsu_l1d.trap;
            ma_fault_cause <= lsu_l1d.cause;
            ma_fault_tval <= raddr;
            if (lsu_l1d.trap) begin
              ma_state <= MA_DONE;
            end else begin
              ma_lo_data <= lsu_l1d.rdata;
              ma_state <= MA_HI;
            end
          end
        end
        MA_HI: begin
          if (lsu_l1d.rready) begin
            ma_skip <= ma_skip || lsu_l1d.difftest_skip;
            ma_fault <= lsu_l1d.trap;
            ma_fault_cause <= lsu_l1d.cause;
            ma_fault_tval <= ma_req_addr;
            if (!lsu_l1d.trap) ma_hi_data <= lsu_l1d.rdata;
            ma_state <= (!lsu_l1d.trap && ma_load_third) ? MA_X : MA_DONE;
          end
        end
        MA_X: begin
          if (lsu_l1d.rready) begin
            ma_skip <= ma_skip || lsu_l1d.difftest_skip;
            ma_fault <= lsu_l1d.trap;
            ma_fault_cause <= lsu_l1d.cause;
            ma_fault_tval <= ma_req_addr;
            if (!lsu_l1d.trap) ma_x_data <= lsu_l1d.rdata;
            ma_state <= MA_DONE;
          end
        end
        MA_DONE: begin
          // The IOQ may switch directly to another load after this response;
          // release ownership on the handshake instead of requiring an
          // otherwise-unrelated rvalid bubble.
          if (!exu_lsu.rvalid || exu_lsu.rready) begin
            ma_state <= MA_IDLE;
            ma_fault <= 1'b0;
          end
        end
        default: ma_state <= MA_IDLE;
      endcase
    end
  end

  rapt_store_beats #(
      .XLEN(XLEN)
  ) u_store_beats (
      .waddr(waddr),
      .waddr_hi(sq_paddr_hi[sq_head]),
      .wdata(wdata),
      .wdata64(wdata64),
      .wfp64(wfp64),
      .walu(walu),
      .waddr_third(sq_paddr_third[sq_head]),
      .ma_store_span(ma_store_span),
      .ma_store_third(ma_store_third),
      .ma_waddr_lo(ma_waddr_lo),
      .ma_waddr_hi(ma_waddr_hi),
      .ma_waddr_third(ma_waddr_third),
      .ma_wdata_lo(ma_wdata_lo),
      .ma_wdata_hi(ma_wdata_hi),
      .ma_wdata_third(ma_wdata_third),
      .ma_walu_lo(ma_walu_lo),
      .ma_walu_hi(ma_walu_hi),
      .ma_walu_third(ma_walu_third)
  );

  logic cbo_zero_active;
  logic [XLEN-1:0] cbo_zero_addr;
  assign cbo_zero_active = walu == `RAPT_CBO_ZERO_WALU
                        && (state_store == LS_S_V || state_store == LS_S_CBO_V);
  assign cbo_zero_addr = {waddr[XLEN-1:6], 6'b0}
                       + ((state_store == LS_S_CBO_V ? XLEN'(cbo_zero_beat) : XLEN'(0))
                              * XLEN'(XLEN / 8));

  // L1D drive muxing.
  assign lsu_l1d.wpbmt = (state_store == LS_S_HI_V) ? sq_pbmt[sq_head][1]
                       : (state_store == LS_S_X_V) ? sq_pbmt[sq_head][2]
                       : sq_pbmt[sq_head][0];
  assign lsu_l1d.waddr  = cbo_zero_active ? cbo_zero_addr
                       : (state_store == LS_S_HI_V) ? ma_waddr_hi
                       : (state_store == LS_S_X_V)  ? ma_waddr_third
                       : ma_store_span              ? ma_waddr_lo : waddr;
  assign lsu_l1d.walu   = cbo_zero_active ? CboBusWstrb
                       : (state_store == LS_S_HI_V) ? ma_walu_hi
                       : (state_store == LS_S_X_V)  ? ma_walu_third : ma_walu_lo;
  assign lsu_l1d.wvalid = (state_store == LS_S_V && wvalid)
                       || (state_store == LS_S_HI_V)
                       || (state_store == LS_S_X_V)
                       || (state_store == LS_S_CBO_V);
  assign lsu_l1d.wdata  = cbo_zero_active ? '0
                       : (state_store == LS_S_HI_V) ? ma_wdata_hi
                       : (state_store == LS_S_X_V)  ? ma_wdata_third
                       : ma_store_span              ? ma_wdata_lo : wdata;

  // ==========================================================================
  //  Assertions (enable with +define+RAPT_ASSERT_EN)
  //  Category legend:
  //    COMMIT_ORDER   : in-order commit marks the oldest speculative entry
  //    HANDSHAKE      : queue capacity / ready-valid contract
  //    FLUSH_ROLLBACK : flush drops exactly the speculative region
  // ==========================================================================

  // COMMIT_ORDER: if a store commit coincides with a flush (AMO/f_time), the
  // store being retired is the current commit-boundary entry and survives the
  // speculative rollback.
  `RAPT_SVA_IMPLY(clock, reset, LSU_SQ_COMMIT_ON_FLUSH_MATCH,
                  (sq_commit_fire && (cmu_bcast.flush_pipe || cmu_bcast.fence_time)),
                  (sq_valid[sq_cmt] && !sq_committed[sq_cmt] && sq_dest[sq_cmt] == rou_lsu.dest))

  // COMMIT_ORDER: the entry being commit-marked must exist, be speculative,
  // and belong to the store the ROB is retiring (stores commit in order, so
  // no CAM is needed -- this assertion proves that assumption holds).
  `RAPT_SVA_IMPLY(clock, reset, LSU_SQ_COMMIT_ENTRY_MATCH, (sq_commit_fire),
                  (sq_valid[sq_cmt] && !sq_committed[sq_cmt] && sq_dest[sq_cmt] == rou_lsu.dest))

  // COMMIT_ORDER: the alloc-time vaddr of the entry being committed must
  // describe the same word as the ROB's durable copy.  With DMMU enabled
  // only the page offset is invariant across translation.
  `RAPT_SVA_IMPLY(
      clock, reset, LSU_SQ_COMMIT_ADDR_PAGE_OFFSET, (sq_commit_fire && !$isunknown
      (rou_lsu.sq_vaddr) && !$isunknown(sq_vaddr[sq_cmt])),
      (csr_bcast.dmmu_en ? (sq_vaddr[sq_cmt][PageOffBits-1:WordOffBits] == rou_lsu.sq_vaddr[PageOffBits-1:WordOffBits]) : (sq_vaddr[sq_cmt][XLEN-1:WordOffBits] == rou_lsu.sq_vaddr[XLEN-1:WordOffBits])))

  // HANDSHAKE: the SQ drain target slot must be a valid committed entry.
  `RAPT_SVA_IMPLY(clock, reset, LSU_SQ_DRAIN_VALID,
                  (state_store == LS_S_R || state_store == LS_S_CBO_R),
                  (sq_valid[sq_head] && sq_committed[sq_head]))

  // HANDSHAKE: a load/AMO blocked by an older partial store must not complete
  // via a stale L1D rready from a request that was never issued.
  `RAPT_SVA_IMPLY(clock, reset, LSU_BLOCKED_LOAD_NOT_READY,
                  (raddr_valid && load_in_sq && !fwd_hit), (!exu_lsu.rready))

  // LR establishes its reservation in L1D and therefore cannot complete via
  // store-queue forwarding even when an older store fully covers its bytes.
  `RAPT_SVA_IMPLY(clock, reset, LSU_LR_NO_SQ_FORWARD, (raddr_valid && exu_lsu.atomic_lock),
                  (!fwd_hit))

  // HANDSHAKE: allocation requires a free slot at sq_tail.
  `RAPT_SVA_IMPLY(clock, reset, LSU_SQ_ALLOC_NEEDS_READY, (sq_alloc_fire), (sq_alloc_ready))

  // HANDSHAKE: alloc/commit/drain must target distinct entries whenever two
  // of them fire in the same cycle (single-writer-per-array discipline).
  `RAPT_SVA_IMPLY(clock, reset, LSU_SQ_ALLOC_COMMIT_DISTINCT, (sq_alloc_fire && sq_commit_fire),
                  (sq_tail != sq_cmt))
  `RAPT_SVA_IMPLY(clock, reset, LSU_SQ_COMMIT_DRAIN_DISTINCT, (sq_commit_fire && sq_drain_fire),
                  (sq_cmt != sq_head))

  // FLUSH_ROLLBACK: the cycle after a flush there are no speculative entries;
  // committed entries (still draining) are untouched.
  `RAPT_SVA_NEXT(clock, reset, LSU_SQ_FLUSH_ROLLBACK,
                 (cmu_bcast.flush_pipe || cmu_bcast.fence_time),
                 (sq_cmt == sq_tail && ((sq_valid & ~sq_committed) == '0)))
endmodule
/* verilator lint_on PINCONNECTEMPTY */
