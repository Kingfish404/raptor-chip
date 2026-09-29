`include "rapt.svh"
`include "rapt_soc_if.svh"

module tb_l2_mshr_concurrent;
  localparam int XLEN = `RAPT_XLEN;
  localparam int IdW = 4;
  localparam int LineBeats = 1 << `RAPT_L2_LINE_LEN;
  localparam int NormalMshrs = XLEN == 64 ? 5 : 3;
  localparam int NumResponses = NormalMshrs + 3;
  localparam logic [XLEN-1:0] Base = XLEN'('h8000_0000);
  logic clock = 1'b0;
  logic reset = 1'b1;
  logic [IdW-1:0] outer_id[NormalMshrs];
  logic [NumResponses-1:0] response_seen = '0;
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
      .axi_s,
      .axi_m
  );
  always #5 clock = ~clock;
  `include "tb_common.svh"
  `include "tb_l2_axi_tasks.svh"


  initial begin
    init_l2_axi(1'b0);
    axi_s.rready = 1'b0;
    tick(3);
    reset = 1'b0;
    for (int cycle = 0; cycle < 1100 && !dut.dir_ready; cycle++) tick(1);
    check(dut.dir_ready, "L2 directory wipe did not finish");
    check(
        dut.BoomNormalMshrs == NormalMshrs
              && dut.BoomMshrs == NormalMshrs + 2
              && dut.BoomSecondaryEntries == (XLEN == 64 ? 33 : 35),
        "live MSHR and secondary-buffer sizes differ from BOOM's 40-cycle formula");

    // BOOM's 40-cycle sizing permits five RV64 or three RV32 ordinary MSHRs.
    for (int slot = 0; slot < NormalMshrs; slot++) begin
      logic [IdW-1:0] id_seen;
      logic [XLEN-1:0] addr_seen;
      logic [7:0] len_seen;
      send_l2_ar(Base + XLEN'(slot * 64), IdW'(slot + 8));
      accept_l2_downstream_ar(id_seen, addr_seen, len_seen);
      check(
          id_seen == IdW'(slot) && addr_seen == Base + XLEN'(slot * 64)
                && len_seen == 8'(LineBeats - 1),
          "ordinary MSHR did not issue an independent aligned outer AR");
      outer_id[slot] = id_seen;
    end
    check(dut.ms_slot_valid[NormalMshrs-1:0] == {NormalMshrs{1'b1}},
          "normal MSHRs were not simultaneously active");
    axi_s.araddr  = Base + XLEN'(NormalMshrs * 64);
    axi_s.arid    = 4'd4;
    axi_s.arvalid = 1'b1;
    #1;
    check(!axi_s.arready, "different-set miss exceeded BOOM's normal MSHR count");
    axi_s.arvalid = 1'b0;

    // BOOM's A-channel secondary lists hold scalar reads to an active line.
    // These requests must not allocate another outer refill or lose their
    // individual upstream IDs while all primary misses are in flight.
    send_l2_ar(Base + XLEN'(XLEN / 8), 4'd1);
    send_l2_ar(Base + XLEN'((NormalMshrs - 1) * 64 + 3 * XLEN / 8), 4'd2);
    send_l2_ar(Base + XLEN'(2 * XLEN / 8), 4'd3);
    check(dut.ms_secondary_queue_valid[0] && dut.ms_secondary_queue_valid[NormalMshrs-1],
          "same-line secondaries did not enter the active MSHR queues");
    check(!axi_m.arvalid, "secondary read issued an unnecessary outer refill");
    axi_s.araddr = Base + XLEN'(NormalMshrs * 64);
    axi_s.arid = 4'd1;
    axi_s.arvalid = 1'b1;
    #1;
    check(!axi_s.arready, "queued secondary ID was reused before its response");
    axi_s.arvalid = 1'b0;
    // Different-tag same-set requests are covered by
    // tb_l2_mshr_different_tag; they now enter this slot's secondary list.

    // Interleave outer R streams by RID; every slot keeps its own beat
    // count and the original inner ID must return on the slave R channel.
    for (int beat = 0; beat < LineBeats; beat++) begin
      for (int slot = NormalMshrs - 1; slot >= 0; slot--) begin
        return_l2_downstream_r(outer_id[slot], Base + XLEN'(slot * 64 + beat),
                               beat == LineBeats - 1);
        check(!dut.boom_bank_line_busy,
              "streamed MSHR refill started a redundant buffered line install");
        if (beat == 0 && slot == NormalMshrs - 1) begin
          for (int cycle = 0; cycle < 5 && !axi_s.rvalid; cycle++) tick(1);
          check(
              axi_s.rvalid && axi_s.rid == 4'(8 + NormalMshrs - 1)
                    && axi_s.rdata == Base + XLEN'((NormalMshrs - 1) * 64),
              "critical word did not return before the line completed");
        end
      end
    end
    for (int count = 0; count < NumResponses; count++) begin
      int slot;
      logic [XLEN-1:0] expected_data;
      for (int cycle = 0; cycle < 100 && !axi_s.rvalid; cycle++) tick(1);
      check(
          axi_s.rvalid && ((axi_s.rid >= 4'd8
                            && axi_s.rid <= 4'(8 + NormalMshrs - 1))
                             || (axi_s.rid >= 4'd1 && axi_s.rid <= 4'd3)),
          "an upstream refill response was lost or misrouted");
      if (axi_s.rid >= 4'd8) begin
        slot = int'(axi_s.rid) - 8;
        expected_data = Base + XLEN'(slot * 64);
      end else begin
        slot = NormalMshrs + int'(axi_s.rid) - 1;
        expected_data = axi_s.rid == 4'd2 ? Base + XLEN'((NormalMshrs - 1) * 64 + 3)
                        : axi_s.rid == 4'd3 ? Base + XLEN'(2) : Base + XLEN'(1);
        if (axi_s.rid == 4'd3)
          check(response_seen[NormalMshrs], "same-line secondary FIFO reordered");
      end
      check(
          !response_seen[slot] && axi_s.rdata == expected_data
                && axi_s.rresp == 2'b00 && axi_s.rlast,
          "interleaved refill returned the wrong inner data or ID");
      response_seen[slot] = 1'b1;
      axi_s.rready = 1'b1;
      tick(1);
      axi_s.rready = 1'b0;
    end
    check(response_seen == '1, "primary or secondary L2 responses were lost");
    // The two-row bank install may retry a bank after a higher-priority C
    // write, so drain all contexts without assuming a fixed latency.
    for (
        int cycle = 0;
        cycle < 100 && (dut.ms_busy || dut.cache_install || dut.boom_bank_line_busy);
        cycle++
    )
    tick(1);
    check(!dut.ms_busy && !dut.cache_install && !dut.boom_bank_line_busy,
          "completed MSHRs were not retired");
    send_l2_ar(Base + XLEN'((NormalMshrs - 1) * 64), 4'd4);
    check(dut.dir_result_clients, "D-side secondary ownership was not installed");
    for (int cycle = 0; cycle < 10 && !axi_s.rvalid; cycle++) tick(1);
    check(axi_s.rvalid && axi_s.rid == 4'd4 && !axi_m.arvalid,
          "secondary-owned line was not a local hit");
    axi_s.rready = 1'b1;
    tick(1);
    axi_s.rready = 1'b0;

    // A failed outer fill must report the same error to every queued
    // secondary, release its slot, and leave the line absent from the cache.
    send_l2_ar(Base + XLEN'(6 * 64), 4'd5);
    begin
      logic [IdW-1:0] failed_outer_id;
      logic [XLEN-1:0] failed_outer_addr;
      logic [7:0] failed_outer_len;
      accept_l2_downstream_ar(failed_outer_id, failed_outer_addr, failed_outer_len);
      send_l2_ar(Base + XLEN'(6 * 64 + XLEN / 8), 4'd6);
      send_l2_ar(Base + XLEN'(6 * 64 + 2 * XLEN / 8), 4'd7);
      for (int beat = 0; beat < LineBeats; beat++)
      return_l2_downstream_r(failed_outer_id, Base + XLEN'(6 * 64 + beat), beat == LineBeats - 1,
                             beat == 0 ? 2'b10 : 2'b00);
      for (int count = 0; count < 3; count++) begin
        for (int cycle = 0; cycle < 100 && !axi_s.rvalid; cycle++) tick(1);
        check(axi_s.rvalid && axi_s.rid == 4'(5 + count) && axi_s.rresp == 2'b10 && axi_s.rlast,
              "failed refill did not report an error to its primary and secondaries");
        axi_s.rready = 1'b1;
        tick(1);
        axi_s.rready = 1'b0;
      end
      for (int cycle = 0; cycle < 20 && dut.ms_busy; cycle++) tick(1);
      send_l2_ar(Base + XLEN'(6 * 64), 4'd9);
      accept_l2_downstream_ar(failed_outer_id, failed_outer_addr, failed_outer_len);
      check(failed_outer_addr == Base + XLEN'(6 * 64),
            "failed primary or secondary installed a corrupted line");
    end
    $display("PASS: RV%0d %0d concurrent L2 clean misses and same-line secondaries", XLEN,
             NormalMshrs);
    $finish;
  end
endmodule
