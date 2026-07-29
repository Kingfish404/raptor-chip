`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_dpi_c.svh"

/* verilator lint_off PINCONNECTEMPTY */
module rapt_lsu #(
    parameter unsigned SQ_SIZE = `RAPT_SQ_SIZE,
    parameter int XLEN = `RAPT_XLEN
) (
    input clock,

    cmu_bcast_if.in cmu_bcast,

    lsu_l1d_if.master lsu_l1d,

    exu_lsu_if.slave exu_lsu,
    exu_wb_if.in exu_ioq_bcast,
    rou_lsu_if.in rou_lsu,

    csr_bcast_if.in csr_bcast,
    pmp_update_if.in pmp_update,

    // A2: PMU: one-cycle pulse when SQ becomes full
    /* verilator lint_off UNUSEDSIGNAL */
    output logic pmu_sq_full,
    /* verilator lint_on UNUSEDSIGNAL */

    input reset
);
  pmp_state_if pmp_state ();

  rapt_pmp_state pmp_state_regs (
      .clock,
      .reset,
      .update(pmp_update),
      .state(pmp_state)
  );

  localparam int WordOffBits = $clog2(XLEN / 8);
  localparam int PageOffBits = 12;
  localparam int SQLen = $clog2(SQ_SIZE);
  localparam int ROBLen = $clog2(`RAPT_ROB_SIZE);

  typedef enum logic [1:0] {
    LS_S_V    = 2'b00,  // present lo beat, wait for wready
    LS_S_R    = 2'b01,  // lo beat retired; aligned case completes here
    LS_S_HI_V = 2'b10,  // misaligned: present hi beat, wait for wready
    LS_S_HI_R = 2'b11   // hi beat retired; SQ entry released next cycle
  } state_store_t;

  state_store_t state_store;

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
  logic [4:0] sq_alu[SQ_SIZE];
  /* verilator lint_off UNUSEDSIGNAL */
  logic [ROBLen-1:0] sq_dest[SQ_SIZE];  // ROB id: assertions/debug only
  /* verilator lint_on UNUSEDSIGNAL */
  logic [XLEN-1:0] sq_vaddr[SQ_SIZE];  // virtual : forwarding comparison
  logic [XLEN-1:0] sq_paddr[SQ_SIZE];  // physical: bus write-through
  logic [XLEN-1:0] sq_wdata[SQ_SIZE];
  // A2: SQ full state tracker (for pmu_sq_full rising-edge detection)
  logic sq_full_r;

  logic sq_alloc_fire;
  logic sq_alloc_ready;
  logic sq_commit_fire;
  logic sq_drain_fire;

  assign sq_alloc_fire  = exu_ioq_bcast.valid && exu_ioq_bcast.wen;
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
  logic [XLEN-1:0] waddr;
  logic [4:0] walu;
  assign wvalid = sq_valid[sq_head] && sq_committed[sq_head];
  assign wdata  = sq_wdata[sq_head];
  assign waddr  = sq_paddr[sq_head];
  assign walu   = sq_alu[sq_head];

  assign raddr = exu_lsu.raddr;
  assign ralu = exu_lsu.ralu;

  // Drain completion: FSM signals release of the head entry.
  assign sq_drain_fire = (state_store == LS_S_R || state_store == LS_S_HI_R)
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
        if (sq_valid[i] && !sq_committed[i] && !sq_commit_oh[i])
          sq_flush_clear_oh[i] = 1'b1;
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
      // Reset payload arrays so unused entries cannot feed X values into the
      // store FSM or store-to-load forwarding logic in FPGA synthesis.
      for (int i = 0; i < SQ_SIZE; i++) begin
        sq_alu[i]   <= '0;
        sq_dest[i]  <= '0;
        sq_vaddr[i] <= '0;
        sq_paddr[i] <= '0;
        sq_wdata[i] <= '0;
      end
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
          `RAPT_DPI_C_NPC_DIFFTEST_MEM_DIFF(rou_lsu.sq_waddr, rou_lsu.sq_wdata,
                                            {{2'b0}, rou_lsu.alu})
        end
      end else begin
        if (sq_alloc_fire) begin
          sq_alu[sq_tail]   <= exu_ioq_bcast.alu[4:0];
          sq_dest[sq_tail]  <= exu_ioq_bcast.dest;
          sq_vaddr[sq_tail] <= exu_ioq_bcast.tval;      // virtual (forwarding)
          sq_paddr[sq_tail] <= exu_ioq_bcast.sq_waddr;  // physical (drain)
          sq_wdata[sq_tail] <= exu_ioq_bcast.sq_wdata;
          sq_tail <= sq_tail + 1'b1;
        end
        if (sq_commit_fire) begin
          sq_cmt <= sq_cmt + 1'b1;
          `RAPT_DPI_C_NPC_DIFFTEST_MEM_DIFF(rou_lsu.sq_waddr, rou_lsu.sq_wdata,
                                            {{2'b0}, rou_lsu.alu})
        end
      end

      // ---- Drain release (committed side; independent of flush) ----
      if (sq_drain_fire) begin
        sq_head <= sq_head + 1'b1;
      end

      // Static per-entry state muxes. Drain is textually last in the former
      // implementation, so it retains highest priority on any pointer alias.
      for (int i = 0; i < SQ_SIZE; i++) begin
        if (sq_drain_oh[i])
          sq_valid[i] <= 1'b0;
        else if (sq_flush_clear_oh[i])
          sq_valid[i] <= 1'b0;
        else if (sq_alloc_oh[i])
          sq_valid[i] <= 1'b1;

        if (sq_drain_oh[i])
          sq_committed[i] <= 1'b0;
        else if (sq_commit_oh[i])
          sq_committed[i] <= 1'b1;
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
  logic [XLEN-1:0] sq_fwd_data;
  logic [SQ_SIZE-1:0] sq_match_vec;
  logic [SQ_SIZE-1:0] sq_fwd_full_vec;  // full-width store (can forward)
  always_comb begin
    for (int j = 0; j < SQ_SIZE; j++) begin
      automatic logic [SQLen-1:0] idx = sq_head + j[SQLen-1:0];
      sq_match_vec[j] = sq_valid[idx]
          && (sq_vaddr[idx][XLEN-1:WordOffBits] == raddr[XLEN-1:WordOffBits]);
      sq_fwd_full_vec[j] = sq_match_vec[j] && (sq_alu[idx] ==
`ifdef RAPT_RV64
          `RAPT_SD_WSTRB
`else
          `RAPT_SW_WSTRB
`endif
      );
    end
  end

  // Youngest match wins: highest j in age order (last set bit)
  always_comb begin
    // Before translation, a load VA cannot disprove aliasing with an SQ
    // store's PA. Keep exact-VA forwarding, but conservatively block every
    // other MMU-mode load until older stores have drained.
    load_in_sq = csr_bcast.dmmu_en ? (|sq_valid || sq_alloc_fire) : |sq_match_vec;
    sq_fwd_ok = 0;
    sq_fwd_data = 0;
    for (int j = 0; j < SQ_SIZE; j++) begin
      if (sq_match_vec[j]) begin
        sq_fwd_ok = sq_fwd_full_vec[j];
        sq_fwd_data = sq_wdata[sq_head+j[SQLen-1:0]];
      end
    end
  end

  // Store-to-load forwarding hit.
  // NOTE: `fwd_hit` assignment is deferred until after `ma_span` is computed
  // below, because misaligned loads that cross a word boundary cannot be
  // satisfied by the word-granular SQ match (the high half lives in the
  // next word, which the matched store does not cover).  See assign block
  // immediately following the `ma_span` definition.
  logic fwd_hit;
  logic [XLEN-1:0] fwd_data;
  assign fwd_data = sq_fwd_data;

  assign raddr_valid = exu_lsu.rvalid;

  // ==========================================================================
  //  Misaligned load support
  //    Splits a load that crosses a word (RV32) / dword (RV64) boundary into
  //    two aligned cache/bus transactions, then merges the two halves into a
  //    single XLEN-wide result before handing it back to the EXU.
  //    Covers LH[U] crossing (raddr[1:0]==3), LW[U] at any non-zero low-bit
  //    alignment, and (RV64) LD with raddr[2:0]!=0.
  // ==========================================================================
  localparam int OFFW = $clog2(XLEN/8);  // 2 for RV32, 3 for RV64
  typedef enum logic [1:0] {
    MA_IDLE = 2'b00,  // normal aligned flow
    MA_HI   = 2'b01,  // lo half latched, requesting hi half
    MA_DONE = 2'b10   // both halves latched, presenting merged rdata
  } ma_state_t;
  ma_state_t ma_state;
  logic [XLEN-1:0] ma_lo_data;
  logic [XLEN-1:0] ma_hi_data;

  // Detect a misaligned access that must be split into two beats.
  logic ma_span;
  assign ma_span =
       ((ralu == `RAPT_ALU_LH__ || ralu == `RAPT_ALU_LHU_) && raddr[1:0] == 2'b11)
    || ((ralu == `RAPT_ALU_LW__) && (raddr[1:0] != 2'b00))
`ifdef RAPT_RV64
    || ((ralu == `RAPT_ALU_LWU_) && (raddr[1:0] != 2'b00))
    || ((ralu == `RAPT_ALU_LD__) && (raddr[OFFW-1:0] != '0))
`endif
  ;
  // Misaligned loads that cross a word/dword boundary cannot use single-shot
  // SQ forwarding: the word-granular `sq_match_vec` only covers the lo
  // word, but the load also needs the byte(s) in the next word.  Suppress
  // the forwarding hit so the request stalls (`ma_load_req` already requires
  // `!load_in_sq`) until the matching store drains to L1D, after which the
  // misaligned-split path will fetch both halves.
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
  assign mmio_load_blocked = mmio_ordered
                          && !((sq_valid == '0) && (state_store == LS_S_V));
  // LR must reach L1D to establish a physical-address reservation. If an
  // older same-address store is still in the SQ, wait for it to drain rather
  // than completing LR through the ordinary load-forwarding path.
  assign fwd_hit = !exu_lsu.atomic_lock
                && !ma_span && !mmio_ordered && load_in_sq && sq_fwd_ok;
  logic pmp_load_fault_lsu;
  // Only engage the split for requests that actually reach the cache
  // (no SQ forward/conflict).  Forwarded loads keep the single-shot path;
  // the store queue does not straddle word boundaries today.
  logic ma_load_req;
  assign ma_load_req = raddr_valid && ma_span && !fwd_hit
                    && !load_in_sq
                    && !pmp_load_fault_lsu;

  // ==========================================================================
  //  Hit-under-miss B channel (Phase A2, RAPT_LSU_HUM)
  //  Best-effort second load while the A channel waits on a miss.  Same
  //  correctness rules as A, but with NO trap/PMP/MA-split path: any load
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
  logic [SQ_SIZE-1:0] sq_match_vec_b;
  logic [SQ_SIZE-1:0] sq_fwd_full_vec_b;
  always_comb begin
    for (int j = 0; j < SQ_SIZE; j++) begin
      automatic logic [SQLen-1:0] idx = sq_head + j[SQLen-1:0];
      sq_match_vec_b[j] = sq_valid[idx]
          && (sq_vaddr[idx][XLEN-1:WordOffBits] == raddr_b[XLEN-1:WordOffBits]);
      sq_fwd_full_vec_b[j] = sq_match_vec_b[j] && (sq_alu[idx] ==
`ifdef RAPT_RV64
          `RAPT_SD_WSTRB
`else
          `RAPT_SW_WSTRB
`endif
      );
    end
  end
  always_comb begin
    load_in_sq_b = csr_bcast.dmmu_en ? (|sq_valid || sq_alloc_fire) : |sq_match_vec_b;
    sq_fwd_ok_b = 0;
    sq_fwd_data_b = 0;
    for (int j = 0; j < SQ_SIZE; j++) begin
      if (sq_match_vec_b[j]) begin
        sq_fwd_ok_b = sq_fwd_full_vec_b[j];
        sq_fwd_data_b = sq_wdata[sq_head+j[SQLen-1:0]];
      end
    end
  end

  logic ma_span_b;
  assign ma_span_b =
       ((ralu_b == `RAPT_ALU_LH__ || ralu_b == `RAPT_ALU_LHU_) && raddr_b[1:0] == 2'b11)
    || ((ralu_b == `RAPT_ALU_LW__) && (raddr_b[1:0] != 2'b00))
`ifdef RAPT_RV64
    || ((ralu_b == `RAPT_ALU_LWU_) && (raddr_b[1:0] != 2'b00))
    || ((ralu_b == `RAPT_ALU_LD__) && (raddr_b[OFFW-1:0] != '0))
`endif
  ;
  logic mmio_ordered_b;
  assign mmio_ordered_b = !csr_bcast.dmmu_en && !rapt_pkg::addr_cacheable(raddr_b);

  logic fwd_hit_b;
  assign fwd_hit_b = exu_lsu.rvalid_b && !ma_span_b && !mmio_ordered_b
                  && load_in_sq_b && sq_fwd_ok_b;

  // Pass to L1D only when nothing local blocks it.
  assign lsu_l1d.rvalid_b = exu_lsu.rvalid_b && !fwd_hit_b && !load_in_sq_b
                         && !ma_span_b && !mmio_ordered_b;
  assign lsu_l1d.raddr_b  = raddr_b;
  assign lsu_l1d.ralu_b   = ralu_b;

  // B load data path: align + extend (parallel to A's)
  logic [XLEN-1:0] rdata_b_unalign;
  logic [XLEN-1:0] rdata_b_al;
  assign rdata_b_unalign = fwd_hit_b ? sq_fwd_data_b : lsu_l1d.rdata_b;
  assign rdata_b_al = rdata_b_unalign >> (raddr_b[OFFW-1:0] * 8);
  assign exu_lsu.rdata_b = (
      ({XLEN{ralu_b == `RAPT_ALU_LB__}} & {{XLEN-8{rdata_b_al[7]}}, rdata_b_al[7:0]})
    | ({XLEN{ralu_b == `RAPT_ALU_LBU_}} & {{XLEN-8{1'b0}}, rdata_b_al[7:0]})
    | ({XLEN{ralu_b == `RAPT_ALU_LH__}} & {{XLEN-16{rdata_b_al[15]}}, rdata_b_al[15:0]})
    | ({XLEN{ralu_b == `RAPT_ALU_LHU_}} & {{XLEN-16{1'b0}}, rdata_b_al[15:0]})
`ifdef RAPT_RV64
    | ({XLEN{ralu_b == `RAPT_ALU_LW__}} & {{XLEN-32{rdata_b_al[31]}}, rdata_b_al[31:0]})
    | ({XLEN{ralu_b == `RAPT_ALU_LWU_}} & {{XLEN-32{1'b0}}, rdata_b_al[31:0]})
    | ({XLEN{ralu_b == `RAPT_ALU_LD__}} & rdata_b_al)
`else
    | ({XLEN{ralu_b == `RAPT_ALU_LW__}} & rdata_b_al)
`endif
    );
  assign exu_lsu.rready_b = fwd_hit_b || lsu_l1d.rready_b;
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
  // The MA-split path below turns a misaligned load into two aligned
  // requests; L1D's PMP sees only those aligned addresses and cannot
  // detect a partial-region violation that straddles a PMP boundary.
  // Check the un-split access here so partial matches trap correctly.
  logic [1:0] lsu_eff_priv;
  assign lsu_eff_priv = (csr_bcast.priv == `RAPT_PRIV_M && csr_bcast.mprv)
                        ? csr_bcast.mpp : csr_bcast.priv;
  logic [3:0] lsu_load_size_m1;

  // ==========================================================================
  //  Misaligned store support
  //    SW/SH at `waddr[OFFW-1:0]` crossing a word (RV32) / dword (RV64)
  //    boundary is split into two aligned beats.  Beat 0 drives the original
  //    waddr/walu/wdata -- the BUS already shifts wstrb/wdata by `waddr_lo * 8`
  //    and truncates, so the lo word naturally gets the correct partial
  //    write.  Beat 1 drives the next word-aligned address with the bytes
  //    that spilled past the word boundary, shifted down to live at byte 0.
  // ==========================================================================
  logic ma_store_span;
  logic [XLEN-1:0] ma_waddr_hi;
  logic [4:0]      ma_walu_hi;
  logic [XLEN-1:0] ma_wdata_hi;
  logic [OFFW:0]   ma_w_off;       // byte offset into the aligned word (extra bit)
  logic [OFFW:0]   ma_w_size;      // store size in bytes, 1/2/4/(8)
  logic [XLEN/8-1:0] ma_wstrb_lo;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [2*XLEN/8-1:0]   ma_wstrb_wide;  // low half unused (bus path handles lo)
  logic [2*XLEN-1:0]     ma_wdata_wide;  // low half unused (bus path handles lo)
  /* verilator lint_on UNUSEDSIGNAL */
  logic [$clog2(2*XLEN)-1:0] ma_w_shift;

  always_comb begin
    unique case (ralu[1:0])
      2'b00:   lsu_load_size_m1 = 4'd0;
      2'b01:   lsu_load_size_m1 = 4'd1;
      2'b10:   lsu_load_size_m1 = 4'd3;
      2'b11:   lsu_load_size_m1 = 4'd7;
      default: lsu_load_size_m1 = 4'd3;
    endcase
  end
  rapt_pmp #(.XLEN(XLEN)) u_pmp_load_lsu (
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
      .fault  (pmp_load_fault_lsu),
      .fault_lo_o()
  );

  // Aligned low and high request addresses for the two beats.
  logic [XLEN-1:0] ma_raddr_lo, ma_raddr_hi;
  assign ma_raddr_lo = {raddr[XLEN-1:OFFW], {OFFW{1'b0}}};
  assign ma_raddr_hi = ma_raddr_lo + XLEN'(XLEN/8);

  // Merge the two halves into a single XLEN-wide value positioned so that
  // byte 0 of the merged word corresponds to `raddr`.  Concatenate hi:lo
  // into a double-wide vector and shift right by the byte offset in bits;
  // the shift amount is guaranteed non-zero on the MA path (raddr[OFFW-1:0]
  // is non-zero whenever ma_span is asserted).
  logic [2*XLEN-1:0] ma_cat;
  logic [XLEN-1:0]   ma_merged;
  logic [$clog2(2*XLEN)-1:0] ma_shift;
  assign ma_shift  = {{($clog2(2*XLEN)-OFFW-3){1'b0}}, raddr[OFFW-1:0], 3'b000};
  assign ma_cat    = {ma_hi_data, ma_lo_data};
  assign ma_merged = ma_cat[ma_shift +: XLEN];

  // Address/rvalid muxing toward the L1D interface.
  logic [XLEN-1:0] ma_req_addr;
  logic [4:0]      ma_req_alu;
  assign ma_req_addr = (ma_state == MA_HI) ? ma_raddr_hi
                     : (ma_load_req)        ? ma_raddr_lo
                     :                        raddr;
  // Force an aligned word/dword load opcode during the split so the L1D
  // never sees a "misaligned" request.
  assign ma_req_alu = (ma_state == MA_HI || ma_load_req)
`ifdef RAPT_RV64
                    ? `RAPT_ALU_LD__
`else
                    ? `RAPT_ALU_LW__
`endif
                    : ralu;

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

  assign exu_lsu.rdata = (
      ({XLEN{ralu == `RAPT_ALU_LB__}} & {{XLEN-8{rdata[7]}}, rdata[7:0]})
    | ({XLEN{ralu == `RAPT_ALU_LBU_}} & {{XLEN-8{1'b0}}, rdata[7:0]})
    | ({XLEN{ralu == `RAPT_ALU_LH__}} & {{XLEN-16{rdata[15]}}, rdata[15:0]})
    | ({XLEN{ralu == `RAPT_ALU_LHU_}} & {{XLEN-16{1'b0}}, rdata[15:0]})
`ifdef RAPT_RV64
    | ({XLEN{ralu == `RAPT_ALU_LW__}} & {{XLEN-32{rdata[31]}}, rdata[31:0]})
    | ({XLEN{ralu == `RAPT_ALU_LWU_}} & {{XLEN-32{1'b0}}, rdata[31:0]})
    | ({XLEN{ralu == `RAPT_ALU_LD__}} & rdata)
`else
    | ({XLEN{ralu == `RAPT_ALU_LW__}} & rdata)
`endif
    );
  // Swallow per-beat traps on the MA split path (we never issue a misaligned
  // address to the cache, so any L1D-raised trap on the beats is spurious).
  logic ma_active;
  assign ma_active = (ma_state != MA_IDLE) || ma_load_req;
  // Raise the pre-split PMP trap on the cycle the request is seen, so the
  // IOQ retires the load as a trap without touching the cache.
  logic lsu_pmp_trap;
  assign lsu_pmp_trap = raddr_valid && ma_span && pmp_load_fault_lsu
                     && !fwd_hit && !load_in_sq
                     && (ma_state == MA_IDLE);
  assign exu_lsu.trap = lsu_pmp_trap ? 1'b1
                      : (raddr_valid && fwd_hit) ? 1'b0
                      : ma_active             ? 1'b0
                      :                         lsu_l1d.trap;
  assign exu_lsu.cause = lsu_pmp_trap ? `RAPT_CAUSE_LOAD_ACC_FAULT
                                       : lsu_l1d.cause;
  assign exu_lsu.difftest_skip = (raddr_valid && fwd_hit) ? 1'b0
                              : ma_active             ? 1'b1
                              :                         lsu_l1d.difftest_skip;
  // rready contract:
  //  - aligned hit / forward: one-cycle rready pulse (as before)
  //  - MA split:              hold rready low during LO/HI beats; raise it
  //                           once merged data is parked in MA_DONE.
  //  - pre-split PMP trap:    pulse rready immediately so IOQ retires.
  assign exu_lsu.rready = lsu_pmp_trap
                       || (raddr_valid && fwd_hit)
                       || (ma_state == MA_DONE)
                       || (lsu_l1d.rvalid && lsu_l1d.rready
                                        && !ma_load_req && ma_state == MA_IDLE);

  always_ff @(posedge clock) begin
    if (reset) begin
      state_store <= LS_S_V;
    end else begin
      unique case (state_store)
        LS_S_V: begin
          if (wvalid) begin
            if (lsu_l1d.wready) begin
              // Lo beat accepted. If the store straddles a word/dword boundary
              // we still owe a high beat; otherwise retire.
              state_store <= ma_store_span ? LS_S_HI_V : LS_S_R;
            end
          end
        end
        LS_S_R: begin
          state_store <= LS_S_V;
        end
        LS_S_HI_V: begin
          if (lsu_l1d.wready) begin
            state_store <= LS_S_HI_R;
          end
        end
        LS_S_HI_R: begin
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
  assign lsu_l1d.rvalid = (ma_state == MA_HI)
                       || (raddr_valid && !load_in_sq
                                       && !mmio_load_blocked
                                       && (ma_state == MA_IDLE));
  assign lsu_l1d.atomic_lock = exu_lsu.atomic_lock;
  assign lsu_l1d.ordered = exu_lsu.ordered && sq_all_empty;

  // Misalign-split FSM.
  always_ff @(posedge clock) begin
    if (reset) begin
      ma_state <= MA_IDLE;
      ma_lo_data <= '0;
      ma_hi_data <= '0;
    end else if (cmu_bcast.flush_pipe) begin
      ma_state <= MA_IDLE;
    end else begin
      unique case (ma_state)
        MA_IDLE: begin
          if (ma_load_req && lsu_l1d.rready) begin
            ma_lo_data <= lsu_l1d.rdata;
            ma_state <= MA_HI;
          end
        end
        MA_HI: begin
          if (lsu_l1d.rready) begin
            ma_hi_data <= lsu_l1d.rdata;
            ma_state <= MA_DONE;
          end
        end
        MA_DONE: begin
          // The IOQ may switch directly to another load after this response;
          // release ownership on the handshake instead of requiring an
          // otherwise-unrelated rvalid bubble.
          if (!exu_lsu.rvalid || exu_lsu.rready) begin
            ma_state <= MA_IDLE;
          end
        end
        default: ma_state <= MA_IDLE;
      endcase
    end
  end


  assign ma_w_off  = {1'b0, waddr[OFFW-1:0]};
  // Compute store size from walu byte mask.
  always_comb begin
    unique case (walu)
      `RAPT_SB_WSTRB: ma_w_size = (OFFW+1)'(1);
      `RAPT_SH_WSTRB: ma_w_size = (OFFW+1)'(2);
      `RAPT_SW_WSTRB: ma_w_size = (OFFW+1)'(4);
`ifdef RAPT_RV64
      `RAPT_SD_WSTRB: ma_w_size = (OFFW+1)'(8);
`endif
      default:        ma_w_size = (OFFW+1)'(0);
    endcase
  end
  // Misaligned cross-word if off + size > word size.
  assign ma_store_span = (ma_w_size != '0)
                      && ((ma_w_off + ma_w_size) > (OFFW+1)'(XLEN/8));

`ifdef RAPT_RV64
  assign ma_wstrb_lo = (walu == `RAPT_SD_WSTRB) ? 8'hff : {3'b0, walu};
`else
  assign ma_wstrb_lo = walu[XLEN/8-1:0];
`endif

  /* verilator lint_off WIDTHTRUNC */
  assign ma_wstrb_wide = {{(XLEN/8){1'b0}}, ma_wstrb_lo} << ma_w_off;
  assign ma_w_shift    = {{($clog2(2*XLEN)-OFFW-3){1'b0}}, waddr[OFFW-1:0], 3'b000};
  assign ma_wdata_wide = {{XLEN{1'b0}}, wdata} << ma_w_shift;
  assign ma_wdata_hi   = ma_wdata_wide[2*XLEN-1:XLEN];
  /* verilator lint_on WIDTHTRUNC */
  assign ma_waddr_hi = {waddr[XLEN-1:OFFW], {OFFW{1'b0}}} + XLEN'(XLEN/8);
`ifdef RAPT_RV64
  // walu is 5-bit; XLEN/8 == 8.  Only the low 5 bits of the overflow can
  // possibly be set (SD has at most 7 spill bytes, so <= 0x7f; but even SW
  // overflow fits in 3 bits).  Zero-extend safely.
  assign ma_walu_hi = {1'b0, ma_wstrb_wide[XLEN/8+3:XLEN/8]};
`else
  assign ma_walu_hi = {{(5-XLEN/8){1'b0}}, ma_wstrb_wide[2*XLEN/8-1:XLEN/8]};
`endif

  // L1D drive muxing.
  assign lsu_l1d.waddr  = (state_store == LS_S_HI_V) ? ma_waddr_hi : waddr;
  assign lsu_l1d.walu   = (state_store == LS_S_HI_V) ? ma_walu_hi  : walu;
  assign lsu_l1d.wvalid = (state_store == LS_S_V && wvalid)
                       || (state_store == LS_S_HI_V);
  assign lsu_l1d.wdata  = (state_store == LS_S_HI_V) ? ma_wdata_hi : wdata;

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
      (sq_valid[sq_cmt] && !sq_committed[sq_cmt]
       && sq_dest[sq_cmt] == rou_lsu.dest))

  // COMMIT_ORDER: the entry being commit-marked must exist, be speculative,
  // and belong to the store the ROB is retiring (stores commit in order, so
  // no CAM is needed -- this assertion proves that assumption holds).
  `RAPT_SVA_IMPLY(clock, reset, LSU_SQ_COMMIT_ENTRY_MATCH,
      (sq_commit_fire),
      (sq_valid[sq_cmt] && !sq_committed[sq_cmt]
       && sq_dest[sq_cmt] == rou_lsu.dest))

  // COMMIT_ORDER: the alloc-time vaddr of the entry being committed must
  // describe the same word as the ROB's durable copy.  With DMMU enabled
  // only the page offset is invariant across translation.
  `RAPT_SVA_IMPLY(clock, reset, LSU_SQ_COMMIT_ADDR_PAGE_OFFSET,
      (sq_commit_fire
       && !$isunknown(rou_lsu.sq_vaddr) && !$isunknown(sq_vaddr[sq_cmt])),
      (csr_bcast.dmmu_en
       ? (sq_vaddr[sq_cmt][PageOffBits-1:WordOffBits]
         == rou_lsu.sq_vaddr[PageOffBits-1:WordOffBits])
       : (sq_vaddr[sq_cmt][XLEN-1:WordOffBits]
         == rou_lsu.sq_vaddr[XLEN-1:WordOffBits])))

  // HANDSHAKE: the SQ drain target slot must be a valid committed entry.
  `RAPT_SVA_IMPLY(clock, reset, LSU_SQ_DRAIN_VALID,
      (state_store == LS_S_R),
      (sq_valid[sq_head] && sq_committed[sq_head]))

  // HANDSHAKE: a load/AMO blocked by an older partial store must not complete
  // via a stale L1D rready from a request that was never issued.
  `RAPT_SVA_IMPLY(clock, reset, LSU_BLOCKED_LOAD_NOT_READY,
      (raddr_valid && load_in_sq && !fwd_hit),
      (!exu_lsu.rready))

    // LR establishes its reservation in L1D and therefore cannot complete via
    // store-queue forwarding even when an older store fully covers its bytes.
    `RAPT_SVA_IMPLY(clock, reset, LSU_LR_NO_SQ_FORWARD,
      (raddr_valid && exu_lsu.atomic_lock),
      (!fwd_hit))

  // HANDSHAKE: allocation requires a free slot at sq_tail.
  `RAPT_SVA_IMPLY(clock, reset, LSU_SQ_ALLOC_NEEDS_READY,
      (sq_alloc_fire),
      (sq_alloc_ready))

  // HANDSHAKE: alloc/commit/drain must target distinct entries whenever two
  // of them fire in the same cycle (single-writer-per-array discipline).
  `RAPT_SVA_IMPLY(clock, reset, LSU_SQ_ALLOC_COMMIT_DISTINCT,
      (sq_alloc_fire && sq_commit_fire),
      (sq_tail != sq_cmt))
  `RAPT_SVA_IMPLY(clock, reset, LSU_SQ_COMMIT_DRAIN_DISTINCT,
      (sq_commit_fire && sq_drain_fire),
      (sq_cmt != sq_head))

  // FLUSH_ROLLBACK: the cycle after a flush there are no speculative entries;
  // committed entries (still draining) are untouched.
  `RAPT_SVA_NEXT(clock, reset, LSU_SQ_FLUSH_ROLLBACK,
      (cmu_bcast.flush_pipe || cmu_bcast.fence_time),
      (sq_cmt == sq_tail && ((sq_valid & ~sq_committed) == '0)))
endmodule
/* verilator lint_on PINCONNECTEMPTY */
