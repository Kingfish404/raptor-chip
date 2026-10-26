`include "rapt.svh"
`include "rapt_soc_if.svh"

// Right-aligned internal store masks must become legal AXI byte lanes even
// when an unaligned narrow store straddles its nominal size boundary.
module tb_axi_write_lanes;
  localparam int XLEN = `RAPT_XLEN;
  localparam int Bytes = XLEN / 8;
  localparam int MaxSize = $clog2(Bytes);
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  mem_link_if #(
      .XLEN(XLEN),
      .ID_W(4)
  ) mem ();
  axi4_if #(
      .XLEN(XLEN),
      .ID_W(4)
  ) axi ();
  rapt_axi_master #(
      .XLEN(XLEN)
  ) dut (
      .clock,
      .reset,
      .mem,
      .axi
  );
  int cases = 0;

  task automatic tick;
    @(posedge clock);
    #1;
  endtask
  task automatic check(input bit ok, input string why);
    if (!ok) $fatal(1, "%s (case %0d)", why, cases);
  endtask

  task automatic write_case(input int offset, input int mask, input int size, input int ordering,
                            input bit zero_line = 0);
    logic [XLEN-1:0] address, data, expected_data;
    logic [Bytes-1:0] expected_mask;
    bit aw_seen;
    int w_seen, beats, expected_size, last_lane, limit_lane;
    address = XLEN'('h80000040 + offset);
    data = XLEN'('ha47f5a3510ebc6a1);
    expected_mask = zero_line ? '1 : Bytes'(mask << offset);
    expected_data = zero_line ? '0 : data << (offset*8);
    beats = zero_line ? 64/Bytes : 1;
    expected_size = zero_line ? MaxSize : size;
    // Independent arithmetic oracle: choose the first natural size window
    // whose exclusive upper bound contains every asserted physical lane.
    last_lane = offset;
    for (int lane = 0; lane < Bytes; lane++) if (expected_mask[lane]) last_lane = lane;
    if (!zero_line)
      while ((((offset / (1 << expected_size)) + 1) * (1 << expected_size)) <= last_lane)
        expected_size++;
    check(expected_size <= MaxSize, "test generated a cross-word request");
    check(mem.wr_req_ready, "previous write not drained");
    mem.wr_req_valid = 1;
    mem.wr_req_id = 3;
    mem.wr_req_addr = address;
    mem.wr_req_size = 3'(size);
    mem.wr_req_strb = Bytes'(mask);
    mem.wr_req_data = data;
    mem.wr_req_zero = zero_line;
    mem.wr_req_pbmt = 0;
    tick();
    mem.wr_req_valid = 0;
    // Accepted payload must not follow the next request while AW/W stall.
    mem.wr_req_addr = '1;
    mem.wr_req_size = 0;
    mem.wr_req_strb = 0;
    mem.wr_req_data = ~data;
    aw_seen = 0;
    w_seen = 0;
    for (int cycle = 0; !aw_seen || w_seen < beats; cycle++) begin
      check(cycle < 100, "AW/W stalled indefinitely");
      @(negedge clock);
      axi.awready = cycle >= (ordering == 1 ? 4 : 1);
      axi.wready = cycle >= (ordering == 0 ? 4 : 1) && cycle%3 != 0;
      #1;
      check(!mem.wr_req_ready, "accepted a second outstanding write");
      if (axi.awvalid) begin
        check(!aw_seen, "duplicated AW");
        check(axi.awaddr == (zero_line ? address & ~XLEN'(63) : address), "AWADDR changed");
        check(axi.awsize == 3'(expected_size), "AWSIZE does not minimally cover lanes");
        check(axi.awid == 3 && axi.awlen == 8'(beats - 1), "AW identity/length changed");
        check(axi.awburst == (zero_line ? 1 : 0), "AWBURST changed");
        if (axi.awready) aw_seen = 1;
      end
      if (axi.wvalid) begin
        check(axi.wdata == expected_data && axi.wstrb == expected_mask, "write payload changed");
        check(axi.wlast == (w_seen == beats - 1), "WLAST changed");
        limit_lane = zero_line ? Bytes
            : ((offset / (1 << int'(axi.awsize))) + 1) * (1 << int'(axi.awsize));
        for (int lane = 0; lane < Bytes; lane++)
        if (axi.wstrb[lane])
          check(zero_line || (lane >= offset && lane < limit_lane),
                "WSTRB outside the declared AXI transfer span");
        if (axi.wready) w_seen++;
      end
      tick();
    end
    axi.awready = 0;
    axi.wready = 0;
    axi.bid = 3;
    axi.bresp = ordering == 2 ? 2 : 0;
    axi.bvalid = 1;
    mem.wr_rsp_ready = 0;
    repeat (2) begin
      #1;
      check(mem.wr_rsp_valid && !axi.bready, "B backpressure changed");
      check(mem.wr_rsp_id == 3 && mem.wr_rsp_error == (ordering == 2), "B identity/error lost");
      tick();
    end
    mem.wr_rsp_ready = 1;
    tick();
    axi.bvalid = 0;
    check(mem.wr_req_ready, "B handshake did not release write capacity");
    cases++;
  endtask

  initial begin
    mem.rd_req_valid=0;
    mem.rd_req_id=0;
    mem.rd_req_addr=0;
    mem.rd_req_size=0;
    mem.rd_req_len=0;
    mem.rd_req_burst=0;
    mem.rd_req_pbmt=0;
    mem.rd_req_noallocate=0;
    mem.rd_rsp_ready=1;
    mem.wr_req_valid=0;
    mem.wr_req_id=0;
    mem.wr_req_addr=0;
    mem.wr_req_size=0;
    mem.wr_req_strb=0;
    mem.wr_req_data=0;
    mem.wr_req_zero=0;
    mem.wr_req_pbmt=0;
    mem.wr_rsp_ready=1;
    axi.arready=1;
    axi.rvalid=0;
    axi.rid=0;
    axi.rdata=0;
    axi.rresp=0;
    axi.rlast=0;
    axi.awready=0;
    axi.wready=0;
    axi.bvalid=0;
    axi.bid=0;
    axi.bresp=0;
    repeat (3) tick();
    reset = 0;
    tick();
    for (int offset = 0; offset < Bytes; offset++)
    for (int mask = 1; mask < (1 << (Bytes - offset)); mask++)
    for (int ordering = 0; ordering < 3; ordering++)
    write_case(offset, mask, mask == 1 ? 0 : mask == 3 ? 1 : mask < 16 ? 2 : 3, ordering);
    // Requested full-width sparse writes must never be narrowed. Zero-line
    // bursts keep their address alignment, beat count, all-byte strobes and B.
    for (int ordering = 0; ordering < 3; ordering++) begin
      write_case(0, 1, MaxSize, ordering);
      write_case(3, 0, 0, ordering, 1);
    end
    $display("PASS: AXI write lanes XLEN=%0d cases=%0d", XLEN, cases);
    $finish;
  end
  initial begin
    #1000000;
    $fatal(1, "write-lane watchdog");
  end
endmodule
