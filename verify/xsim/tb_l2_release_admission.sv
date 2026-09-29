`include "rapt.svh"
`include "rapt_soc_if.svh"

module tb_l2_release_admission;
  localparam int XLEN = `RAPT_XLEN;
  localparam int CMshr = XLEN == 64 ? 6 : 4;
  localparam int IdW = 4;
  localparam int LineBeats = 1 << `RAPT_L2_LINE_LEN;
  localparam logic [XLEN-1:0] LineAddr = XLEN'('h80000100);
  localparam logic [XLEN-1:0] OtherAddr = XLEN'('h80010100);
  localparam logic [XLEN-1:0] IndependentAddr = LineAddr + XLEN'(64);
  localparam logic [XLEN-1:0] RetireAddr = LineAddr + XLEN'(128);
  localparam logic [XLEN-1:0] ReplayPrimaryAddr = LineAddr + XLEN'(192);
  localparam logic [XLEN-1:0] ReplayDuringCAddr = ReplayPrimaryAddr + XLEN'('h10000);
  localparam logic [XLEN-1:0] PrimaryDuringCAddr = LineAddr + XLEN'(256);
  localparam logic [XLEN-1:0] ReplayAddr = IndependentAddr + XLEN'('h10000);
  localparam logic [XLEN-1:0] EarlyReleaseAddr = XLEN'('h80001000);
  localparam logic [XLEN-1:0] CleanReleaseAddr = XLEN'('h80002000);
  localparam logic [XLEN-1:0] PartialReleaseAddr = XLEN'('h80003000);
  localparam logic [XLEN-1:0] ErrorReleaseAddr = XLEN'('h80004000);
  localparam logic [XLEN-1:0] LateErrorReleaseAddr = XLEN'('h80005000);
  localparam logic [XLEN-1:0] PostErrorReleaseAddr = XLEN'('h80006000);

  logic clock = 1'b0;
  logic reset = 1'b1;
  logic release_valid = 1'b0;
  logic [XLEN-1:0] release_addr = '0;
  logic [XLEN-1:0] release_data = '0;
  logic release_has_data = 1'b0;
  logic release_mask = 1'b0;
  logic release_last = 1'b0;
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

  function automatic logic [15:0] next_lfsr(input logic [15:0] value);
    return {value[14:0], value[15] ^ value[13] ^ value[12] ^ value[10]};
  endfunction

  initial begin
    logic [IdW-1:0] outer_id;
    logic [XLEN-1:0] outer_addr;
    logic [7:0] outer_len;
    logic [2:0] owner_way;
    bit got_ack, got_read, found_preempted;

    init_l2_axi(1'b0);
    tick(5);
    reset = 1'b0;
    for (int cycle = 0; cycle < (1 << `RAPT_L2_LEN) + 64 && !axi_s.awready; cycle++) tick(1);
    check(axi_s.awready, "directory wipe timed out");

    // Install the line before its L1D owner releases it.
    axi_s.rready = 1'b1;
    send_l2_ar(LineAddr, 4'h1);
    accept_l2_downstream_ar(outer_id, outer_addr, outer_len);
    check(outer_addr == LineAddr && outer_len == 8'(LineBeats - 1),
          "initial line refill had wrong address or length");
    for (int beat = 0; beat < LineBeats; beat++)
    return_l2_downstream_r(outer_id, XLEN'(beat), beat == LineBeats - 1);
    for (
        int cycle = 0;
        cycle < 64 && (dut.ms_busy || dut.cache_install || dut.boom_bank_line_busy || dut.rs != 0);
        cycle++
    )
    tick(1);
    check(!dut.ms_busy && !dut.cache_install && !dut.boom_bank_line_busy && dut.rs == 0,
          "initial refill or eight-beat install did not finish");

    axi_s.araddr  = LineAddr;
    axi_s.arvalid = 1'b1;
    #1;
    check(axi_s.arready, "baseline AR was already blocked before ReleaseData");
    axi_s.arvalid = 1'b0;

    // An AW offered on the same cycle as the first ReleaseData beat must
    // stall, before the buffer has registered its occupied bit.
    axi_s.awaddr  = LineAddr;
    axi_s.awcache = 4'hf;
    axi_s.awvalid = 1'b1;
    #1;
    check(axi_s.awready, "baseline AW was already blocked before ReleaseData");
    release_addr = LineAddr;
    release_data = XLEN'('h12340000);
    release_has_data = 1'b1;
    release_mask = 1'b1;
    release_last = 1'b0;
    release_valid = 1'b1;
    #1;
    check(release_ready && !axi_s.awready, "AW entered on first ReleaseData beat");
    check(
        dut.release_head_valid && dut.release_head_addr == LineAddr
              && !dut.release_head_complete && dut.release_lookup_fire
              && dut.ms_sched_valid[CMshr] && dut.ms_secondary_schedule_onehot[CMshr],
        "first ReleaseData beat did not schedule the reserved C directory request");
    tick(1);
    release_valid = 1'b0;
    axi_s.awvalid = 1'b0;

    // A gap in C beats must retain the reservation. A new AR and AW would
    // otherwise be able to evict the line before the Release becomes visible.
    axi_s.araddr  = LineAddr;
    axi_s.arvalid = 1'b1;
    #1;
    check(!axi_s.arready, "AR entered during partial ReleaseData");
    tick(2);
    check(!axi_s.arready, "AR entered during a C-channel gap");
    check(dut.release_head_valid && !dut.release_head_complete && dut.release_state != 0,
          "Release directory lookup waited for the final C beat");
    for (int cycle = 0; cycle < 8 && dut.release_word != 1; cycle++) tick(1);
    check(dut.release_word == 1, "first ReleaseData word did not reach the bank");
    tick(3);
    check(dut.release_word == 1 && !release_ack, "Release consumed an unreceived data beat");
    axi_s.arvalid = 1'b0;
    axi_s.awvalid = 1'b1;
    #1;
    check(!axi_s.awready, "AW entered during partial ReleaseData");
    axi_s.awvalid = 1'b0;

    for (int beat = 1; beat < LineBeats; beat++) begin
      release_addr  = LineAddr + XLEN'(beat * (XLEN / 8));
      release_data  = XLEN'('h12340000 + beat);
      release_last  = beat == LineBeats - 1;
      release_valid = 1'b1;
      #1;
      check(release_ready, "ReleaseData beat was unexpectedly stalled");
      tick(1);
      release_valid = 1'b0;
    end

    got_ack = 1'b0;
    for (int cycle = 0; cycle < 128 && !got_ack; cycle++) begin
      #1;
      got_ack = release_ack;
      if (got_ack)
        check(dut.ms_secondary_schedule_onehot[CMshr],
              "ReleaseAck bypassed the reserved C metadata schedule");
      tick(1);
    end
    check(got_ack, "dirty Release did not receive ReleaseAck");

    axi_s.rready = 1'b0;
    send_l2_ar(LineAddr, 4'h2);
    got_read = 1'b0;
    for (int cycle = 0; cycle < 64 && !got_read; cycle++) begin
      check(!axi_m.arvalid, "released resident line was refetched");
      if (axi_s.rvalid) begin
        check(axi_s.rdata == XLEN'('h12340000), "ReleaseData was not stored in L2");
        got_read = 1'b1;
      end else tick(1);
    end
    check(got_read, "post-Release read did not complete");

    // Place a normal refill in the same set without selecting the D-owned
    // resident way for eviction. Its outer R beats remain withheld through
    // the resident line's C ReleaseAck.
    owner_way = dut.r_selected_way;
    axi_s.rready = 1'b1;
    tick(1);
    axi_s.rready = 1'b0;
    for (
        int attempt = 0;
        attempt < 32 && next_lfsr(dut.g_boom_directory.u_directory.victim_lfsr) [9:7] == owner_way;
        attempt++
    ) begin
      send_l2_ar(LineAddr, 4'h2);
      for (int cycle = 0; cycle < 64 && !axi_s.rvalid; cycle++) tick(1);
      check(axi_s.rvalid && axi_s.rdata == XLEN'('h12340000),
            "could not advance replacement away from D-owned line");
      axi_s.rready = 1'b1;
      tick(1);
      axi_s.rready = 1'b0;
    end
    check(next_lfsr(dut.g_boom_directory.u_directory.victim_lfsr) [9:7] != owner_way,
          "could not choose a different way for same-set refill");
    send_l2_ar(OtherAddr, 4'h4);
    accept_l2_downstream_ar(outer_id, outer_addr, outer_len);
    check(outer_addr == OtherAddr && outer_len == 8'(LineBeats - 1) && dut.ms_busy,
          "same-set normal refill was not live before the concurrent Release");
    for (int beat = 0; beat < LineBeats; beat++) begin
      release_addr = LineAddr + XLEN'(beat * (XLEN / 8));
      release_data = XLEN'('h56780000 + beat);
      release_has_data = 1'b1;
      release_mask = 1'b1;
      release_last = beat == LineBeats - 1;
      release_valid = 1'b1;
      #1;
      check(release_ready, "concurrent ReleaseData beat was stalled");
      tick(1);
      release_valid = 1'b0;
      if (beat == 0) begin
        found_preempted = 1'b0;
        for (int slot = 0; slot < 5; slot++) begin
          if (dut.ms_slot_valid[slot] && dut.ms_set[slot] == LineAddr[15:6]) begin
            check(dut.ms_secondary_schedule_stalled[slot],
                  "reserved C handler did not pre-empt the same-set normal MSHR");
            found_preempted = 1'b1;
          end
        end
        check(found_preempted && dut.ms_sched_valid[CMshr],
              "concurrent Release did not occupy the reserved C slot");
      end
    end
    got_ack = 1'b0;
    for (int cycle = 0; cycle < 128 && !got_ack; cycle++) begin
      #1;
      if (release_ack) begin
        check(dut.ms_busy, "normal refill retired before concurrent ReleaseAck");
        check(dut.ms_secondary_schedule_onehot[CMshr],
              "concurrent ReleaseAck bypassed the reserved C metadata schedule");
        got_ack = 1'b1;
      end
      tick(1);
    end
    check(got_ack, "Release waited for a same-set normal refill to finish");
    for (int beat = 0; beat < LineBeats; beat++)
    return_l2_downstream_r(outer_id, OtherAddr + XLEN'(beat), beat == LineBeats - 1);
    got_read = 1'b0;
    for (int cycle = 0; cycle < 64 && !got_read; cycle++) begin
      if (axi_s.rvalid) begin
        check(axi_s.rid == 4'h4 && axi_s.rdata == OtherAddr && axi_s.rresp == 2'b00,
              "preempted normal refill returned the wrong word");
        axi_s.rready = 1'b1;
        tick(1);
        axi_s.rready = 1'b0;
        got_read = 1'b1;
      end else tick(1);
    end
    check(got_read, "normal refill did not resume after concurrent ReleaseAck");
    send_l2_ar(LineAddr, 4'h2);
    got_read = 1'b0;
    for (int cycle = 0; cycle < 64 && !got_read; cycle++) begin
      check(!axi_m.arvalid, "concurrent ReleaseData line was refetched");
      if (axi_s.rvalid) begin
        check(axi_s.rdata == XLEN'('h56780000), "concurrent ReleaseData was not stored");
        got_read = 1'b1;
      end else tick(1);
    end
    check(got_read, "post-concurrent-Release resident read did not complete");

    // The C reservation interlocks only its own set. A clean miss and its
    // queued secondary in another set may respond while ReleaseData waits
    // for later C beats.
    axi_s.rready = 1'b1;
    tick(1);
    axi_s.rready = 1'b0;
    for (int cycle = 0; cycle < 20 && dut.ms_busy; cycle++) tick(1);
    send_l2_ar(IndependentAddr, 4'h5, 4'h4);
    accept_l2_downstream_ar(outer_id, outer_addr, outer_len);
    check(outer_addr == IndependentAddr, "independent-set refill missed its outer line");
    send_l2_ar(IndependentAddr + XLEN'(XLEN / 8), 4'h6, 4'h4);
    release_addr = LineAddr;
    release_data = XLEN'('h9abc0000);
    release_has_data = 1'b1;
    release_mask = 1'b1;
    release_last = 1'b0;
    release_valid = 1'b1;
    // The first C beat bypasses an empty Release list. An independent-set
    // secondary only enters its A queue and can handshake on that same edge.
    axi_s.araddr = IndependentAddr + XLEN'(2 * (XLEN / 8));
    axi_s.arid = 4'h7;
    axi_s.arvalid = 1'b1;
    #1;
    check(release_ready, "independent-set Release first beat was stalled");
    check(dut.release_lookup_fire && axi_s.arready && dut.ms_secondary_accept,
          "different-set secondary AR blocked by first C Release beat");
    tick(1);
    release_valid = 1'b0;
    axi_s.arvalid = 1'b0;
    for (int beat = 0; beat < LineBeats; beat++)
    return_l2_downstream_r(outer_id, IndependentAddr + XLEN'(beat), beat == LineBeats - 1);
    for (int cycle = 0; cycle < 100 && !axi_s.rvalid; cycle++) tick(1);
    check(dut.ms_done_any && dut.release_pending,
          "independent-set refill was not complete during partial ReleaseData");
    axi_s.araddr = IndependentAddr + XLEN'(3 * (XLEN / 8));
    axi_s.arid = 4'h3;
    axi_s.arvalid = 1'b1;
    #1;
    check(axi_s.arready && dut.ms_secondary_accept,
          "completed different-set MSHR rejected a new secondary during Release");
    tick(1);
    axi_s.arvalid = 1'b0;
    // A different tag for that MSHR's set can queue now, then re-read the
    // directory only after the C metadata update releases its one-port SRAM.
    axi_s.araddr = ReplayAddr;
    axi_s.arid = 4'h0;
    axi_s.arvalid = 1'b1;
    #1;
    check(axi_s.arready && dut.ms_secondary_accept,
          "different-tag secondary could not queue during partial ReleaseData");
    tick(1);
    axi_s.arvalid = 1'b0;
    check(axi_s.rvalid && axi_s.rid == 4'h5 && axi_s.rdata == IndependentAddr && !release_ack,
          "different-set primary waited for ReleaseAck");
    axi_s.rready = 1'b1;
    tick(1);
    axi_s.rready = 1'b0;
    for (int cycle = 0; cycle < 100 && !axi_s.rvalid; cycle++) tick(1);
    check(
        axi_s.rvalid && axi_s.rid == 4'h6 && axi_s.rdata == IndependentAddr + XLEN'(1)
          && !release_ack,
        "different-set secondary waited for ReleaseAck");
    axi_s.rready = 1'b1;
    tick(1);
    axi_s.rready = 1'b0;
    for (int cycle = 0; cycle < 100 && !axi_s.rvalid; cycle++) tick(1);
    check(
        axi_s.rvalid && axi_s.rid == 4'h7
              && axi_s.rdata == IndependentAddr + XLEN'(2) && !release_ack,
        "secondary admitted during Release waited for ReleaseAck");
    axi_s.rready = 1'b1;
    tick(1);
    axi_s.rready = 1'b0;
    for (int cycle = 0; cycle < 100 && !axi_s.rvalid; cycle++) tick(1);
    check(
        axi_s.rvalid && axi_s.rid == 4'h3
              && axi_s.rdata == IndependentAddr + XLEN'(3) && !release_ack,
        "completed-MSHR secondary admitted during Release waited for ReleaseAck");
    axi_s.rready = 1'b1;
    tick(1);
    axi_s.rready = 1'b0;
    for (int beat = 1; beat < LineBeats; beat++) begin
      release_addr  = LineAddr + XLEN'(beat * (XLEN / 8));
      release_data  = '0;
      release_mask  = 1'b0;
      release_last  = beat == LineBeats - 1;
      release_valid = 1'b1;
      #1;
      check(release_ready, "independent-set Release continuation was stalled");
      tick(1);
      release_valid = 1'b0;
    end
    got_ack = 1'b0;
    for (int cycle = 0; cycle < 128 && !got_ack; cycle++) begin
      #1;
      got_ack = release_ack;
      tick(1);
    end
    check(got_ack, "independent-set Release did not acknowledge");
    accept_l2_downstream_ar(outer_id, outer_addr, outer_len);
    check(outer_addr == ReplayAddr && outer_len == 8'(LineBeats - 1),
          "different-tag secondary did not replay after ReleaseAck");
    for (int beat = 0; beat < LineBeats; beat++)
    return_l2_downstream_r(outer_id, ReplayAddr + XLEN'(beat), beat == LineBeats - 1);
    got_read = 1'b0;
    for (int cycle = 0; cycle < 100 && !got_read; cycle++) begin
      if (axi_s.rvalid) begin
        check(axi_s.rid == 4'h0 && axi_s.rdata == ReplayAddr && axi_s.rresp == 2'b00,
              "replayed different-tag secondary returned the wrong data");
        got_read = 1'b1;
      end else tick(1);
    end
    check(got_read, "different-tag secondary did not complete after ReleaseAck");
    axi_s.rready = 1'b1;
    tick(1);
    axi_s.rready = 1'b0;
    for (int cycle = 0; cycle < 100 && dut.ms_busy; cycle++) tick(1);
    check(!dut.ms_busy, "replayed MSHR did not retire");

    // Reacquire the resident line as a D client, then install an unrelated
    // clean refill just before another partial C Release starts. Its MSHR
    // retirement uses no bank or directory port and must finish before Ack.
    send_l2_ar(LineAddr, 4'h2);
    for (int cycle = 0; cycle < 100 && !axi_s.rvalid; cycle++) tick(1);
    check(axi_s.rvalid && axi_s.rdata == XLEN'('h9abc0000),
          "resident line could not be reacquired before retirement test");
    axi_s.rready = 1'b1;
    tick(1);
    send_l2_ar(RetireAddr, 4'h5, 4'h4);
    accept_l2_downstream_ar(outer_id, outer_addr, outer_len);
    check(outer_addr == RetireAddr, "retirement refill missed its outer line");
    for (int beat = 0; beat < LineBeats; beat++)
    return_l2_downstream_r(outer_id, RetireAddr + XLEN'(beat), beat == LineBeats - 1);
    for (int cycle = 0; cycle < 100 && !(|dut.ms_installed); cycle++) tick(1);
    check(dut.ms_busy && |dut.ms_installed,
          "retirement refill did not reach the installed MSHR state");
    release_addr = LineAddr;
    release_data = XLEN'('hdef00000);
    release_has_data = 1'b1;
    release_mask = 1'b1;
    release_last = 1'b0;
    release_valid = 1'b1;
    #1;
    check(release_ready, "retirement-test Release first beat was stalled");
    tick(1);
    release_valid = 1'b0;
    for (int cycle = 0; cycle < 64 && dut.ms_busy; cycle++) tick(1);
    check(!dut.ms_busy && dut.release_pending && !release_ack,
          "different-set installed MSHR waited for ReleaseAck to retire");
    for (int beat = 1; beat < LineBeats; beat++) begin
      release_addr  = LineAddr + XLEN'(beat * (XLEN / 8));
      release_data  = XLEN'('hdef00000 + beat);
      release_last  = beat == LineBeats - 1;
      release_valid = 1'b1;
      #1;
      check(release_ready, "retirement-test Release continuation was stalled");
      tick(1);
      release_valid = 1'b0;
    end
    got_ack = 1'b0;
    for (int cycle = 0; cycle < 128 && !got_ack; cycle++) begin
      #1;
      got_ack = release_ack;
      tick(1);
    end
    check(got_ack, "retirement-test Release did not acknowledge");

    // A completed different-set MSHR with a different-tag secondary can
    // replay through the directory after C's first lookup, while later C
    // data beats are still missing. The new clean refill may respond early.
    axi_s.rready = 1'b0;
    send_l2_ar(LineAddr, 4'h2);
    for (int cycle = 0; cycle < 100 && !axi_s.rvalid; cycle++) tick(1);
    check(axi_s.rvalid && axi_s.rdata == XLEN'('hdef00000),
          "resident line could not be reacquired before C replay test");
    axi_s.rready = 1'b1;
    tick(1);
    send_l2_ar(ReplayPrimaryAddr, 4'h5, 4'h4);
    accept_l2_downstream_ar(outer_id, outer_addr, outer_len);
    check(outer_addr == ReplayPrimaryAddr, "C replay primary missed its outer line");
    send_l2_ar(ReplayDuringCAddr, 4'h0, 4'h4);
    for (int beat = 0; beat < LineBeats; beat++)
    return_l2_downstream_r(outer_id, ReplayPrimaryAddr + XLEN'(beat), beat == LineBeats - 1);
    for (int cycle = 0; cycle < 100 && !(|dut.ms_installed); cycle++) tick(1);
    check(dut.ms_busy && |dut.ms_installed, "C replay primary did not install before the Release");
    release_addr = LineAddr;
    release_data = XLEN'('hfed00000);
    release_has_data = 1'b1;
    release_mask = 1'b1;
    release_last = 1'b0;
    release_valid = 1'b1;
    #1;
    check(release_ready, "C replay Release first beat was stalled");
    tick(1);
    release_valid = 1'b0;
    accept_l2_downstream_ar(outer_id, outer_addr, outer_len);
    check(
        outer_addr == ReplayDuringCAddr && outer_len == 8'(LineBeats - 1)
              && dut.release_pending && !release_ack,
        "different-set secondary replay waited for ReleaseAck");
    axi_s.rready = 1'b0;
    for (int beat = 0; beat < LineBeats; beat++)
    return_l2_downstream_r(outer_id, ReplayDuringCAddr + XLEN'(beat), beat == LineBeats - 1);
    got_read = 1'b0;
    for (int cycle = 0; cycle < 100 && !got_read; cycle++) begin
      if (axi_s.rvalid) begin
        check(axi_s.rid == 4'h0 && axi_s.rdata == ReplayDuringCAddr && !release_ack,
              "different-set replay did not respond during partial ReleaseData");
        got_read = 1'b1;
      end else tick(1);
    end
    check(got_read, "different-set replay response timed out");
    axi_s.rready = 1'b1;
    tick(1);
    axi_s.rready = 1'b0;
    for (int beat = 1; beat < LineBeats; beat++) begin
      release_addr  = LineAddr + XLEN'(beat * (XLEN / 8));
      release_data  = XLEN'('hfed00000 + beat);
      release_last  = beat == LineBeats - 1;
      release_valid = 1'b1;
      #1;
      check(release_ready, "C replay Release continuation was stalled");
      tick(1);
      release_valid = 1'b0;
    end
    got_ack = 1'b0;
    for (int cycle = 0; cycle < 128 && !got_ack; cycle++) begin
      #1;
      got_ack = release_ack;
      tick(1);
    end
    check(got_ack, "C replay Release did not acknowledge");

    // After C's directory lookup, a different-set cacheable primary may
    // take a new directory lookup and outer refill during the C data gap.
    axi_s.rready = 1'b1;
    for (int cycle = 0; cycle < 100 && dut.ms_busy; cycle++) tick(1);
    check(!dut.ms_busy, "C replay MSHR did not retire");
    axi_s.rready = 1'b0;
    send_l2_ar(LineAddr, 4'h2);
    for (int cycle = 0; cycle < 100 && !axi_s.rvalid; cycle++) tick(1);
    check(axi_s.rvalid && axi_s.rdata == XLEN'('hfed00000),
          "resident line could not be reacquired before primary admission test");
    axi_s.rready = 1'b1;
    tick(1);
    axi_s.rready = 1'b0;
    release_addr = LineAddr;
    release_data = XLEN'('hfac00000);
    release_has_data = 1'b1;
    release_mask = 1'b1;
    release_last = 1'b0;
    release_valid = 1'b1;
    #1;
    check(release_ready, "primary-admission Release first beat was stalled");
    tick(1);
    release_valid = 1'b0;
    for (int cycle = 0; cycle < 32 && dut.release_state != 2'd2; cycle++) tick(1);
    check(dut.release_state == 2'd2 && dut.release_pending,
          "primary-admission Release lookup did not finish");
    axi_s.araddr = PrimaryDuringCAddr;
    axi_s.arid = 4'h5;
    axi_s.arvalid = 1'b1;
    #1;
    check(axi_s.arready && !release_ack, "different-set primary AR waited for ReleaseAck");
    tick(1);
    axi_s.arvalid = 1'b0;
    accept_l2_downstream_ar(outer_id, outer_addr, outer_len);
    check(
        outer_addr == PrimaryDuringCAddr && outer_len == 8'(LineBeats - 1)
              && dut.release_pending && !release_ack,
        "different-set primary refill waited for ReleaseAck");
    for (int beat = 0; beat < LineBeats; beat++) begin
      if (beat == 1) begin
        // Queue SinkC's next data beat, then offer a live SinkD beat to the
        // same physical bank while SinkC drains from the Release buffer.
        release_addr  = LineAddr + XLEN'(XLEN / 8);
        release_data  = XLEN'('hfac00001);
        release_last  = 1'b0;
        release_valid = 1'b1;
        #1;
        check(release_ready, "different-set ReleaseData beat was not buffered");
        tick(1);
        release_valid = 1'b0;
        axi_m.rid = outer_id;
        axi_m.rdata = PrimaryDuringCAddr + XLEN'(beat);
        axi_m.rlast = 1'b0;
        axi_m.rvalid = 1'b1;
        #1;
        check(dut.bank_priority_word_valid && !axi_m.rready && dut.ms_sinkd_valid,
              "SinkC did not backpressure the same-bank live SinkD beat");
        tick(1);
        #1;
        check(dut.release_word == 2 && axi_m.rready && !release_ack,
              "SinkC beat did not advance or live SinkD failed to retry");
        tick(1);
        axi_m.rvalid = 1'b0;
      end else
        return_l2_downstream_r(outer_id, PrimaryDuringCAddr + XLEN'(beat), beat == LineBeats - 1);
    end
    got_read = 1'b0;
    for (int cycle = 0; cycle < 100 && !got_read; cycle++) begin
      if (axi_s.rvalid) begin
        check(axi_s.rid == 4'h5 && axi_s.rdata == PrimaryDuringCAddr && !release_ack,
              "different-set primary did not respond during partial ReleaseData");
        got_read = 1'b1;
      end else tick(1);
    end
    check(got_read, "different-set primary response timed out");
    axi_s.rready = 1'b1;
    tick(1);
    axi_s.rready = 1'b0;
    for (int cycle = 0; cycle < 100 && !dut.ms_complete_valid; cycle++) tick(1);
    check(dut.ms_complete_valid && dut.release_word == 2,
          "different-set refill did not schedule metadata install during ReleaseData");
    tick(1);
    check(dut.cache_install && dut.release_word == 2 && !dut.boom_bank_line_busy && !release_ack,
          "streamed refill unexpectedly started a buffered line install");
    tick(1);
    check(dut.release_word == 2 && !dut.boom_bank_line_busy && !release_ack,
          "SinkC beat was lost during streamed refill metadata install");
    for (int cycle = 0; cycle < 100 && !(|dut.ms_installed); cycle++) tick(1);
    check((|dut.ms_installed) && dut.release_pending && !release_ack,
          "different-set refill did not install during partial ReleaseData");
    for (int cycle = 0; cycle < 100 && dut.release_word != 2; cycle++) tick(1);
    check(dut.release_word == 2 && !release_ack,
          "ReleaseData beat was lost during the different-set line install");
    for (int cycle = 0; cycle < 100 && dut.ms_busy; cycle++) tick(1);
    check(!dut.ms_busy && dut.release_pending && !release_ack,
          "installed different-set refill did not retire during ReleaseData");
    send_l2_ar(PrimaryDuringCAddr, 4'h6, 4'h4);
    got_read = 1'b0;
    for (int cycle = 0; cycle < 100 && !got_read; cycle++) begin
      check(!axi_m.arvalid, "different-set installed line was refetched during ReleaseData");
      if (axi_s.rvalid) begin
        check(axi_s.rid == 4'h6 && axi_s.rdata == PrimaryDuringCAddr && !release_ack,
              "different-set installed line did not hit during partial ReleaseData");
        got_read = 1'b1;
      end else tick(1);
    end
    check(got_read, "different-set installed line read timed out");
    axi_s.rready = 1'b1;
    tick(1);
    axi_s.rready = 1'b0;
    for (int beat = 2; beat < LineBeats; beat++) begin
      release_addr  = LineAddr + XLEN'(beat * (XLEN / 8));
      release_data  = XLEN'('hfac00000 + beat);
      release_last  = beat == LineBeats - 1;
      release_valid = 1'b1;
      #1;
      check(release_ready, "primary-admission Release continuation was stalled");
      tick(1);
      release_valid = 1'b0;
    end
    got_ack = 1'b0;
    for (int cycle = 0; cycle < 128 && !got_ack; cycle++) begin
      #1;
      got_ack = release_ack;
      tick(1);
    end
    check(got_ack, "primary-admission Release did not acknowledge");

    // The D client can receive the critical word before the rest of its L2
    // fill. C takes the reserved way after the first returned beat, but each
    // C word waits for its matching SinkD word before overwriting that bank.
    axi_s.rready = 1'b1;
    for (int cycle = 0; cycle < 100 && dut.ms_busy; cycle++) tick(1);
    check(!dut.ms_busy, "earlier MSHR did not retire before early Release test");
    axi_s.rready = 1'b0;
    send_l2_ar(EarlyReleaseAddr, 4'h2, 4'h4);
    accept_l2_downstream_ar(outer_id, outer_addr, outer_len);
    check(outer_addr == EarlyReleaseAddr && outer_len == 8'(LineBeats - 1),
          "D-client early Release miss did not issue its outer line");
    return_l2_downstream_r(outer_id, XLEN'('h11110000), 1'b0);
    for (int cycle = 0; cycle < 64 && !axi_s.rvalid; cycle++) tick(1);
    check(
        axi_s.rvalid && axi_s.rid == 4'h2 && axi_s.rdata == XLEN'('h11110000)
              && axi_s.rlast && dut.ms_busy,
        "D-client did not receive its critical word before full L2 refill");
    axi_s.rready = 1'b1;
    tick(1);
    axi_s.rready = 1'b0;
    for (int beat = 0; beat < LineBeats; beat++) begin
      release_addr = EarlyReleaseAddr + XLEN'(beat * (XLEN / 8));
      release_data = XLEN'('h22220000 + beat);
      release_has_data = 1'b1;
      release_mask = 1'b1;
      release_last = beat == LineBeats - 1;
      release_valid = 1'b1;
      #1;
      check(release_ready, "early same-line ReleaseData beat was stalled");
      if (beat == 0)
        check(dut.release_lookup_fire && dut.release_nested_candidate && !dut.dir_read_valid,
              "first C beat did not nest into the in-flight MSHR");
      tick(1);
      release_valid = 1'b0;
    end
    check(
        dut.release_nested_q && dut.release_state == dut.REL_DATA
              && dut.release_word == 1 && !release_ack && !dut.ms_slot_done[int'(dut.release_nested_slot_q)],
        "C did not wait for the next SinkD word before writing ReleaseData");
    tick(3);
    check(dut.release_word == 1 && !release_ack,
          "C advanced past a word that SinkD had not yet filled");
    return_l2_downstream_r(outer_id, XLEN'('h11110001), 1'b0);
    for (int cycle = 0; cycle < 16 && dut.release_word != 2; cycle++) tick(1);
    check(dut.release_word == 2 && !dut.ms_slot_done[int'(dut.release_nested_slot_q)],
          "nested C did not write the next word during the outer refill");
    for (int beat = 2; beat < LineBeats; beat++)
    return_l2_downstream_r(outer_id, XLEN'('h11110000 + beat), beat == LineBeats - 1);
    check(dut.release_nested_q && dut.release_state == dut.REL_DATA && !(|dut.ms_installed),
          "nested C installed metadata before writing ReleaseData");
    got_ack = 1'b0;
    for (int cycle = 0; cycle < 256 && !got_ack; cycle++) begin
      #1;
      if (release_ack) begin
        check(
            dut.release_nested_q && dut.ms_slot_done[int'(dut.release_nested_slot_q)]
                  && !dut.ms_installed[int'(dut.release_nested_slot_q)],
            "nested C Ack did not commit the completed MSHR");
        got_ack = 1'b1;
      end
      tick(1);
    end
    check(got_ack && |dut.ms_installed, "nested same-line Release did not install metadata on Ack");
    for (int cycle = 0; cycle < 100 && dut.ms_busy; cycle++) tick(1);
    send_l2_ar(EarlyReleaseAddr, 4'h2, 4'h4);
    got_read = 1'b0;
    for (int cycle = 0; cycle < 64 && !got_read; cycle++) begin
      check(!axi_m.arvalid, "early ReleaseData line was refetched");
      if (axi_s.rvalid) begin
        check(axi_s.rdata == XLEN'('h22220000) && axi_s.rresp == 2'b00,
              "early ReleaseData did not override the outer refill");
        got_read = 1'b1;
      end else tick(1);
    end
    check(got_read, "post-early-Release resident read timed out");
    axi_s.rready = 1'b1;
    tick(1);
    axi_s.rready = 1'b0;
    for (int cycle = 0; cycle < 100 && dut.ms_busy; cycle++) tick(1);
    check(!dut.ms_busy, "dirty nested C MSHR did not retire");

    // A clean Release has no data beats. It reserves C during SinkD but
    // waits for the completed refill before committing clean metadata.
    send_l2_ar(CleanReleaseAddr, 4'h2, 4'h4);
    accept_l2_downstream_ar(outer_id, outer_addr, outer_len);
    check(outer_addr == CleanReleaseAddr, "clean nested C miss used the wrong line");
    return_l2_downstream_r(outer_id, XLEN'('h33330000), 1'b0);
    for (int cycle = 0; cycle < 64 && !axi_s.rvalid; cycle++) tick(1);
    check(axi_s.rvalid && axi_s.rdata == XLEN'('h33330000),
          "clean nested C client did not receive its critical word");
    axi_s.rready = 1'b1;
    tick(1);
    axi_s.rready = 1'b0;
    release_addr = CleanReleaseAddr;
    release_data = '0;
    release_has_data = 1'b0;
    release_mask = 1'b0;
    release_last = 1'b1;
    release_valid = 1'b1;
    #1;
    check(release_ready && dut.release_lookup_fire && dut.release_nested_candidate,
          "clean C did not reserve the in-flight MSHR");
    tick(1);
    release_valid = 1'b0;
    check(dut.release_nested_q && dut.release_state == dut.REL_DIRECTORY && !release_ack,
          "clean nested C acknowledged before SinkD completed");
    for (int beat = 1; beat < LineBeats; beat++)
    return_l2_downstream_r(outer_id, XLEN'('h33330000 + beat), beat == LineBeats - 1);
    check(dut.release_nested_q && dut.release_state == dut.REL_DIRECTORY,
          "clean nested C unnecessarily entered the data state");
    got_ack = 1'b0;
    for (int cycle = 0; cycle < 64 && !got_ack; cycle++) begin
      #1;
      if (release_ack) begin
        check(dut.release_nested_q && !(|dut.ms_installed),
              "clean nested C Ack did not own the uninstalled line");
        got_ack = 1'b1;
      end
      tick(1);
    end
    check(got_ack && |dut.ms_installed, "clean nested C did not install the line on Ack");
    for (int cycle = 0; cycle < 100 && dut.ms_busy; cycle++) tick(1);
    send_l2_ar(CleanReleaseAddr, 4'h2, 4'h4);
    got_read = 1'b0;
    for (int cycle = 0; cycle < 64 && !got_read; cycle++) begin
      check(!axi_m.arvalid, "clean nested C line was refetched");
      if (axi_s.rvalid) begin
        check(axi_s.rdata == XLEN'('h33330000) && axi_s.rresp == 2'b00,
              "clean nested C line lost its outer refill data");
        got_read = 1'b1;
      end else tick(1);
    end
    check(got_read, "clean nested C resident read timed out");
    axi_s.rready = 1'b1;
    tick(1);
    axi_s.rready = 1'b0;
    for (int cycle = 0; cycle < 100 && dut.ms_busy; cycle++) tick(1);

    // Unmasked C words leave their SinkD data intact. C can finish its own
    // beat list early but must still hold Ack until SinkD completes the line.
    send_l2_ar(PartialReleaseAddr, 4'h2, 4'h4);
    accept_l2_downstream_ar(outer_id, outer_addr, outer_len);
    check(outer_addr == PartialReleaseAddr, "partial nested C miss used the wrong line");
    return_l2_downstream_r(outer_id, XLEN'('h44440000), 1'b0);
    for (int cycle = 0; cycle < 64 && !axi_s.rvalid; cycle++) tick(1);
    check(axi_s.rvalid && axi_s.rdata == XLEN'('h44440000),
          "partial nested C client did not receive its critical word");
    axi_s.rready = 1'b1;
    tick(1);
    axi_s.rready = 1'b0;
    for (int beat = 0; beat < LineBeats; beat++) begin
      release_addr = PartialReleaseAddr + XLEN'(beat * (XLEN / 8));
      release_data = XLEN'('h55550000 + beat);
      release_has_data = 1'b1;
      release_mask = beat == 0;
      release_last = beat == LineBeats - 1;
      release_valid = 1'b1;
      #1;
      check(release_ready, "partial nested C data beat was stalled");
      if (beat == 0)
        check(dut.release_lookup_fire && dut.release_nested_candidate,
              "partial C did not nest into the in-flight MSHR");
      tick(1);
      release_valid = 1'b0;
    end
    for (int cycle = 0; cycle < 32 && dut.release_state != dut.REL_DIRECTORY; cycle++) tick(1);
    check(
        dut.release_state == dut.REL_DIRECTORY && !release_ack && !dut.ms_slot_done[int'(dut.release_nested_slot_q)],
        "partial C acknowledged before unmasked SinkD words completed");
    for (int beat = 1; beat < LineBeats; beat++)
    return_l2_downstream_r(outer_id, XLEN'('h44440000 + beat), beat == LineBeats - 1);
    got_ack = 1'b0;
    for (int cycle = 0; cycle < 64 && !got_ack; cycle++) begin
      #1;
      got_ack = release_ack;
      tick(1);
    end
    check(got_ack, "partial nested C did not acknowledge after SinkD completed");
    for (int cycle = 0; cycle < 100 && dut.ms_busy; cycle++) tick(1);
    send_l2_ar(PartialReleaseAddr, 4'h2, 4'h4);
    for (int cycle = 0; cycle < 64 && !axi_s.rvalid; cycle++) tick(1);
    check(axi_s.rvalid && axi_s.rdata == XLEN'('h55550000),
          "partial nested C lost its masked ReleaseData word");
    axi_s.rready = 1'b1;
    tick(1);
    axi_s.rready = 1'b0;
    send_l2_ar(PartialReleaseAddr + XLEN'(XLEN / 8), 4'h2, 4'h4);
    for (int cycle = 0; cycle < 64 && !axi_s.rvalid; cycle++) tick(1);
    check(axi_s.rvalid && axi_s.rdata == XLEN'('h44440001),
          "partial nested C overwrote an unmasked refill word");
    axi_s.rready = 1'b1;
    tick(1);

    // A late outer error after an early critical response cannot strand C.
    // Retry the refill, then replay buffered ReleaseData over its new words.
    axi_s.rready = 1'b0;
    for (int cycle = 0; cycle < 100 && dut.ms_busy; cycle++) tick(1);
    send_l2_ar(ErrorReleaseAddr, 4'h2, 4'h4);
    accept_l2_downstream_ar(outer_id, outer_addr, outer_len);
    check(outer_addr == ErrorReleaseAddr, "nested error miss used the wrong line");
    return_l2_downstream_r(outer_id, XLEN'('h66660000), 1'b0);
    for (int cycle = 0; cycle < 64 && !axi_s.rvalid; cycle++) tick(1);
    check(axi_s.rvalid && axi_s.rdata == XLEN'('h66660000),
          "nested error client did not receive its critical word");
    axi_s.rready = 1'b1;
    tick(1);
    axi_s.rready = 1'b0;
    for (int beat = 0; beat < LineBeats; beat++) begin
      release_addr = ErrorReleaseAddr + XLEN'(beat * (XLEN / 8));
      release_data = XLEN'('h88880000 + beat);
      release_has_data = 1'b1;
      release_mask = beat == 0;
      release_last = beat == LineBeats - 1;
      release_valid = 1'b1;
      #1;
      check(release_ready, "nested error ReleaseData beat was stalled");
      tick(1);
      release_valid = 1'b0;
    end
    for (int cycle = 0; cycle < 32 && dut.release_state != dut.REL_DIRECTORY; cycle++) tick(1);
    check(dut.release_state == dut.REL_DIRECTORY && !release_ack,
          "nested error C did not wait for the outer refill");
    for (int beat = 1; beat < LineBeats; beat++)
    return_l2_downstream_r(outer_id, XLEN'('h66660000 + beat), beat == LineBeats - 1,
                           beat == 1 ? 2'b10 : 2'b00);
    check(!release_ack, "nested C acknowledged a failed outer refill");
    accept_l2_downstream_ar(outer_id, outer_addr, outer_len);
    check(outer_addr == ErrorReleaseAddr && outer_len == 8'(LineBeats - 1),
          "failed nested refill was not retried from the original line");
    for (int beat = 0; beat < LineBeats; beat++)
    return_l2_downstream_r(outer_id, XLEN'('h77770000 + beat), beat == LineBeats - 1);
    got_ack = 1'b0;
    for (int cycle = 0; cycle < 128 && !got_ack; cycle++) begin
      #1;
      got_ack = release_ack;
      tick(1);
    end
    check(got_ack, "nested C did not acknowledge after a successful retry");
    for (int cycle = 0; cycle < 100 && dut.ms_busy; cycle++) tick(1);
    send_l2_ar(ErrorReleaseAddr, 4'h2, 4'h4);
    for (int cycle = 0; cycle < 64 && !axi_s.rvalid; cycle++) tick(1);
    check(axi_s.rvalid && axi_s.rdata == XLEN'('h88880000),
          "nested C lost its released word after retry");
    axi_s.rready = 1'b1;
    tick(1);
    axi_s.rready = 1'b0;
    send_l2_ar(ErrorReleaseAddr + XLEN'(XLEN / 8), 4'h2, 4'h4);
    for (int cycle = 0; cycle < 64 && !axi_s.rvalid; cycle++) tick(1);
    check(axi_s.rvalid && axi_s.rdata == XLEN'('h77770001),
          "nested C retained the failed refill's unmasked word");
    axi_s.rready = 1'b1;
    tick(1);

    // The C request may first arrive after the failing outer RLAST. The
    // errored MSHR must remain available for C to claim and retry; otherwise
    // both the MSHR completion and C lookup wait on one another forever.
    axi_s.rready = 1'b0;
    for (int cycle = 0; cycle < 100 && dut.ms_busy; cycle++) tick(1);
    send_l2_ar(LateErrorReleaseAddr, 4'h2, 4'h4);
    accept_l2_downstream_ar(outer_id, outer_addr, outer_len);
    check(outer_addr == LateErrorReleaseAddr, "late-error miss used the wrong line");
    return_l2_downstream_r(outer_id, XLEN'('h99990000), 1'b0);
    for (int cycle = 0; cycle < 64 && !axi_s.rvalid; cycle++) tick(1);
    check(axi_s.rvalid && axi_s.rdata == XLEN'('h99990000),
          "late-error client did not receive its critical word");
    axi_s.rready = 1'b1;
    tick(1);
    axi_s.rready = 1'b0;
    for (int beat = 1; beat < LineBeats; beat++)
    return_l2_downstream_r(outer_id, XLEN'('h99990000 + beat), beat == LineBeats - 1,
                           beat == 1 ? 2'b10 : 2'b00);
    check(dut.ms_slot_done[int'(outer_id)] && dut.ms_slot_resp[int'(outer_id)] != 2'b00,
          "late-error MSHR did not retain the outer response error");
    release_addr = LateErrorReleaseAddr;
    release_data = '0;
    release_has_data = 1'b0;
    release_mask = 1'b0;
    release_last = 1'b1;
    release_valid = 1'b1;
    #1;
    check(release_ready, "late-error clean Release was stalled");
    tick(1);
    release_valid = 1'b0;
    for (int cycle = 0; cycle < 8 && !dut.release_nested_q; cycle++) tick(1);
    check(dut.release_nested_q, "late-error C did not claim the errored MSHR");
    accept_l2_downstream_ar(outer_id, outer_addr, outer_len);
    check(outer_addr == LateErrorReleaseAddr && outer_len == 8'(LineBeats - 1),
          "late-error C did not retry its original line");
    for (int beat = 0; beat < LineBeats; beat++)
    return_l2_downstream_r(outer_id, XLEN'('haaaa0000 + beat), beat == LineBeats - 1);
    got_ack = 1'b0;
    for (int cycle = 0; cycle < 128 && !got_ack; cycle++) begin
      #1;
      got_ack = release_ack;
      tick(1);
    end
    check(got_ack, "late-error clean C did not acknowledge after retry");
    for (int cycle = 0; cycle < 100 && dut.ms_busy; cycle++) tick(1);
    send_l2_ar(LateErrorReleaseAddr, 4'h2, 4'h4);
    for (int cycle = 0; cycle < 64 && !axi_s.rvalid; cycle++) tick(1);
    check(axi_s.rvalid && axi_s.rdata == XLEN'('haaaa0000),
          "late-error C did not retain the successful retry data");
    axi_s.rready = 1'b1;
    tick(1);

    // A late outer error also needs recovery if no C is pending yet. The
    // early grant has already made the line visible to its L1D client, so
    // dropping the errored MSHR would leave a later clean Release orphaned.
    axi_s.rready = 1'b0;
    for (int cycle = 0; cycle < 100 && dut.ms_busy; cycle++) tick(1);
    send_l2_ar(PostErrorReleaseAddr, 4'h2, 4'h4);
    accept_l2_downstream_ar(outer_id, outer_addr, outer_len);
    check(outer_addr == PostErrorReleaseAddr, "post-error miss used the wrong line");
    return_l2_downstream_r(outer_id, XLEN'('hbbbb0000), 1'b0);
    for (int cycle = 0; cycle < 64 && !axi_s.rvalid; cycle++) tick(1);
    check(axi_s.rvalid && axi_s.rdata == XLEN'('hbbbb0000),
          "post-error client did not receive its critical word");
    axi_s.rready = 1'b1;
    tick(1);
    axi_s.rready = 1'b0;
    send_l2_ar(PostErrorReleaseAddr + XLEN'(XLEN / 8), 4'h3, 4'h4);
    for (int beat = 1; beat < LineBeats; beat++)
    return_l2_downstream_r(outer_id, XLEN'('hbbbb0000 + beat), beat == LineBeats - 1,
                           beat == 1 ? 2'b10 : 2'b00);
    accept_l2_downstream_ar(outer_id, outer_addr, outer_len);
    check(outer_addr == PostErrorReleaseAddr && outer_len == 8'(LineBeats - 1),
          "orphaned early grant was not recovered by a refill retry");
    for (int beat = 0; beat < LineBeats; beat++)
    return_l2_downstream_r(outer_id, XLEN'('hcccc0000 + beat), beat == LineBeats - 1);
    for (int cycle = 0; cycle < 128 && !axi_s.rvalid; cycle++) tick(1);
    check(
        axi_s.rvalid && axi_s.rid == 4'h3 && axi_s.rresp == 2'b00
              && axi_s.rdata == XLEN'('hcccc0001),
        "post-error secondary did not use the successful retry data");
    axi_s.rready = 1'b1;
    tick(1);
    axi_s.rready = 1'b0;
    for (int cycle = 0; cycle < 100 && dut.ms_busy; cycle++) tick(1);
    release_addr = PostErrorReleaseAddr;
    release_data = '0;
    release_has_data = 1'b0;
    release_mask = 1'b0;
    release_last = 1'b1;
    release_valid = 1'b1;
    #1;
    check(release_ready, "post-error clean Release was stalled");
    tick(1);
    release_valid = 1'b0;
    got_ack = 1'b0;
    for (int cycle = 0; cycle < 128 && !got_ack; cycle++) begin
      #1;
      got_ack = release_ack;
      tick(1);
    end
    check(got_ack, "post-error clean C did not acknowledge");
    send_l2_ar(PostErrorReleaseAddr, 4'h2, 4'h4);
    for (int cycle = 0; cycle < 64 && !axi_s.rvalid; cycle++) begin
      check(!axi_m.arvalid, "post-error resident line was refetched");
      tick(1);
    end
    check(axi_s.rvalid && axi_s.rdata == XLEN'('hcccc0000),
          "post-error clean C did not preserve the successful retry data");
    axi_s.rready = 1'b1;
    tick(1);
    $display("PASS: L2 reserves admission from first ReleaseData beat, RV%0d", XLEN);
    $finish;
  end
endmodule
