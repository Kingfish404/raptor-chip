`include "rapt.svh"
`include "rapt_soc_if.svh"

module tb_l2_cross_line_put;
  localparam int XLEN = `RAPT_XLEN;
  localparam int IdW = 4;
  localparam int LineBeats = 1 << `RAPT_L2_LINE_LEN;
  localparam logic [XLEN-1:0] LineAddr = XLEN'('h80000100);
  localparam logic [XLEN-1:0] BurstAddr = LineAddr + XLEN'((LineBeats - 1) * (XLEN / 8));
  localparam logic [XLEN-1:0] ErrorAddr = XLEN'('h80000300);
  localparam logic [XLEN-1:0] FullAddr = XLEN'('h80000400);
  localparam logic [XLEN-1:0] LongAddr = XLEN'('h80000600);
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

  task automatic send_burst_beat(input logic [XLEN-1:0] data, input bit last,
                                 input logic [XLEN/8-1:0] mask = '1);
    bit accepted;
    axi_s.wdata = data;
    axi_s.wstrb = mask;
    axi_s.wlast = last;
    axi_s.wvalid = 1;
    accepted = 0;
    for (int cycle = 0; cycle < 128 && !accepted; cycle++) begin
      @(posedge clock);
      accepted = axi_s.wready;
    end
    check(accepted, "cross-line W stalled");
    #1;
    axi_s.wvalid = 0;
  endtask

  task automatic read_resident(input logic [XLEN-1:0] addr, input logic [XLEN-1:0] expected);
    axi_s.rready = 0;
    send_l2_ar(addr, 4'h3);
    for (int cycle = 0; cycle < 128 && !axi_s.rvalid && !axi_m.arvalid; cycle++) tick(1);
    check(axi_s.rvalid && !axi_m.arvalid && axi_s.rdata == expected && axi_s.rresp == 2'b00,
          $sformatf("cross-line readback at %h got %h expected %h", addr, axi_s.rdata, expected));
    axi_s.rready = 1;
    tick(1);
    axi_s.rready = 0;
  endtask

  initial begin
    logic [IdW-1:0] outer_id;
    logic [XLEN-1:0] outer_addr;
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

    // A cacheable two-beat INCR crosses from a resident line into a miss.
    // It commits the first line, refills the second, and returns one B.
    axi_s.awaddr = BurstAddr;
    axi_s.awid = 4'h2;
    axi_s.awlen = 8'd1;
    axi_s.awsize = 3'($clog2(XLEN / 8));
    axi_s.awburst = 2'b01;
    axi_s.awcache = 4'hf;
    axi_s.awvalid = 1;
    accepted = 0;
    for (int cycle = 0; cycle < 128 && !accepted; cycle++) begin
      @(posedge clock);
      accepted = axi_s.awready;
    end
    check(accepted && dut.burst_alloc_needs_read, "cross-line INCR did not allocate locally");
    #1;
    axi_s.awvalid = 0;
    send_burst_beat(XLEN'('haa), 0);
    send_burst_beat(XLEN'('hbb), 1);
    check(!axi_m.awvalid && !axi_m.wvalid, "allocated cross-line Put was forwarded");
    accept_l2_downstream_ar(outer_id, outer_addr, outer_len);
    check(outer_addr == LineAddr + XLEN'(64) && outer_len == 8'(LineBeats - 1),
          "second-line refill shape");
    for (int beat = 0; beat < LineBeats; beat++)
    return_l2_downstream_r(outer_id, XLEN'('h200 + beat), beat == LineBeats - 1);
    for (int cycle = 0; cycle < 128 && !axi_s.bvalid; cycle++) tick(1);
    check(axi_s.bvalid && axi_s.bid == 4'h2 && axi_s.bresp == 2'b00,
          "cross-line INCR did not return one local B");
    axi_s.bready = 1;
    tick(1);
    axi_s.bready = 0;
    read_resident(BurstAddr, XLEN'('haa));
    read_resident(LineAddr + XLEN'(64), XLEN'('hbb));

    // An error in the second line does not roll back the already committed
    // first line, and the failed second line must remain uncached.
    axi_s.awaddr = LineAddr + XLEN'(64 + (LineBeats - 1) * (XLEN / 8));
    axi_s.awid = 4'ha;
    axi_s.awlen = 8'd1;
    axi_s.awsize = 3'($clog2(XLEN / 8));
    axi_s.awburst = 2'b01;
    axi_s.awvalid = 1;
    accepted = 0;
    for (int cycle = 0; cycle < 128 && !accepted; cycle++) begin
      @(posedge clock);
      accepted = axi_s.awready;
    end
    check(accepted && dut.burst_alloc_needs_read, "second-segment error Put did not allocate");
    #1;
    axi_s.awvalid = 0;
    send_burst_beat(XLEN'('hdd), 0);
    send_burst_beat(XLEN'('hee), 1);
    accept_l2_downstream_ar(outer_id, outer_addr, outer_len);
    check(outer_addr == LineAddr + XLEN'(128), "failed second-line refill address");
    for (int beat = 0; beat < LineBeats; beat++)
    return_l2_downstream_r(outer_id, XLEN'('h400 + beat), beat == LineBeats - 1,
                           beat == LineBeats - 1 ? 2'b10 : 2'b00);
    for (int cycle = 0; cycle < 128 && !axi_s.bvalid; cycle++) tick(1);
    check(axi_s.bvalid && axi_s.bid == 4'ha && axi_s.bresp == 2'b10,
          "second-segment error response");
    axi_s.bready = 1;
    tick(1);
    axi_s.bready = 0;
    read_resident(LineAddr + XLEN'(64 + (LineBeats - 1) * (XLEN / 8)), XLEN'('hdd));
    axi_s.rready = 1;
    send_l2_ar(LineAddr + XLEN'(128), 4'hb);
    accept_l2_downstream_ar(outer_id, outer_addr, outer_len);
    check(outer_addr == LineAddr + XLEN'(128), "failed second line was installed");
    for (int beat = 0; beat < LineBeats; beat++)
    return_l2_downstream_r(outer_id, XLEN'('h400 + beat), beat == LineBeats - 1);
    for (int cycle = 0; cycle < 128 && dut.ms_busy; cycle++) tick(1);
    check(!dut.ms_busy, "post-error line refill did not retire");

    // Two byte writes straddle the boundary but touch different SRAM words.
    axi_s.awaddr = LineAddr + XLEN'(63);
    axi_s.awid = 4'h9;
    axi_s.awlen = 8'd1;
    axi_s.awsize = 3'd0;
    axi_s.awburst = 2'b01;
    axi_s.awvalid = 1;
    accepted = 0;
    for (int cycle = 0; cycle < 128 && !accepted; cycle++) begin
      @(posedge clock);
      accepted = axi_s.awready;
    end
    check(accepted && dut.burst_alloc_needs_read, "narrow cross-line Put did not allocate");
    #1;
    axi_s.awvalid = 0;
    send_burst_beat(XLEN'('h5a) << (8 * (XLEN / 8 - 1)), 0, (XLEN / 8)'(1 << (XLEN / 8 - 1)));
    send_burst_beat(XLEN'('h6b), 1, (XLEN / 8)'(1));
    for (int cycle = 0; cycle < 128 && !axi_s.bvalid; cycle++) tick(1);
    check(
        axi_s.bvalid && axi_s.bid == 4'h9 && axi_s.bresp == 2'b00
              && !axi_m.awvalid && !axi_m.arvalid,
        "narrow cross-line Put response");
    axi_s.bready = 1;
    tick(1);
    axi_s.bready = 0;
    read_resident(BurstAddr, XLEN'('haa) | (XLEN'('h5a) << (8 * (XLEN / 8 - 1))));
    read_resident(LineAddr + XLEN'(64), XLEN'('h6b));

    // Two complete lines need neither old-data refill. The second segment
    // starts after the first line's SourceD beat writes and directory commit.
    axi_s.awaddr = FullAddr;
    axi_s.awid = 4'h7;
    axi_s.awlen = 8'(2 * LineBeats - 1);
    axi_s.awsize = 3'($clog2(XLEN / 8));
    axi_s.awburst = 2'b01;
    axi_s.awvalid = 1;
    accepted = 0;
    for (int cycle = 0; cycle < 128 && !accepted; cycle++) begin
      @(posedge clock);
      accepted = axi_s.awready;
    end
    check(accepted && dut.burst_alloc_needs_read, "two-line full Put did not allocate locally");
    #1;
    axi_s.awvalid = 0;
    for (int beat = 0; beat < 2 * LineBeats; beat++)
    send_burst_beat(XLEN'('h500 + beat), beat == 2 * LineBeats - 1);
    for (int cycle = 0; cycle < 128 && !axi_s.bvalid; cycle++) begin
      check(!axi_m.awvalid && !axi_m.arvalid, "two-line full Put fetched old data");
      tick(1);
    end
    check(axi_s.bvalid && axi_s.bid == 4'h7 && axi_s.bresp == 2'b00, "two-line full Put response");
    axi_s.bready = 1;
    tick(1);
    axi_s.bready = 0;
    read_resident(FullAddr, XLEN'('h500));
    read_resident(FullAddr + XLEN'((2 * LineBeats - 1) * (XLEN / 8)),
                  XLEN'('h500 + 2 * LineBeats - 1));

    // The 40-beat shared Put pool must make progress on a longer burst.
    axi_s.awaddr = LongAddr;
    axi_s.awid = 4'h8;
    axi_s.awlen = 8'd47;
    axi_s.awsize = 3'($clog2(XLEN / 8));
    axi_s.awburst = 2'b01;
    axi_s.awvalid = 1;
    accepted = 0;
    for (int cycle = 0; cycle < 128 && !accepted; cycle++) begin
      @(posedge clock);
      accepted = axi_s.awready;
    end
    check(accepted && dut.burst_alloc_needs_read, "long Put did not allocate locally");
    #1;
    axi_s.awvalid = 0;
    for (int beat = 0; beat < 48; beat++) send_burst_beat(XLEN'('h900 + beat), beat == 47);
    for (int cycle = 0; cycle < 256 && !axi_s.bvalid; cycle++) begin
      check(!axi_m.awvalid && !axi_m.arvalid, "long full Put fetched old data");
      tick(1);
    end
    check(axi_s.bvalid && axi_s.bid == 4'h8 && axi_s.bresp == 2'b00, "long Put response");
    axi_s.bready = 1;
    tick(1);
    axi_s.bready = 0;
    read_resident(LongAddr, XLEN'('h900));
    read_resident(LongAddr + XLEN'(47 * (XLEN / 8)), XLEN'('h92f));

    if (XLEN == 64) begin
      // Sixteen 8-byte WRAP beats visit line A, line B, then line A again.
      axi_s.awaddr = BurstAddr;
      axi_s.awid = 4'h4;
      axi_s.awlen = 8'd15;
      axi_s.awsize = 3'($clog2(XLEN / 8));
      axi_s.awburst = 2'b10;
      axi_s.awvalid = 1;
      accepted = 0;
      for (int cycle = 0; cycle < 128 && !accepted; cycle++) begin
        @(posedge clock);
        accepted = axi_s.awready;
      end
      check(accepted && dut.burst_alloc_needs_read, "cross-line WRAP did not allocate locally");
      #1;
      axi_s.awvalid = 0;
      for (int beat = 0; beat < 16; beat++) send_burst_beat(XLEN'('h700 + beat), beat == 15);
      for (int cycle = 0; cycle < 128 && !axi_s.bvalid; cycle++) begin
        check(!axi_m.awvalid && !axi_m.arvalid, "resident WRAP reached outer memory");
        tick(1);
      end
      check(axi_s.bvalid && axi_s.bid == 4'h4 && axi_s.bresp == 2'b00, "cross-line WRAP response");
      axi_s.bready = 1;
      tick(1);
      axi_s.bready = 0;
      read_resident(BurstAddr, XLEN'('h700));
      read_resident(LineAddr + XLEN'(64), XLEN'('h701));
      read_resident(LineAddr, XLEN'('h709));
    end

    // A failed first segment must drain all remaining W beats before B.
    axi_s.awaddr = ErrorAddr + XLEN'((LineBeats - 1) * (XLEN / 8));
    axi_s.awid = 4'h5;
    axi_s.awlen = 8'd1;
    axi_s.awsize = 3'($clog2(XLEN / 8));
    axi_s.awburst = 2'b01;
    axi_s.awvalid = 1;
    accepted = 0;
    for (int cycle = 0; cycle < 128 && !accepted; cycle++) begin
      @(posedge clock);
      accepted = axi_s.awready;
    end
    check(accepted && dut.burst_alloc_needs_read, "failing cross-line Put did not allocate");
    #1;
    axi_s.awvalid = 0;
    send_burst_beat(XLEN'('hca), 0);
    accept_l2_downstream_ar(outer_id, outer_addr, outer_len);
    check(outer_addr == ErrorAddr, "failing segment refill address");
    for (int beat = 0; beat < LineBeats; beat++)
    return_l2_downstream_r(outer_id, XLEN'('h300 + beat), beat == LineBeats - 1,
                           beat == LineBeats - 1 ? 2'b10 : 2'b00);
    tick(3);
    check(!axi_s.bvalid, "B escaped before WLAST after segment failure");
    send_burst_beat(XLEN'('hcb), 1);
    for (int cycle = 0; cycle < 128 && !axi_s.bvalid; cycle++) tick(1);
    check(axi_s.bvalid && axi_s.bid == 4'h5 && axi_s.bresp == 2'b10, "failed segment response");
    axi_s.bready = 1;
    tick(1);
    axi_s.bready = 0;
    send_l2_ar(ErrorAddr + XLEN'((LineBeats - 1) * (XLEN / 8)), 4'h6);
    accept_l2_downstream_ar(outer_id, outer_addr, outer_len);
    check(outer_addr == ErrorAddr, "failed segment left speculative line installed");
    $display("PASS: segmented cross-line INCR/WRAP Put and error drain XLEN=%0d", XLEN);
    $finish;
  end
endmodule
