`include "rapt.svh"
`include "rapt_soc.svh"
`include "rapt_soc_if.svh"

// Standalone directed + randomized stress test for `rapt_coherence_hub`
// (NHARTS = 4). Verifies:
//   1. Back-invalidation probes reach all sibling harts before wr_rsp returns.
//   2. Golden-memory data consistency across concurrent multi-hart reads/writes.
//   3. CBO.INVAL broadcast to sibling harts.
//   4. Cluster atomic lock mutual exclusion, write isolation, and round-robin fairness.
module tb_coherence_hub;
  localparam int XLEN = `RAPT_XLEN;
  localparam int NHARTS = 4;
  localparam int WordBytes = XLEN / 8;

  logic clock = 1'b0;
  logic reset = 1'b1;
  always #5 clock = ~clock;

  `include "tb_common.svh"

  logic [NHARTS-1:0] rd_req_valid;
  logic [NHARTS-1:0] rd_req_ready;
  logic [       3:0] rd_req_id        [NHARTS];
  logic [  XLEN-1:0] rd_req_addr      [NHARTS];
  logic [       2:0] rd_req_size      [NHARTS];
  logic [       7:0] rd_req_len       [NHARTS];
  logic [       1:0] rd_req_burst     [NHARTS];
  logic [       1:0] rd_req_pbmt      [NHARTS];
  logic [NHARTS-1:0] rd_req_noallocate;
  logic [NHARTS-1:0] rd_req_cacheable;

  logic [NHARTS-1:0] rd_rsp_valid;
  logic [NHARTS-1:0] rd_rsp_ready;
  logic [       3:0] rd_rsp_id        [NHARTS];
  logic [  XLEN-1:0] rd_rsp_data      [NHARTS];
  logic [NHARTS-1:0] rd_rsp_last;
  logic [NHARTS-1:0] rd_rsp_error;

  logic [NHARTS-1:0] wr_req_valid;
  logic [NHARTS-1:0] wr_req_zero;
  logic [NHARTS-1:0] wr_req_ready;
  logic [       3:0] wr_req_id        [NHARTS];
  logic [  XLEN-1:0] wr_req_addr      [NHARTS];
  logic [       2:0] wr_req_size      [NHARTS];
  logic [       1:0] wr_req_pbmt      [NHARTS];
  logic [  XLEN-1:0] wr_req_data      [NHARTS];
  logic [XLEN/8-1:0] wr_req_strb      [NHARTS];

  logic [NHARTS-1:0] wr_rsp_valid;
  logic [NHARTS-1:0] wr_rsp_ready;
  logic [       3:0] wr_rsp_id        [NHARTS];
  logic [NHARTS-1:0] wr_rsp_error;

  logic [NHARTS-1:0] probe_valid;
  logic [  XLEN-1:0] probe_addr       [NHARTS];
  logic [NHARTS-1:0] probe_ready;
  logic [NHARTS-1:0] probe_window;

  logic [NHARTS-1:0] cbo_inval;
  logic [  XLEN-1:6] cbo_block        [NHARTS];

  logic [NHARTS-1:0] atomic_lock_req;
  logic [NHARTS-1:0] atomic_lock_grant;
  logic              l2_probe_valid;
  logic [  XLEN-1:0] l2_probe_addr;
  logic              l2_probe_ready;
  logic              out_cbo_inval;
  logic [  XLEN-1:6] out_cbo_block;

  mem_link_if #(.XLEN(XLEN)) out_mem ();
  logic out_rd_req_cacheable;

  rapt_coherence_hub #(
      .XLEN  (XLEN),
      .NHARTS(NHARTS)
  ) dut (
      .clock                 (clock),
      .reset                 (reset),
      .rd_req_valid_i        (rd_req_valid),
      .rd_req_ready_o        (rd_req_ready),
      .rd_req_id_i           (rd_req_id),
      .rd_req_addr_i         (rd_req_addr),
      .rd_req_size_i         (rd_req_size),
      .rd_req_len_i          (rd_req_len),
      .rd_req_burst_i        (rd_req_burst),
      .rd_req_pbmt_i         (rd_req_pbmt),
      .rd_req_noallocate_i   (rd_req_noallocate),
      .rd_req_cacheable_i    (rd_req_cacheable),
      .rd_rsp_valid_o        (rd_rsp_valid),
      .rd_rsp_ready_i        (rd_rsp_ready),
      .rd_rsp_id_o           (rd_rsp_id),
      .rd_rsp_data_o         (rd_rsp_data),
      .rd_rsp_last_o         (rd_rsp_last),
      .rd_rsp_error_o        (rd_rsp_error),
      .wr_req_valid_i        (wr_req_valid),
      .wr_req_zero_i         (wr_req_zero),
      .wr_req_ready_o        (wr_req_ready),
      .wr_req_id_i           (wr_req_id),
      .wr_req_addr_i         (wr_req_addr),
      .wr_req_size_i         (wr_req_size),
      .wr_req_pbmt_i         (wr_req_pbmt),
      .wr_req_data_i         (wr_req_data),
      .wr_req_strb_i         (wr_req_strb),
      .wr_rsp_valid_o        (wr_rsp_valid),
      .wr_rsp_ready_i        (wr_rsp_ready),
      .wr_rsp_id_o           (wr_rsp_id),
      .wr_rsp_error_o        (wr_rsp_error),
      .probe_valid_o         (probe_valid),
      .probe_addr_o          (probe_addr),
      .probe_ready_i         (probe_ready),
      .probe_window_o        (probe_window),
      .cbo_inval_i           (cbo_inval),
      .cbo_block_i           (cbo_block),
      .atomic_lock_req_i     (atomic_lock_req),
      .atomic_lock_grant_o   (atomic_lock_grant),
      .l2_probe_valid_i      (l2_probe_valid),
      .l2_probe_addr_i       (l2_probe_addr),
      .l2_probe_ready_o      (l2_probe_ready),
      .out_cbo_inval_o       (out_cbo_inval),
      .out_cbo_block_o       (out_cbo_block),
      .out_mem               (out_mem),
      .out_rd_req_cacheable_o(out_rd_req_cacheable)
  );

  // Downstream memory model (16 cacheable 64-byte lines at 0x8000_0000..0x8000_03ff)
  logic [XLEN-1:0] golden_mem[128];
  logic            rd_rsp_q;
  logic [     3:0] rd_rsp_id_q;
  logic [XLEN-1:0] rd_rsp_data_q;
  logic            wr_rsp_q;
  logic [     3:0] wr_rsp_id_q;

  assign out_mem.rd_req_ready = !rd_rsp_q;
  assign out_mem.rd_rsp_valid = rd_rsp_q;
  assign out_mem.rd_rsp_id    = rd_rsp_id_q;
  assign out_mem.rd_rsp_data  = rd_rsp_data_q;
  assign out_mem.rd_rsp_last  = 1'b1;
  assign out_mem.rd_rsp_error = 1'b0;

  assign out_mem.wr_req_ready = !wr_rsp_q;
  assign out_mem.wr_rsp_valid = wr_rsp_q;
  assign out_mem.wr_rsp_id    = wr_rsp_id_q;
  assign out_mem.wr_rsp_error = 1'b0;

  always_ff @(posedge clock) begin
    if (reset) begin
      rd_rsp_q <= 1'b0;
      wr_rsp_q <= 1'b0;
      for (int i = 0; i < 128; i++) golden_mem[i] <= XLEN'(32'hA000_0000 + i);
    end else begin
      if (out_mem.rd_req_valid && out_mem.rd_req_ready) begin
        automatic
        int
        widx = int'((out_mem.rd_req_addr - XLEN'(32'h8000_0000)) >> $clog2(
            WordBytes
        ));
        rd_rsp_q      <= 1'b1;
        rd_rsp_id_q   <= out_mem.rd_req_id;
        rd_rsp_data_q <= golden_mem[widx & 127];
      end else if (rd_rsp_q && out_mem.rd_rsp_ready) begin
        rd_rsp_q <= 1'b0;
      end

      if (out_mem.wr_req_valid && out_mem.wr_req_ready) begin
        automatic
        int
        widx = int'((out_mem.wr_req_addr - XLEN'(32'h8000_0000)) >> $clog2(
            WordBytes
        ));
        wr_rsp_q    <= 1'b1;
        wr_rsp_id_q <= out_mem.wr_req_id;
        golden_mem[widx & 127] <= out_mem.wr_req_data;
      end else if (wr_rsp_q && out_mem.wr_rsp_ready) begin
        wr_rsp_q <= 1'b0;
      end
    end
  end

  // Per-hart mock L1D caches (16 lines) and 64B sub-line probe trackers
  localparam int LineOffW = $clog2(`RAPT_CACHE_LINE_BYTES);
  localparam int SubLines = (LineOffW < 6) ? (1 << (6 - LineOffW)) : 1;
  logic [15:0] l1d_valid[NHARTS];
  logic [NHARTS-1:0] probe_seen_mask;
  logic [SubLines-1:0] probe_sub_seen[NHARTS];

  always_ff @(posedge clock) begin
    if (reset) begin
      probe_ready     <= '0;
      probe_seen_mask <= '0;
      for (int h = 0; h < NHARTS; h++) begin
        l1d_valid[h]      <= '0;
        probe_sub_seen[h] <= '0;
      end
    end else begin
      for (int h = 0; h < NHARTS; h++) begin
        probe_ready[h] <= probe_valid[h];
        if (probe_valid[h]) begin
          automatic int line = int'((probe_addr[h] - XLEN'(32'h8000_0000)) >> 6) & 15;
          automatic int sub = (SubLines > 1)
              ? int'((probe_addr[h] >> LineOffW) & XLEN'(SubLines - 1)) : 0;
          l1d_valid[h][line]     <= 1'b0;
          probe_seen_mask[h]     <= 1'b1;
          probe_sub_seen[h][sub] <= 1'b1;
        end
      end
    end
  end

  // Invariant: atomic_lock_grant must always be one-hot or zero
  always_ff @(posedge clock) begin
    if (!reset) begin
      check($onehot0(atomic_lock_grant), "atomic_lock_grant violated mutual exclusion");
    end
  end

  initial begin
    int grants_seen[NHARTS];
    rd_req_valid      = '0;
    rd_req_noallocate = '0;
    rd_req_cacheable  = '1;
    rd_rsp_ready      = '1;
    wr_req_valid      = '0;
    wr_req_zero       = '0;
    wr_rsp_ready      = '1;
    cbo_inval         = '0;
    atomic_lock_req   = '0;
    l2_probe_valid    = 1'b0;
    l2_probe_addr     = '0;
    for (int h = 0; h < NHARTS; h++) begin
      rd_req_id[h]    = 4'd2;
      rd_req_addr[h]  = '0;
      rd_req_size[h]  = 3'($clog2(WordBytes));
      rd_req_len[h]   = 8'd0;
      rd_req_burst[h] = 2'b01;
      rd_req_pbmt[h]  = 2'b00;
      wr_req_id[h]    = 4'd2;
      wr_req_addr[h]  = '0;
      wr_req_size[h]  = 3'($clog2(WordBytes));
      wr_req_pbmt[h]  = 2'b00;
      wr_req_data[h]  = '0;
      wr_req_strb[h]  = '1;
      cbo_block[h]    = '0;
      grants_seen[h]  = 0;
    end

    tick(3);
    reset = 1'b0;
    tick(1);

    // 1. Verify cacheable write from hart 0 probes harts 1, 2, 3 before wr_rsp[0]
    for (int h = 0; h < NHARTS; h++) l1d_valid[h][3] = 1'b1;
    probe_seen_mask = '0;
    wr_req_valid[0] = 1'b1;
    wr_req_addr[0]  = XLEN'(32'h8000_00c0);  // line 3
    wr_req_data[0]  = XLEN'(32'hDEAD_BEEF);
    wr_req_id[0]    = 4'd5;
    #1;
    while (!wr_req_ready[0]) tick(1);
    tick(1);
    wr_req_valid[0] = 1'b0;
    #1;
    while (!wr_rsp_valid[0]) tick(1);
    check(wr_rsp_id[0] == 4'd5, "wr_rsp_id mismatch for hart 0");
    if (probe_seen_mask != 4'b1110) begin
      $display("DEBUG: probe_seen_mask=%b wr_is_cacheable=%b addr=0x%x", probe_seen_mask,
               dut.wr_is_cacheable_q, dut.wr_addr_q);
    end
    check(probe_seen_mask == 4'b1110, "write from hart 0 did not probe all sibling harts");
    check(l1d_valid[0][3] == 1'b1, "writer hart 0 was unexpectedly invalidated");
    check(l1d_valid[1][3] == 1'b0 && l1d_valid[2][3] == 1'b0 && l1d_valid[3][3] == 1'b0,
          "sibling L1Ds were not invalidated by write probe");
    tick(1);

    // 2. Verify CBO.INVAL from hart 2 probes all SubLines on harts 0, 1, 3
    for (int h = 0; h < NHARTS; h++) begin
      l1d_valid[h][5]   = 1'b1;
      probe_sub_seen[h] = '0;
    end
    probe_seen_mask = '0;
    cbo_inval[2]    = 1'b1;
    cbo_block[2]    = (XLEN-6)'(32'h8000_0140 >> 6);  // line 5
    tick(1);
    cbo_inval[2] = 1'b0;
    tick(SubLines * 4 + 2);
    check(probe_seen_mask == 4'b1011, "CBO.INVAL from hart 2 did not probe harts 0, 1, 3");
    check(l1d_valid[0][5] == 1'b0 && l1d_valid[1][5] == 1'b0 && l1d_valid[3][5] == 1'b0,
          "sibling L1Ds were not invalidated by CBO.INVAL");
    for (int h = 0; h < NHARTS; h++) begin
      if (h != 2) begin
        check(probe_sub_seen[h] == '1,
              "CBO.INVAL did not probe every cache sub-line of the 64B block");
      end
    end

    // 3. Verify atomic lock mutual exclusion, write blocking, and round-robin fairness
    atomic_lock_req = 4'b1111;
    for (int round = 0; round < 8; round++) begin
      automatic int owner = -1;
      tick(1);
      for (int h = 0; h < NHARTS; h++) begin
        if (atomic_lock_grant[h]) owner = h;
      end
      check(owner >= 0, "atomic lock was not granted when all harts requested");
      grants_seen[owner]++;
      // Non-owner write must be blocked while owner holds lock
      wr_req_valid[(owner + 1) % NHARTS] = 1'b1;
      wr_req_addr[(owner + 1) % NHARTS]  = XLEN'(32'h8000_0000);
      tick(2);
      check(!wr_req_ready[(owner+1)%NHARTS], "non-owner write bypassed atomic lock");
      wr_req_valid[(owner + 1) % NHARTS] = 1'b0;
      // Release lock for this owner
      atomic_lock_req[owner] = 1'b0;
      tick(1);
      atomic_lock_req[owner] = 1'b1;
    end
    atomic_lock_req = 4'b0000;
    for (int h = 0; h < NHARTS; h++) begin
      check(grants_seen[h] == 2, "atomic lock round-robin fairness violated");
    end

    // 4. Concurrent multi-hart reads verify ID recovery and data integrity
    for (int h = 0; h < NHARTS; h++) begin
      rd_req_valid[h] = 1'b1;
      rd_req_id[h]    = 4'(8 + h);
      rd_req_addr[h]  = XLEN'(32'h8000_00c0);
    end
    begin
      logic [NHARTS-1:0] req_done = '0;
      logic [NHARTS-1:0] rsp_done = '0;
      int guard = 0;
      while ((req_done != '1 || rsp_done != '1) && guard < 100) begin
        automatic logic [NHARTS-1:0] accepted = rd_req_valid & rd_req_ready;
        automatic logic [NHARTS-1:0] responded = rd_rsp_valid;
        for (int h = 0; h < NHARTS; h++) begin
          if (responded[h]) begin
            check(rd_rsp_id[h] == 4'(8 + h), "read response local ID mismatch");
            check(rd_rsp_data[h] == XLEN'(32'hDEAD_BEEF), "read response data mismatch");
            rsp_done[h] = 1'b1;
          end
        end
        tick(1);
        for (int h = 0; h < NHARTS; h++) begin
          if (accepted[h]) begin
            req_done[h]     = 1'b1;
            rd_req_valid[h] = 1'b0;
          end
        end
        guard++;
      end
      check(req_done == '1 && rsp_done == '1, "concurrent multi-hart reads timed out");
    end

    // 5. Verify CBO.ZERO from hart 1 probes all SubLines of the 64B block on harts 0, 2, 3
    probe_seen_mask = '0;
    for (int h = 0; h < NHARTS; h++) probe_sub_seen[h] = '0;
    wr_req_valid[1] = 1'b1;
    wr_req_zero[1]  = 1'b1;
    wr_req_id[1]    = 4'd6;
    wr_req_addr[1]  = XLEN'(32'h8000_0180);
    while (!wr_req_ready[1]) tick(1);
    tick(1);
    wr_req_valid[1] = 1'b0;
    wr_req_zero[1]  = 1'b0;
    #1;
    while (!wr_rsp_valid[1]) tick(1);
    check(wr_rsp_id[1] == 4'd6, "wr_rsp_id mismatch for hart 1 cbo.zero");
    check(probe_seen_mask == 4'b1101, "CBO.ZERO from hart 1 did not probe harts 0, 2, 3");
    for (int h = 0; h < NHARTS; h++) begin
      if (h != 1) begin
        check(probe_sub_seen[h] == '1,
              "CBO.ZERO did not probe every cache sub-line of the 64B block");
      end
    end
    tick(1);

    // 6. Verify downstream L2 probe broadcasts to ALL harts (0..NHARTS-1) before l2_probe_ready
    probe_seen_mask = '0;
    for (int h = 0; h < NHARTS; h++) l1d_valid[h][7] = 1'b1;
    l2_probe_valid = 1'b1;
    l2_probe_addr  = XLEN'(32'h8000_01c0);  // line 7
    #1;
    while (!l2_probe_ready) tick(1);
    tick(1);
    l2_probe_valid = 1'b0;
    check(probe_seen_mask == 4'b1111, "downstream L2 probe did not broadcast to all 4 harts");
    for (int h = 0; h < NHARTS; h++) begin
      check(l1d_valid[h][7] == 1'b0, "hart L1D was not invalidated by downstream L2 probe");
    end
    tick(1);

    $display("PASS: coherence hub (NHARTS=%0d, XLEN=%0d, SubLines=%0d)", NHARTS, XLEN, SubLines);
    $finish;
  end
endmodule
