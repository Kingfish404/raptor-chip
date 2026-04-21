`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_dpi_c.svh"

module rapt_lsu #(
    parameter unsigned SQ_SIZE = `RAPT_SQ_SIZE,
    parameter bit [7:0] XLEN = `RAPT_XLEN
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
  /* verilator lint_off UNUSEDSIGNAL */
  typedef enum logic {
    LS_S_V = 0,
    LS_S_R = 1
  } state_store_t;

  state_store_t state_store;

  logic raddr_valid;
  logic [XLEN-1:0] raddr;
  logic [4:0] ralu;
  logic [XLEN-1:0] rdata_unalign;
  logic [XLEN-1:0] rdata;
  logic rready;

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
  logic [XLEN-1:0] sq_pc[SQ_SIZE];
  // === Store Queue (SQ) ===

  logic load_in_sq;
  logic [$clog2(SQ_SIZE)-1:0] load_in_sq_idx;
  logic store_in_sq;
  logic [$clog2(SQ_SIZE)-1:0] store_in_sq_idx;

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

  always @(posedge clock) begin
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
        sq_pc[sq_tail] <= rou_lsu.pc;

        sq_tail <= sq_tail + 1;
        `RAPT_DPI_C_NPC_DIFFTEST_MEM_DIFF(rou_lsu.sq_waddr, rou_lsu.sq_wdata, {{3'b0}, rou_lsu.alu})
      end
      if (state_store == LS_S_R && sq_valid[sq_head]) begin
        // Store Finished
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

  // logic [7:0] wstrb;
  // assign wstrb = (
  //          ({8{ralu == `RAPT_ALU_SB}} & 8'h1) |
  //          ({8{ralu == `RAPT_ALU_SH}} & 8'h3) |
  //          ({8{ralu == `RAPT_ALU_SW}} & 8'hf)
  //        );

  assign rdata_unalign = (raddr_valid && fwd_hit) ? fwd_data : lsu_l1d.rdata;
  assign rdata = (rdata_unalign >> (raddr[$clog2(XLEN/8)-1:0] * 8));

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
  assign exu_lsu.trap = (raddr_valid && fwd_hit) ? 1'b0 : lsu_l1d.trap;
  assign exu_lsu.cause = lsu_l1d.cause;
  assign exu_lsu.difftest_skip = (raddr_valid && fwd_hit) ? 1'b0 : lsu_l1d.difftest_skip;
  assign exu_lsu.rready = (raddr_valid && fwd_hit) || lsu_l1d.rready;

  always @(posedge clock) begin
    if (reset) begin
      state_store <= LS_S_V;
    end else begin
      unique case (state_store)
        LS_S_V: begin
          if (wvalid) begin
            if (lsu_l1d.wready) begin
              state_store <= LS_S_R;
            end
          end
        end
        LS_S_R: begin
          state_store <= LS_S_V;
        end
        default: begin
          state_store <= LS_S_V;
        end
      endcase
    end
  end

  assign lsu_l1d.raddr = raddr;
  assign lsu_l1d.ralu = ralu;
  assign lsu_l1d.rvalid = raddr_valid && !load_in_sq && !stq_addr_conflict;
  assign lsu_l1d.atomic_lock = exu_lsu.atomic_lock;

  /* verilator lint_on UNUSEDSIGNAL */

  assign lsu_l1d.waddr = waddr;
  assign lsu_l1d.walu = walu;
  assign lsu_l1d.wvalid = wvalid && state_store == LS_S_V;
  assign lsu_l1d.wdata = wdata;

  // ==========================================================================
  //  Assertions (enable with +define+RAPT_ASSERT_EN)
  //  Category legend:
  //    COMMIT_DURABLE : commit-time inputs must come from durable sources
  //    HANDSHAKE      : queue capacity / ready-valid contract
  //    FLUSH_CLEAR    : STQ is fully cleared on pipeline flush
  //    FLUSH_SURVIVE  : SQ keeps older-than-flush entries (no flush of SQ)
  // ==========================================================================

  // COMMIT_DURABLE: vaddr and waddr at SQ commit must address the same word.
  // This is the invariant that the sq-vaddr-flush bug violated.
  `RAPT_SVA_IMPLY(clock, reset, LSU_SQ_COMMIT_ADDR_ALIGN,
      (rou_lsu.valid && rou_lsu.store && sq_ready
       && !$isunknown(rou_lsu.sq_vaddr) && !$isunknown(rou_lsu.sq_waddr)),
      (rou_lsu.sq_vaddr[XLEN-1:$clog2(XLEN/8)]
         == rou_lsu.sq_waddr[XLEN-1:$clog2(XLEN/8)]))

  // HANDSHAKE: SQ commit requires a free slot at sq_tail (sq_ready).
  `RAPT_SVA_IMPLY(clock, reset, LSU_SQ_COMMIT_NEEDS_READY,
      (rou_lsu.valid && rou_lsu.store),
      (sq_ready))

  // HANDSHAKE: the SQ drain target slot must be valid when state_store==LS_S_R.
  `RAPT_SVA_IMPLY(clock, reset, LSU_SQ_DRAIN_VALID,
      (state_store == LS_S_R),
      (sq_valid[sq_head]))

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
