`include "rapt.svh"
`include "rapt_soc_if.svh"
module tb_l2_response_error;
  localparam int XLEN = `RAPT_XLEN;
  localparam int IdW = 4;
  localparam int LineBeats = 64 / (XLEN / 8);
`ifdef RAPT_TEST_BOOM_L2
  localparam int TestL2Len = `RAPT_L2_LEN;
`else
  localparam int TestL2Len = 2;
`endif
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
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
      .ID_W(IdW),
      .L2_LEN(TestL2Len),
      .L2_LINE_LEN($clog2(LineBeats))
  ) dut (
      .clock(clock),
      .reset(reset),
      .axi_s(axi_s),
      .axi_m(axi_m)
  );
`ifdef RAPT_TEST_BOOM_L2
  int b_lookups = 0;
  int scalar_commits = 0;
  always @(posedge clock) if (!reset && dut.dir_error_lookup_request) b_lookups++;
  always @(posedge clock) begin
    if (!reset && dut.forward_scalar_commit) begin
      scalar_commits++;
      check(dut.g_boom_directory.u_directory.write_dirty,
            "successful forwarded scalar write was not marked dirty");
    end
  end
`endif
  `include "tb_common.svh"
  `include "tb_l2_axi_tasks.svh"

  task automatic fill(input int error_beat, input logic [1:0] response);
    logic [IdW-1:0] id;
    logic [XLEN-1:0] addr;
    logic [7:0] len;
    accept_l2_downstream_ar(id, addr, len);
    check(len == 8'(LineBeats - 1), "miss did not request one cache line");
    for (int beat = 0; beat < LineBeats; beat++) begin
      @(negedge clock);
      axi_m.rid=id;
      axi_m.rdata=XLEN'('h100+beat);
      axi_m.rresp=beat==error_beat?response:2'b00;
      axi_m.rlast=beat==LineBeats-1;
      axi_m.rvalid=1;
      do @(posedge clock); while (!axi_m.rready);
      #1;
      axi_m.rvalid = 0;
    end
  endtask

  task automatic receive_error(input int beats, input logic [1:0] response);
    for (int beat = 0; beat < beats; beat++) begin
      bit seen;
      seen = 0;
      for (int i = 0; i < 80; i++) begin
        @(negedge clock);
        if (axi_s.rvalid) begin
          seen = 1;
          break;
        end
      end
      check(seen, "errored cache fill did not complete upstream request");
      repeat (4) begin
        check(
            axi_s.rvalid && axi_s.rid==4'h5 && axi_s.rresp==response &&
              axi_s.rlast==(beat==beats-1),
            "error response changed under backpressure");
        @(negedge clock);
      end
      axi_s.rready = 1;
      @(posedge clock);
      #1;
      axi_s.rready = 0;
    end
  endtask

  initial begin
    init_l2_axi(1);
    tick(4);
    reset = 0;
    for (int warmup = 0; warmup < (1 << TestL2Len) + 64 && !axi_s.awready; warmup++) tick(1);
    check(axi_s.awready, "L2 directory reset wipe timed out");
    tick(2);
    // Queue the next request while an early-restarted miss is still filling.
    // Its SRAM lookup must not coincide with the preceding line install.
    send_l2_ar_len(XLEN'('h80000100), 4'h5, 0, 1);
    fork
      fill(-1, 0);
      begin
        for (int i = 0; i < 80 && !axi_s.rvalid; i++) tick(1);
        check(axi_s.rvalid && axi_s.rdata == XLEN'('h100), "early restart data");
        axi_s.rready = 1;
        tick(1);
        send_l2_ar_len(XLEN'('h80000100), 4'h5, 0, 1);
        for (int i = 0; i < 80 && !axi_s.rvalid; i++) tick(1);
        check(axi_s.rvalid && axi_s.rdata == XLEN'('h100),
              "request after early restart read stale SRAM data");
        tick(1);
      end
    join
    tick(2);
    // An error before the requested word must complete with SLVERR, not retry
    // forever. Error on the final refill beat must be sticky as well.
    for (int mode = 0; mode < 2; mode++) begin
      axi_s.rready = 0;
      send_l2_ar_len(XLEN'('h80000000 + (LineBeats - 1) * (XLEN / 8)), 4'h5, 0, 1);
      fill(mode == 0 ? 0 : LineBeats - 1, mode == 0 ? 2'b10 : 2'b11);
      receive_error(1, mode == 0 ? 2'b10 : 2'b11);
      tick(3);
      check(!axi_m.arvalid, "failed read was retried after the upstream error");
    end
    // A burst must return its complete remaining length even on an error.
    send_l2_ar_len(XLEN'('h80000000), 4'h5, 2, 1);
    fill(1, 2'b10);
    receive_error(3, 2'b10);
    tick(3);
    // None of the failed fills can install a line. A successful retry refills
    // from the external bus and subsequently serves the requested value.
    send_l2_ar_len(XLEN'('h80000000), 4'h5, 0, 1);
    fill(-1, 0);
    for (int i = 0; i < 80 && !axi_s.rvalid; i++) tick(1);
    check(axi_s.rvalid && axi_s.rresp == 0 && axi_s.rdata == XLEN'('h100),
          "successful retry returned wrong data");
    axi_s.rready = 1;
    tick(2);
    // Cached bursts advance by ARSIZE, not the XLEN-wide SRAM bank width.
    for (int burst = 0; burst < 2; burst++) begin
      for (int size = 0; size <= $clog2(XLEN / 8); size++) begin
        @(negedge clock);
        axi_s.rready=0;
        axi_s.araddr=XLEN'('h80000000);
        axi_s.arid=5;
        axi_s.arlen=2;
        axi_s.arsize=3'(size);
        axi_s.arburst=2'(burst);
        axi_s.arvalid=1;
        do @(posedge clock); while (!axi_s.arready);
        #1;
        axi_s.arvalid = 0;
        for (int beat = 0; beat < 3; beat++) begin
          int word_index;
          word_index = burst == 0 ? 0 : ((beat << size) / (XLEN / 8));
          for (int i = 0; i < 80 && !axi_s.rvalid; i++) tick(1);
          check(
              axi_s.rvalid && axi_s.rresp==0 && axi_s.rdata==XLEN'('h100+word_index)
                && axi_s.rlast==(beat==2),
              "cached burst ignored ARSIZE or ARBURST");
          tick(2);
          axi_s.rready = 1;
          tick(1);
          axi_s.rready = 0;
        end
        tick(2);
      end
    end
    begin
      logic [IdW-1:0] id;
      logic [XLEN-1:0] addr, data;
      logic [XLEN/8-1:0] strb;
      logic last;
`ifdef RAPT_TEST_BOOM_L2
      // Keep an older dirty word in the line. Failed forwarded writes must
      // preserve both this word and the original value at their own address.
      axi_s.bready = 0;
      send_l2_aw(XLEN'('h80000000 + 3 * (XLEN / 8)), 4'h7, 4'hf);
      send_l2_w_full(XLEN'('hfeed));
      for (int i = 0; i < 80 && !axi_s.bvalid; i++) tick(1);
      check(axi_s.bvalid && axi_s.bresp == 2'b00, "older dirty write did not complete");
      axi_s.bready = 1;
      tick(1);
`endif
      // A non-bufferable cacheable write waits for the real outer B.
      axi_s.bready = 0;
      send_l2_aw(XLEN'('h80000000), 4'h6, 4'he);
      send_l2_w_full(XLEN'('hdeadbeef));
      tick(3);
      check(!axi_s.bvalid, "non-bufferable write completed before downstream B");
      accept_l2_downstream_write(id, addr, data, strb, last);
      return_l2_downstream_b(id, 2'b10);
`ifdef RAPT_TEST_BOOM_L2
      check(b_lookups == 0, "failed forwarded write changed the directory");
      check(scalar_commits == 0, "failed forwarded write changed the cache bank");
`endif
      check(axi_s.bvalid && axi_s.bresp == 2'b10, "write error was not forwarded");
      axi_s.bready = 1;
      tick(2);
      axi_s.rready = 0;
      send_l2_ar_len(XLEN'('h80000000), 4'h5, 0, 1);
`ifdef RAPT_TEST_BOOM_L2
      for (int i = 0; i < 80 && !axi_s.rvalid; i++) tick(1);
      check(axi_s.rvalid && axi_s.rresp == 0 && axi_s.rdata == XLEN'('h100) && !axi_m.arvalid,
            "failed forwarded write lost the original cached word");
      axi_s.rready = 1;
      tick(2);
      axi_s.rready = 0;
      send_l2_ar_len(XLEN'('h80000000 + 3 * (XLEN / 8)), 4'h5, 0, 1);
      for (int i = 0; i < 80 && !axi_s.rvalid; i++) tick(1);
      check(axi_s.rvalid && axi_s.rdata == XLEN'('hfeed) && !axi_m.arvalid,
            "failed forwarded write lost older dirty data");
