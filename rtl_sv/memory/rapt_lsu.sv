`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_dpi_c.svh"

module rapt_lsu #(
    parameter unsigned SQ_SIZE = `RAPT_SQ_SIZE,
    parameter int XLEN = `RAPT_XLEN
) (
    input clock,

    cmu_bcast_if.in cmu_bcast,

    lsu_l1d_if.master lsu_l1d,

    exu_lsu_if.slave exu_lsu,
    exu_ioq_bcast_if.in exu_ioq_bcast,
    rou_lsu_if.in rou_lsu,

    csr_bcast_if.in csr_bcast,

    input reset
);
  localparam int WordOffBits = $clog2(XLEN / 8);
  localparam int PageOffBits = 12;

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

  // === Store Temporary Queue (STQ) ===
  logic [$clog2(SQ_SIZE)-1:0] stq_head;
  logic [$clog2(SQ_SIZE)-1:0] stq_tail;
  logic [SQ_SIZE-1:0] stq_valid;

  logic [4:0] stq_alu[SQ_SIZE];
  logic [XLEN-1:0] stq_waddr[SQ_SIZE];
  logic [XLEN-1:0] stq_wdata[SQ_SIZE];
  // === Store Temporary Queue (STQ) ===

  // === Store Queue (SQ) ===
  logic sq_ready;
  logic [$clog2(SQ_SIZE)-1:0] sq_head;
  logic [$clog2(SQ_SIZE)-1:0] sq_tail;
  logic [SQ_SIZE-1:0] sq_valid;
  logic [4:0] sq_alu[SQ_SIZE];
  logic [XLEN-1:0] sq_waddr[SQ_SIZE];  // physical: for bus write-through
  logic [XLEN-1:0] sq_vaddr[SQ_SIZE];  // virtual : for forwarding comparison
  logic [XLEN-1:0] sq_wdata[SQ_SIZE];
  // === Store Queue (SQ) ===

  // SQ index helpers (debug/waveform only; outputs feed sq_fwd_data lookup
  // directly via sq_head + j arithmetic).
  /* verilator lint_off UNUSEDSIGNAL */
  logic load_in_sq;
  logic [$clog2(SQ_SIZE)-1:0] load_in_sq_idx;
  logic store_in_sq;
  logic [$clog2(SQ_SIZE)-1:0] store_in_sq_idx;
  /* verilator lint_on UNUSEDSIGNAL */

  // Store-to-load forwarding from SQ
  logic sq_fwd_ok;
  logic [XLEN-1:0] sq_fwd_data;

  logic wvalid;
  logic [XLEN-1:0] wdata;
  logic [XLEN-1:0] waddr;
  logic [4:0] walu;

  assign raddr = exu_lsu.raddr;
  assign ralu = exu_lsu.ralu;
  assign sq_ready = sq_valid[sq_tail] == 0;
  assign rou_lsu.sq_ready = sq_ready;

  assign wvalid = sq_valid[sq_head];
  assign wdata = sq_wdata[sq_head];
  assign waddr = sq_waddr[sq_head];
  assign walu = sq_alu[sq_head];

  always_ff @(posedge clock) begin
    if (reset) begin
      sq_head   <= 0;
      sq_tail   <= 0;
      sq_valid  <= 0;

      stq_head  <= 0;
      stq_tail  <= 0;
      stq_valid <= 0;
    end else begin
      if (cmu_bcast.flush_pipe || cmu_bcast.fence_time) begin
        stq_head  <= 0;
        stq_tail  <= 0;
        stq_valid <= 0;
      end else begin
        if (exu_ioq_bcast.valid && exu_ioq_bcast.wen) begin
          stq_valid[stq_tail] <= 1;

          stq_alu[stq_tail] <= exu_ioq_bcast.alu[4:0];
          stq_waddr[stq_tail] <= exu_ioq_bcast.tval;  // virtual addr for forwarding
          stq_wdata[stq_tail] <= exu_ioq_bcast.sq_wdata;
          stq_tail <= stq_tail + 1;
        end
        if (rou_lsu.valid && rou_lsu.store && sq_ready) begin
          stq_valid[stq_head] <= 0;
          stq_head <= stq_head + 1;
        end
      end
      if (rou_lsu.valid && rou_lsu.store && sq_ready) begin
        // Store Commit
        sq_valid[sq_tail] <= 1;

        sq_alu[sq_tail] <= rou_lsu.alu[4:0];
        sq_waddr[sq_tail] <= rou_lsu.sq_waddr;
        // Virtual address comes from ROB (tval), not STQ. ROB survives flushes
        // and retains the correct per-store virtual address for forwarding,
        // whereas STQ entries can be clobbered by post-flush re-enqueues.
        sq_vaddr[sq_tail] <= rou_lsu.sq_vaddr;
        sq_wdata[sq_tail] <= rou_lsu.sq_wdata;

        sq_tail <= sq_tail + 1;
        `RAPT_DPI_C_NPC_DIFFTEST_MEM_DIFF(rou_lsu.sq_waddr, rou_lsu.sq_wdata, {{2'b0}, rou_lsu.alu})
      end
      if (state_store == LS_S_R && sq_valid[sq_head]) begin
        // Store Finished (aligned case — released after single beat).
        sq_valid[sq_head] <= 0;

        sq_alu[sq_head] <= 0;
        sq_waddr[sq_head] <= 0;
        sq_wdata[sq_head] <= 0;

        sq_head <= sq_head + 1;
      end
      if (state_store == LS_S_HI_R && sq_valid[sq_head]) begin
        // Store Finished (misaligned case — released after hi beat).
        sq_valid[sq_head] <= 0;

        sq_alu[sq_head] <= 0;
        sq_waddr[sq_head] <= 0;
        sq_wdata[sq_head] <= 0;

        sq_head <= sq_head + 1;
      end
    end
  end

  // SQ address conflict + store-to-load forwarding.
  // Phase 1: parallel match vector (all comparisons fire simultaneously)
  // Phase 2: age-ordered priority select (youngest match wins)
  logic [SQ_SIZE-1:0] sq_match_vec;
  logic [SQ_SIZE-1:0] sq_full_vec;  // full-width store (can forward)
  always_comb begin
    for (int j = 0; j < SQ_SIZE; j++) begin
      automatic logic [$clog2(SQ_SIZE)-1:0] idx = sq_head + j[$clog2(SQ_SIZE)-1:0];
      sq_match_vec[j] = sq_valid[idx]
          && (sq_vaddr[idx][XLEN-1:$clog2(XLEN/8)] == raddr[XLEN-1:$clog2(XLEN/8)]);
      sq_full_vec[j] = sq_match_vec[j] && (sq_alu[idx] ==
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
    load_in_sq = |sq_match_vec;
    load_in_sq_idx = sq_head;
    sq_fwd_ok = 0;
    sq_fwd_data = 0;
    for (int j = 0; j < SQ_SIZE; j++) begin
      if (sq_match_vec[j]) begin
        load_in_sq_idx = sq_head + j[$clog2(SQ_SIZE)-1:0];
        sq_fwd_ok = sq_full_vec[j];
        sq_fwd_data = sq_wdata[sq_head + j[$clog2(SQ_SIZE)-1:0]];
      end
    end
  end

  // Store address conflict detection (first match)
  logic [SQ_SIZE-1:0] store_match_vec;
  always_comb begin
    for (int i = 0; i < SQ_SIZE; i++) begin
      store_match_vec[i] = sq_valid[i] && (sq_waddr[i] == rou_lsu.sq_waddr);
    end
  end
  always_comb begin
    store_in_sq = |store_match_vec;
    store_in_sq_idx = 0;
    for (int i = SQ_SIZE - 1; i >= 0; i--) begin
      if (store_match_vec[i]) begin
        store_in_sq_idx = i[$clog2(SQ_SIZE)-1:0];
      end
    end
  end

  // STQ address conflict + store-to-load forwarding (parallel match)
  logic stq_addr_conflict;
  logic stq_fwd_ok;
  logic [XLEN-1:0] stq_fwd_data;
  logic [SQ_SIZE-1:0] stq_match_vec;
  logic [SQ_SIZE-1:0] stq_full_vec;
  always_comb begin
    for (int j = 0; j < SQ_SIZE; j++) begin
      automatic logic [$clog2(SQ_SIZE)-1:0] idx = stq_head + j[$clog2(SQ_SIZE)-1:0];
      stq_match_vec[j] = stq_valid[idx]
          && (stq_waddr[idx][XLEN-1:$clog2(XLEN/8)] == raddr[XLEN-1:$clog2(XLEN/8)]);
      stq_full_vec[j] = stq_match_vec[j] && (stq_alu[idx] ==
`ifdef RAPT_RV64
          `RAPT_SD_WSTRB
`else
          `RAPT_SW_WSTRB
`endif
      );
    end
  end
  always_comb begin
    stq_addr_conflict = |stq_match_vec;
    stq_fwd_ok = 0;
    stq_fwd_data = 0;
    for (int j = 0; j < SQ_SIZE; j++) begin
      if (stq_match_vec[j]) begin
        stq_fwd_ok = stq_full_vec[j];
        stq_fwd_data = stq_wdata[stq_head + j[$clog2(SQ_SIZE)-1:0]];
      end
    end
  end

  // Store-to-load forwarding priority: STQ (youngest) > SQ (committed)
  logic fwd_hit;
  logic [XLEN-1:0] fwd_data;
  assign fwd_hit = (stq_addr_conflict && stq_fwd_ok)
                || (!stq_addr_conflict && load_in_sq && sq_fwd_ok);
  assign fwd_data = (stq_addr_conflict && stq_fwd_ok) ? stq_fwd_data : sq_fwd_data;

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
  logic pmp_load_fault_lsu;
  // Only engage the split for requests that actually reach the cache
  // (no SQ forward, no STQ conflict).  Forwarded loads keep the single-shot
  // path; the store queue does not straddle word boundaries today.
  logic ma_load_req;
  assign ma_load_req = raddr_valid && ma_span && !fwd_hit
                    && !load_in_sq && !stq_addr_conflict
                    && !pmp_load_fault_lsu;

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
  //    waddr/walu/wdata — the BUS already shifts wstrb/wdata by `waddr_lo * 8`
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
      .pmp_napot_mask (csr_bcast.pmp_napot_mask),
      .pmp_napot_base (csr_bcast.pmp_napot_base),
      .pmp_tor_lo     (csr_bcast.pmp_tor_lo),
      .pmp_tor_hi     (csr_bcast.pmp_tor_hi),
      .pmp_cfg_r      (csr_bcast.pmp_cfg_r),
      .pmp_cfg_w      (csr_bcast.pmp_cfg_w),
      .pmp_cfg_x      (csr_bcast.pmp_cfg_x),
      .pmp_cfg_l      (csr_bcast.pmp_cfg_l),
      .pmp_mode_off   (csr_bcast.pmp_mode_off),
      .pmp_mode_tor   (csr_bcast.pmp_mode_tor),
      .pmp_mode_na4   (csr_bcast.pmp_mode_na4),
      .pmp_mode_napot (csr_bcast.pmp_mode_napot),
      .fault  (pmp_load_fault_lsu)
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
  //  Load data path — uses the split-merge result when ma_state == MA_DONE.
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
                     && !fwd_hit && !load_in_sq && !stq_addr_conflict
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
                       || (raddr_valid && !load_in_sq && !stq_addr_conflict
                                       && (ma_state == MA_IDLE));
  assign lsu_l1d.atomic_lock = exu_lsu.atomic_lock;

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
          // EXU consumes the merged word when rvalid drops.
          if (!exu_lsu.rvalid) begin
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
  //    COMMIT_DURABLE : commit-time inputs must come from durable sources
  //    HANDSHAKE      : queue capacity / ready-valid contract
  //    FLUSH_CLEAR    : STQ is fully cleared on pipeline flush
  //    FLUSH_SURVIVE  : SQ keeps older-than-flush entries (no flush of SQ)
  // ==========================================================================

    // COMMIT_DURABLE: vaddr and waddr at SQ commit must describe the same word.
    // With DMMU enabled only the page offset is invariant across translation.
    `RAPT_SVA_IMPLY(clock, reset, LSU_SQ_COMMIT_ADDR_PAGE_OFFSET,
      (rou_lsu.valid && rou_lsu.store && sq_ready
       && !$isunknown(rou_lsu.sq_vaddr) && !$isunknown(rou_lsu.sq_waddr)),
      (csr_bcast.dmmu_en
       ? (rou_lsu.sq_vaddr[PageOffBits-1:WordOffBits]
         == rou_lsu.sq_waddr[PageOffBits-1:WordOffBits])
       : (rou_lsu.sq_vaddr[XLEN-1:WordOffBits]
         == rou_lsu.sq_waddr[XLEN-1:WordOffBits])))

  // HANDSHAKE: SQ commit requires a free slot at sq_tail (sq_ready).
  `RAPT_SVA_IMPLY(clock, reset, LSU_SQ_COMMIT_NEEDS_READY,
      (rou_lsu.valid && rou_lsu.store),
      (sq_ready))

  // HANDSHAKE: the SQ drain target slot must be valid when state_store==LS_S_R.
  `RAPT_SVA_IMPLY(clock, reset, LSU_SQ_DRAIN_VALID,
      (state_store == LS_S_R),
      (sq_valid[sq_head]))

    // HANDSHAKE: a load/AMO blocked by an older partial store must not complete
    // via a stale L1D rready from a request that was never issued.
    `RAPT_SVA_IMPLY(clock, reset, LSU_BLOCKED_LOAD_NOT_READY,
      (raddr_valid && (load_in_sq || stq_addr_conflict) && !fwd_hit),
      (!exu_lsu.rready))

  // FLUSH_CLEAR: STQ head/tail/valid must be zero the cycle after flush.
  `RAPT_SVA_NEXT(clock, reset, LSU_STQ_FLUSH_CLEAR,
      (cmu_bcast.flush_pipe || cmu_bcast.fence_time),
      (stq_head == '0 && stq_tail == '0 && stq_valid == '0))

  // COMMIT_DURABLE: after an SQ commit, the freshly written sq_vaddr must
  // equal what was presented on rou_lsu.sq_vaddr that cycle. Detects any
  // regression that reroutes sq_vaddr through a speculative structure.
  `RAPT_SVA_NEXT(clock, reset, LSU_SQ_VADDR_FROM_ROB,
      (rou_lsu.valid && rou_lsu.store && sq_ready),
      (sq_vaddr[$past(sq_tail)] == $past(rou_lsu.sq_vaddr)))
endmodule
