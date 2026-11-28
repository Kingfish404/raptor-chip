`include "rapt.svh"
`include "rapt_soc.svh"
`include "rapt_soc_if.svh"

// rapt_coherence_hub: multi-hart coherence hub, request arbiter, back-invalidation
// probe broadcaster, and cluster atomic serialization lock.
//
// Protocol (Write-Through L1D + Back-Invalidate Coherence):
//   1. Reads: up to PerHartReadCredits outstanding reads per hart, tagged
//      downstream with `out_id = 4'(hart_id)` so AXI4 preserves per-hart FIFO
//      ordering while allowing concurrent inter-hart transactions. New reads to
//      a cache line with an active write/probe (from any hart, including the
//      writer itself), a pending same-hart write, or a queued CBO.INVAL stall
//      until the write/probe completes so reads never overtake older stores.
//   2. Writes: serialized one at a time. Cacheable writes update downstream
//      memory/L2 first, then broadcast back-invalidation probes (`probe_valid_o`)
//      to every other hart at the cache line (or all sub-lines of a 64B CBO),
//      wait for all `probe_ready_i` acknowledgements, and only then return
//      `wr_rsp_valid_o` to the writer. Non-cacheable (MMIO/CLINT/PLIC) writes
//      skip probes.
//   3. CBO.INVAL: buffered per hart in a CboFifoDepth-entry FIFO and broadcast
//      as 64B back-invalidation probes to all other harts.
//   4. Atomic Lock (`atomic_lock_req_i` / `atomic_lock_grant_o`): serializes
//      cross-hart AMO (Zaamo/Zabha/Zacas) and SC (Zalrsc) operations. Granted
//      only when no write/probe is in flight; while held, other harts' writes
//      are deferred so the lock holder's RMW or SC-check+store is globally atomic.
module rapt_coherence_hub #(
    parameter int XLEN = `RAPT_XLEN,
    parameter int NHARTS = 2,
    parameter int ID_W = 4,
    parameter int PerHartReadCredits = 8,
    parameter int CboFifoDepth = 8,
    parameter int L2LineOffset = rapt_pkg::L2LinkConfig.line_offset
) (
    input logic clock,
    input logic reset,

    // Per-hart read requests
    input  logic [NHARTS-1:0] rd_req_valid_i,
    output logic [NHARTS-1:0] rd_req_ready_o,
    input  logic [  ID_W-1:0] rd_req_id_i        [NHARTS],
    input  logic [  XLEN-1:0] rd_req_addr_i      [NHARTS],
    input  logic [       2:0] rd_req_size_i      [NHARTS],
    input  logic [       7:0] rd_req_len_i       [NHARTS],
    input  logic [       1:0] rd_req_burst_i     [NHARTS],
    input  logic [       1:0] rd_req_pbmt_i      [NHARTS],
    input  logic [NHARTS-1:0] rd_req_noallocate_i,
    input  logic [NHARTS-1:0] rd_req_cacheable_i,

    // Per-hart read responses
    output logic [NHARTS-1:0] rd_rsp_valid_o,
    input  logic [NHARTS-1:0] rd_rsp_ready_i,
    output logic [  ID_W-1:0] rd_rsp_id_o        [NHARTS],
    output logic [  XLEN-1:0] rd_rsp_data_o      [NHARTS],
    output logic [NHARTS-1:0] rd_rsp_last_o,
    output logic [NHARTS-1:0] rd_rsp_error_o,

    // Per-hart write requests
    input  logic [NHARTS-1:0] wr_req_valid_i,
    input  logic [NHARTS-1:0] wr_req_zero_i,
    output logic [NHARTS-1:0] wr_req_ready_o,
    input  logic [  ID_W-1:0] wr_req_id_i        [NHARTS],
    input  logic [  XLEN-1:0] wr_req_addr_i      [NHARTS],
    input  logic [       2:0] wr_req_size_i      [NHARTS],
    input  logic [       1:0] wr_req_pbmt_i      [NHARTS],
    input  logic [  XLEN-1:0] wr_req_data_i      [NHARTS],
    input  logic [XLEN/8-1:0] wr_req_strb_i      [NHARTS],

    // Per-hart write responses
    output logic [NHARTS-1:0] wr_rsp_valid_o,
    input  logic [NHARTS-1:0] wr_rsp_ready_i,
    output logic [  ID_W-1:0] wr_rsp_id_o        [NHARTS],
    output logic [NHARTS-1:0] wr_rsp_error_o,

    // Per-hart back-invalidation probe channels
    output logic [NHARTS-1:0] probe_valid_o,
    output logic [  XLEN-1:0] probe_addr_o       [NHARTS],
    input  logic [NHARTS-1:0] probe_ready_i,
    output logic [NHARTS-1:0] probe_window_o,

    // Per-hart CBO.INVAL notifications
    input  logic [NHARTS-1:0] cbo_inval_i,
    input  logic [  XLEN-1:6] cbo_block_i        [NHARTS],

    // Per-hart cluster atomic lock handshake
    input  logic [NHARTS-1:0] atomic_lock_req_i,
    output logic [NHARTS-1:0] atomic_lock_grant_o,

    // Downstream L2 probe + CBO channels
    input  logic              l2_probe_valid_i,
    input  logic [  XLEN-1:0] l2_probe_addr_i,
    output logic              l2_probe_ready_o,
    output logic              out_cbo_inval_o,
    output logic [  XLEN-1:6] out_cbo_block_o,

    // Merged downstream memory link
    mem_link_if.master out_mem,
    output logic       out_rd_req_cacheable_o
);
  if (NHARTS < 1 || NHARTS > (1 << ID_W)) begin : g_invalid_nharts
    $error("rapt_coherence_hub: NHARTS=%0d exceeds ID_W=%0d space", NHARTS, ID_W);
  end
  if (CboFifoDepth < 1 || ((CboFifoDepth & (CboFifoDepth - 1)) != 0)) begin : g_invalid_cbo_depth
    $error("rapt_coherence_hub: CboFifoDepth=%0d must be a power of 2", CboFifoDepth);
  end

  localparam int HartW      = (NHARTS <= 1) ? 1 : $clog2(NHARTS);
  localparam int RdPtrW     = (PerHartReadCredits <= 1) ? 1 : $clog2(PerHartReadCredits);
  localparam int RdCntW     = $clog2(PerHartReadCredits + 1);
  localparam int CboPtrW    = (CboFifoDepth <= 1) ? 1 : $clog2(CboFifoDepth);
  localparam int CboCntW    = $clog2(CboFifoDepth + 1);
  localparam int LineOffW   = $clog2(`RAPT_CACHE_LINE_BYTES);
  localparam int SubLines   = (LineOffW < 6) ? (1 << (6 - LineOffW)) : 1;
  localparam int SubLineW   = (SubLines <= 1) ? 1 : $clog2(SubLines);
  localparam int L2CmpLsb   = (L2LineOffset > LineOffW) ? L2LineOffset : LineOffW;
  localparam int L2SubLines = (LineOffW < L2LineOffset) ? (1 << (L2LineOffset - LineOffW)) : 1;
  localparam int L2SubLineW = (L2SubLines <= 1) ? 1 : $clog2(L2SubLines);

  // ------------------------------------------------------------------
  // Downstream L2 Probe FSM state (services l2_probe_valid_i across all harts)
  // ------------------------------------------------------------------
  typedef enum logic [1:0] {
    L2P_IDLE,
    L2P_PROBE,
    L2P_NEXT,
    L2P_ACK
  } l2p_state_t;

  l2p_state_t              l2p_state_q;
  logic [      XLEN-1:0]   l2p_addr_q;
  logic [    NHARTS-1:0]   l2p_pending_q;
  logic [L2SubLineW-1:0]   l2p_sub_q;
  logic                    l2_probe_busy;

  assign l2_probe_busy    = l2_probe_valid_i || (l2p_state_q != L2P_IDLE);
  assign l2_probe_ready_o = (l2p_state_q == L2P_ACK) && l2_probe_valid_i;

  // ------------------------------------------------------------------
  // Write + Back-Invalidation Probe FSM state
  // ------------------------------------------------------------------
  typedef enum logic [2:0] {
    WR_IDLE,
    WR_ISSUE,
    WR_WAIT_B,
    WR_PROBE,
    WR_PROBE_NEXT,
    WR_RSP
  } wr_state_t;

  wr_state_t             wr_state_q;
  logic [   HartW-1:0]   wr_rr_q;
  logic [   HartW-1:0]   wr_hart_q;
  logic                  wr_is_cbo_q;
  logic                  wr_is_cacheable_q;
  logic                  wr_zero_q;
  logic [    ID_W-1:0]   wr_id_q;
  logic [    XLEN-1:0]   wr_addr_q;
  logic [         2:0]   wr_size_q;
  logic [         1:0]   wr_pbmt_q;
  logic [    XLEN-1:0]   wr_data_q;
  logic [  XLEN/8-1:0]   wr_strb_q;
  logic                  wr_error_q;
  logic [  NHARTS-1:0]   probe_pending_q;
  logic [SubLineW-1:0]   probe_sub_q;

  // Per-hart CBO.INVAL FIFO queues
  logic [              XLEN-1:6] cbo_fifo_block[NHARTS][CboFifoDepth];
  logic [NHARTS-1:0][CboPtrW-1:0] cbo_fifo_head;
  logic [NHARTS-1:0][CboPtrW-1:0] cbo_fifo_tail;
  logic [NHARTS-1:0][CboCntW-1:0] cbo_fifo_cnt;
  logic [            NHARTS-1:0] cbo_pending;
  logic [            NHARTS-1:0] cbo_fifo_full;
  logic [             HartW-1:0] cbo_rr_q;

  for (genvar h = 0; h < NHARTS; h++) begin : g_cbo_flags
    assign cbo_pending[h]   = (cbo_fifo_cnt[h] != '0);
    assign cbo_fifo_full[h] = (cbo_fifo_cnt[h] == CboCntW'(CboFifoDepth));
  end

  // Cluster atomic serialization lock
  logic                  amo_owner_valid_q;
  logic [   HartW-1:0]   amo_owner_q;
  logic [   HartW-1:0]   amo_rr_q;

  always_comb begin
    atomic_lock_grant_o = '0;
    if (amo_owner_valid_q && atomic_lock_req_i[amo_owner_q]) begin
      atomic_lock_grant_o[amo_owner_q] = 1'b1;
    end
  end

  // Next atomic lock winner (only when wr_state_q == WR_IDLE and no current owner)
  logic                  amo_next_valid;
  logic [   HartW-1:0]   amo_next_hart;
  always_comb begin
    amo_next_valid = 1'b0;
    amo_next_hart  = '0;
    if (!amo_owner_valid_q && (wr_state_q == WR_IDLE)) begin
      for (int i = 0; i < NHARTS; i++) begin
        automatic int idx = (int'(amo_rr_q) + i) % NHARTS;
        if (!amo_next_valid && atomic_lock_req_i[idx]) begin
          amo_next_valid = 1'b1;
          amo_next_hart  = HartW'(idx);
        end
      end
    end
  end

  // ------------------------------------------------------------------
  // Per-hart read local-ID FIFOs & read-vs-write/CBO hazards
  // ------------------------------------------------------------------
  logic [NHARTS-1:0][PerHartReadCredits-1:0][  ID_W-1:0] rd_fifo_id;
  logic [NHARTS-1:0][RdPtrW-1:0]                         rd_fifo_head;
  logic [NHARTS-1:0][RdPtrW-1:0]                         rd_fifo_tail;
  logic [NHARTS-1:0][RdCntW-1:0]                         rd_fifo_cnt;
  logic [NHARTS-1:0]                                     rd_fifo_uncached_q;
  logic [NHARTS-1:0] rd_fifo_full;
  logic [NHARTS-1:0] rd_active_wr_hazard;
  logic [NHARTS-1:0] rd_self_wr_hazard;
  logic [NHARTS-1:0] rd_cbo_hazard;
  logic [NHARTS-1:0] rd_l2_probe_hazard;
  logic [NHARTS-1:0] rd_line_hazard;
  logic [NHARTS-1:0] rd_order_hazard;

  for (genvar h = 0; h < NHARTS; h++) begin : g_rd_flags
    assign rd_fifo_full[h] = (rd_fifo_cnt[h] == RdCntW'(PerHartReadCredits));
    // Block new reads from ALL harts (including wr_hart_q) to a cache line
    // (or 64B CBO block) with an active write/probe so combinational ARVALID
    // in rapt_axi_master can never overtake a registered AWVALID or B/probe.
    assign rd_active_wr_hazard[h] = (wr_state_q != WR_IDLE) && (
        (wr_is_cacheable_q && ((wr_is_cbo_q || wr_zero_q)
            ? (rd_req_addr_i[h][XLEN-1:6] == wr_addr_q[XLEN-1:6])
            : (rd_req_addr_i[h][XLEN-1:LineOffW] == wr_addr_q[XLEN-1:LineOffW])))
        || (!rd_req_cacheable_i[h] && !wr_is_cbo_q && (HartW'(h) == wr_hart_q)));
    // Block same-hart reads (e.g. PTW PTE walk, I-PTW, or non-allocating
    // partial-store follow-up load) from overtaking a pending older store
    // waiting at wr_req_valid_i[h].
    assign rd_self_wr_hazard[h] = wr_req_valid_i[h] && (
        !rd_req_cacheable_i[h]
        || ((rapt_pkg::addr_cacheable(wr_req_addr_i[h]) || wr_req_zero_i[h])
            && (wr_req_zero_i[h]
                ? (rd_req_addr_i[h][XLEN-1:6] == wr_req_addr_i[h][XLEN-1:6])
                : (rd_req_addr_i[h][XLEN-1:LineOffW] == wr_req_addr_i[h][XLEN-1:LineOffW]))));
    always_comb begin
      rd_cbo_hazard[h] = !rd_req_cacheable_i[h] && (cbo_inval_i[h] || cbo_pending[h]);
      for (int i = 0; i < NHARTS; i++) begin
        if (cbo_inval_i[i] && (rd_req_addr_i[h][XLEN-1:6] == cbo_block_i[i])) begin
          rd_cbo_hazard[h] = 1'b1;
        end
        for (int s = 0; s < CboFifoDepth; s++) begin
          automatic logic [CboPtrW-1:0] rel_idx = CboPtrW'(s) - cbo_fifo_head[i];
          if (({1'b0, rel_idx} < cbo_fifo_cnt[i])
              && (rd_req_addr_i[h][XLEN-1:6] == cbo_fifo_block[i][s])) begin
            rd_cbo_hazard[h] = 1'b1;
          end
        end
      end
    end
    assign rd_l2_probe_hazard[h] = (l2_probe_valid_i
            && (rd_req_addr_i[h][XLEN-1:L2CmpLsb] == l2_probe_addr_i[XLEN-1:L2CmpLsb]))
        || ((l2p_state_q != L2P_IDLE)
            && (rd_req_addr_i[h][XLEN-1:L2CmpLsb] == l2p_addr_q[XLEN-1:L2CmpLsb]));
    assign rd_line_hazard[h] = rd_active_wr_hazard[h]
        || rd_self_wr_hazard[h]
        || rd_cbo_hazard[h]
        || rd_l2_probe_hazard[h];
    // Downstream router can return on-chip MMIO (CLINT/PLIC) reads ahead of
    // AXI DRAM reads even under the same out_mem.rd_req_id. Serialize uncached
    // reads per hart so the local-ID FIFO can never swap responses.
    assign rd_order_hazard[h] = (rd_fifo_cnt[h] != '0)
        && (!rd_req_cacheable_i[h] || rd_fifo_uncached_q[h]);
  end

  // ------------------------------------------------------------------
  // Read request round-robin arbiter with stall-lock
  // ------------------------------------------------------------------
  logic [ HartW-1:0] rd_rr_q;
  logic              rd_lock_q;
  logic [ HartW-1:0] rd_lock_hart_q;
  logic              rd_grant_valid;
  logic [ HartW-1:0] rd_grant_hart;
  logic [NHARTS-1:0] rd_elig;

  assign rd_elig = rd_req_valid_i & ~rd_fifo_full & ~rd_line_hazard & ~rd_order_hazard;

  always_comb begin
    rd_grant_valid = 1'b0;
    rd_grant_hart  = '0;
    if (rd_lock_q) begin
      rd_grant_valid = rd_req_valid_i[rd_lock_hart_q] && !rd_fifo_full[rd_lock_hart_q];
      rd_grant_hart  = rd_lock_hart_q;
    end else begin
      for (int i = 0; i < NHARTS; i++) begin
        automatic int idx = (int'(rd_rr_q) + i) % NHARTS;
        if (!rd_grant_valid && rd_elig[idx]) begin
          rd_grant_valid = 1'b1;
          rd_grant_hart  = HartW'(idx);
        end
      end
    end
  end

  assign out_mem.rd_req_valid      = rd_grant_valid;
  assign out_mem.rd_req_id         = ID_W'(rd_grant_hart);
  assign out_mem.rd_req_addr       = rd_req_addr_i[rd_grant_hart];
  assign out_mem.rd_req_size       = rd_req_size_i[rd_grant_hart];
  assign out_mem.rd_req_len        = rd_req_len_i[rd_grant_hart];
  assign out_mem.rd_req_burst      = rd_req_burst_i[rd_grant_hart];
  assign out_mem.rd_req_pbmt       = rd_req_pbmt_i[rd_grant_hart];
  assign out_mem.rd_req_noallocate = rd_req_noallocate_i[rd_grant_hart];
  assign out_rd_req_cacheable_o    = rd_req_cacheable_i[rd_grant_hart];

  always_comb begin
    rd_req_ready_o = '0;
    if (rd_grant_valid && out_mem.rd_req_ready) begin
      rd_req_ready_o[rd_grant_hart] = 1'b1;
    end
  end

  // Read response demux
  logic [HartW-1:0] rd_rsp_hart;
  assign rd_rsp_hart = out_mem.rd_rsp_id[HartW-1:0];

  always_comb begin
    rd_rsp_valid_o = '0;
    rd_rsp_last_o  = '0;
    rd_rsp_error_o = '0;
    for (int h = 0; h < NHARTS; h++) begin
      rd_rsp_id_o[h]   = rd_fifo_id[h][rd_fifo_head[h]];
      rd_rsp_data_o[h] = out_mem.rd_rsp_data;
    end
    if (out_mem.rd_rsp_valid && (int'(out_mem.rd_rsp_id) < NHARTS)) begin
      rd_rsp_valid_o[rd_rsp_hart] = 1'b1;
      rd_rsp_last_o[rd_rsp_hart]  = out_mem.rd_rsp_last;
      rd_rsp_error_o[rd_rsp_hart] = out_mem.rd_rsp_error;
    end
  end
  assign out_mem.rd_rsp_ready = (int'(out_mem.rd_rsp_id) < NHARTS)
      ? rd_rsp_ready_i[rd_rsp_hart] : 1'b1;

  // ------------------------------------------------------------------
  // Write / CBO arbitration in WR_IDLE
  // ------------------------------------------------------------------
  logic              cbo_pick_valid;
  logic [ HartW-1:0] cbo_pick_hart;
  logic              wr_pick_valid;
  logic [ HartW-1:0] wr_pick_hart;
  logic [NHARTS-1:0] wr_elig;

  // While a hart holds the cluster atomic lock, only that hart may start writes.
  // Also defer new writes/CBOs when an atomic lock grant is about to activate,
  // or when out_mem.rd_req already presents a conflicting read (from a sibling
  // hart or an earlier stalled rd_lock_q read from the same hart), preserving
  // both AXI ARVALID stability and strict read-vs-write hazard exclusion.
  logic [XLEN-1:0] rd_grant_addr;
  assign rd_grant_addr = rd_req_addr_i[rd_grant_hart];
  logic [NHARTS-1:0] wr_rd_lock_hazard;
  logic [NHARTS-1:0] cbo_rd_lock_hazard;
  for (genvar h = 0; h < NHARTS; h++) begin : g_wr_rd_hazard
    wire [XLEN-1:6] cbo_head_blk = cbo_fifo_block[h][cbo_fifo_head[h]];
    assign wr_rd_lock_hazard[h] = rd_grant_valid && (
        ((rapt_pkg::addr_cacheable(wr_req_addr_i[h]) || wr_req_zero_i[h])
            && (wr_req_zero_i[h]
                ? (rd_grant_addr[XLEN-1:6] == wr_req_addr_i[h][XLEN-1:6])
                : (rd_grant_addr[XLEN-1:LineOffW] == wr_req_addr_i[h][XLEN-1:LineOffW])))
        || ((rd_grant_hart == HartW'(h)) && !rd_req_cacheable_i[h]));
    assign cbo_rd_lock_hazard[h] = rd_grant_valid
        && (rd_grant_addr[XLEN-1:6] == cbo_head_blk);
  end

  always_comb begin
    wr_elig = '0;
    if (wr_state_q == WR_IDLE) begin
      if (amo_owner_valid_q) begin
        wr_elig[amo_owner_q] = wr_req_valid_i[amo_owner_q] && !wr_rd_lock_hazard[amo_owner_q];
      end else if (!amo_next_valid) begin
        wr_elig = wr_req_valid_i & ~wr_rd_lock_hazard;
      end
    end
  end

  logic [NHARTS-1:0] cbo_elig;
  assign cbo_elig = (wr_state_q == WR_IDLE && !l2_probe_busy
      && !amo_owner_valid_q && !amo_next_valid)
      ? (cbo_pending & ~cbo_rd_lock_hazard) : '0;

  always_comb begin
    cbo_pick_valid = 1'b0;
    cbo_pick_hart  = '0;
    for (int i = 0; i < NHARTS; i++) begin
      automatic int idx = (int'(cbo_rr_q) + i) % NHARTS;
      if (!cbo_pick_valid && cbo_elig[idx]) begin
        cbo_pick_valid = 1'b1;
        cbo_pick_hart  = HartW'(idx);
      end
    end
  end

  always_comb begin
    wr_pick_valid = 1'b0;
    wr_pick_hart  = '0;
    if (!cbo_pick_valid) begin
      for (int i = 0; i < NHARTS; i++) begin
        automatic int idx = (int'(wr_rr_q) + i) % NHARTS;
        if (!wr_pick_valid && wr_elig[idx]) begin
          wr_pick_valid = 1'b1;
          wr_pick_hart  = HartW'(idx);
        end
      end
    end
  end

  logic [XLEN-1:0] wr_pick_addr;
  logic            wr_pick_cacheable;
  assign wr_pick_addr = wr_req_addr_i[wr_pick_hart];
  assign wr_pick_cacheable = rapt_pkg::addr_cacheable(wr_pick_addr)
      || wr_req_zero_i[wr_pick_hart];

  always_comb begin
    wr_req_ready_o = '0;
    if (wr_state_q == WR_IDLE && wr_pick_valid) begin
      wr_req_ready_o[wr_pick_hart] = 1'b1;
    end
  end

  // Downstream write channel
  assign out_mem.wr_req_valid = (wr_state_q == WR_ISSUE);
  assign out_mem.wr_req_zero  = wr_zero_q;
  assign out_mem.wr_req_id    = ID_W'(wr_hart_q);
  assign out_mem.wr_req_addr  = wr_addr_q;
  assign out_mem.wr_req_size  = wr_size_q;
  assign out_mem.wr_req_pbmt  = wr_pbmt_q;
  assign out_mem.wr_req_data  = wr_data_q;
  assign out_mem.wr_req_strb  = wr_strb_q;
  assign out_mem.wr_rsp_ready = (wr_state_q == WR_WAIT_B) && !l2_probe_busy;
  assign out_cbo_inval_o      = (wr_state_q == WR_IDLE) && cbo_pick_valid;
  assign out_cbo_block_o      = cbo_fifo_block[cbo_pick_hart][cbo_fifo_head[cbo_pick_hart]];

  // Per-hart write responses
  always_comb begin
    wr_rsp_valid_o = '0;
    wr_rsp_error_o = '0;
    for (int h = 0; h < NHARTS; h++) begin
      wr_rsp_id_o[h] = wr_id_q;
    end
    if (wr_state_q == WR_RSP) begin
      wr_rsp_valid_o[wr_hart_q] = 1'b1;
      wr_rsp_error_o[wr_hart_q] = wr_error_q;
    end
  end

  // Per-hart probe outputs (multiplexed between L2P_PROBE and WR_PROBE)
  logic [XLEN-1:0] wr_probe_line_addr;
  if (SubLines > 1) begin : g_probe_subline
    assign wr_probe_line_addr = (wr_is_cbo_q || wr_zero_q)
        ? {wr_addr_q[XLEN-1:6], probe_sub_q, {LineOffW{1'b0}}}
        : {wr_addr_q[XLEN-1:LineOffW], {LineOffW{1'b0}}};
  end else begin : g_probe_single
    assign wr_probe_line_addr = {wr_addr_q[XLEN-1:LineOffW], {LineOffW{1'b0}}};
  end

  logic [XLEN-1:0] l2_probe_line_addr;
  if (L2SubLines > 1) begin : g_l2_probe_subline
    assign l2_probe_line_addr = {l2p_addr_q[XLEN-1:L2LineOffset], l2p_sub_q, {LineOffW{1'b0}}};
  end else begin : g_l2_probe_single
    assign l2_probe_line_addr = {l2p_addr_q[XLEN-1:LineOffW], {LineOffW{1'b0}}};
  end

  logic [XLEN-1:0] probe_line_addr;
  assign probe_line_addr = (l2p_state_q == L2P_PROBE) ? l2_probe_line_addr : wr_probe_line_addr;

  for (genvar h = 0; h < NHARTS; h++) begin : g_probe_out
    wire h_probe_active = (l2p_state_q == L2P_PROBE)
        ? l2p_pending_q[h]
        : ((wr_state_q == WR_PROBE) && probe_pending_q[h]);
    assign probe_valid_o[h]  = h_probe_active;
    assign probe_addr_o[h]   = probe_line_addr;
    assign probe_window_o[h] = h_probe_active;
  end

  // ------------------------------------------------------------------
  // Sequential state updates
  // ------------------------------------------------------------------
  always_ff @(posedge clock) begin
    if (reset) begin
      l2p_state_q       <= L2P_IDLE;
      l2p_addr_q        <= '0;
      l2p_pending_q     <= '0;
      l2p_sub_q         <= '0;
      rd_rr_q           <= '0;
      rd_lock_q         <= 1'b0;
      rd_lock_hart_q    <= '0;
      wr_state_q        <= WR_IDLE;
      wr_rr_q           <= '0;
      wr_hart_q         <= '0;
      wr_is_cbo_q       <= 1'b0;
      wr_is_cacheable_q <= 1'b0;
      wr_zero_q         <= 1'b0;
      wr_id_q           <= '0;
      wr_addr_q         <= '0;
      wr_size_q         <= '0;
      wr_pbmt_q         <= '0;
      wr_data_q         <= '0;
      wr_strb_q         <= '0;
      wr_error_q        <= 1'b0;
      probe_pending_q   <= '0;
      probe_sub_q       <= '0;
      cbo_rr_q          <= '0;
      cbo_fifo_head     <= '0;
      cbo_fifo_tail     <= '0;
      cbo_fifo_cnt      <= '0;
      amo_owner_valid_q <= 1'b0;
      amo_owner_q       <= '0;
      amo_rr_q          <= '0;
      rd_fifo_id        <= '0;
      rd_fifo_head      <= '0;
      rd_fifo_tail      <= '0;
      rd_fifo_cnt       <= '0;
      rd_fifo_uncached_q <= '0;
      for (int h = 0; h < NHARTS; h++) begin
        for (int s = 0; s < CboFifoDepth; s++) begin
          cbo_fifo_block[h][s] <= '0;
        end
      end
    end else begin
      // Per-hart CBO.INVAL FIFO push/pop updates
      for (int h = 0; h < NHARTS; h++) begin
        automatic logic cbo_push = cbo_inval_i[h] && !cbo_fifo_full[h];
        automatic logic cbo_pop  = (wr_state_q == WR_IDLE) && cbo_pick_valid
            && (cbo_pick_hart == HartW'(h));
        if (cbo_pop) begin
          cbo_fifo_head[h] <= cbo_fifo_head[h] + CboPtrW'(1);
        end
        if (cbo_push) begin
          cbo_fifo_block[h][cbo_fifo_tail[h]] <= cbo_block_i[h];
          cbo_fifo_tail[h] <= cbo_fifo_tail[h] + CboPtrW'(1);
        end
        unique case ({
          cbo_push, cbo_pop
        })
          2'b10:   cbo_fifo_cnt[h] <= cbo_fifo_cnt[h] + CboCntW'(1);
          2'b01:   cbo_fifo_cnt[h] <= cbo_fifo_cnt[h] - CboCntW'(1);
          default: ;
        endcase
      end

      // Cluster atomic lock updates
      if (amo_owner_valid_q) begin
        if (!atomic_lock_req_i[amo_owner_q]) begin
          amo_owner_valid_q <= 1'b0;
          amo_rr_q <= (int'(amo_owner_q) == NHARTS - 1) ? '0 : amo_owner_q + HartW'(1);
        end
      end else if (amo_next_valid) begin
        amo_owner_valid_q <= 1'b1;
        amo_owner_q       <= amo_next_hart;
      end

      // Read arbiter lock / round-robin advance
      if (rd_grant_valid) begin
        if (out_mem.rd_req_ready) begin
          rd_lock_q <= 1'b0;
          rd_rr_q   <= (int'(rd_grant_hart) == NHARTS - 1) ? '0 : rd_grant_hart + HartW'(1);
        end else begin
          rd_lock_q      <= 1'b1;
          rd_lock_hart_q <= rd_grant_hart;
        end
      end else begin
        rd_lock_q <= 1'b0;
      end

      // Per-hart read ID FIFO updates
      for (int h = 0; h < NHARTS; h++) begin
        automatic logic rd_push = rd_req_valid_i[h] && rd_req_ready_o[h];
        automatic logic rd_pop  = rd_rsp_valid_o[h] && rd_rsp_ready_i[h] && rd_rsp_last_o[h];
        if (rd_push) begin
          rd_fifo_id[h][rd_fifo_tail[h]] <= rd_req_id_i[h];
          rd_fifo_tail[h] <= (int'(rd_fifo_tail[h]) == PerHartReadCredits - 1)
              ? '0 : rd_fifo_tail[h] + RdPtrW'(1);
          if (!rd_req_cacheable_i[h]) begin
            rd_fifo_uncached_q[h] <= 1'b1;
          end
        end
        if (rd_pop) begin
          rd_fifo_head[h] <= (int'(rd_fifo_head[h]) == PerHartReadCredits - 1)
              ? '0 : rd_fifo_head[h] + RdPtrW'(1);
          if (!rd_push && rd_fifo_cnt[h] == RdCntW'(1)) begin
            rd_fifo_uncached_q[h] <= 1'b0;
          end
        end
        unique case ({
          rd_push, rd_pop
        })
          2'b10:   rd_fifo_cnt[h] <= rd_fifo_cnt[h] + RdCntW'(1);
          2'b01:   rd_fifo_cnt[h] <= rd_fifo_cnt[h] - RdCntW'(1);
          default: ;
        endcase
      end

      // Downstream L2 Probe FSM
      unique case (l2p_state_q)
        L2P_IDLE: begin
          if (l2_probe_valid_i && (wr_state_q != WR_PROBE) && (wr_state_q != WR_PROBE_NEXT)) begin
            l2p_addr_q    <= l2_probe_addr_i;
            l2p_pending_q <= '1;
            l2p_sub_q     <= '0;
            l2p_state_q   <= L2P_PROBE;
          end
        end
        L2P_PROBE: begin
          automatic logic [NHARTS-1:0] l2p_next;
          l2p_next = l2p_pending_q & ~probe_ready_i;
          l2p_pending_q <= l2p_next;
          if (l2p_next == '0) begin
            if ((L2SubLines > 1) && (int'(l2p_sub_q) < L2SubLines - 1)) begin
              l2p_sub_q   <= l2p_sub_q + L2SubLineW'(1);
              l2p_state_q <= L2P_NEXT;
            end else begin
              l2p_state_q <= L2P_ACK;
            end
          end
        end
        L2P_NEXT: begin
          l2p_pending_q <= '1;
          l2p_state_q   <= L2P_PROBE;
        end
        L2P_ACK: begin
          l2p_state_q <= L2P_IDLE;
        end
        default: l2p_state_q <= L2P_IDLE;
      endcase

      // Write + Probe FSM
      unique case (wr_state_q)
        WR_IDLE: begin
          if (cbo_pick_valid) begin
            wr_hart_q         <= cbo_pick_hart;
            wr_is_cbo_q       <= 1'b1;
            wr_is_cacheable_q <= 1'b1;
            wr_zero_q         <= 1'b0;
            wr_addr_q <= {cbo_fifo_block[cbo_pick_hart][cbo_fifo_head[cbo_pick_hart]], 6'b0};
            cbo_rr_q <= (int'(cbo_pick_hart) == NHARTS - 1) ? '0 : cbo_pick_hart + HartW'(1);
            probe_pending_q   <= ~(NHARTS'(1) << cbo_pick_hart);
            probe_sub_q       <= '0;
            wr_state_q        <= (NHARTS > 1) ? WR_PROBE : WR_IDLE;
          end else if (wr_pick_valid) begin
            wr_hart_q         <= wr_pick_hart;
            wr_is_cbo_q       <= 1'b0;
            wr_is_cacheable_q <= wr_pick_cacheable;
            wr_zero_q         <= wr_req_zero_i[wr_pick_hart];
            wr_id_q           <= wr_req_id_i[wr_pick_hart];
            wr_addr_q         <= wr_req_addr_i[wr_pick_hart];
            wr_size_q         <= wr_req_size_i[wr_pick_hart];
            wr_pbmt_q         <= wr_req_pbmt_i[wr_pick_hart];
            wr_data_q         <= wr_req_data_i[wr_pick_hart];
            wr_strb_q         <= wr_req_strb_i[wr_pick_hart];
            wr_rr_q <= (int'(wr_pick_hart) == NHARTS - 1) ? '0 : wr_pick_hart + HartW'(1);
            wr_state_q        <= WR_ISSUE;
          end
        end
        WR_ISSUE: begin
          if (out_mem.wr_req_ready) begin
            wr_state_q <= WR_WAIT_B;
          end
        end
        WR_WAIT_B: begin
          if (out_mem.wr_rsp_valid && out_mem.wr_rsp_ready) begin
            wr_error_q <= out_mem.wr_rsp_error;
            if (wr_is_cacheable_q && (NHARTS > 1)) begin
              probe_pending_q <= ~(NHARTS'(1) << wr_hart_q);
              probe_sub_q     <= '0;
              wr_state_q      <= WR_PROBE;
            end else begin
              wr_state_q <= WR_RSP;
            end
          end
        end
        WR_PROBE: begin
          automatic logic [NHARTS-1:0] next_pending;
          next_pending = probe_pending_q & ~probe_ready_i;
          probe_pending_q <= next_pending;
          if (next_pending == '0) begin
            if ((SubLines > 1) && (wr_is_cbo_q || wr_zero_q)
                && (int'(probe_sub_q) < SubLines - 1)) begin
              probe_sub_q <= probe_sub_q + SubLineW'(1);
              wr_state_q  <= WR_PROBE_NEXT;
            end else begin
              wr_state_q <= wr_is_cbo_q ? WR_IDLE : WR_RSP;
            end
          end
        end
        WR_PROBE_NEXT: begin
          probe_pending_q <= ~(NHARTS'(1) << wr_hart_q);
          wr_state_q      <= WR_PROBE;
        end
        WR_RSP: begin
          if (wr_rsp_ready_i[wr_hart_q]) begin
            wr_state_q <= WR_IDLE;
          end
        end
        default: wr_state_q <= WR_IDLE;
      endcase
    end
  end
endmodule