`else
      fill(-1, 0);
      for (int i = 0; i < 80 && !axi_s.rvalid; i++) tick(1);
      check(axi_s.rvalid && axi_s.rresp == 0 && axi_s.rdata == XLEN'('h100),
            "failed cache-hit write poisoned a later read");
`endif
      axi_s.rready = 1;
      tick(2);
`ifdef RAPT_TEST_BOOM_L2
      axi_s.bready = 0;
      send_l2_aw(XLEN'('h80000000), 4'h8, 4'he);
      send_l2_w(XLEN'('h55), (XLEN / 8)'(1));
      accept_l2_downstream_write(id, addr, data, strb, last);
      check(strb == (XLEN / 8)'(1), "forwarded byte mask changed");
      return_l2_downstream_b(id, 2'b00);
      check(b_lookups != 0, "successful forwarded write skipped its directory lookup");
      check(scalar_commits == 1, "successful forwarded write did not commit exactly once");
      check(axi_s.bvalid && axi_s.bresp == 2'b00, "successful forwarded B missing");
      axi_s.bready = 1;
      tick(2);
      axi_s.rready = 0;
      send_l2_ar_len(XLEN'('h80000000), 4'h5, 0, 1);
      for (int i = 0; i < 80 && !axi_s.rvalid; i++) tick(1);
      check(axi_s.rvalid && axi_s.rdata == XLEN'('h155) && !axi_m.arvalid,
            "successful forwarded write did not update the resident line");
      axi_s.rready = 1;
      tick(2);
`endif
    end
    $display("PASS: L2 refill errors, burst/backpressure, retry and forwarded scalar B RV%0d",
             XLEN);
    $finish;
  end
  initial begin
    #100000;
    $fatal(1, "L2 error test watchdog");
  end
endmodule
