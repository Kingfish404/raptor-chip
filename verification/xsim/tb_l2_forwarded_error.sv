// A forwarded cacheable burst changes resident data only after a successful
// outer B. A failed B preserves both the old target and older dirty bytes.
`include "rapt.svh"
`include "rapt_soc_if.svh"

module tb_l2_forwarded_error;
  localparam int XLEN = `RAPT_XLEN;
  localparam int IdW = 4;
  localparam int LineBeats = 1 << `RAPT_L2_LINE_LEN;
  localparam logic [XLEN-1:0] LineAddr = XLEN'('h80000100);
  logic clock = 0;
  logic reset = 1;
  axi4_if #(
      .XLEN(XLEN),
      .ID_W(IdW)
  ) axi_s ();
  axi4_if #(
      .XLEN(XLEN),
      .ID_W(IdW)
  ) axi_m ();
  rapt_l2 #(
      .XLEN(XLEN),
      .ID_W(IdW)
  ) dut (
      .clock,
      .reset,
      .cbo_inval_i(1'b0),
      .cbo_block_i('0),
      .probe_ready_i(1'b1),
      .axi_s,
      .axi_m
  );
  always #5 clock = ~clock;
  `include "tb_common.svh"
  `include "tb_l2_axi_tasks.svh"
  int replay_commits = 0;
  always @(posedge clock) begin
    if (!reset && dut.forward_replay_commit) begin
      replay_commits++;
      check(dut.g_boom_directory.u_directory.write_dirty,
            "successful forwarded burst did not mark its resident line dirty");
    end
  end

  initial begin
    logic [IdW-1:0] outer_id;
    logic [XLEN-1:0] outer_addr;
    logic [XLEN-1:0] expected_first, expected_last;
    logic [7:0] outer_len;
    bit accepted;
    init_l2_axi(0);
    tick(5);
    reset = 0;
    for (int cycle = 0; cycle < 1200 && !axi_s.awready; cycle++) tick(1);
    check(axi_s.awready, "directory wipe timed out");

    send_l2_ar(LineAddr, 4'h1);
    accept_l2_downstream_ar(outer_id, outer_addr, outer_len);
    check(outer_addr == LineAddr && outer_len == 8'(LineBeats - 1), "initial refill shape");
    for (int beat = 0; beat < LineBeats; beat++)
    return_l2_downstream_r(outer_id, XLEN'('h100 + beat), beat == LineBeats - 1);
    for (int cycle = 0; cycle < 128 && dut.ms_busy; cycle++) tick(1);
    check(!dut.ms_busy, "initial refill did not retire");

    // Keep an older dirty word that a failed-write invalidation must preserve.
    send_l2_aw(LineAddr + XLEN'(3 * (XLEN / 8)), 4'h2);
    send_l2_w_full(XLEN'('hfeed));
    for (int cycle = 0; cycle < 128 && !axi_s.bvalid; cycle++) tick(1);
    check(axi_s.bvalid && axi_s.bid == 4'h2 && axi_s.bresp == 2'b00, "local dirty write response");
    axi_s.bready = 1;
    tick(1);
    axi_s.bready = 0;

    // AWCACHE[0]=0 requires a real outer B, so this cacheable INCR remains
    // forwarded even though both beats are inside the resident line.
    axi_s.awaddr = LineAddr;
    axi_s.awid = 4'h4;
    axi_s.awlen = 8'd1;
    axi_s.awsize = 3'($clog2(XLEN / 8));
    axi_s.awburst = 2'b01;
    axi_s.awcache = 4'he;
    axi_s.awvalid = 1;
    accepted = 0;
    for (int cycle = 0; cycle < 128 && !accepted; cycle++) begin
      @(posedge clock);
      accepted = axi_s.awready;
    end
    check(accepted && !dut.burst_alloc_needs_read, "non-bufferable AW did not forward");
    #1;
    axi_s.awvalid = 0;
    for (int beat = 0; beat < 2; beat++) begin
      axi_s.wdata = XLEN'('haa + beat);
      axi_s.wstrb = '1;
      axi_s.wlast = beat == 1;
      axi_s.wvalid = 1;
      accepted = 0;
      for (int cycle = 0; cycle < 128 && !accepted; cycle++) begin
        @(posedge clock);
        accepted = axi_s.wready;
      end
      check(accepted, "forwarded W stalled");
      #1;
      axi_s.wvalid = 0;
    end
    axi_m.awready = 1;
    accepted = 0;
    for (int cycle = 0; cycle < 128 && !accepted; cycle++) begin
      @(posedge clock);
      accepted = axi_m.awvalid;
    end
    check(accepted && axi_m.awaddr == LineAddr, "outer AW missing");
    #1;
    axi_m.awready = 0;
    axi_m.wready = 1;
    for (int beat = 0; beat < 2; beat++) begin
      accepted = 0;
      for (int cycle = 0; cycle < 128 && !accepted; cycle++) begin
        @(posedge clock);
        accepted = axi_m.wvalid;
      end
      check(accepted, "outer W missing");
      #1;
    end
    axi_m.wready = 0;
    return_l2_downstream_b(4'h4, 2'b10);
    check(replay_commits == 0, "failed forwarded B replayed cached data");
    check(axi_s.bvalid && axi_s.bresp == 2'b10, "outer error B was not forwarded");
    axi_s.bready = 1;
    tick(1);
    axi_s.bready = 0;

    axi_s.rready = 0;
    send_l2_ar(LineAddr, 4'h5);
    for (int cycle = 0; cycle < 128 && !axi_s.rvalid && !axi_m.arvalid; cycle++) tick(1);
    check(axi_s.rvalid && axi_s.rdata == XLEN'('h100) && !axi_m.arvalid,
          "failed forwarded B changed the resident target word");
    axi_s.rready = 1;
    tick(1);
    axi_s.rready = 0;
    send_l2_ar(LineAddr + XLEN'(3 * (XLEN / 8)), 4'h6);
    for (int cycle = 0; cycle < 128 && !axi_s.rvalid && !axi_m.arvalid; cycle++) tick(1);
    check(axi_s.rvalid && axi_s.rdata == XLEN'('hfeed) && !axi_m.arvalid,
          "failed forwarded B lost older dirty data");
    axi_s.rready = 1;
    tick(1);
    axi_s.rready = 0;

    // The same forwarded shape commits only after a successful outer B.
    axi_s.awaddr = LineAddr;
    axi_s.awid = 4'h8;
    axi_s.awlen = 8'd1;
    axi_s.awsize = 3'($clog2(XLEN / 8));
    axi_s.awburst = 2'b01;
    axi_s.awcache = 4'he;
    axi_s.awvalid = 1;
    accepted = 0;
    for (int cycle = 0; cycle < 128 && !accepted; cycle++) begin
      @(posedge clock);
      accepted = axi_s.awready;
    end
    check(accepted, "successful forwarded AW stalled");
    #1;
    axi_s.awvalid = 0;
    for (int beat = 0; beat < 2; beat++) begin
      axi_s.wdata = beat == 0 ? XLEN'('h55) : XLEN'('h66);
      axi_s.wstrb = beat == 0 ? (XLEN / 8)'(1) : '1;
      axi_s.wlast = beat == 1;
      axi_s.wvalid = 1;
      accepted = 0;
      for (int cycle = 0; cycle < 128 && !accepted; cycle++) begin
        @(posedge clock);
        accepted = axi_s.wready;
      end
      check(accepted, "successful forwarded W stalled");
      #1;
      axi_s.wvalid = 0;
    end
    axi_m.awready = 1;
    accepted = 0;
    for (int cycle = 0; cycle < 128 && !accepted; cycle++) begin
      @(posedge clock);
      accepted = axi_m.awvalid;
    end
    check(accepted && axi_m.awaddr == LineAddr, "successful outer AW missing");
    #1;
    axi_m.awready = 0;
    axi_m.wready = 1;
    for (int beat = 0; beat < 2; beat++) begin
      accepted = 0;
      for (int cycle = 0; cycle < 128 && !accepted; cycle++) begin
        @(posedge clock);
        accepted = axi_m.wvalid;
      end
      check(accepted, "successful outer W missing");
      #1;
    end
    axi_m.wready = 0;
    check(!axi_s.arready && !axi_s.awready && !axi_s.bvalid,
          "forwarded hit escaped before the outer B");
    return_l2_downstream_b(4'h8, 2'b00);
    check(replay_commits == 2, "successful B did not replay both resident beats");
    check(axi_s.bvalid && axi_s.bresp == 2'b00, "successful B was not returned upstream");
    axi_s.bready = 1;
    tick(1);
    axi_s.bready = 0;
    axi_s.rready = 0;
    send_l2_ar(LineAddr, 4'h9);
    for (int cycle = 0; cycle < 128 && !axi_s.rvalid && !axi_m.arvalid; cycle++) tick(1);
    check(axi_s.rvalid && axi_s.rdata == XLEN'('h155) && !axi_m.arvalid,
          "successful masked forwarded write missed its resident target");
    axi_s.rready = 1;
    tick(1);
    axi_s.rready = 0;
    send_l2_ar(LineAddr + XLEN'(XLEN / 8), 4'ha);
    for (int cycle = 0; cycle < 128 && !axi_s.rvalid && !axi_m.arvalid; cycle++) tick(1);
    check(axi_s.rvalid && axi_s.rdata == XLEN'('h66) && !axi_m.arvalid,
          "successful forwarded write missed its second beat");
    axi_s.rready = 1;
    tick(1);

    // Exercise all 256 journal entries with a legal byte-wide INCR burst
    // over four resident lines. The shared 40-beat Put pool drains as W
    // arrives, while the hit journal retains every byte until outer B.
    for (int line = 1; line < 4; line++) begin
      send_l2_ar(LineAddr + XLEN'(line * 64), 4'(line));
      accept_l2_downstream_ar(outer_id, outer_addr, outer_len);
      check(outer_addr == LineAddr + XLEN'(line * 64) && outer_len == 8'(LineBeats - 1),
            "long-burst resident line refill shape");
      for (int beat = 0; beat < LineBeats; beat++)
      return_l2_downstream_r(outer_id, XLEN'('h200 + line * 16 + beat), beat == LineBeats - 1);
      for (int cycle = 0; cycle < 128 && dut.ms_busy; cycle++) tick(1);
      check(!dut.ms_busy, "long-burst resident refill did not retire");
    end
    axi_s.bready = 0;
    fork
      begin : long_upstream
        bit upstream_accepted;
        axi_s.awaddr = LineAddr;
        axi_s.awid = 4'hc;
        axi_s.awlen = 8'd255;
        axi_s.awsize = 3'd0;
        axi_s.awburst = 2'b01;
        axi_s.awcache = 4'he;
        axi_s.awvalid = 1;
        upstream_accepted = 0;
        for (int cycle = 0; cycle < 128 && !upstream_accepted; cycle++) begin
          @(posedge clock);
          upstream_accepted = axi_s.awready;
        end
        check(upstream_accepted, "long forwarded AW stalled");
        #1;
        axi_s.awvalid = 0;
        for (int beat = 0; beat < 256; beat++) begin
          axi_s.wdata = XLEN'(beat) << ((beat % (XLEN / 8)) * 8);
          axi_s.wstrb = (XLEN / 8)'(1 << (beat % (XLEN / 8)));
          axi_s.wlast = beat == 255;
          axi_s.wvalid = 1;
          upstream_accepted = 0;
          for (int cycle = 0; cycle < 1024 && !upstream_accepted; cycle++) begin
            @(posedge clock);
            upstream_accepted = axi_s.wready;
          end
          check(upstream_accepted, "long forwarded W stalled");
          #1;
          axi_s.wvalid = 0;
        end
      end
      begin : long_downstream
        bit downstream_accepted;
        axi_m.awready = 1;
        downstream_accepted = 0;
        for (int cycle = 0; cycle < 128 && !downstream_accepted; cycle++) begin
          @(posedge clock);
          downstream_accepted = axi_m.awvalid;
        end
        check(downstream_accepted && axi_m.awlen == 8'd255 && axi_m.awsize == 3'd0,
              "long forwarded outer AW shape");
        #1;
        axi_m.awready = 0;
        axi_m.wready = 1;
        for (int beat = 0; beat < 256; beat++) begin
          bit seen;
          seen = 0;
          for (int cycle = 0; cycle < 1024 && !seen; cycle++) begin
            @(posedge clock);
            seen = axi_m.wvalid;
          end
          check(seen && axi_m.wlast == (beat == 255), "long forwarded outer W shape");
        end
        #1;
        axi_m.wready = 0;
      end
    join
    check(dut.forward_log_count == 9'd256 && replay_commits == 2,
          "long burst did not retain all resident hit beats");
    axi_m.bid = 4'hc;
    axi_m.bresp = 2'b00;
    axi_m.bvalid = 1;
    accepted = 0;
    for (int cycle = 0; cycle < 2000 && !accepted; cycle++) begin
      @(posedge clock);
      accepted = axi_m.bready;
    end
    check(accepted, "long forwarded B replay timed out");
    #1;
    axi_m.bvalid = 0;
    check(replay_commits == 258, "long forwarded B skipped or repeated a journal beat");
    check(axi_s.bvalid && axi_s.bresp == 2'b00, "long forwarded B missing upstream");
    axi_s.bready = 1;
    tick(1);
    axi_s.bready = 0;
    expected_first = '0;
    expected_last = '0;
    for (int byte_index = 0; byte_index < XLEN / 8; byte_index++) begin
      expected_first[byte_index*8+:8] = 8'(byte_index);
      expected_last[byte_index*8+:8] = 8'(256 - (XLEN / 8) + byte_index);
    end
    axi_s.rready = 0;
    send_l2_ar(LineAddr, 4'hd);
    for (int cycle = 0; cycle < 128 && !axi_s.rvalid && !axi_m.arvalid; cycle++) tick(1);
    check(axi_s.rvalid && axi_s.rdata == expected_first && !axi_m.arvalid,
          "long forwarded burst missed its first cached word");
    axi_s.rready = 1;
    tick(1);
    axi_s.rready = 0;
    send_l2_ar(LineAddr + XLEN'(256 - (XLEN / 8)), 4'he);
    for (int cycle = 0; cycle < 128 && !axi_s.rvalid && !axi_m.arvalid; cycle++) tick(1);
    check(axi_s.rvalid && axi_s.rdata == expected_last && !axi_m.arvalid,
          "long forwarded burst missed its final cached word");
    $display("PASS: forwarded B error/success and 256-beat replay XLEN=%0d", XLEN);
    $finish;
  end
endmodule
