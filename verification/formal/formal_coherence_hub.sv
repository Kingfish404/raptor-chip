`include "rapt.svh"
`include "rapt_soc.svh"
`include "rapt_soc_if.svh"

// Formal verification harness for rapt_coherence_hub:
// Proves multi-hart mutual exclusion, probe-before-write-response ordering,
// 64B CBO sub-line coverage, ALL-hart (sibling + self) read-vs-write line
// hazard blocking, same-hart pending-store ordering, multi-entry CBO.INVAL
// FIFO non-loss + read hazard blocking, uncached read serialization, per-hart
// read ID FIFO integrity, and downstream AXI/mem_link request stability.
module formal_coherence_hub #(
    parameter int XLEN = `RAPT_XLEN,
    parameter int NHARTS = 2,
    parameter int ID_W = 4,
    parameter int PerHartReadCredits = 4,
    parameter int CboFifoDepth = 4,
    parameter int L2LineOffset = rapt_pkg::L2LinkConfig.line_offset
) (
    input logic clock,
    input logic reset,

    input logic [NHARTS-1:0] rd_req_valid_i,
    input logic [  ID_W-1:0] rd_req_id_i        [NHARTS],
    input logic [  XLEN-1:0] rd_req_addr_i      [NHARTS],
    input logic [       2:0] rd_req_size_i      [NHARTS],
    input logic [       7:0] rd_req_len_i       [NHARTS],
    input logic [       1:0] rd_req_burst_i     [NHARTS],
    input logic [       1:0] rd_req_pbmt_i      [NHARTS],
    input logic [NHARTS-1:0] rd_req_noallocate_i,
    input logic [NHARTS-1:0] rd_req_cacheable_i,
    input logic [NHARTS-1:0] rd_rsp_ready_i,

    input logic [NHARTS-1:0] wr_req_valid_i,
    input logic [NHARTS-1:0] wr_req_zero_i,
    input logic [  ID_W-1:0] wr_req_id_i        [NHARTS],
    input logic [  XLEN-1:0] wr_req_addr_i      [NHARTS],
    input logic [       2:0] wr_req_size_i      [NHARTS],
    input logic [       1:0] wr_req_pbmt_i      [NHARTS],
    input logic [  XLEN-1:0] wr_req_data_i      [NHARTS],
    input logic [XLEN/8-1:0] wr_req_strb_i      [NHARTS],
    input logic [NHARTS-1:0] wr_rsp_ready_i,

    input logic [NHARTS-1:0] probe_ready_i,
    input logic [NHARTS-1:0] cbo_inval_i,
    input logic [  XLEN-1:6] cbo_block_i        [NHARTS],
    input logic [NHARTS-1:0] atomic_lock_req_i,
    input logic              l2_probe_valid_i,
    input logic [  XLEN-1:0] l2_probe_addr_i,

    input logic              out_rd_req_ready_i,
    input logic              out_rd_rsp_valid_i,
    input logic [  ID_W-1:0] out_rd_rsp_id_i,
    input logic [  XLEN-1:0] out_rd_rsp_data_i,
    input logic              out_rd_rsp_last_i,
    input logic              out_rd_rsp_error_i,
    input logic              out_wr_req_ready_i,
    input logic              out_wr_rsp_valid_i,
    input logic              out_wr_rsp_error_i
);
  localparam int HartW      = (NHARTS <= 1) ? 1 : $clog2(NHARTS);
  localparam int LineOffW   = $clog2(`RAPT_CACHE_LINE_BYTES);
  localparam int SubLines   = (LineOffW < 6) ? (1 << (6 - LineOffW)) : 1;
  localparam int SubLineW   = (SubLines <= 1) ? 1 : $clog2(SubLines);
  localparam int L2LineOffW = L2LineOffset;
  localparam int L2SubLines = (LineOffW < L2LineOffW) ? (1 << (L2LineOffW - LineOffW)) : 1;
  localparam int L2SubLineW = (L2SubLines <= 1) ? 1 : $clog2(L2SubLines);
  localparam int L2CmpLsb   = (L2LineOffW > LineOffW) ? L2LineOffW : LineOffW;
  localparam int RdPtrW     = (PerHartReadCredits <= 1) ? 1 : $clog2(PerHartReadCredits);
  localparam int RdCntW     = $clog2(PerHartReadCredits + 1);
  localparam int CboPtrW    = (CboFifoDepth <= 1) ? 1 : $clog2(CboFifoDepth);
  localparam int CboCntW    = $clog2(CboFifoDepth + 1);

  logic [NHARTS-1:0] rd_req_ready_o;
  logic [NHARTS-1:0] rd_rsp_valid_o;
  logic [  ID_W-1:0] rd_rsp_id_o   [NHARTS];
  logic [  XLEN-1:0] rd_rsp_data_o [NHARTS];
  logic [NHARTS-1:0] rd_rsp_last_o;
  logic [NHARTS-1:0] rd_rsp_error_o;
  logic [NHARTS-1:0] wr_req_ready_o;
  logic [NHARTS-1:0] wr_rsp_valid_o;
  logic [  ID_W-1:0] wr_rsp_id_o   [NHARTS];
  logic [NHARTS-1:0] wr_rsp_error_o;
  logic [NHARTS-1:0] probe_valid_o;
  logic [  XLEN-1:0] probe_addr_o  [NHARTS];
  logic [NHARTS-1:0] probe_window_o;
  logic [NHARTS-1:0] atomic_lock_grant_o;
  logic              l2_probe_ready_o;
  logic              out_cbo_inval_o;
  logic [  XLEN-1:6] out_cbo_block_o;
  logic              out_rd_req_cacheable_o;

  mem_link_if #(
      .XLEN(XLEN),
      .ID_W(ID_W)
  ) out_mem ();
  assign out_mem.rd_req_ready = out_rd_req_ready_i;
  assign out_mem.rd_rsp_valid = out_rd_rsp_valid_i;
  assign out_mem.rd_rsp_id    = out_rd_rsp_id_i;
  assign out_mem.rd_rsp_data  = out_rd_rsp_data_i;
  assign out_mem.rd_rsp_last  = out_rd_rsp_last_i;
  assign out_mem.rd_rsp_error = out_rd_rsp_error_i;
  assign out_mem.wr_req_ready = out_wr_req_ready_i;
  assign out_mem.wr_rsp_valid = out_wr_rsp_valid_i;
  assign out_mem.wr_rsp_error = out_wr_rsp_error_i;

  rapt_coherence_hub #(
      .XLEN(XLEN),
      .NHARTS(NHARTS),
      .ID_W(ID_W),
      .PerHartReadCredits(PerHartReadCredits),
      .CboFifoDepth(CboFifoDepth),
      .L2LineOffset(L2LineOffset)
  ) dut (
      .clock(clock),
      .reset(reset),
      .rd_req_valid_i(rd_req_valid_i),
      .rd_req_ready_o(rd_req_ready_o),
      .rd_req_id_i(rd_req_id_i),
      .rd_req_addr_i(rd_req_addr_i),
      .rd_req_size_i(rd_req_size_i),
      .rd_req_len_i(rd_req_len_i),
      .rd_req_burst_i(rd_req_burst_i),
      .rd_req_pbmt_i(rd_req_pbmt_i),
      .rd_req_noallocate_i(rd_req_noallocate_i),
      .rd_req_cacheable_i(rd_req_cacheable_i),
      .rd_rsp_valid_o(rd_rsp_valid_o),
      .rd_rsp_ready_i(rd_rsp_ready_i),
      .rd_rsp_id_o(rd_rsp_id_o),
      .rd_rsp_data_o(rd_rsp_data_o),
      .rd_rsp_last_o(rd_rsp_last_o),
      .rd_rsp_error_o(rd_rsp_error_o),
      .wr_req_valid_i(wr_req_valid_i),
      .wr_req_zero_i(wr_req_zero_i),
      .wr_req_ready_o(wr_req_ready_o),
      .wr_req_id_i(wr_req_id_i),
      .wr_req_addr_i(wr_req_addr_i),
      .wr_req_size_i(wr_req_size_i),
      .wr_req_pbmt_i(wr_req_pbmt_i),
      .wr_req_data_i(wr_req_data_i),
      .wr_req_strb_i(wr_req_strb_i),
      .wr_rsp_valid_o(wr_rsp_valid_o),
      .wr_rsp_ready_i(wr_rsp_ready_i),
      .wr_rsp_id_o(wr_rsp_id_o),
      .wr_rsp_error_o(wr_rsp_error_o),
      .probe_valid_o(probe_valid_o),
      .probe_addr_o(probe_addr_o),
      .probe_ready_i(probe_ready_i),
      .probe_window_o(probe_window_o),
      .cbo_inval_i(cbo_inval_i),
      .cbo_block_i(cbo_block_i),
      .atomic_lock_req_i(atomic_lock_req_i),
      .atomic_lock_grant_o(atomic_lock_grant_o),
      .l2_probe_valid_i(l2_probe_valid_i),
      .l2_probe_addr_i(l2_probe_addr_i),
      .l2_probe_ready_o(l2_probe_ready_o),
      .out_cbo_inval_o(out_cbo_inval_o),
      .out_cbo_block_o(out_cbo_block_o),
      .out_mem(out_mem),
      .out_rd_req_cacheable_o(out_rd_req_cacheable_o)
  );

  // ------------------------------------------------------------------
  // Formal environment assumptions & independent reference scoreboard
  // ------------------------------------------------------------------
  logic past_valid;
  initial past_valid = 1'b0;
  always_ff @(posedge clock) past_valid <= 1'b1;

  // Start in reset on cycle 0
  always_comb if (!past_valid) assume (reset);

  // Independent per-hart read ID reference FIFOs
  logic [NHARTS-1:0][PerHartReadCredits-1:0][  ID_W-1:0] ref_rd_id;
  logic [NHARTS-1:0][RdPtrW-1:0]                         ref_rd_head;
  logic [NHARTS-1:0][RdPtrW-1:0]                         ref_rd_tail;
  logic [NHARTS-1:0][RdCntW-1:0]                         ref_rd_cnt;
  logic [NHARTS-1:0]                                     ref_rd_unc;

  // Independent CBO FIFO occupancy tracker
  logic [NHARTS-1:0][CboCntW-1:0] ref_cbo_cnt;

  // Independent write + probe scoreboard
  logic                               ref_wr_active;
  logic [     HartW-1:0]              ref_wr_hart;
  logic                               ref_wr_cacheable;
  logic                               ref_wr_zero;
  logic [      ID_W-1:0]              ref_wr_id;
  logic [      XLEN-1:0]              ref_wr_addr;
  logic                               ref_wr_b_seen;
  logic [NHARTS-1:0][  SubLines-1:0]  ref_probe_seen;
  logic [NHARTS-1:0][L2SubLines-1:0]  ref_l2_probe_seen;
  logic                               ref_out_wr_inflight;
  logic                               prev_l2_probe_valid;
  logic [      XLEN-1:0]              prev_l2_probe_addr;

  // Previous-cycle request stability trackers
  logic                          prev_out_rd_valid;
  logic [  ID_W-1:0]             prev_out_rd_id;
  logic [  XLEN-1:0]             prev_out_rd_addr;
  logic                          prev_out_wr_valid;
  logic [  XLEN-1:0]             prev_out_wr_addr;
  logic [NHARTS-1:0]             prev_rd_req_valid;
  logic [NHARTS-1:0][  ID_W-1:0] prev_rd_req_id;
  logic [NHARTS-1:0][  XLEN-1:0] prev_rd_req_addr;
  logic [NHARTS-1:0]             prev_rd_req_cach;

  // Well-formed AXI/mem_link environment assumptions
  always_comb begin
    if (!reset) begin
      // Downstream only returns read responses for IDs with outstanding reads
      if (out_rd_rsp_valid_i) begin
        assume (int'(out_rd_rsp_id_i) < NHARTS);
        assume (ref_rd_cnt[out_rd_rsp_id_i[HartW-1:0]] != '0);
      end
      // Downstream only returns write B when a write is actually in flight
      if (out_wr_rsp_valid_i) begin
        assume (ref_out_wr_inflight);
      end
      // Do not overflow the per-hart CBO FIFO in formal environment
      for (int h = 0; h < NHARTS; h++) begin
        if (ref_cbo_cnt[h] == CboCntW'(CboFifoDepth)) begin
          assume (!cbo_inval_i[h]);
        end
      end
      // Upstream read requests and L2 probes stay stable while stalled
      if (past_valid) begin
        if (prev_l2_probe_valid) begin
          assume (l2_probe_valid_i);
          assume (l2_probe_addr_i == prev_l2_probe_addr);
        end
        for (int h = 0; h < NHARTS; h++) begin
          if (prev_rd_req_valid[h]) begin
            assume (rd_req_valid_i[h]);
            assume (rd_req_id_i[h] == prev_rd_req_id[h]);
            assume (rd_req_addr_i[h] == prev_rd_req_addr[h]);
            assume (rd_req_cacheable_i[h] == prev_rd_req_cach[h]);
          end
        end
      end
    end
  end

  // Update reference scoreboards
  always_ff @(posedge clock) begin
    if (reset) begin
      ref_wr_active       <= 1'b0;
      ref_wr_hart         <= '0;
      ref_wr_cacheable    <= 1'b0;
      ref_wr_zero         <= 1'b0;
      ref_wr_id           <= '0;
      ref_wr_addr         <= '0;
      ref_wr_b_seen       <= 1'b0;
      ref_out_wr_inflight <= 1'b0;
      prev_out_rd_valid   <= 1'b0;
      prev_out_rd_id      <= '0;
      prev_out_rd_addr    <= '0;
      prev_out_wr_valid   <= 1'b0;
      prev_out_wr_addr    <= '0;
      prev_rd_req_valid   <= '0;
      prev_rd_req_cach    <= '0;
      prev_l2_probe_valid <= 1'b0;
      prev_l2_probe_addr  <= '0;
      ref_rd_id           <= '0;
      ref_rd_head         <= '0;
      ref_rd_tail         <= '0;
      ref_rd_cnt          <= '0;
      ref_rd_unc          <= '0;
      ref_cbo_cnt         <= '0;
      ref_probe_seen      <= '0;
      ref_l2_probe_seen   <= '0;
      prev_rd_req_id      <= '0;
      prev_rd_req_addr    <= '0;
    end else begin
      // Track stalled requests for stability check
      prev_out_rd_valid   <= out_mem.rd_req_valid && !out_mem.rd_req_ready;
      prev_out_rd_id      <= out_mem.rd_req_id;
      prev_out_rd_addr    <= out_mem.rd_req_addr;
      prev_out_wr_valid   <= out_mem.wr_req_valid && !out_mem.wr_req_ready;
      prev_out_wr_addr    <= out_mem.wr_req_addr;
      prev_l2_probe_valid <= l2_probe_valid_i && !l2_probe_ready_o;
      prev_l2_probe_addr  <= l2_probe_addr_i;

      // Track L2 probe acknowledgements across all harts
      if (!l2_probe_valid_i || l2_probe_ready_o) begin
        ref_l2_probe_seen <= '0;
      end else if (dut.l2p_state_q == 2'd1) begin
        for (int h = 0; h < NHARTS; h++) begin
          if (probe_valid_o[h] && probe_ready_i[h]
              && (probe_addr_o[h][XLEN-1:L2CmpLsb] == l2_probe_addr_i[XLEN-1:L2CmpLsb])) begin
            if (L2SubLines > 1) begin
              ref_l2_probe_seen[h][probe_addr_o[h][LineOffW+:L2SubLineW]] <= 1'b1;
            end else begin
              ref_l2_probe_seen[h][0] <= 1'b1;
            end
          end
        end
      end

      for (int h = 0; h < NHARTS; h++) begin
        prev_rd_req_valid[h] <= rd_req_valid_i[h] && !rd_req_ready_o[h];
        prev_rd_req_id[h]    <= rd_req_id_i[h];
        prev_rd_req_addr[h]  <= rd_req_addr_i[h];
        prev_rd_req_cach[h]  <= rd_req_cacheable_i[h];
      end

      // Independent CBO count scoreboard
      for (int h = 0; h < NHARTS; h++) begin
        automatic logic cbo_push = cbo_inval_i[h];
        automatic logic cbo_pop  = (dut.wr_state_q == 3'd0)
            && dut.cbo_pick_valid && (dut.cbo_pick_hart == HartW'(h));
        unique case ({
          cbo_push, cbo_pop
        })
          2'b10:   ref_cbo_cnt[h] <= ref_cbo_cnt[h] + CboCntW'(1);
          2'b01:   ref_cbo_cnt[h] <= ref_cbo_cnt[h] - CboCntW'(1);
          default: ;
        endcase
      end

      // Downstream write in-flight tracker
      if (out_mem.wr_req_valid && out_mem.wr_req_ready) begin
        ref_out_wr_inflight <= 1'b1;
      end else if (out_mem.wr_rsp_valid && out_mem.wr_rsp_ready) begin
        ref_out_wr_inflight <= 1'b0;
      end

      // Per-hart read FIFO scoreboard
      for (int h = 0; h < NHARTS; h++) begin
        automatic logic push = rd_req_valid_i[h] && rd_req_ready_o[h];
        automatic logic pop  = rd_rsp_valid_o[h] && rd_rsp_ready_i[h] && rd_rsp_last_o[h];
        if (push) begin
          ref_rd_id[h][ref_rd_tail[h]] <= rd_req_id_i[h];
          ref_rd_tail[h] <= (int'(ref_rd_tail[h]) == PerHartReadCredits - 1)
              ? '0 : ref_rd_tail[h] + RdPtrW'(1);
          if (!rd_req_cacheable_i[h]) ref_rd_unc[h] <= 1'b1;
        end
        if (pop) begin
          ref_rd_head[h] <= (int'(ref_rd_head[h]) == PerHartReadCredits - 1)
              ? '0 : ref_rd_head[h] + RdPtrW'(1);
          if (!push && ref_rd_cnt[h] == RdCntW'(1)) ref_rd_unc[h] <= 1'b0;
        end
        unique case ({
          push, pop
        })
          2'b10:   ref_rd_cnt[h] <= ref_rd_cnt[h] + RdCntW'(1);
          2'b01:   ref_rd_cnt[h] <= ref_rd_cnt[h] - RdCntW'(1);
          default: ;
        endcase
      end

      // Write + Probe scoreboard
      for (int h = 0; h < NHARTS; h++) begin
        if (wr_req_valid_i[h] && wr_req_ready_o[h]) begin
          ref_wr_active    <= 1'b1;
          ref_wr_hart      <= HartW'(h);
          ref_wr_cacheable <= rapt_pkg::addr_cacheable(wr_req_addr_i[h]) || wr_req_zero_i[h];
          ref_wr_zero      <= wr_req_zero_i[h];
          ref_wr_id        <= wr_req_id_i[h];
          ref_wr_addr      <= wr_req_addr_i[h];
          ref_wr_b_seen    <= 1'b0;
          ref_probe_seen   <= '0;
        end
      end
      if (ref_wr_active) begin
        if (out_mem.wr_rsp_valid && out_mem.wr_rsp_ready) begin
          ref_wr_b_seen <= 1'b1;
        end
        for (int h = 0; h < NHARTS; h++) begin
          if ((dut.l2p_state_q == 2'd0) && probe_valid_o[h] && probe_ready_i[h]) begin
            if (SubLines > 1) begin
              if (ref_wr_zero) begin
                if (probe_addr_o[h][XLEN-1:6] == ref_wr_addr[XLEN-1:6]) begin
                  ref_probe_seen[h][probe_addr_o[h][LineOffW+:SubLineW]] <= 1'b1;
                end
              end else if (probe_addr_o[h][XLEN-1:LineOffW] == ref_wr_addr[XLEN-1:LineOffW]) begin
                ref_probe_seen[h][0] <= 1'b1;
              end
            end else begin
              if (probe_addr_o[h][XLEN-1:LineOffW] == ref_wr_addr[XLEN-1:LineOffW]) begin
                ref_probe_seen[h][0] <= 1'b1;
              end
            end
          end
        end
        if (wr_rsp_valid_o[ref_wr_hart] && wr_rsp_ready_i[ref_wr_hart]) begin
          ref_wr_active <= 1'b0;
        end
      end
    end
  end

  // ------------------------------------------------------------------
  // Formal Assertions
  // ------------------------------------------------------------------
  always_comb begin
    if (!reset && past_valid) begin
      // 1. Strict mutual exclusion on grants and write/read acceptances
      assert ((atomic_lock_grant_o & (atomic_lock_grant_o - NHARTS'(1))) == '0);
      assert ((atomic_lock_grant_o & ~atomic_lock_req_i) == '0);
      assert ((rd_req_ready_o & (rd_req_ready_o - NHARTS'(1))) == '0);
      assert ((wr_req_ready_o & (wr_req_ready_o - NHARTS'(1))) == '0);
      assert ((wr_rsp_valid_o & (wr_rsp_valid_o - NHARTS'(1))) == '0);

      // 2. Atomic lock exclusivity: only the lock owner may accept or issue writes
      if (dut.amo_owner_valid_q && (dut.wr_state_q != 3'd0)) begin
        assert (!dut.wr_is_cbo_q);
        assert (dut.amo_owner_q == dut.wr_hart_q);
      end
      for (int h = 0; h < NHARTS; h++) begin
        if (|atomic_lock_grant_o && !atomic_lock_grant_o[h]) begin
          assert (!wr_req_ready_o[h]);
        end
        if (atomic_lock_grant_o[h]) begin
          if (out_mem.wr_req_valid) begin
            assert (out_mem.wr_req_id == ID_W'(h));
          end
        end
      end

      // 3. No concurrent writes accepted while a write is active + FSM inductive invariants
      assert (dut.wr_state_q <= 3'd5);
      assert (int'(dut.wr_hart_q) < NHARTS);
      assert (int'(dut.amo_owner_q) < NHARTS);
      assert (int'(dut.rd_lock_hart_q) < NHARTS);
      assert (int'(dut.probe_sub_q) < SubLines);
      assert (int'(dut.l2p_sub_q) < L2SubLines);
      assert (ref_wr_active == ((dut.wr_state_q != 3'd0) && !dut.wr_is_cbo_q));
      assert (ref_out_wr_inflight == (dut.wr_state_q == 3'd2));
      if (dut.wr_is_cbo_q && (dut.wr_state_q != 3'd0)) begin
        assert ((dut.wr_state_q == 3'd3) || (dut.wr_state_q == 3'd4));
      end
      if (ref_wr_active) begin
        assert (wr_req_ready_o == '0);
        assert (dut.wr_hart_q == ref_wr_hart);
        assert (dut.wr_is_cacheable_q == ref_wr_cacheable);
        assert (dut.wr_zero_q == ref_wr_zero);
        assert (dut.wr_id_q == ref_wr_id);
        assert (dut.wr_addr_q == ref_wr_addr);
        assert (ref_wr_b_seen == (dut.wr_state_q >= 3'd3));
        if ((dut.wr_state_q == 3'd1) || (dut.wr_state_q == 3'd2)) begin
          assert (ref_probe_seen == '0);
        end else if ((dut.wr_state_q == 3'd3) || (dut.wr_state_q == 3'd4)) begin
          assert (ref_wr_cacheable && (NHARTS > 1));
          assert (!dut.probe_pending_q[ref_wr_hart]);
          assert (!ref_probe_seen[ref_wr_hart]);
          if (!ref_wr_zero) begin
            assert (dut.wr_state_q == 3'd3);
            assert (dut.probe_sub_q == '0);
          end else if (dut.wr_state_q == 3'd4) begin
            assert (int'(dut.probe_sub_q) > 0);
          end
          for (int h = 0; h < NHARTS; h++) begin
            if (HartW'(h) != ref_wr_hart) begin
              for (int sb = 0; sb < SubLines; sb++) begin
                if (sb < int'(dut.probe_sub_q)) begin
                  assert (ref_probe_seen[h][sb]);
                end else if ((dut.wr_state_q == 3'd3) && (sb == int'(dut.probe_sub_q))) begin
                  assert (ref_probe_seen[h][sb] == !dut.probe_pending_q[h]);
                end else begin
                  assert (!ref_probe_seen[h][sb]);
                end
              end
            end
          end
        end
      end

      // 4. Probe-before-wr_rsp completeness & writer never self-probed by WR_PROBE
      assert ((dut.l2p_state_q == 2'd0) || ((dut.wr_state_q != 3'd3) && (dut.wr_state_q != 3'd4)));
      if (dut.l2p_state_q == 2'd0) begin
        assert (ref_l2_probe_seen == '0);
      end else begin
        assert (prev_l2_probe_valid);
        assert (dut.l2p_addr_q == prev_l2_probe_addr);
        if (dut.l2p_state_q == 2'd2) begin
          assert (int'(dut.l2p_sub_q) > 0);
        end
        for (int h = 0; h < NHARTS; h++) begin
          for (int sb = 0; sb < L2SubLines; sb++) begin
            if (dut.l2p_state_q == 2'd3) begin
              assert (ref_l2_probe_seen[h][sb]);
            end else if (sb < int'(dut.l2p_sub_q)) begin
              assert (ref_l2_probe_seen[h][sb]);
            end else if ((dut.l2p_state_q == 2'd1) && (sb == int'(dut.l2p_sub_q))) begin
              assert (ref_l2_probe_seen[h][sb] == !dut.l2p_pending_q[h]);
            end else begin
              assert (!ref_l2_probe_seen[h][sb]);
            end
          end
        end
      end
      if (l2_probe_ready_o) begin
        assert (l2_probe_valid_i);
        for (int h = 0; h < NHARTS; h++) begin
          assert (&ref_l2_probe_seen[h]);
        end
      end
      assert (out_cbo_inval_o == ((dut.wr_state_q == 3'd0) && dut.cbo_pick_valid));
      if (ref_wr_active) begin
        if (dut.l2p_state_q == 2'd0) begin
          assert (!probe_valid_o[ref_wr_hart]);
        end
        if (wr_rsp_valid_o[ref_wr_hart]) begin
          assert (ref_wr_b_seen);
          assert (wr_rsp_id_o[ref_wr_hart] == ref_wr_id);
          if (ref_wr_cacheable && NHARTS > 1) begin
            for (int h = 0; h < NHARTS; h++) begin
              if (HartW'(h) != ref_wr_hart) begin
                if (ref_wr_zero) begin
                  assert (&ref_probe_seen[h]);
                end else begin
                  assert (ref_probe_seen[h][0]);
                end
              end
            end
          end
        end
      end else begin
        assert (wr_rsp_valid_o == '0);
      end

      // 5. Read-vs-write line hazard: NO hart (neither sibling NOR writer)
      //    may accept a read to an active cacheable/zero write line, nor may
      //    the writer accept an uncached read while its write is active.
      if (ref_wr_active) begin
        for (int h = 0; h < NHARTS; h++) begin
          if (rd_req_ready_o[h]) begin
            if (ref_wr_cacheable) begin
              if (ref_wr_zero) begin
                assert (rd_req_addr_i[h][XLEN-1:6] != ref_wr_addr[XLEN-1:6]);
              end else begin
                assert (rd_req_addr_i[h][XLEN-1:LineOffW] != ref_wr_addr[XLEN-1:LineOffW]);
              end
            end
            if (HartW'(h) == ref_wr_hart) begin
              assert (rd_req_cacheable_i[h]);
            end
          end
        end
      end

      // 6. Uncached read serialization & per-hart read ID FIFO integrity
      for (int h = 0; h < NHARTS; h++) begin
        assert (dut.rd_fifo_cnt[h] == ref_rd_cnt[h]);
        assert (dut.rd_fifo_cnt[h] <= RdCntW'(PerHartReadCredits));
        assert (int'(dut.rd_fifo_head[h]) < PerHartReadCredits);
        assert (int'(dut.rd_fifo_tail[h]) < PerHartReadCredits);
        assert (dut.rd_fifo_head[h] == ref_rd_head[h]);
        assert (dut.rd_fifo_tail[h] == ref_rd_tail[h]);
        assert (dut.rd_fifo_uncached_q[h] == ref_rd_unc[h]);
        assert (((int'(ref_rd_head[h]) + int'(ref_rd_cnt[h])) % PerHartReadCredits)
            == int'(ref_rd_tail[h]));
        if (ref_rd_cnt[h] == '0) begin
          assert (!ref_rd_unc[h]);
        end
        for (int s = 0; s < PerHartReadCredits; s++) begin
          automatic
          int
          rel = (s >= int'(ref_rd_head[h]))
              ? (s - int'(ref_rd_head[h]))
              : (s + PerHartReadCredits - int'(ref_rd_head[h]));
          if (rel < int'(ref_rd_cnt[h])) begin
            assert (dut.rd_fifo_id[h][s] == ref_rd_id[h][s]);
          end
        end
        if (rd_req_valid_i[h] && rd_req_ready_o[h]) begin
          assert (ref_rd_cnt[h] < RdCntW'(PerHartReadCredits));
          if (ref_rd_cnt[h] != '0) begin
            assert (rd_req_cacheable_i[h] && !ref_rd_unc[h]);
          end
        end
        if (rd_rsp_valid_o[h]) begin
          assert (ref_rd_cnt[h] != '0);
          assert (rd_rsp_id_o[h] == ref_rd_id[h][ref_rd_head[h]]);
        end
      end

      // 7. Downstream channel stability while stalled
      assert (dut.rd_lock_q == prev_out_rd_valid);
      if (prev_out_rd_valid) begin
        automatic logic [HartW-1:0] lh = dut.rd_lock_hart_q;
        assert (lh == prev_out_rd_id[HartW-1:0]);
        assert (prev_rd_req_valid[lh]);
        assert (!dut.rd_fifo_full[lh]);
        assert ((ref_rd_cnt[lh] == '0) || (prev_rd_req_cach[lh] && !ref_rd_unc[lh]));
        if (ref_wr_active) begin
          if (ref_wr_cacheable) begin
            if (ref_wr_zero) begin
              assert (prev_out_rd_addr[XLEN-1:6] != ref_wr_addr[XLEN-1:6]);
            end else begin
              assert (prev_out_rd_addr[XLEN-1:LineOffW] != ref_wr_addr[XLEN-1:LineOffW]);
            end
          end
          if (lh == ref_wr_hart) begin
            assert (prev_rd_req_cach[lh]);
          end
        end
        assert (out_mem.rd_req_valid);
        assert (out_mem.rd_req_id == prev_out_rd_id);
        assert (out_mem.rd_req_addr == prev_out_rd_addr);
      end
      if (prev_out_wr_valid) begin
        assert (dut.wr_state_q == 3'd1);
        assert (dut.wr_addr_q == prev_out_wr_addr);
        assert (out_mem.wr_req_valid);
        assert (out_mem.wr_req_addr == prev_out_wr_addr);
      end

      // 8. Same-hart pending write & CBO FIFO non-loss / read-hazard ordering
      for (int h = 0; h < NHARTS; h++) begin
        assert (dut.cbo_fifo_cnt[h] == ref_cbo_cnt[h]);
        assert (dut.cbo_fifo_cnt[h] <= CboCntW'(CboFifoDepth));
        assert (dut.cbo_fifo_tail[h] == (dut.cbo_fifo_head[h] + dut.cbo_fifo_cnt[h][CboPtrW-1:0]));
        if (!prev_out_rd_valid && rd_req_ready_o[h]) begin
          if (wr_req_valid_i[h]) begin
            assert (rd_req_cacheable_i[h]);
            if (rapt_pkg::addr_cacheable(wr_req_addr_i[h]) || wr_req_zero_i[h]) begin
              if (wr_req_zero_i[h]) begin
                assert (rd_req_addr_i[h][XLEN-1:6] != wr_req_addr_i[h][XLEN-1:6]);
              end else begin
                assert (rd_req_addr_i[h][XLEN-1:LineOffW] != wr_req_addr_i[h][XLEN-1:LineOffW]);
              end
            end
          end
          for (int i = 0; i < NHARTS; i++) begin
            if (cbo_inval_i[i]) begin
              assert (rd_req_addr_i[h][XLEN-1:6] != cbo_block_i[i]);
            end
          end
        end
      end
    end
  end

  // ------------------------------------------------------------------
  // Cover witnesses: ensure all SMP scenarios are reachable
  // ------------------------------------------------------------------
  always @(posedge clock) begin
    if (!reset && past_valid) begin
      // Cover 1: Cacheable write completes after probing all siblings
      cover (ref_wr_active && ref_wr_cacheable && !ref_wr_zero
          && wr_rsp_valid_o[ref_wr_hart] && wr_rsp_ready_i[ref_wr_hart]);
      // Cover 2: 64B cbo.zero completes after probing all sub-lines on all siblings
      cover (ref_wr_active && ref_wr_zero
          && wr_rsp_valid_o[ref_wr_hart] && wr_rsp_ready_i[ref_wr_hart]);
      // Cover 3: Multi-entry CBO FIFO queueing & simultaneous push+pop
      cover (ref_cbo_cnt[0] >= CboCntW'(2));
      cover (cbo_inval_i[0] && (dut.wr_state_q == 3'd0)
          && dut.cbo_pick_valid && (dut.cbo_pick_hart == '0));
      // Cover 4: Atomic lock granted to hart 1 & L2 probe / CBO forward completion
      cover (l2_probe_valid_i && l2_probe_ready_o);
      cover (out_cbo_inval_o);
      if (NHARTS >= 2) begin
        cover (atomic_lock_grant_o[1]);
        cover (ref_rd_cnt[0] != '0 && ref_rd_cnt[1] != '0);
      end
    end
  end
endmodule
