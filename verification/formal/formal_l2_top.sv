`include "rapt.svh"
`include "rapt_soc.svh"
`include "rapt_soc_if.svh"

// Formal top-level verification harness for rapt_l2.
// Proves AXI4 master/slave protocol compliance under arbitrary stalls,
// deadlock-freedom invariants, and symbolic-address end-to-end data coherence
// across hits, misses, multi-MSHR refills, evictions, probes, and bypasses.
module formal_l2_top #(
    parameter int XLEN = `RAPT_XLEN,
    parameter int ID_W = 4,
    parameter int L2_LEN = `RAPT_L2_LEN,
    parameter int L2_LINE_LEN = `RAPT_L2_LINE_LEN,
    parameter int L2_N_WAYS = `RAPT_L2_N_WAYS,
    parameter int PADDR_BITS = `RAPT_PADDR_BITS,
    parameter bit CHECK_COHERENCE = 1'b1,
    parameter bit ALLOW_OUTER_ERR = 1'b0,
    parameter bit ALLOW_PROBE_RELEASE = 1'b1,
    parameter bit ALLOW_CBO = 1'b1
) (
    input logic clock,
    input logic reset,
    // Symbolic watched cacheable word address and initial memory value.
    input logic [XLEN-1:0] watched_addr,
    input logic [XLEN-1:0] init_word,
    // Inner AXI4 slave request inputs (driven by formal solver).
    input logic s_arvalid,
    input logic [XLEN-1:0] s_araddr,
    input logic [ID_W-1:0] s_arid,
    input logic [7:0] s_arlen,
    input logic [2:0] s_arsize,
    input logic [1:0] s_arburst,
    input logic [3:0] s_arcache,
    input logic s_rready,
    input logic s_awvalid,
    input logic [XLEN-1:0] s_awaddr,
    input logic [ID_W-1:0] s_awid,
    input logic [7:0] s_awlen,
    input logic [2:0] s_awsize,
    input logic [1:0] s_awburst,
    input logic [3:0] s_awcache,
    input logic s_wvalid,
    input logic [XLEN-1:0] s_wdata,
    input logic [XLEN/8-1:0] s_wstrb,
    input logic s_wlast,
    input logic s_bready,
    // Outer AXI4 master response inputs (driven by formal solver).
    input logic m_arready,
    input logic m_rvalid,
    input logic [ID_W-1:0] m_rid,
    input logic [XLEN-1:0] m_rdata,
    input logic [1:0] m_rresp,
    input logic m_rlast,
    input logic m_awready,
    input logic m_wready,
    input logic m_bvalid,
    input logic [ID_W-1:0] m_bid,
    input logic [1:0] m_bresp,
    // Client coherence / CBO inputs.
    input logic cbo_inval_i,
    input logic [XLEN-1:6] cbo_block_i,
    input logic probe_ready_i,
    input logic probe_release_valid_i,
    input logic [XLEN-1:0] probe_release_addr_i,
    input logic [XLEN-1:0] probe_release_data_i,
    input logic l1d_writeback_pending_i
);
  localparam int WordBytes = XLEN / 8;
  localparam int ByteOffBits = $clog2(WordBytes);
  localparam int LineWords = 1 << L2_LINE_LEN;
  localparam int OffsetBits = L2_LINE_LEN + ByteOffBits;
  localparam int NumOuterIds = 1 << ID_W;
  localparam int MaxInnerAr = 16;
  localparam bit BoomBankedStore = L2_N_WAYS == 8 && (L2_LEN == 9 || L2_LEN == 10)
      && (LineWords * XLEN == 512) && (XLEN == 32 || XLEN == 64);

  axi4_if #(
      .XLEN(XLEN),
      .ID_W(ID_W)
  ) axi_s ();
  axi4_if #(
      .XLEN(XLEN),
      .ID_W(ID_W)
  ) axi_m ();

  logic probe_valid_o, probe_release_ready_o, release_ready_o, release_ack_o, probe_window_o;
  logic [XLEN-1:0] probe_addr_o;

  assign axi_s.arvalid = s_arvalid;
  assign axi_s.araddr = s_araddr;
  assign axi_s.arid = s_arid;
  assign axi_s.arlen = s_arlen;
  assign axi_s.arsize = s_arsize;
  assign axi_s.arburst = s_arburst;
  assign axi_s.arcache = s_arcache;
  assign axi_s.rready = s_rready;
  assign axi_s.awvalid = s_awvalid;
  assign axi_s.awaddr = s_awaddr;
  assign axi_s.awid = s_awid;
  assign axi_s.awlen = s_awlen;
  assign axi_s.awsize = s_awsize;
  assign axi_s.awburst = s_awburst;
  assign axi_s.awcache = s_awcache;
  assign axi_s.wvalid = s_wvalid;
  assign axi_s.wdata = s_wdata;
  assign axi_s.wstrb = s_wstrb;
  assign axi_s.wlast = s_wlast;
  assign axi_s.bready = s_bready;

  assign axi_m.arready = m_arready;
  assign axi_m.rvalid = m_rvalid;
  assign axi_m.rid = m_rid;
  assign axi_m.rdata = m_rdata;
  assign axi_m.rresp = m_rresp;
  assign axi_m.rlast = m_rlast;
  assign axi_m.awready = m_awready;
  assign axi_m.wready = m_wready;
  assign axi_m.bvalid = m_bvalid;
  assign axi_m.bid = m_bid;
  assign axi_m.bresp = m_bresp;

  rapt_l2 #(
      .XLEN(XLEN),
      .ID_W(ID_W),
      .L2_LEN(L2_LEN),
      .L2_LINE_LEN(L2_LINE_LEN),
      .L2_N_WAYS(L2_N_WAYS),
      .PADDR_BITS(PADDR_BITS)
  ) dut (
      .sram_ctrl_i(rapt_pkg::SramCtrlReset),
      .clock,
      .reset,
      .cbo_inval_i(ALLOW_CBO && cbo_inval_i),
      .cbo_block_i(cbo_block_i),
      .probe_valid_o,
      .probe_addr_o,
      .probe_ready_i,
      .probe_release_valid_i(ALLOW_PROBE_RELEASE && probe_release_valid_i),
      .probe_release_addr_i,
      .probe_release_data_i,
      .probe_release_ready_o,
      .release_valid_i(1'b0),
      .release_addr_i('0),
      .release_data_i('0),
      .release_has_data_i(1'b0),
      .release_mask_i(1'b0),
      .release_last_i(1'b0),
      .release_ready_o,
      .release_ack_o,
      .l1d_writeback_pending_i(l1d_writeback_pending_i),
      .probe_window_o,
      .axi_s,
      .axi_m
  );

  function automatic logic [XLEN-1:0] merge_bytes(input logic [XLEN-1:0] old_word,
                                                  input logic [XLEN-1:0] new_word,
                                                  input logic [WordBytes-1:0] strb);
    logic [XLEN-1:0] res;
    res = old_word;
    for (int i = 0; i < WordBytes; i++) begin
      if (strb[i]) res[i*8+:8] = new_word[i*8+:8];
    end
    return res;
  endfunction

  function automatic logic [XLEN-1:0] next_beat_addr(
      input logic [XLEN-1:0] cur_addr, input logic [2:0] size, input logic [1:0] burst,
      input logic [7:0] len);
    logic [XLEN-1:0] step, wrap_bytes, wrap_mask, base;
    step = XLEN'(1) << size;
    if (burst == 2'b00) return cur_addr;
    if (burst == 2'b10) begin
      wrap_bytes = (XLEN'(len) + XLEN'(1)) << size;
      wrap_mask = wrap_bytes - XLEN'(1);
      base = cur_addr & ~wrap_mask;
      return base | ((cur_addr + step) & wrap_mask);
    end
    return cur_addr + step;
  endfunction

  logic past_valid = 1'b0;
  logic [XLEN-1:0] watched_addr_q, init_word_q;

  // Inner AXI stability shadows (environment assumptions).
  logic s_ar_stall_q, s_aw_stall_q, s_w_stall_q;
  logic [XLEN-1:0] s_araddr_q, s_awaddr_q, s_wdata_q;
  logic [ID_W-1:0] s_arid_q, s_awid_q;
  logic [7:0] s_arlen_q, s_awlen_q;
  logic [2:0] s_arsize_q, s_awsize_q;
  logic [1:0] s_arburst_q, s_awburst_q;
  logic [3:0] s_arcache_q, s_awcache_q;
  logic [WordBytes-1:0] s_wstrb_q;
  logic s_wlast_q;

  // Inner AXI response stability shadows (DUT assertions).
  logic s_r_stall_q, s_b_stall_q;
  logic [XLEN-1:0] s_rdata_q;
  logic [ID_W-1:0] s_rid_q, s_bid_q;
  logic [1:0] s_rresp_q, s_bresp_q;
  logic s_rlast_q;

  // Outer AXI master stability shadows (DUT assertions).
  logic m_ar_stall_q, m_aw_stall_q, m_w_stall_q;
  logic [XLEN-1:0] m_araddr_q, m_awaddr_q, m_wdata_q;
  logic [ID_W-1:0] m_arid_q, m_awid_q;
  logic [7:0] m_arlen_q, m_awlen_q;
  logic [2:0] m_arsize_q, m_awsize_q;
  logic [1:0] m_arburst_q, m_awburst_q;
  logic [3:0] m_arcache_q, m_awcache_q;
  logic [WordBytes-1:0] m_wstrb_q;
  logic m_wlast_q;

  // Inner outstanding read tracker (per ID, at most 1 active per ID in formal).
  logic [NumOuterIds-1:0] s_rd_active;
  logic [XLEN-1:0] s_rd_addr[NumOuterIds];
  logic [7:0] s_rd_rem[NumOuterIds];
  logic [7:0] s_rd_len[NumOuterIds];
  logic [2:0] s_rd_size[NumOuterIds];
  logic [1:0] s_rd_burst[NumOuterIds];

  // Inner write stream tracker (in-order AW/W pairing, single-beat or burst).
  logic s_wr_aw_active;
  logic [XLEN-1:0] s_wr_cur_addr;
  logic [7:0] s_wr_rem, s_wr_len;
  logic [2:0] s_wr_size;
  logic [1:0] s_wr_burst;
  logic [4:0] s_b_pending;

  // Outer backing-memory tracker for ARs (per outer ID) and AWs (single active).
  logic [NumOuterIds-1:0] m_rd_active;
  logic [XLEN-1:0] m_rd_addr[NumOuterIds];
  logic [7:0] m_rd_rem[NumOuterIds];
  logic [7:0] m_rd_len[NumOuterIds];
  logic [2:0] m_rd_size[NumOuterIds];
  logic [1:0] m_rd_burst[NumOuterIds];

  logic m_wr_active;
  logic [XLEN-1:0] m_wr_addr;
  logic [7:0] m_wr_rem, m_wr_len;
  logic [2:0] m_wr_size;
  logic [1:0] m_wr_burst;
  logic [ID_W-1:0] m_wr_id;
  logic m_b_due;
  logic [ID_W-1:0] m_b_due_id;

  // Golden coherence state for watched_addr.
  logic [XLEN-1:0] golden_word, backing_word;
  logic [4:0] watched_b_pending;
  logic [15:0] b_fifo_watched;
  logic [3:0] b_fifo_wptr, b_fifo_rptr;
  wire watched_wr_inflight = (watched_b_pending != 5'd0)
      || (s_wr_aw_active && s_wr_cur_addr[XLEN-1:OffsetBits] == watched_addr[XLEN-1:OffsetBits]);
  logic watched_rd_inflight;

  wire s_ar_fire = axi_s.arvalid && axi_s.arready;
  wire s_r_fire = axi_s.rvalid && axi_s.rready;
  wire s_aw_fire = axi_s.awvalid && axi_s.awready;
  wire s_w_fire = axi_s.wvalid && axi_s.wready;
  wire s_b_fire = axi_s.bvalid && axi_s.bready;
  wire m_ar_fire = axi_m.arvalid && axi_m.arready;
  wire m_r_fire = axi_m.rvalid && axi_m.rready;
  wire m_aw_fire = axi_m.awvalid && axi_m.awready;
  wire m_w_fire = axi_m.wvalid && axi_m.wready;
  wire m_b_fire = axi_m.bvalid && axi_m.bready;

  wire [XLEN-1:0] watched_word_base = {watched_addr[XLEN-1:ByteOffBits], {ByteOffBits{1'b0}}};
  wire [XLEN-1:0] s_w_eff_addr = s_wr_aw_active ? s_wr_cur_addr : axi_s.awaddr;
  wire [XLEN-1:0] m_w_eff_addr = m_wr_active ? m_wr_addr : axi_m.awaddr;

  // Check whether any active inner read currently targets watched_addr's line.
  logic any_s_rd_watched;
  always_comb begin
    any_s_rd_watched = 1'b0;
    for (int id = 0; id < NumOuterIds; id++) begin
      if (s_rd_active[id]
          && s_rd_addr[id][XLEN-1:OffsetBits] == watched_addr[XLEN-1:OffsetBits]) begin
        any_s_rd_watched = 1'b1;
      end
    end
  end

  if (BoomBankedStore) begin : g_boom_init_assume
    always_comb begin
      if (!past_valid) assume (!dut.g_boom_directory.u_directory.write_queued);
    end
  end

  always_comb begin
    if (!past_valid)
      assume (reset);
      else assume (!reset);
    // Constrain watched_addr to be word-aligned in cacheable PMEM.
    assume (watched_addr[ByteOffBits-1:0] == '0);
    assume (rapt_pkg::addr_in_pmem(watched_addr));
    assume (rapt_pkg::addr_cacheable(watched_addr));

    if (!reset) begin
      // ---- Inner AXI4 Master Legality Assumptions ----
      if (s_ar_stall_q) begin
        assume (s_arvalid);
        assume (s_araddr == s_araddr_q);
        assume (s_arid == s_arid_q);
        assume (s_arlen == s_arlen_q);
        assume (s_arsize == s_arsize_q);
        assume (s_arburst == s_arburst_q);
        assume (s_arcache == s_arcache_q);
      end
      if (s_aw_stall_q) begin
        assume (s_awvalid);
        assume (s_awaddr == s_awaddr_q);
        assume (s_awid == s_awid_q);
        assume (s_awlen == s_awlen_q);
        assume (s_awsize == s_awsize_q);
        assume (s_awburst == s_awburst_q);
        assume (s_awcache == s_awcache_q);
      end
      if (s_w_stall_q) begin
        assume (s_wvalid);
        assume (s_wdata == s_wdata_q);
        assume (s_wstrb == s_wstrb_q);
        assume (s_wlast == s_wlast_q);
      end
      // Legal inner AR shapes (matching core masters: L1I=1, L1D=2, PTW=3/4, MSHRs=8..15).
      if (s_arvalid) begin
        assume (s_arsize <= 3'(ByteOffBits));
        assume (s_arburst != 2'b11);
        assume (s_arlen < 8'(LineWords));
        if (s_arburst == 2'b01) begin
          assume (({1'b0, s_araddr[OffsetBits-1:0]}
              + ((OffsetBits + 1)'(s_arlen + 8'd1) << s_arsize))
              <= (OffsetBits + 1)'(1 << OffsetBits));
        end
        if (s_arburst == 2'b10) begin
          assume (s_arlen == 8'd1 || s_arlen == 8'd3 || s_arlen == 8'd7);
          assume (s_araddr[ByteOffBits-1:0] == '0);
        end
        // One outstanding inner AR per ID keeps golden tracking unambiguous.
        assume (!s_rd_active[s_arid]);
        // Keep addresses in legal canonical physical space.
        assume ((s_araddr >> PADDR_BITS) == '0);
        // No coherence race on watched_addr while a write is in flight or starting.
        if (CHECK_COHERENCE
            && (watched_wr_inflight
                || (s_awvalid
                    && s_awaddr[XLEN-1:OffsetBits] == watched_addr[XLEN-1:OffsetBits]))) begin
          assume (s_araddr[XLEN-1:OffsetBits] != watched_addr[XLEN-1:OffsetBits]);
        end
      end
      // Legal inner AW/W pairing (one AW burst at a time from inner master).
      if (s_awvalid) begin
        assume (!s_wr_aw_active);
        assume (s_awsize == 3'(ByteOffBits));
        assume (s_awaddr[ByteOffBits-1:0] == '0);
        assume (s_awburst == 2'b01);
        assume (s_awlen < 8'(LineWords));
        assume (({1'b0, s_awaddr[OffsetBits-1:ByteOffBits]} + {1'b0, s_awlen})
            <= (L2_LINE_LEN + 1)'(LineWords));
        assume ((s_awaddr >> PADDR_BITS) == '0);
        assume (s_b_pending < 5'd12);
        if (CHECK_COHERENCE && any_s_rd_watched)
          assume (s_awaddr[XLEN-1:OffsetBits] != watched_addr[XLEN-1:OffsetBits]);
      end
      if (s_wvalid) begin
        assume (s_wr_aw_active || s_awvalid);
        if (s_wr_aw_active)
          assume (s_wlast == (s_wr_rem == 8'd0));
          else assume (s_wlast == (s_awlen == 8'd0));
      end
      // Client probe_release contract: only in response to an active probe on matching line.
      if (ALLOW_PROBE_RELEASE && probe_release_valid_i) begin
        assume (probe_valid_o);
        assume (probe_release_addr_i[XLEN-1:OffsetBits] == probe_addr_o[XLEN-1:OffsetBits]);
        assume (probe_release_addr_i[ByteOffBits-1:0] == '0);
        // Coherent L1D probe writeback supplies current golden_word if targeting watched_addr.
        if (CHECK_COHERENCE && probe_release_addr_i == watched_word_base)
          assume (probe_release_data_i == golden_word);
      end
      if (ALLOW_CBO && cbo_inval_i) begin
        assume (!s_awvalid && !s_wr_aw_active);
      end

      // ---- Outer AXI4 Slave Legality & Backing Memory Model ----
      if (m_rvalid) begin
        assume (m_rd_active[m_rid]);
        assume (m_rlast == (m_rd_rem[m_rid] == 8'd0));
        if (!ALLOW_OUTER_ERR
            || (CHECK_COHERENCE
                && m_rd_addr[m_rid][XLEN-1:OffsetBits] == watched_addr[XLEN-1:OffsetBits])) begin
          assume (m_rresp == 2'b00);
        end
        // Backing memory returns exact backing_word for watched_addr.
        if (CHECK_COHERENCE
            && {m_rd_addr[m_rid][XLEN-1:ByteOffBits], {ByteOffBits{1'b0}}} == watched_word_base
            && m_rresp == 2'b00) begin
          assume (m_rdata == backing_word);
        end
      end
      if (m_bvalid) begin
        assume (m_b_due);
        assume (m_bid == m_b_due_id);
        if (!ALLOW_OUTER_ERR || dut.cbo_state == 4'd8 || CHECK_COHERENCE) assume (m_bresp == 2'b00);
      end
    end
  end

  always_ff @(posedge clock) begin
    if (past_valid) begin
      assume (watched_addr == watched_addr_q);
      assume (init_word == init_word_q);
    end
    watched_addr_q <= watched_addr;
    init_word_q <= init_word;
    past_valid <= 1'b1;

    if (reset) begin
      s_ar_stall_q <= 1'b0;
      s_aw_stall_q <= 1'b0;
      s_w_stall_q <= 1'b0;
      s_r_stall_q <= 1'b0;
      s_b_stall_q <= 1'b0;
      m_ar_stall_q <= 1'b0;
      m_aw_stall_q <= 1'b0;
      m_w_stall_q <= 1'b0;
      s_rd_active <= '0;
      s_wr_aw_active <= 1'b0;
      s_b_pending <= '0;
      m_rd_active <= '0;
      m_wr_active <= 1'b0;
      m_b_due <= 1'b0;
      golden_word <= init_word;
      backing_word <= init_word;
      watched_b_pending <= '0;
      b_fifo_watched <= '0;
      b_fifo_wptr <= '0;
      b_fifo_rptr <= '0;
      watched_rd_inflight <= 1'b0;
    end else begin
      // ================================================================
      // 1. AXI4 Master (axi_m) Protocol Stability & Ordering Assertions
      // ================================================================
      if (m_ar_stall_q) begin
        m_ar_valid_stable : assert (axi_m.arvalid);
        m_ar_addr_stable : assert (axi_m.araddr == m_araddr_q);
        m_ar_id_stable : assert (axi_m.arid == m_arid_q);
        m_ar_len_stable : assert (axi_m.arlen == m_arlen_q);
        m_ar_size_stable : assert (axi_m.arsize == m_arsize_q);
        m_ar_burst_stable : assert (axi_m.arburst == m_arburst_q);
        m_ar_cache_stable : assert (axi_m.arcache == m_arcache_q);
      end
      if (m_aw_stall_q) begin
        m_aw_valid_stable : assert (axi_m.awvalid);
        m_aw_addr_stable : assert (axi_m.awaddr == m_awaddr_q);
        m_aw_id_stable : assert (axi_m.awid == m_awid_q);
        m_aw_len_stable : assert (axi_m.awlen == m_awlen_q);
        m_aw_size_stable : assert (axi_m.awsize == m_awsize_q);
        m_aw_burst_stable : assert (axi_m.awburst == m_awburst_q);
        m_aw_cache_stable : assert (axi_m.awcache == m_awcache_q);
      end
      if (m_w_stall_q) begin
        m_w_valid_stable : assert (axi_m.wvalid);
        m_w_data_stable : assert (axi_m.wdata == m_wdata_q);
        m_w_strb_stable : assert (axi_m.wstrb == m_wstrb_q);
        m_w_last_stable : assert (axi_m.wlast == m_wlast_q);
      end
      if (m_w_fire) begin
        m_w_has_aw : assert (m_wr_active || m_aw_fire);
        if (m_wr_active)
          m_wlast_exact :
          assert (axi_m.wlast == (m_wr_rem == 8'd0));
          else m_wlast_exact_same : assert (axi_m.wlast == (axi_m.awlen == 8'd0));
      end

      // ================================================================
      // 2. AXI4 Slave (axi_s) Protocol Stability & Ordering Assertions
      // ================================================================
      if (s_r_stall_q) begin
        s_r_valid_stable : assert (axi_s.rvalid);
        s_r_data_stable : assert (axi_s.rdata == s_rdata_q);
        s_r_id_stable : assert (axi_s.rid == s_rid_q);
        s_r_resp_stable : assert (axi_s.rresp == s_rresp_q);
        s_r_last_stable : assert (axi_s.rlast == s_rlast_q);
      end
      if (s_b_stall_q) begin
        s_b_valid_stable : assert (axi_s.bvalid);
        s_b_id_stable : assert (axi_s.bid == s_bid_q);
        s_b_resp_stable : assert (axi_s.bresp == s_bresp_q);
      end
      if (s_r_fire) begin
        s_r_matches_ar : assert (s_rd_active[axi_s.rid]);
        s_rlast_exact : assert (axi_s.rlast == (s_rd_rem[axi_s.rid] == 8'd0));
        // End-to-end symbolic memory coherence check!
        if (CHECK_COHERENCE
            && {s_rd_addr[axi_s.rid][XLEN-1:ByteOffBits], {ByteOffBits{1'b0}}}
               == watched_word_base
            && axi_s.rresp == 2'b00) begin
          s_rdata_coherent : assert (axi_s.rdata == golden_word);
        end
      end
      if (s_b_fire) begin
        s_b_has_aw : assert (s_b_pending != '0);
      end

      // ================================================================
      // 3. L2 Whitebox Deadlock-Freedom & Architectural Safety Invariants
      // ================================================================
      // Bug #3 (KU15P silicon hang): R_BYPASS_WAIT must never coexist with ms_busy.
      no_bypass_wait_mshr_deadlock : assert (!(dut.rs == 5'd15 && dut.ms_busy));
      // Bug #4A: R_HIT_PROBE must never probe L1D for L1D's own read IDs (2 or 8..15).
      no_self_probe_l1d_id :
      assert (!(dut.rs == 5'd3 && (dut.r_id == ID_W'(2) || dut.r_id[3] == 1'b1)));
      // No probe while a voluntary Release is pending.
      no_probe_during_release : assert (!(probe_valid_o && dut.release_pending));

      // ================================================================
      // 4. Update Protocol Shadows and Backing/Golden Memory Trackers
      // ================================================================
      s_ar_stall_q <= axi_s.arvalid && !axi_s.arready;
      if (axi_s.arvalid) begin
        s_araddr_q <= axi_s.araddr;
        s_arid_q <= axi_s.arid;
        s_arlen_q <= axi_s.arlen;
        s_arsize_q <= axi_s.arsize;
        s_arburst_q <= axi_s.arburst;
        s_arcache_q <= axi_s.arcache;
      end
      s_aw_stall_q <= axi_s.awvalid && !axi_s.awready;
      if (axi_s.awvalid) begin
        s_awaddr_q <= axi_s.awaddr;
        s_awid_q <= axi_s.awid;
        s_awlen_q <= axi_s.awlen;
        s_awsize_q <= axi_s.awsize;
        s_awburst_q <= axi_s.awburst;
        s_awcache_q <= axi_s.awcache;
      end
      s_w_stall_q <= axi_s.wvalid && !axi_s.wready;
      if (axi_s.wvalid) begin
        s_wdata_q <= axi_s.wdata;
        s_wstrb_q <= axi_s.wstrb;
        s_wlast_q <= axi_s.wlast;
      end
      s_r_stall_q <= axi_s.rvalid && !axi_s.rready;
      if (axi_s.rvalid) begin
        s_rdata_q <= axi_s.rdata;
        s_rid_q <= axi_s.rid;
        s_rresp_q <= axi_s.rresp;
        s_rlast_q <= axi_s.rlast;
      end
      s_b_stall_q <= axi_s.bvalid && !axi_s.bready;
      if (axi_s.bvalid) begin
        s_bid_q <= axi_s.bid;
        s_bresp_q <= axi_s.bresp;
      end
      m_ar_stall_q <= axi_m.arvalid && !axi_m.arready;
      if (axi_m.arvalid) begin
        m_araddr_q <= axi_m.araddr;
        m_arid_q <= axi_m.arid;
        m_arlen_q <= axi_m.arlen;
        m_arsize_q <= axi_m.arsize;
        m_arburst_q <= axi_m.arburst;
        m_arcache_q <= axi_m.arcache;
      end
      m_aw_stall_q <= axi_m.awvalid && !axi_m.awready;
      if (axi_m.awvalid) begin
        m_awaddr_q <= axi_m.awaddr;
        m_awid_q <= axi_m.awid;
        m_awlen_q <= axi_m.awlen;
        m_awsize_q <= axi_m.awsize;
        m_awburst_q <= axi_m.awburst;
        m_awcache_q <= axi_m.awcache;
      end
      m_w_stall_q <= axi_m.wvalid && !axi_m.wready;
      if (axi_m.wvalid) begin
        m_wdata_q <= axi_m.wdata;
        m_wstrb_q <= axi_m.wstrb;
        m_wlast_q <= axi_m.wlast;
      end

      // Inner AR / R tracking.
      if (s_ar_fire) begin
        s_rd_active[axi_s.arid] <= 1'b1;
        s_rd_addr[axi_s.arid] <= axi_s.araddr;
        s_rd_rem[axi_s.arid] <= axi_s.arlen;
        s_rd_len[axi_s.arid] <= axi_s.arlen;
        s_rd_size[axi_s.arid] <= axi_s.arsize;
        s_rd_burst[axi_s.arid] <= axi_s.arburst;
      end
      if (s_r_fire) begin
        if (axi_s.rlast) s_rd_active[axi_s.rid] <= 1'b0;
        else begin
          s_rd_rem[axi_s.rid] <= s_rd_rem[axi_s.rid] - 8'd1;
          s_rd_addr[axi_s.rid] <= next_beat_addr(
              s_rd_addr[axi_s.rid], s_rd_size[axi_s.rid], s_rd_burst[axi_s.rid],
              s_rd_len[axi_s.rid]
          );
        end
      end

      // Inner AW / W / B tracking + golden_word update.
      if (s_aw_fire) begin
        if (!(s_w_fire && axi_s.wlast)) begin
          s_wr_aw_active <= 1'b1;
          s_wr_cur_addr <= s_w_fire
              ? next_beat_addr(axi_s.awaddr, axi_s.awsize, axi_s.awburst, axi_s.awlen)
              : axi_s.awaddr;
          s_wr_rem <= s_w_fire ? axi_s.awlen - 8'd1 : axi_s.awlen;
          s_wr_len <= axi_s.awlen;
          s_wr_size <= axi_s.awsize;
          s_wr_burst <= axi_s.awburst;
        end
        b_fifo_watched[b_fifo_wptr] <=
            (axi_s.awaddr[XLEN-1:OffsetBits] == watched_addr[XLEN-1:OffsetBits]);
        b_fifo_wptr <= b_fifo_wptr + 4'd1;
      end else if (s_w_fire) begin
        if (axi_s.wlast) s_wr_aw_active <= 1'b0;
        else begin
          s_wr_rem <= s_wr_rem - 8'd1;
          s_wr_cur_addr <= next_beat_addr(s_wr_cur_addr, s_wr_size, s_wr_burst, s_wr_len);
        end
      end
      if (s_w_fire) begin
        if ({s_w_eff_addr[XLEN-1:ByteOffBits], {ByteOffBits{1'b0}}} == watched_word_base) begin
          golden_word <= merge_bytes(golden_word, axi_s.wdata, axi_s.wstrb);
        end
      end
      if (s_b_fire) b_fifo_rptr <= b_fifo_rptr + 4'd1;
      s_b_pending <= s_b_pending + (s_aw_fire ? 5'd1 : 5'd0) - (s_b_fire ? 5'd1 : 5'd0);
      watched_b_pending <= watched_b_pending
          + ((s_aw_fire
              && axi_s.awaddr[XLEN-1:OffsetBits] == watched_addr[XLEN-1:OffsetBits])
              ? 5'd1 : 5'd0)
          - ((s_b_fire && b_fifo_watched[b_fifo_rptr]) ? 5'd1 : 5'd0);

      // Outer AR / R tracking.
      if (m_ar_fire) begin
        m_rd_active[axi_m.arid] <= 1'b1;
        m_rd_addr[axi_m.arid] <= axi_m.araddr;
        m_rd_rem[axi_m.arid] <= axi_m.arlen;
        m_rd_len[axi_m.arid] <= axi_m.arlen;
        m_rd_size[axi_m.arid] <= axi_m.arsize;
        m_rd_burst[axi_m.arid] <= axi_m.arburst;
      end
      if (m_r_fire) begin
        if (axi_m.rlast) m_rd_active[axi_m.rid] <= 1'b0;
        else begin
          m_rd_rem[axi_m.rid] <= m_rd_rem[axi_m.rid] - 8'd1;
          m_rd_addr[axi_m.rid] <= next_beat_addr(
              m_rd_addr[axi_m.rid], m_rd_size[axi_m.rid], m_rd_burst[axi_m.rid],
              m_rd_len[axi_m.rid]
          );
        end
      end

      // Outer AW / W / B tracking + backing_word update.
      if (m_aw_fire) begin
        if (!(m_w_fire && axi_m.wlast)) begin
          m_wr_active <= 1'b1;
          m_wr_addr <= m_w_fire
              ? next_beat_addr(axi_m.awaddr, axi_m.awsize, axi_m.awburst, axi_m.awlen)
              : axi_m.awaddr;
          m_wr_rem <= m_w_fire ? axi_m.awlen - 8'd1 : axi_m.awlen;
          m_wr_len <= axi_m.awlen;
          m_wr_size <= axi_m.awsize;
          m_wr_burst <= axi_m.awburst;
          m_wr_id <= axi_m.awid;
        end else begin
          m_b_due <= 1'b1;
          m_b_due_id <= axi_m.awid;
        end
      end else if (m_w_fire) begin
        if (axi_m.wlast) begin
          m_wr_active <= 1'b0;
          m_b_due <= 1'b1;
          m_b_due_id <= m_wr_id;
        end else begin
          m_wr_rem <= m_wr_rem - 8'd1;
          m_wr_addr <= next_beat_addr(m_wr_addr, m_wr_size, m_wr_burst, m_wr_len);
        end
      end
      if (m_w_fire) begin
        if ({m_w_eff_addr[XLEN-1:ByteOffBits], {ByteOffBits{1'b0}}} == watched_word_base) begin
          backing_word <= merge_bytes(backing_word, axi_m.wdata, axi_m.wstrb);
        end
      end
      if (m_b_fire) m_b_due <= 1'b0;

      // Key coverage witnesses.
      cov_read_hit_coherence :
      cover (
          s_r_fire && axi_s.rresp == 2'b00 && axi_s.rdata == golden_word
          && {s_rd_addr[axi_s.rid][XLEN-1:ByteOffBits], {ByteOffBits{1'b0}}} == watched_word_base
          && golden_word != init_word
      );
      cov_mshr_multi : cover (dut.ms_slot_valid[0] && dut.ms_slot_valid[1]);
      cov_probe_fire : cover (probe_valid_o && probe_ready_i);
      cov_evict_stalled_w : cover (m_w_stall_q && axi_m.wvalid && axi_m.wready);
      cov_bypass_ar : cover (dut.rs == 5'd16 && m_ar_fire);
    end
  end
endmodule
