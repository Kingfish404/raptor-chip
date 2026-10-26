`include "rapt.svh"
`include "rapt_soc_if.svh"

module tb_l2_mshr_different_tag;
  localparam int XLEN = `RAPT_XLEN;
  localparam int IdW = 4;
  localparam int LineBeats = 1 << `RAPT_L2_LINE_LEN;
  localparam logic [XLEN-1:0] LineA = XLEN'('h8000_0000);
  localparam logic [XLEN-1:0] LineB = LineA + XLEN'(64 * 1024);
  localparam logic [XLEN-1:0] LineC = LineA + XLEN'(2 * 64 * 1024);
  localparam logic [XLEN-1:0] LineD = LineA + XLEN'(64);
  localparam logic [XLEN-1:0] LineE = LineD + XLEN'(64 * 1024);
  localparam logic [XLEN-1:0] LineF = LineA + XLEN'(3 * 64);
  localparam logic [XLEN-1:0] LineG = LineA + XLEN'(4 * 64);
  localparam logic [XLEN-1:0] LineH = LineA + XLEN'(5 * 64);
  logic clock = 1'b0;
  logic reset = 1'b1;
  logic [IdW-1:0] outer_id;
  logic [XLEN-1:0] outer_addr;
  logic [7:0] outer_len;
  logic cbo_inval = 1'b0;
  logic [XLEN-1:6] cbo_block = '0;
  logic probe_valid, probe_ready = 1'b0;
  logic [XLEN-1:0] probe_addr;
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
      .cbo_inval_i  (cbo_inval),
      .cbo_block_i  (cbo_block),
      .probe_valid_o(probe_valid),
      .probe_addr_o (probe_addr),
      .probe_ready_i(probe_ready),
      .axi_s,
      .axi_m
  );
  always #5 clock = ~clock;
  `include "tb_common.svh"
  `include "tb_l2_axi_tasks.svh"

  initial begin
    bit accepted;
    init_l2_axi(1'b0);
    axi_s.rready = 1'b0;
    tick(3);
    reset = 1'b0;
    for (int cycle = 0; cycle < 1100 && !dut.dir_ready; cycle++) tick(1);
    check(dut.dir_ready, "directory wipe did not complete");

    send_l2_ar(LineA, 4'd3);
    accept_l2_downstream_ar(outer_id, outer_addr, outer_len);
    check(outer_id == 4'd0 && outer_addr == LineA,
          "first clean miss did not allocate the ordinary MSHR");

    // BOOM queues a different tag with the same set under the active MSHR.
    // It must be accepted before the first outer refill returns, then
    // re-read the directory when that MSHR reloads.
    axi_s.araddr = LineB;
    axi_s.arid = 4'd4;
    axi_s.arlen = 8'(LineBeats - 1);
    axi_s.arburst = 2'b01;
    axi_s.arvalid = 1'b1;
    accepted = 1'b0;
    for (int cycle = 0; cycle < 32 && !accepted; cycle++) begin
      @(posedge clock);
      accepted = axi_s.arready;
    end
    check(accepted, "different-tag same-set secondary was not accepted");
    #1;
    axi_s.arvalid = 1'b0;
    check(!axi_m.arvalid, "secondary tag bypassed its owning MSHR");

    for (int beat = 0; beat < LineBeats; beat++)
    return_l2_downstream_r(outer_id, LineA + XLEN'(beat), beat == LineBeats - 1);
    for (int cycle = 0; cycle < 100 && !axi_s.rvalid; cycle++) tick(1);
    check(axi_s.rvalid && axi_s.rid == 4'd3 && axi_s.rdata == LineA,
          "first refill response was lost");
    axi_s.rready = 1'b1;
    tick(1);
    axi_s.rready = 1'b0;

    accept_l2_downstream_ar(outer_id, outer_addr, outer_len);
    check(outer_id == 4'd0 && outer_addr == LineB && outer_len == 8'(LineBeats - 1),
          "different-tag secondary was not reloaded into a new refill");
    // Keep two more requests on the same MSHR while B is filling. A now
    // resides in the directory; C must reload yet another line.
    send_l2_ar(LineA, 4'd5);
    send_l2_ar(LineC, 4'd6);
    for (int beat = 0; beat < LineBeats; beat++)
    return_l2_downstream_r(outer_id, LineB + XLEN'(beat), beat == LineBeats - 1);
    axi_s.rready = 1'b1;
    for (int beat = 0; beat < LineBeats; beat++) begin
      for (int cycle = 0; cycle < 100 && !axi_s.rvalid; cycle++) tick(1);
      check(
          axi_s.rvalid && axi_s.rid == 4'd4 && axi_s.rdata == LineB + XLEN'(beat)
            && axi_s.rlast == (beat == LineBeats - 1),
          "different-tag full-line secondary lost an AXI beat or ID");
      check(dut.ms_secondary_id_busy[4], "secondary ID was freed before the final burst beat");
      tick(1);
    end
    axi_s.rready = 1'b0;
    check(!dut.ms_secondary_id_busy[4], "different-tag burst ID was not freed at RLAST");

    // BOOM's random victim may have evicted A when B was installed. Both a
    // resident hit and another refill must preserve the queued AXI ID.
    for (int cycle = 0; cycle < 100 && !axi_s.rvalid && !axi_m.arvalid; cycle++) tick(1);
    if (axi_m.arvalid) begin
      accept_l2_downstream_ar(outer_id, outer_addr, outer_len);
      check(outer_id == 4'd0 && outer_addr == LineA,
            "evicted A did not reload through its owning MSHR");
      for (int beat = 0; beat < LineBeats; beat++)
      return_l2_downstream_r(outer_id, LineA + XLEN'(beat), beat == LineBeats - 1);
    end
    for (int cycle = 0; cycle < 100 && !axi_s.rvalid; cycle++) tick(1);
    check(axi_s.rvalid && axi_s.rid == 4'd5 && axi_s.rdata == LineA,
          "resident secondary did not replay through the directory");
    axi_s.rready = 1'b1;
    tick(1);
    axi_s.rready = 1'b0;

    accept_l2_downstream_ar(outer_id, outer_addr, outer_len);
    check(outer_addr == LineC, "third same-set tag did not retain its secondary queue");
    for (int beat = 0; beat < LineBeats; beat++)
    return_l2_downstream_r(outer_id, LineC + XLEN'(beat), beat == LineBeats - 1);
    for (int cycle = 0; cycle < 100 && !axi_s.rvalid; cycle++) tick(1);
    check(axi_s.rvalid && axi_s.rid == 4'd6 && axi_s.rdata == LineC,
          "third same-set tag lost its ID or line");
    axi_s.rready = 1'b1;
    tick(1);
    axi_s.rready = 1'b0;

    // A full-line secondary with the same tag cannot use the scalar
    // critical-word bypass; replay its complete burst after line install.
    for (int cycle = 0; cycle < 20 && dut.ms_busy; cycle++) tick(1);
    send_l2_ar(LineF, 4'd1);
    accept_l2_downstream_ar(outer_id, outer_addr, outer_len);
    check(outer_addr == LineF, "same-tag burst primary missed its outer line");
    send_l2_ar_len(LineF, 4'd2, 8'(LineBeats - 1), 2'b01, 4'h4);
    check(!axi_m.arvalid, "same-tag full-line secondary started a duplicate refill");
    for (int beat = 0; beat < LineBeats; beat++)
    return_l2_downstream_r(outer_id, LineF + XLEN'(beat), beat == LineBeats - 1);
    for (int cycle = 0; cycle < 100 && !axi_s.rvalid; cycle++) tick(1);
    check(axi_s.rvalid && axi_s.rid == 4'd1 && axi_s.rdata == LineF && axi_s.rlast,
          "same-tag burst primary response was lost");
    axi_s.rready = 1'b1;
    tick(1);
    for (int beat = 0; beat < LineBeats; beat++) begin
      for (int cycle = 0; cycle < 100 && !axi_s.rvalid; cycle++) tick(1);
      check(
          axi_s.rvalid && axi_s.rid == 4'd2 && axi_s.rdata == LineF + XLEN'(beat)
            && axi_s.rlast == (beat == LineBeats - 1),
          "same-tag full-line secondary lost an AXI beat or ID");
      check(dut.ms_secondary_id_busy[2], "same-tag burst ID was freed early");
      tick(1);
    end
    axi_s.rready = 1'b0;
    check(!dut.ms_secondary_id_busy[2], "same-tag burst ID was not freed at RLAST");

    // A full-line primary also owns its set until all beats are returned;
    // a scalar same-tag secondary stays queued behind that burst.
    for (int cycle = 0; cycle < 20 && dut.ms_busy; cycle++) tick(1);
    send_l2_ar_len(LineG, 4'd3, 8'(LineBeats - 1), 2'b01, 4'h4);
    accept_l2_downstream_ar(outer_id, outer_addr, outer_len);
    check(outer_addr == LineG, "full-line primary missed its outer line");
    send_l2_ar(LineG + XLEN'(2 * XLEN / 8), 4'd4, 4'h4);
    check(!axi_m.arvalid, "scalar secondary under a full-line primary duplicated the refill");
    for (int beat = 0; beat < LineBeats; beat++)
    return_l2_downstream_r(outer_id, LineG + XLEN'(beat), beat == LineBeats - 1);
    axi_s.rready = 1'b1;
    for (int beat = 0; beat < LineBeats; beat++) begin
      for (int cycle = 0; cycle < 100 && !axi_s.rvalid; cycle++) tick(1);
      check(
          axi_s.rvalid && axi_s.rid == 4'd3 && axi_s.rdata == LineG + XLEN'(beat)
            && axi_s.rlast == (beat == LineBeats - 1),
          "full-line primary lost an AXI beat or ID");
      tick(1);
    end
    for (int cycle = 0; cycle < 100 && !axi_s.rvalid; cycle++) tick(1);
    check(
        axi_s.rvalid && axi_s.rid == 4'd4 && axi_s.rdata == LineG + XLEN'(2)
          && axi_s.rlast && dut.ms_secondary_id_busy[4],
        "scalar secondary under full-line primary was lost");
    tick(1);
    axi_s.rready = 1'b0;

    // A failed primary refill must release the owning set after reporting
    // the error, so a queued different-tag request can reuse the MSHR.
    send_l2_ar(LineD, 4'd7);
    accept_l2_downstream_ar(outer_id, outer_addr, outer_len);
    check(outer_addr == LineD, "error-case primary missed its outer line");
    send_l2_ar(LineE, 4'd8);
    for (int beat = 0; beat < LineBeats; beat++)
    return_l2_downstream_r(outer_id, LineD + XLEN'(beat), beat == LineBeats - 1,
                           beat == 0 ? 2'b10 : 2'b00);
    for (int cycle = 0; cycle < 100 && !axi_s.rvalid; cycle++) tick(1);
    check(axi_s.rvalid && axi_s.rid == 4'd7 && axi_s.rresp == 2'b10,
          "failed primary refill did not report its error");
    axi_s.rready = 1'b1;
    tick(1);
    axi_s.rready = 1'b0;

    accept_l2_downstream_ar(outer_id, outer_addr, outer_len);
    check(outer_addr == LineE, "secondary after failed refill did not reload");
    for (int beat = 0; beat < LineBeats; beat++)
    return_l2_downstream_r(outer_id, LineE + XLEN'(beat), beat == LineBeats - 1);
    for (int cycle = 0; cycle < 100 && !axi_s.rvalid; cycle++) tick(1);
    check(axi_s.rvalid && axi_s.rid == 4'd8 && axi_s.rdata == LineE && axi_s.rresp == 2'b00,
          "secondary after failed refill lost its ID or data");
    axi_s.rready = 1'b1;
    tick(1);
    axi_s.rready = 1'b0;

    // Same-tag secondary bursts inherit a failed refill's response on
    // every AXI beat; a different-tag request above still reloads instead.
    for (int cycle = 0; cycle < 20 && dut.ms_busy; cycle++) tick(1);
    send_l2_ar(LineH, 4'd9);
    accept_l2_downstream_ar(outer_id, outer_addr, outer_len);
    check(outer_addr == LineH, "error-burst primary missed its outer line");
    send_l2_ar_len(LineH, 4'd10, 8'(LineBeats - 1), 2'b01, 4'h4);
    for (int beat = 0; beat < LineBeats; beat++)
    return_l2_downstream_r(outer_id, LineH + XLEN'(beat), beat == LineBeats - 1,
                           beat == 0 ? 2'b10 : 2'b00);
    for (int cycle = 0; cycle < 100 && !axi_s.rvalid; cycle++) tick(1);
    check(axi_s.rvalid && axi_s.rid == 4'd9 && axi_s.rresp == 2'b10 && axi_s.rlast,
          "error-burst primary did not report the refill failure");
    axi_s.rready = 1'b1;
    tick(1);
    for (int beat = 0; beat < LineBeats; beat++) begin
      for (int cycle = 0; cycle < 100 && !axi_s.rvalid; cycle++) tick(1);
      check(
          axi_s.rvalid && axi_s.rid == 4'd10 && axi_s.rresp == 2'b10
            && axi_s.rlast == (beat == LineBeats - 1),
          "same-tag full-line secondary lost an error beat or RLAST");
      check(dut.ms_secondary_id_busy[10], "failed secondary burst ID was freed early");
      tick(1);
    end
    axi_s.rready = 1'b0;
    check(!dut.ms_secondary_id_busy[10], "failed secondary burst ID stayed reserved");
    check(!axi_m.arvalid, "same-tag failed secondary started a duplicate outer refill");

    // AXI ID 8 belongs to the D client. A replayed secondary must set its
    // ownership bit so a targeted CBO probes that client before eviction.
    cbo_block = LineE[XLEN-1:6];
    cbo_inval = 1'b1;
    tick(1);
    cbo_inval = 1'b0;
    for (int cycle = 0; cycle < (1 << `RAPT_L2_LEN) + 64 && !probe_valid; cycle++) tick(1);
    check(probe_valid && probe_addr == LineE,
          "replayed D-client secondary was installed without ownership");
    $display("PASS: RV%0d same-set different-tag MSHR replay", XLEN);
    $finish;
  end
endmodule
