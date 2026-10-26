// A forwarded cacheable write must revoke an L1D-owned resident line before
// reporting success; otherwise the client can keep reading its stale copy.
`include "rapt.svh"
`include "rapt_soc_if.svh"

module tb_l2_forwarded_client;
  localparam int XLEN = `RAPT_XLEN;
  localparam int IdW = 4;
  localparam int LineBeats = 1 << `RAPT_L2_LINE_LEN;
  localparam int LineBytes = LineBeats * (XLEN / 8);
  localparam logic [XLEN-1:0] LineAddr = XLEN'('h80000100);
  localparam logic [XLEN-1:0] OtherLineAddr = LineAddr + XLEN'(LineBytes);
  localparam logic [XLEN-1:0] BoundaryAddr = OtherLineAddr - XLEN'(XLEN / 8);
  localparam logic [XLEN-1:0] NewWord = XLEN'('h12345678);
  localparam logic [XLEN-1:0] DirtyWord = XLEN'('hfedcba98);
  localparam logic [XLEN-1:0] FailedWord = XLEN'('hdeadbeef);

  logic clock = 1'b0;
  logic reset = 1'b1;
  logic probe_valid;
  logic probe_ready = 1'b0;
  logic [XLEN-1:0] probe_addr;
  logic probe_release_valid = 1'b0;
  logic [XLEN-1:0] probe_release_addr, probe_release_data;
  logic probe_release_ready;
  logic release_valid = 1'b0;
  logic [XLEN-1:0] release_addr = '0;
  logic [XLEN-1:0] release_data = '0;
  logic release_has_data = 1'b0;
  logic release_mask = 1'b0;
  logic release_last = 1'b1;
  logic release_ready, release_ack;
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
      .probe_valid_o(probe_valid),
      .probe_addr_o(probe_addr),
      .probe_ready_i(probe_ready),
      .probe_release_valid_i(probe_release_valid),
      .probe_release_addr_i(probe_release_addr),
      .probe_release_data_i(probe_release_data),
      .probe_release_ready_o(probe_release_ready),
      .release_valid_i(release_valid),
      .release_addr_i(release_addr),
      .release_data_i(release_data),
      .release_has_data_i(release_has_data),
      .release_mask_i(release_mask),
      .release_last_i(release_last),
      .release_ready_o(release_ready),
      .release_ack_o(release_ack),
      .axi_s,
      .axi_m
  );
  always #5 clock = ~clock;
  `include "tb_common.svh"
  `include "tb_l2_axi_tasks.svh"

  initial begin
    logic [IdW-1:0] outer_id;
    logic [XLEN-1:0] outer_addr, outer_data;
    logic [XLEN/8-1:0] outer_strb;
    logic [7:0] outer_len;
    logic outer_last;
    bit probe_seen;
    bit outer_b_seen;
    init_l2_axi(0);
    probe_ready = 1'b0;
    release_last = 1'b1;
    tick(5);
    reset = 1'b0;
    for (int cycle = 0; cycle < 1200 && !axi_s.awready; cycle++) tick(1);
    check(axi_s.awready, "directory wipe timed out");

    // AXI read ID 2 identifies the probe-capable L1D client.
    send_l2_ar(LineAddr, 4'h2);
    accept_l2_downstream_ar(outer_id, outer_addr, outer_len);
    check(outer_addr == LineAddr && outer_len == 8'(LineBeats - 1), "D-client refill shape");
    for (int beat = 0; beat < LineBeats; beat++)
    return_l2_downstream_r(outer_id, XLEN'('h100 + beat), beat == LineBeats - 1);
    for (int cycle = 0; cycle < 128 && dut.ms_busy; cycle++) tick(1);
    check(!dut.ms_busy, "D-client refill did not retire");

    // AWCACHE[0]=0 forwards the write and waits for the outer B. The
    // cacheability bits remain set, so the resident L2 line must stay coherent.
    send_l2_aw(LineAddr, 4'h4, 4'he);
    send_l2_w_full(NewWord);
    check(dut.wbuf[dut.d_rptr].lookup_hit && dut.wbuf[dut.d_rptr].lookup_clients,
          "test did not reach a resident D-client-owned line");
    accept_l2_downstream_write(outer_id, outer_addr, outer_data, outer_strb, outer_last);
    check(
        outer_id == 4'h4 && outer_addr == LineAddr && outer_data == NewWord
          && &outer_strb && outer_last,
        "forwarded scalar outer write shape");

    axi_m.bid = outer_id;
    axi_m.bresp = 2'b00;
    axi_m.bvalid = 1'b1;
    probe_seen = 1'b0;
    outer_b_seen = 1'b0;
    for (int cycle = 0; cycle < 128 && !probe_seen; cycle++) begin
      check(!axi_s.bvalid, "forwarded write completed while L1D still owns the line");
      if (probe_valid) begin
        check(probe_addr == LineAddr, "forwarded write probed the wrong line");
        probe_seen = 1'b1;
      end else begin
        if (axi_m.bready) outer_b_seen = 1'b1;
        tick(1);
        if (outer_b_seen) axi_m.bvalid = 1'b0;
      end
    end
    check(probe_seen, "forwarded write did not probe its D-client owner");
    // The owner may have a newer dirty word elsewhere in the line. Its
    // ProbeAckData must reach the selected L2 way before the forwarded mask.
    probe_release_addr  = LineAddr + XLEN'(2 * (XLEN / 8));
    probe_release_data  = DirtyWord;
    probe_release_valid = 1'b1;
    for (int cycle = 0; cycle < 64 && !probe_release_ready; cycle++) tick(1);
    check(probe_release_ready, "forwarded ProbeAckData was not accepted");
    tick(1);
    probe_release_valid = 1'b0;
    repeat (3) begin
      check(!axi_s.bvalid, "forwarded B escaped before probe acknowledgment");
      tick(1);
    end
    probe_ready = 1'b1;
    for (int cycle = 0; cycle < 128 && !axi_s.bvalid; cycle++) begin
      if (axi_m.bready && axi_m.bvalid) begin
        outer_b_seen = 1'b1;
        tick(1);
        axi_m.bvalid = 1'b0;
      end else tick(1);
    end
    check(outer_b_seen && axi_s.bvalid && axi_s.bid == 4'h4 && axi_s.bresp == 2'b00,
          "forwarded write did not return a successful B after probe");
    axi_s.bready = 1'b1;
    tick(1);
    axi_s.bready = 1'b0;

    axi_s.rready = 1'b0;
    send_l2_ar(LineAddr + XLEN'(2 * (XLEN / 8)), 4'h1);
    for (int cycle = 0; cycle < 64 && !axi_s.rvalid; cycle++) tick(1);
    check(!axi_m.arvalid && axi_s.rvalid && axi_s.rdata == DirtyWord,
          "forwarded write lost the D-client's unrelated dirty word");
    axi_s.rready = 1'b1;
    tick(1);
    axi_s.rready = 1'b0;

    // Give the line back to the D client, then exercise the independent
    // forwarded-burst journal path with two beats in the same owned line.
    send_l2_ar(LineAddr, 4'h2);
    for (int cycle = 0; cycle < 64 && !axi_s.rvalid; cycle++) tick(1);
    check(axi_s.rvalid && axi_s.rdata == NewWord, "D-client did not re-own updated line");
    axi_s.rready = 1'b1;
    tick(1);
    axi_s.rready = 1'b0;
    probe_ready = 1'b0;

    axi_s.awaddr = LineAddr;
    axi_s.awid = 4'h5;
    axi_s.awlen = 8'd1;
    axi_s.awsize = 3'($clog2(XLEN / 8));
    axi_s.awburst = 2'b01;
    axi_s.awcache = 4'he;
    axi_s.awvalid = 1'b1;
    for (int cycle = 0; cycle < 128 && !axi_s.awready; cycle++) tick(1);
    check(axi_s.awready, "forwarded client-owned burst AW stalled");
    tick(1);
    axi_s.awvalid = 1'b0;
    for (int beat = 0; beat < 2; beat++) begin
      axi_s.wdata  = NewWord + XLEN'(beat + 1);
      axi_s.wstrb  = '1;
      axi_s.wlast  = beat == 1;
      axi_s.wvalid = 1'b1;
      for (int cycle = 0; cycle < 128 && !axi_s.wready; cycle++) tick(1);
      check(axi_s.wready, "forwarded client-owned burst W stalled");
      tick(1);
      axi_s.wvalid = 1'b0;
    end
    axi_m.awready = 1'b1;
    for (int cycle = 0; cycle < 128 && !axi_m.awvalid; cycle++) tick(1);
    check(axi_m.awvalid && axi_m.awid == 4'h5 && axi_m.awaddr == LineAddr && axi_m.awlen == 8'd1,
          "forwarded client-owned outer AW shape");
    tick(1);
    axi_m.awready = 1'b0;
    axi_m.wready  = 1'b1;
    for (int beat = 0; beat < 2; beat++) begin
      for (int cycle = 0; cycle < 128 && !axi_m.wvalid; cycle++) tick(1);
      check(axi_m.wvalid && axi_m.wdata == NewWord + XLEN'(beat + 1) && axi_m.wlast == (beat == 1),
            "forwarded client-owned outer W shape");
      tick(1);
    end
    axi_m.wready = 1'b0;
    axi_m.bid = 4'h5;
    axi_m.bresp = 2'b00;
    axi_m.bvalid = 1'b1;
    probe_seen = 1'b0;
    outer_b_seen = 1'b0;
    for (int cycle = 0; cycle < 128 && !probe_seen; cycle++) begin
      check(!axi_s.bvalid, "forwarded burst B escaped before D-client Probe");
      if (probe_valid) begin
        check(probe_addr == LineAddr, "forwarded burst probed the wrong line");
        probe_seen = 1'b1;
      end else begin
        if (axi_m.bready) outer_b_seen = 1'b1;
        tick(1);
        if (outer_b_seen) axi_m.bvalid = 1'b0;
      end
    end
    check(probe_seen, "forwarded burst did not probe its D-client owner");
    repeat (3) begin
      check(!axi_s.bvalid, "forwarded burst B escaped before Probe Ack");
      tick(1);
    end
    probe_ready = 1'b1;
    tick(1);
    for (int cycle = 0; cycle < 128 && !axi_s.bvalid; cycle++) begin
      check(!probe_valid, "forwarded burst reprobed the already revoked D-client line");
      if (axi_m.bready && axi_m.bvalid) begin
        outer_b_seen = 1'b1;
        tick(1);
        axi_m.bvalid = 1'b0;
      end else tick(1);
    end
    check(outer_b_seen && axi_s.bvalid && axi_s.bid == 4'h5 && axi_s.bresp == 2'b00,
          "forwarded burst did not return B after Probe Ack");
    axi_s.bready = 1'b1;
    tick(1);
    axi_s.bready = 1'b0;
    for (int beat = 0; beat < 2; beat++) begin
      send_l2_ar(LineAddr + XLEN'(beat * (XLEN / 8)), 4'h1);
      for (int cycle = 0; cycle < 64 && !axi_s.rvalid; cycle++) tick(1);
      check(!axi_m.arvalid && axi_s.rvalid && axi_s.rdata == NewWord + XLEN'(beat + 1),
            "forwarded client-owned burst did not update its resident L2 data");
      check(!dut.dir_lookup_clients, "forwarded write retained stale D-client ownership");
      axi_s.rready = 1'b1;
      tick(1);
      axi_s.rready = 1'b0;
    end

    // A line change within the journal must request a new Probe. Re-own
    // the first line and fill the adjacent line through the D client.
    axi_s.rready = 1'b1;
    send_l2_ar(LineAddr, 4'h2);
    for (int cycle = 0; cycle < 64 && (dut.rs != dut.R_IDLE || dut.rs_rvalid); cycle++) tick(1);
    check(dut.rs == dut.R_IDLE && !dut.rs_rvalid, "first line D-client reownership stalled");
    send_l2_ar(OtherLineAddr, 4'h2);
    accept_l2_downstream_ar(outer_id, outer_addr, outer_len);
    check(outer_addr == OtherLineAddr && outer_len == 8'(LineBeats - 1),
          "second D-client refill shape");
    for (int beat = 0; beat < LineBeats; beat++)
    return_l2_downstream_r(outer_id, XLEN'('h200 + beat), beat == LineBeats - 1);
    for (int cycle = 0; cycle < 128 && dut.ms_busy; cycle++) tick(1);
    check(!dut.ms_busy, "second D-client refill did not retire");
    axi_s.rready = 1'b0;

    axi_s.awaddr = BoundaryAddr;
    axi_s.awid = 4'h6;
    axi_s.awlen = 8'd1;
    axi_s.awsize = 3'($clog2(XLEN / 8));
    axi_s.awburst = 2'b01;
    axi_s.awcache = 4'he;
    axi_s.awvalid = 1'b1;
    for (int cycle = 0; cycle < 128 && !axi_s.awready; cycle++) tick(1);
    check(axi_s.awready, "cross-line forwarded AW stalled");
    tick(1);
    axi_s.awvalid = 1'b0;
    for (int beat = 0; beat < 2; beat++) begin
      axi_s.wdata  = NewWord + XLEN'(beat + 3);
      axi_s.wstrb  = '1;
      axi_s.wlast  = beat == 1;
      axi_s.wvalid = 1'b1;
      for (int cycle = 0; cycle < 128 && !axi_s.wready; cycle++) tick(1);
      check(axi_s.wready, "cross-line forwarded W stalled");
      tick(1);
      axi_s.wvalid = 1'b0;
    end
    axi_m.awready = 1'b1;
    for (int cycle = 0; cycle < 128 && !axi_m.awvalid; cycle++) tick(1);
    check(
        axi_m.awvalid && axi_m.awid == 4'h6 && axi_m.awaddr == BoundaryAddr && axi_m.awlen == 8'd1,
        "cross-line outer AW shape");
    tick(1);
    axi_m.awready = 1'b0;
    axi_m.wready  = 1'b1;
    for (int beat = 0; beat < 2; beat++) begin
      for (int cycle = 0; cycle < 128 && !axi_m.wvalid; cycle++) tick(1);
      check(axi_m.wvalid && axi_m.wdata == NewWord + XLEN'(beat + 3) && axi_m.wlast == (beat == 1),
            "cross-line outer W shape");
      tick(1);
    end
    axi_m.wready = 1'b0;
    axi_m.bid = 4'h6;
    axi_m.bresp = 2'b00;
    axi_m.bvalid = 1'b1;
    probe_ready = 1'b0;
    probe_seen = 1'b0;
    for (int cycle = 0; cycle < 128 && !probe_seen; cycle++) begin
      check(!axi_s.bvalid, "cross-line B escaped before first Probe");
      if (probe_valid) begin
        check(probe_addr == LineAddr, "cross-line first Probe chose the wrong line");
        probe_seen = 1'b1;
      end else tick(1);
    end
    check(probe_seen, "cross-line first Probe missing");
    repeat (3) begin
      check(!axi_s.bvalid, "cross-line B escaped before first Probe Ack");
      tick(1);
    end
    probe_ready = 1'b1;
    tick(1);
    probe_ready = 1'b0;
    probe_seen  = 1'b0;
    for (int cycle = 0; cycle < 128 && !probe_seen; cycle++) begin
      check(!axi_s.bvalid, "cross-line B escaped before second Probe");
      if (probe_valid) begin
        check(probe_addr == OtherLineAddr, "cross-line second Probe chose the wrong line");
        probe_seen = 1'b1;
      end else tick(1);
    end
    check(probe_seen, "cross-line second Probe missing");
    repeat (3) begin
      check(!axi_s.bvalid, "cross-line B escaped before second Probe Ack");
      tick(1);
    end
    probe_ready  = 1'b1;
    outer_b_seen = 1'b0;
    for (int cycle = 0; cycle < 128 && !axi_s.bvalid; cycle++) begin
      if (axi_m.bready && axi_m.bvalid) outer_b_seen = 1'b1;
      tick(1);
      if (outer_b_seen) axi_m.bvalid = 1'b0;
    end
    check(outer_b_seen && axi_s.bvalid && axi_s.bid == 4'h6 && axi_s.bresp == 2'b00,
          "cross-line forwarded B missing after both Probe Acks");
    axi_s.bready = 1'b1;
    tick(1);
    axi_s.bready = 1'b0;

    // A clean victim Release can start after a forwarded burst's last W.
    // L1D waits for ReleaseAck before it can acknowledge a Probe for the
    // other owned line. C must therefore progress while the outer B waits.
    axi_s.rready = 1'b0;
    send_l2_ar(LineAddr, 4'h2);
    for (int cycle = 0; cycle < 64 && !axi_s.rvalid; cycle++) tick(1);
    check(axi_s.rvalid, "Release overlap did not re-own first line");
    axi_s.rready = 1'b1;
    tick(1);
    axi_s.rready = 1'b0;
    send_l2_ar(OtherLineAddr, 4'h2);
    for (int cycle = 0; cycle < 64 && !axi_s.rvalid; cycle++) tick(1);
    check(axi_s.rvalid, "Release overlap did not re-own second line");
    axi_s.rready = 1'b1;
    tick(1);
    axi_s.rready = 1'b0;
    probe_ready = 1'b0;
    axi_s.awaddr = LineAddr;
    axi_s.awid = 4'h8;
    axi_s.awlen = 8'd1;
    axi_s.awsize = 3'($clog2(XLEN / 8));
    axi_s.awburst = 2'b01;
    axi_s.awcache = 4'he;
    axi_s.awvalid = 1'b1;
    for (int cycle = 0; cycle < 128 && !axi_s.awready; cycle++) tick(1);
    check(axi_s.awready, "Release overlap forwarded AW stalled");
    tick(1);
    axi_s.awvalid = 1'b0;
    for (int beat = 0; beat < 2; beat++) begin
      axi_s.wdata = NewWord + XLEN'(beat + 5);
      axi_s.wstrb = '1;
      axi_s.wlast = beat == 1;
      axi_s.wvalid = 1'b1;
      for (int cycle = 0; cycle < 128 && !axi_s.wready; cycle++) tick(1);
      check(axi_s.wready, "Release overlap forwarded W stalled");
      tick(1);
      axi_s.wvalid = 1'b0;
    end
    axi_m.awready = 1'b1;
    for (int cycle = 0; cycle < 128 && !axi_m.awvalid; cycle++) tick(1);
    check(axi_m.awvalid && axi_m.awid == 4'h8, "Release overlap outer AW missing");
    tick(1);
    axi_m.awready = 1'b0;
    axi_m.wready = 1'b1;
    for (int beat = 0; beat < 2; beat++) begin
      for (int cycle = 0; cycle < 128 && !axi_m.wvalid; cycle++) tick(1);
      check(axi_m.wvalid && axi_m.wlast == (beat == 1), "Release overlap outer W missing");
      tick(1);
    end
    axi_m.wready = 1'b0;
    release_addr = OtherLineAddr;
    release_last = 1'b1;
    release_valid = 1'b1;
    for (int cycle = 0; cycle < 64 && !release_ready; cycle++) tick(1);
    check(release_ready, "Release overlap C buffer full");
    tick(1);
    release_valid = 1'b0;
    axi_m.bid = 4'h8;
    axi_m.bresp = 2'b00;
    axi_m.bvalid = 1'b1;
    for (int cycle = 0; cycle < 128 && !release_ack; cycle++) begin
      check(!axi_s.bvalid, "forwarded B escaped while C Release waited");
      check(!probe_valid && !dut.forward_replay_commit,
            "forwarded burst replay ran before overlapping ReleaseAck");
      tick(1);
    end
    check(release_ack, "C Release deadlocked behind forwarded B and blocked Probe");
    tick(1);
    probe_seen = 1'b0;
    for (int cycle = 0; cycle < 128 && !probe_seen; cycle++) begin
      if (probe_valid) begin
        check(probe_addr == LineAddr, "Release overlap probed wrong line");
        probe_seen = 1'b1;
      end else tick(1);
    end
    check(probe_seen, "forwarded Probe missing after ReleaseAck");
    probe_ready = 1'b1;
    outer_b_seen = 1'b0;
    for (int cycle = 0; cycle < 128 && !axi_s.bvalid; cycle++) begin
      if (axi_m.bready && axi_m.bvalid) outer_b_seen = 1'b1;
      tick(1);
      if (outer_b_seen) axi_m.bvalid = 1'b0;
    end
    check(outer_b_seen && axi_s.bvalid && axi_s.bid == 4'h8,
          "forwarded B missing after overlapping ReleaseAck and ProbeAck");
    axi_s.bready = 1'b1;
    tick(1);
    axi_s.bready = 1'b0;

    // The scalar path also holds a cacheable non-bufferable B while it
    // probes its owner. A separate C Release must be able to finish first.
    axi_s.rready = 1'b0;
    send_l2_ar(LineAddr, 4'h2);
    for (int cycle = 0; cycle < 64 && !axi_s.rvalid; cycle++) tick(1);
    check(axi_s.rvalid, "scalar Release overlap did not re-own first line");
    axi_s.rready = 1'b1;
    tick(1);
    axi_s.rready = 1'b0;
    send_l2_ar(OtherLineAddr, 4'h2);
    for (int cycle = 0; cycle < 64 && !axi_s.rvalid; cycle++) tick(1);
    check(axi_s.rvalid, "scalar Release overlap did not re-own second line");
    axi_s.rready = 1'b1;
    tick(1);
    axi_s.rready = 1'b0;
    probe_ready = 1'b0;
    send_l2_aw(LineAddr, 4'h9, 4'he);
    send_l2_w_full(NewWord + XLEN'(9));
    accept_l2_downstream_write(outer_id, outer_addr, outer_data, outer_strb, outer_last);
    check(outer_id == 4'h9 && outer_addr == LineAddr, "scalar Release overlap outer write missing");
    release_addr = OtherLineAddr;
    release_last = 1'b1;
    release_valid = 1'b1;
    for (int cycle = 0; cycle < 64 && !release_ready; cycle++) tick(1);
    check(release_ready, "scalar Release overlap C buffer full");
    tick(1);
    release_valid = 1'b0;
    axi_m.bid = 4'h9;
    axi_m.bresp = 2'b00;
    axi_m.bvalid = 1'b1;
    for (int cycle = 0; cycle < 128 && !release_ack; cycle++) begin
      check(!axi_s.bvalid, "scalar B escaped while C Release waited");
      check(!probe_valid && !dut.forward_scalar_commit,
            "forwarded scalar commit ran before overlapping ReleaseAck");
      tick(1);
    end
    check(release_ack, "C Release deadlocked behind scalar B and blocked Probe");
    tick(1);
    for (int cycle = 0; cycle < 128 && !probe_valid; cycle++) tick(1);
    check(probe_valid && probe_addr == LineAddr,
          "scalar Probe missing after overlapping ReleaseAck");
    probe_ready = 1'b1;
    outer_b_seen = 1'b0;
    for (int cycle = 0; cycle < 128 && !axi_s.bvalid; cycle++) begin
      if (axi_m.bready && axi_m.bvalid) outer_b_seen = 1'b1;
      tick(1);
      if (outer_b_seen) axi_m.bvalid = 1'b0;
    end
    check(outer_b_seen && axi_s.bvalid && axi_s.bid == 4'h9,
          "scalar B missing after overlapping ReleaseAck and ProbeAck");
    axi_s.bready = 1'b1;
    tick(1);
    axi_s.bready = 1'b0;

    // A same-line dirty ReleaseData must commit before the forwarded scalar
    // store. Its unrelated dirty word must survive the eventual W mask.
    axi_s.rready = 1'b0;
    send_l2_ar(LineAddr, 4'h2);
    for (int cycle = 0; cycle < 64 && !axi_s.rvalid; cycle++) tick(1);
    check(axi_s.rvalid, "same-line ReleaseData did not re-own line");
    axi_s.rready = 1'b1;
    tick(1);
    axi_s.rready = 1'b0;
    probe_ready = 1'b0;
    send_l2_aw(LineAddr, 4'ha, 4'he);
    send_l2_w_full(NewWord + XLEN'(10));
    accept_l2_downstream_write(outer_id, outer_addr, outer_data, outer_strb, outer_last);
    check(outer_id == 4'ha && outer_addr == LineAddr, "same-line ReleaseData outer write missing");
    release_has_data = 1'b1;
    for (int beat = 0; beat < LineBeats; beat++) begin
      release_addr = LineAddr + XLEN'(beat * (XLEN / 8));
      release_data = beat == 2 ? DirtyWord : '0;
      release_mask = beat == 2;
      release_last = beat == LineBeats - 1;
      release_valid = 1'b1;
      for (int cycle = 0; cycle < 64 && !release_ready; cycle++) tick(1);
      check(release_ready, "same-line ReleaseData beat stalled");
      tick(1);
      release_valid = 1'b0;
    end
    axi_m.bid = 4'ha;
    axi_m.bresp = 2'b00;
    axi_m.bvalid = 1'b1;
    for (int cycle = 0; cycle < 128 && !release_ack; cycle++) begin
      check(!axi_s.bvalid && !probe_valid && !dut.forward_scalar_commit,
            "same-line forwarded store passed dirty ReleaseData");
      tick(1);
    end
    check(release_ack, "same-line dirty ReleaseData deadlocked behind scalar B");
    tick(1);
    release_has_data = 1'b0;
    release_mask = 1'b0;
    for (int cycle = 0; cycle < 128 && !probe_valid; cycle++) tick(1);
    check(probe_valid && probe_addr == LineAddr,
          "same-line forwarded Probe missing after dirty ReleaseAck");
    probe_ready = 1'b1;
    outer_b_seen = 1'b0;
    for (int cycle = 0; cycle < 128 && !axi_s.bvalid; cycle++) begin
      if (axi_m.bready && axi_m.bvalid) outer_b_seen = 1'b1;
      tick(1);
      if (outer_b_seen) axi_m.bvalid = 1'b0;
    end
    check(outer_b_seen && axi_s.bvalid && axi_s.bid == 4'ha,
          "same-line forwarded B missing after dirty ReleaseAck");
    axi_s.bready = 1'b1;
    tick(1);
    axi_s.bready = 1'b0;
    send_l2_ar(LineAddr, 4'h1);
    for (int cycle = 0; cycle < 64 && !axi_s.rvalid; cycle++) tick(1);
    check(axi_s.rvalid && axi_s.rdata == NewWord + XLEN'(10),
          "same-line forwarded scalar word was not committed");
    axi_s.rready = 1'b1;
    tick(1);
    axi_s.rready = 1'b0;
    send_l2_ar(LineAddr + XLEN'(2 * (XLEN / 8)), 4'h1);
    for (int cycle = 0; cycle < 64 && !axi_s.rvalid; cycle++) tick(1);
    check(axi_s.rvalid && axi_s.rdata == DirtyWord,
          "same-line dirty ReleaseData word was lost during forwarded replay");
    axi_s.rready = 1'b1;
    tick(1);
    axi_s.rready = 1'b0;

    // C must also make progress between the W beats of a forwarded burst.
    // The client can be waiting for ReleaseAck before it supplies the next W.
    send_l2_ar(LineAddr, 4'h2);
    for (int cycle = 0; cycle < 64 && !axi_s.rvalid; cycle++) tick(1);
    check(axi_s.rvalid, "active-burst Release did not re-own first line");
    axi_s.rready = 1'b1;
    tick(1);
    axi_s.rready = 1'b0;
    send_l2_ar(OtherLineAddr, 4'h2);
    for (int cycle = 0; cycle < 64 && !axi_s.rvalid; cycle++) tick(1);
    check(axi_s.rvalid, "active-burst Release did not re-own second line");
    axi_s.rready = 1'b1;
    tick(1);
    axi_s.rready = 1'b0;
    probe_ready = 1'b0;
    axi_s.awaddr = LineAddr;
    axi_s.awid = 4'hb;
    axi_s.awlen = 8'd1;
    axi_s.awsize = 3'($clog2(XLEN / 8));
    axi_s.awburst = 2'b01;
    axi_s.awcache = 4'he;
    axi_s.awvalid = 1'b1;
    for (int cycle = 0; cycle < 128 && !axi_s.awready; cycle++) tick(1);
    check(axi_s.awready, "active-burst Release AW stalled");
    tick(1);
    axi_s.awvalid = 1'b0;
    axi_s.wdata = NewWord + XLEN'(11);
    axi_s.wstrb = '1;
    axi_s.wlast = 1'b0;
    axi_s.wvalid = 1'b1;
    for (int cycle = 0; cycle < 128 && !axi_s.wready; cycle++) tick(1);
    check(axi_s.wready, "active-burst first W stalled");
    tick(1);
    axi_s.wvalid = 1'b0;
    check(dut.burst_active && dut.forward_cache_pending,
          "active-burst C test missed the resident-hit journal");
    axi_m.awready = 1'b1;
    for (int cycle = 0; cycle < 128 && !axi_m.awvalid; cycle++) tick(1);
    check(axi_m.awvalid && axi_m.awid == 4'hb, "active-burst outer AW missing");
    tick(1);
    axi_m.awready = 1'b0;
    axi_m.wready = 1'b1;
    for (int cycle = 0; cycle < 128 && !axi_m.wvalid; cycle++) tick(1);
    check(axi_m.wvalid && !axi_m.wlast, "active-burst outer first W missing");
    tick(1);
    axi_m.wready = 1'b0;
    release_addr = OtherLineAddr;
    release_has_data = 1'b0;
    release_mask = 1'b0;
    release_last = 1'b1;
    release_valid = 1'b1;
    for (int cycle = 0; cycle < 64 && !release_ready; cycle++) tick(1);
    check(release_ready, "active-burst C buffer full");
    tick(1);
    release_valid = 1'b0;
    axi_s.wdata = NewWord + XLEN'(12);
    axi_s.wlast = 1'b1;
    axi_s.wvalid = 1'b1;
    for (int cycle = 0; cycle < 128 && !release_ack; cycle++) begin
      check(dut.burst_active && !axi_s.wready && !axi_s.bvalid && !probe_valid,
            "active-burst W or B escaped before ReleaseAck");
      tick(1);
    end
    check(release_ack, "C Release deadlocked behind an unfinished forwarded burst");
    tick(1);
    for (int cycle = 0; cycle < 128 && !axi_s.wready; cycle++) tick(1);
    check(axi_s.wready, "active-burst final W stayed blocked after ReleaseAck");
    tick(1);
    axi_s.wvalid = 1'b0;
    axi_m.wready = 1'b1;
    for (int cycle = 0; cycle < 128 && !axi_m.wvalid; cycle++) tick(1);
    check(axi_m.wvalid && axi_m.wlast, "active-burst outer final W missing");
    tick(1);
    axi_m.wready = 1'b0;
    axi_m.bid = 4'hb;
    axi_m.bresp = 2'b00;
    axi_m.bvalid = 1'b1;
    for (int cycle = 0; cycle < 128 && !probe_valid; cycle++) tick(1);
    check(probe_valid && probe_addr == LineAddr, "active-burst Probe missing after outer B");
    probe_ready = 1'b1;
    outer_b_seen = 1'b0;
    for (int cycle = 0; cycle < 128 && !axi_s.bvalid; cycle++) begin
      if (axi_m.bready && axi_m.bvalid) outer_b_seen = 1'b1;
      tick(1);
      if (outer_b_seen) axi_m.bvalid = 1'b0;
    end
    check(outer_b_seen && axi_s.bvalid && axi_s.bid == 4'hb,
          "active-burst B missing after C Release and Probe");
    axi_s.bready = 1'b1;
    tick(1);
    axi_s.bready = 1'b0;

    // A dirty same-line ReleaseData may finish between forwarded W beats.
    // The later B replay must preserve its unrelated dirty word while
    // committing both forwarded words in order.
    send_l2_ar(LineAddr, 4'h2);
    for (int cycle = 0; cycle < 64 && !axi_s.rvalid; cycle++) tick(1);
    check(axi_s.rvalid, "active dirty Release did not re-own the line");
    axi_s.rready = 1'b1;
    tick(1);
    axi_s.rready = 1'b0;
    probe_ready = 1'b0;
    axi_s.awaddr = LineAddr;
    axi_s.awid = 4'hc;
    axi_s.awlen = 8'd1;
    axi_s.awsize = 3'($clog2(XLEN / 8));
    axi_s.awburst = 2'b01;
    axi_s.awcache = 4'he;
    axi_s.awvalid = 1'b1;
    for (int cycle = 0; cycle < 128 && !axi_s.awready; cycle++) tick(1);
    check(axi_s.awready, "active dirty Release AW stalled");
    tick(1);
    axi_s.awvalid = 1'b0;
    axi_s.wdata = NewWord + XLEN'(13);
    axi_s.wstrb = '1;
    axi_s.wlast = 1'b0;
    axi_s.wvalid = 1'b1;
    for (int cycle = 0; cycle < 128 && !axi_s.wready; cycle++) tick(1);
    check(axi_s.wready, "active dirty Release first W stalled");
    tick(1);
    axi_s.wvalid = 1'b0;
    check(dut.burst_active && dut.forward_cache_pending,
          "active dirty Release did not reach the resident-hit journal");
    axi_m.awready = 1'b1;
    for (int cycle = 0; cycle < 128 && !axi_m.awvalid; cycle++) tick(1);
    check(axi_m.awvalid && axi_m.awid == 4'hc, "active dirty Release outer AW missing");
    tick(1);
    axi_m.awready = 1'b0;
    axi_m.wready = 1'b1;
    for (int cycle = 0; cycle < 128 && !axi_m.wvalid; cycle++) tick(1);
    check(axi_m.wvalid && !axi_m.wlast, "active dirty Release outer first W missing");
    tick(1);
    axi_m.wready = 1'b0;
    release_has_data = 1'b1;
    for (int beat = 0; beat < LineBeats; beat++) begin
      release_addr = LineAddr + XLEN'(beat * (XLEN / 8));
      release_data = beat == 2 ? DirtyWord + XLEN'(1) : '0;
      release_mask = beat == 2;
      release_last = beat == LineBeats - 1;
      release_valid = 1'b1;
      for (int cycle = 0; cycle < 64 && !release_ready; cycle++) tick(1);
      check(release_ready, "active dirty ReleaseData beat stalled");
      tick(1);
      release_valid = 1'b0;
    end
    axi_s.wdata = NewWord + XLEN'(14);
    axi_s.wlast = 1'b1;
    axi_s.wvalid = 1'b1;
    for (int cycle = 0; cycle < 128 && !release_ack; cycle++) begin
      check(dut.burst_active && !axi_s.wready && !axi_s.bvalid && !probe_valid,
            "active dirty ReleaseData was bypassed by W, B or Probe");
      tick(1);
    end
    check(release_ack, "active dirty ReleaseData deadlocked between W beats");
    tick(1);
    release_has_data = 1'b0;
    release_mask = 1'b0;
    for (int cycle = 0; cycle < 128 && !axi_s.wready; cycle++) tick(1);
    check(axi_s.wready, "active dirty Release final W stayed blocked");
    tick(1);
    axi_s.wvalid = 1'b0;
    axi_m.wready = 1'b1;
    for (int cycle = 0; cycle < 128 && !axi_m.wvalid; cycle++) tick(1);
    check(axi_m.wvalid && axi_m.wlast, "active dirty Release outer final W missing");
    tick(1);
    axi_m.wready = 1'b0;
    axi_m.bid = 4'hc;
    axi_m.bresp = 2'b00;
    axi_m.bvalid = 1'b1;
    for (int cycle = 0; cycle < 128 && !probe_valid; cycle++) tick(1);
    check(probe_valid && probe_addr == LineAddr,
          "active dirty Release replay did not probe its previous owner");
    probe_ready = 1'b1;
    outer_b_seen = 1'b0;
    for (int cycle = 0; cycle < 128 && !axi_s.bvalid; cycle++) begin
      if (axi_m.bready && axi_m.bvalid) outer_b_seen = 1'b1;
      tick(1);
      if (outer_b_seen) axi_m.bvalid = 1'b0;
    end
    check(outer_b_seen && axi_s.bvalid && axi_s.bid == 4'hc && axi_s.bresp == 2'b00,
          "active dirty Release forwarded B missing");
    axi_s.bready = 1'b1;
    tick(1);
    axi_s.bready = 1'b0;
    for (int word = 0; word < 3; word++) begin
      axi_s.rready = 1'b0;
      send_l2_ar(LineAddr + XLEN'(word * (XLEN / 8)), 4'h1);
      for (int cycle = 0; cycle < 64 && !axi_s.rvalid; cycle++) tick(1);
      check(
          axi_s.rvalid && axi_s.rdata ==
            (word == 2 ? DirtyWord + XLEN'(1) : NewWord + XLEN'(13 + word)),
          "active dirty Release and forwarded W data did not merge");
      axi_s.rready = 1'b1;
      tick(1);
      axi_s.rready = 1'b0;
    end

    // A failed outer B must leave a D-owned line and its old data intact.
    send_l2_ar(BoundaryAddr, 4'h2);
    for (int cycle = 0; cycle < 64 && !axi_s.rvalid; cycle++) tick(1);
    check(axi_s.rvalid && axi_s.rdata == NewWord + XLEN'(3),
          "failed-write setup did not re-own the first line");
    axi_s.rready = 1'b1;
    tick(1);
    axi_s.rready = 1'b0;
    probe_ready  = 1'b0;
    send_l2_aw(BoundaryAddr, 4'h7, 4'he);
    send_l2_w_full(FailedWord);
    check(dut.wbuf[dut.d_rptr].lookup_hit && dut.wbuf[dut.d_rptr].lookup_clients,
          "failed-write test did not reach the D-owned line");
    accept_l2_downstream_write(outer_id, outer_addr, outer_data, outer_strb, outer_last);
    check(outer_id == 4'h7 && outer_addr == BoundaryAddr && outer_data == FailedWord,
          "failed forwarded write outer shape");
    axi_m.bid = 4'h7;
    axi_m.bresp = 2'b10;
    axi_m.bvalid = 1'b1;
    for (int cycle = 0; cycle < 64 && !axi_s.bvalid; cycle++) begin
      check(!probe_valid, "failed forwarded write probed the D-client owner");
      tick(1);
    end
    axi_m.bvalid = 1'b0;
    check(!probe_valid && axi_s.bvalid && axi_s.bid == 4'h7 && axi_s.bresp == 2'b10,
          "failed forwarded write lost the error B or probed the owner");
    axi_s.bready = 1'b1;
    tick(1);
    axi_s.bready = 1'b0;
    // Inspect through the existing owner; a foreign Get would itself Probe
    // and revoke the client, obscuring whether the failed write preserved it.
    send_l2_ar(BoundaryAddr, 4'h2);
    for (int cycle = 0; cycle < 64 && !axi_s.rvalid; cycle++) tick(1);
    check(
        !axi_m.arvalid && !probe_valid && axi_s.rvalid && axi_s.rid == 4'h2
          && axi_s.rdata == NewWord + XLEN'(3) && dut.dir_lookup_clients,
        "failed forwarded write changed data or client ownership");
    axi_s.rready = 1'b1;
    tick(1);
    axi_s.rready = 1'b0;
    $display("PASS: forwarded scalar and burst writes revoke D-client ownership XLEN=%0d", XLEN);
    $finish;
  end
endmodule
