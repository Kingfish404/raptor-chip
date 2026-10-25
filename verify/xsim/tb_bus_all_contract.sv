// ---- tb_bus_buffered_writeback ----
`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_soc_if.svh"

module tb_bus_buffered_writeback;
  localparam int XLEN  = `RAPT_XLEN;
  localparam int Words = `RAPT_CACHE_LINE_BYTES / (XLEN / 8);
  logic clock = 0, reset = 1;
  always #5 clock = ~clock;
  mem_link_if #(.XLEN(XLEN)) mem ();
  l1i_bus_if #(.XLEN(XLEN)) l1i_bus ();
  l1d_bus_if #(.XLEN(XLEN)) l1d_bus ();
  csr_bcast_if #(.XLEN(XLEN)) csr_bcast ();
  cmu_bcast_if #(.XLEN(XLEN)) cmu_bcast ();
  logic capture_valid = 0, capture_ready, busy, error;
  logic [XLEN-1:0] capture_addr = 0, write_addr, write_data;
  logic [Words-1:0] capture_dirty = 0;
  logic [Words*XLEN-1:0] capture_data = 0;
  logic write_valid, read_match, miss_match;
  logic mmio = 0;
  integer accepted = 0;
  integer accepted_before;

  rapt_bus #(
      .XLEN(XLEN),
      .PostedWrites(4),
      .PostedAckDelay(3)
  ) bus_dut (
      .clock,
      .reset,
      .mem,
      .l1i_bus,
      .l1d_bus,
      .csr_bcast,
      .cmu_bcast,
      .coherent_request(),
      .coherent_write(),
      .rd_req_cacheable()
  );
  rapt_l1d_writeback #(
      .Xlen(XLEN),
      .LineWords(Words),
      .Entries(2),
      .Pipelined(1)
  ) wb (
      .clock,
      .reset,
      .capture_valid,
      .capture_ready,
      .capture_addr,
      .capture_dirty,
      .capture_data,
      .busy,
      .error,
      .retry(1'b0),
      .write_valid,
      .write_addr,
      .write_data,
      .write_accept(l1d_bus.waccept),
      .write_ready(l1d_bus.wready),
      .write_error(l1d_bus.werr),
      .read_addr(XLEN'('h80000000)),
      .miss_addr(XLEN'('h80001000)),
      .read_match,
      .miss_match
  );
  assign l1d_bus.awvalid = mmio || write_valid;
  assign l1d_bus.wvalid = mmio || write_valid;
  assign l1d_bus.awaddr = mmio ? XLEN'('h10000000) : write_addr;
  assign l1d_bus.wdata = mmio ? XLEN'('h5a) : write_data;
  assign l1d_bus.wstrb = XLEN == 64 ? 8'hff : 8'h0f;
  assign l1d_bus.wzero = 0;
  assign l1d_bus.wpbmt = 0;
  assign l1d_bus.wpost = !mmio;
  assign l1d_bus.wbuffered = !mmio;
  assign l1d_bus.wmore = 0;
  always @(posedge clock)
    if (!reset && mem.wr_req_valid && mem.wr_req_ready) begin
      accepted <= accepted + 1;
      if (!mmio && mem.wr_req_data != XLEN'('h12340000) + (mem.wr_req_addr & XLEN'('h1fff)))
        $fatal(1, "write payload/address changed before acceptance");
    end

  task automatic tick(input int n = 1);
    repeat (n) @(posedge clock);
    #1;
  endtask
  task automatic check(input bit condition, input string message);
    if (!condition) $fatal(1, "%s", message);
  endtask
  task automatic capture(input logic [XLEN-1:0] address);
    check(capture_ready, "capture not ready");
    capture_addr = address;
    capture_dirty = Words'(3);
    for (int i = 0; i < Words; i++)
      capture_data[i*XLEN+:XLEN] = XLEN'('h12340000) + (address & XLEN'('h1fff)) + XLEN'(i*XLEN/8);
    capture_valid = 1;
    tick();
    capture_valid = 0;
  endtask
  task automatic reply(input bit failed = 0);
    mem.wr_rsp_valid = 1;
    mem.wr_rsp_error = failed;
    #1;
    check(l1d_bus.wready && l1d_bus.werr == failed, "buffered B owner/error lost");
    check(!l1d_bus.posted_error, "buffered error routed to write-through owner");
    tick();
    mem.wr_rsp_valid = 0;
    mem.wr_rsp_error = 0;
  endtask
  task automatic request_read(input logic [XLEN-1:0] address);
    l1d_bus.araddr = address;
    l1d_bus.arvalid = 1;
    #1;
    check(l1d_bus.rready, "read capture unavailable");
    tick();
    l1d_bus.arvalid = 0;
  endtask
  task automatic finish_read;
    tick();
    mem.rd_rsp_valid = 1;
    tick();
    mem.rd_rsp_valid = 0;
  endtask

  initial begin
    mem.wr_req_ready = 0;
    mem.wr_rsp_valid = 0;
    mem.wr_rsp_id = 2;
    mem.wr_rsp_error = 0;
    mem.rd_req_ready = 1;
    mem.rd_rsp_valid = 0;
    mem.rd_rsp_id = 2;
    mem.rd_rsp_last = 1;
    mem.rd_rsp_error = 0;
    mem.rd_rsp_data = 0;
    l1i_bus.arvalid = 0;
    l1i_bus.ar_ptw = 0;
    l1d_bus.arvalid = 0;
    l1d_bus.araddr = 0;
    l1d_bus.ar_mshr = 0;
    l1d_bus.ar_mshr_id = 0;
    l1d_bus.ar_ptw = 0;
    l1d_bus.arlen = 0;
    l1d_bus.noallocate = 0;
    l1d_bus.rpbmt = 0;
    l1d_bus.rstrb = XLEN == 64 ? 8'hff : 8'h0f;
    tick(2);
    reset = 0;
    capture(XLEN'('h80000000));
    capture(XLEN'('h80001000));
    tick(3);
    check(write_addr == XLEN'('h80000000) && !l1d_bus.wready, "stalled payload/ack");
    mem.wr_req_ready = 1;
    tick(5);
    check(accepted == 4, "four buffered writes did not issue before first B");
    check(busy && !write_valid && !capture_ready && read_match && miss_match,
          "issuing lost dirty data or line hazards before B");
    check(!l1d_bus.wready && l1d_bus.posted_busy && !l1d_bus.idle,
          "issue falsely completed a writeback/drain");
    request_read(XLEN'('h80002000));
    check(mem.rd_req_valid, "unrelated read blocked by buffered writes");
    finish_read();
    request_read(XLEN'('h80000000));
    check(!mem.rd_req_valid, "same-line read overtook queued writeback");
    reply();
    check(!mem.rd_req_valid && read_match, "first word B released whole line");
    reply();
    check(mem.rd_req_valid && !read_match && miss_match, "completed line not released");
    finish_read();
    mmio = 1;
    tick(2);
    check(!mem.wr_req_valid && accepted == 4, "MMIO overtook pending DDR writes");
    reply();
    check(!mem.wr_req_valid, "MMIO overtook final DDR write");
    reply();
    check(!busy && mem.wr_req_valid, "final B did not release MMIO");
    tick();
    check(accepted == 5 && !l1d_bus.wready, "MMIO was posted");
    reply();
    mmio = 0;
    tick();
    check(l1d_bus.idle, "drained bus remained busy");

    // Exercise simultaneous issue/retire across both word and entry boundaries.
    mem.wr_req_ready = 0;
    capture(XLEN'('h80000000));
    capture(XLEN'('h80001000));
    mem.wr_req_ready = 1;
    tick();
    repeat (3) begin
      reply();
      check(busy, "simultaneous issue/retire released buffer too early");
    end
    reply();
    check(!busy && accepted == 9, "simultaneous issue/retire lost a request");

    // A previously presented AR retains priority while its acceptance stalls.
    // Falling back to a synchronous WB here would still overtake that AR.
    accepted_before = accepted;
    mem.rd_req_ready = 0;
    request_read(XLEN'('h80000000));
    capture(XLEN'('h80000000));
    repeat (3) begin
      #1;
      check(mem.rd_req_valid && !mem.wr_req_valid && !l1d_bus.waccept,
            "buffered writeback overtook a held same-line AR");
      tick();
    end
    check(accepted == accepted_before, "held AR allowed writeback capture");
    mem.rd_req_ready = 1;
    tick();
    check(mem.wr_req_valid, "accepted AR failed to release writeback");
    finish_read();
    check(accepted == accepted_before + 2, "released writeback did not issue");
    reply();
    reply();
    check(!busy, "held-AR writeback did not drain");

    mem.wr_req_ready = 0;
    capture(XLEN'('h80000000));
    capture(XLEN'('h80001000));
    mem.wr_req_ready = 1;
    tick(5);
    reply();
    reply(1);
    check(error && busy && !write_valid && !capture_ready && read_match && miss_match,
          "late error discarded failing data or released ownership");
    reply();
    reply();
    tick(3);
    check(error && busy && read_match && miss_match && !write_valid,
          "younger B responses cleared fail-stop ownership");
    check(
        wb.dirty[wb.head][1] && wb.data[wb.head][XLEN+:XLEN] == (XLEN'('h12340000) + XLEN'(XLEN / 8)),
        "failing word payload was not retained");
    $display(
        "PASS: buffered writeback credits, B ownership, read/MMIO ordering and fail-stop RV%0d",
        XLEN);
    $finish;
  end
  initial begin
    #10000;
    $fatal(1, "buffered writeback timeout");
  end
endmodule


// ---- tb_bus_read_ownership ----
`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_soc_if.svh"

module tb_bus_read_ownership;
  localparam int XLEN = `RAPT_XLEN;
  localparam int IdW  = 4;

  logic clock = 1'b0;
  logic reset = 1'b1;

  mem_link_if #(
      .XLEN(XLEN),
      .ID_W(IdW)
  ) mem ();
  l1i_bus_if #(.XLEN(XLEN)) l1i_bus ();
  l1d_bus_if #(.XLEN(XLEN)) l1d_bus ();
  csr_bcast_if #(.XLEN(XLEN)) csr_bcast ();
  cmu_bcast_if #(.XLEN(XLEN)) cmu_bcast ();

  rapt_bus #(
      .XLEN(XLEN)
  ) dut (
      .clock,
      .mem,
      .l1i_bus,
      .l1d_bus,
      .csr_bcast,
      .cmu_bcast,
      .reset
  );

  always #5 clock = ~clock;

  `include "tb_common.svh"

  task automatic wait_l1i_ready;
    // Targeted PTW coherence captures the address before allowing acceptance.
    for (int wait_cycle = 0; wait_cycle < 64 && !l1i_bus.rready; wait_cycle++) tick(1);
  endtask

  task automatic submit_l1d(input logic [XLEN-1:0] address, input logic is_ptw);
    begin
      @(negedge clock);
      l1d_bus.araddr = address;
      l1d_bus.ar_ptw = is_ptw;
      l1d_bus.arvalid = 1'b1;
      #1;
      check(l1d_bus.rready, "L1D request was not captured");
      check(!l1d_bus.idle, "incoming D-side request advertised memory idle");
      @(posedge clock);
      @(negedge clock);
      l1d_bus.arvalid = 1'b0;
      #1;
      check(!l1d_bus.idle, "captured D-side request advertised memory idle");
    end
  endtask

  task automatic submit_l1i(input logic [XLEN-1:0] address, input logic is_ptw);
    begin
      @(negedge clock);
      l1i_bus.araddr = address;
      l1i_bus.ar_ptw = is_ptw;
      l1i_bus.rpbmt = {1'b0, is_ptw};
      l1i_bus.noallocate = 0;
      l1i_bus.arvalid = 1'b1;
      #1;
      wait_l1i_ready();
      check(l1i_bus.rready, "L1I request was not captured");
      @(posedge clock);
      @(negedge clock);
      l1i_bus.arvalid = 1'b0;
      @(posedge clock);
    end
  endtask

  task automatic expect_issue(input logic [3:0] expected_id,
                              input logic [XLEN-1:0] expected_address);
    begin
      for (int wait_cycle = 0; wait_cycle < 16; wait_cycle++) begin
        #1;
        if (mem.rd_req_valid) begin
          check(mem.rd_req_id == expected_id, $sformatf(
                "read request ID mismatch got=%0d expected=%0d addr=%08x",
                mem.rd_req_id,
                expected_id,
                mem.rd_req_addr
                ));
          check(mem.rd_req_addr == expected_address, $sformatf(
                "read request address mismatch got=%08x expected=%08x id=%0d",
                mem.rd_req_addr,
                expected_address,
                mem.rd_req_id
                ));
          @(posedge clock);
          return;
        end
        @(negedge clock);
      end
      fail("timed out waiting for downstream read request");
    end
  endtask

  task automatic drive_response(input logic [3:0] response_id, input logic [XLEN-1:0] response_data,
                                input logic response_last = 1'b1);
    begin
      @(negedge clock);
      mem.rd_rsp_id = response_id;
      mem.rd_rsp_data = response_data;
      mem.rd_rsp_last = response_last;
      mem.rd_rsp_valid = 1'b1;
      #1;
    end
  endtask

  task automatic finish_response;
    begin
      @(posedge clock);
      @(negedge clock);
      mem.rd_rsp_valid = 1'b0;
      mem.rd_rsp_last = 1'b0;
    end
  endtask

  initial begin
    mem.rd_req_ready = 1'b0;
    mem.rd_rsp_valid = 1'b0;
    mem.rd_rsp_id = '0;
    mem.rd_rsp_data = '0;
    mem.rd_rsp_last = 1'b0;
    mem.rd_rsp_error = 1'b0;
    mem.wr_req_ready = 1'b1;
    mem.wr_rsp_valid = 1'b0;
    mem.wr_rsp_id = '0;
    mem.wr_rsp_error = 1'b0;

    l1i_bus.arvalid = 1'b0;
    l1i_bus.araddr = '0;
    l1i_bus.arburst = 1'b0;
    l1i_bus.ar_ptw = 1'b0;

    l1d_bus.arvalid = 1'b0;
    l1d_bus.araddr = '0;
    l1d_bus.rstrb = 8'h0f;
    l1d_bus.arlen = 0;
    l1d_bus.noallocate = 0;
    l1d_bus.rpbmt = 2'b00;
    l1d_bus.wpbmt = 2'b00;
    l1d_bus.ar_ptw = 1'b0;
    l1d_bus.ar_mshr = 1'b0;
    l1d_bus.ar_mshr_id = '0;
    l1d_bus.awvalid = 1'b0;
    l1d_bus.awaddr = '0;
    l1d_bus.wvalid = 1'b0;
    l1d_bus.wdata = '0;
    l1d_bus.wstrb = '0;
    l1d_bus.wzero = 0;

    csr_bcast.dmmu_en = 1'b0;
    cmu_bcast.flush_pipe = 1'b0;

    tick(4);
    reset = 1'b0;
    tick(1);
    check(l1d_bus.idle, "reset-empty D-side bus did not advertise idle");

    // A later high-priority L1D request must not replace an L1I request that
    // is already presented while the downstream AR channel is stalled.
    l1i_bus.arburst = 1'b1;
    submit_l1i(XLEN'('h8000_0800), 1'b0);
    l1i_bus.arburst = 1'b0;
    #1;
    check(
        mem.rd_req_valid && mem.rd_req_id == 4'd1
          && mem.rd_req_addr == XLEN'('h8000_0800)
          && mem.rd_req_size == 3'b010
          && mem.rd_req_len == 8'h01
          && mem.rd_req_burst == 2'b01,
        "stalled L1I request was not presented from the AR skid buffer");
    submit_l1d(XLEN'('h8000_0c00), 1'b0);
    #1;
    check(
        mem.rd_req_valid && mem.rd_req_id == 4'd1
          && mem.rd_req_addr == XLEN'('h8000_0800)
          && mem.rd_req_size == 3'b010
          && mem.rd_req_len == 8'h01
          && mem.rd_req_burst == 2'b01,
        "later L1D request replaced stalled L1I AR payload");
    tick(2);
    check(
        mem.rd_req_valid && mem.rd_req_id == 4'd1
          && mem.rd_req_addr == XLEN'('h8000_0800)
          && mem.rd_req_size == 3'b010
          && mem.rd_req_len == 8'h01
          && mem.rd_req_burst == 2'b01,
        "stalled L1I AR payload was not held stable");

    @(negedge clock);
    mem.rd_req_ready = 1'b1;
    expect_issue(4'd1, XLEN'('h8000_0800));
    expect_issue(4'd2, XLEN'('h8000_0c00));
    @(negedge clock);
    mem.rd_req_ready = 1'b0;
    drive_response(4'd2, XLEN'('h0c00_0c00));
    check(l1d_bus.rvalid, "held L1D request response was not routed");
    finish_response();

    // Transferring an L1D request into the skid buffer must not mark it
    // issued before the downstream handshake.  Ignore a matching stale
    // response while AR is stalled, then accept the real response normally.
    submit_l1d(XLEN'('h8000_0e00), 1'b0);
    @(posedge clock);
    #1;
    check(dut.l1d_slot_held && !dut.l1d_slot_issued,
          "L1D holding state was confused with a downstream AR handshake");
    drive_response(4'd2, XLEN'('hdead_0002));
    mem.rd_rsp_error = 1'b1;
    #1;
    check(!l1d_bus.ptw_rerr && !l1d_bus.rerr, "stale error reached an unissued L1D slot");
    check(!l1d_bus.rvalid && !l1d_bus.rlast,
          "unissued L1D slot accepted a stale matching-ID response");
    finish_response();
    check(dut.l1d_slot_busy && dut.l1d_slot_held && !dut.l1d_slot_issued,
          "stale response released the unissued L1D slot");
    check(!l1d_bus.idle, "stale response authorized IO fetch before D-side issue");

    @(negedge clock);
    mem.rd_req_ready = 1'b1;
    expect_issue(4'd2, XLEN'('h8000_0e00));
    @(negedge clock);
    mem.rd_req_ready = 1'b0;
    drive_response(4'd2, XLEN'('h0e00_0e00));
    check(l1d_bus.rvalid && l1d_bus.rlast, "L1D response was not routed after its AR handshake");
    finish_response();

    // Queue one request from each independent source while downstream stalls.
    submit_l1d(XLEN'('h8000_1000), 1'b0);
    submit_l1i(XLEN'('h8000_2000), 1'b0);
    submit_l1i(XLEN'('h8000_3000), 1'b1);

    @(negedge clock);
    mem.rd_req_ready = 1'b1;
    expect_issue(4'd2, XLEN'('h8000_1000));
    expect_issue(4'd1, XLEN'('h8000_2000));
    expect_issue(4'd3, XLEN'('h8000_3000));
    @(negedge clock);
    mem.rd_req_ready = 1'b0;

    // L1I and instruction PTW may complete before the older L1D request.
    drive_response(4'd3, XLEN'('h3333_3333));
    mem.rd_rsp_error = 1'b1;
    #1;
    check(l1i_bus.ptw_rerr && !l1i_bus.rerr,
          "instruction PTW error was dropped or routed as a cache error");
    check(l1i_bus.ptw_rvalid, "TLBI response was not routed to instruction PTW");
    check(!l1i_bus.rvalid && !l1d_bus.rvalid && !l1d_bus.ptw_rvalid,
          "TLBI response leaked to another read source");
    finish_response();

    drive_response(4'd1, XLEN'('h1111_1111));
    check(!l1i_bus.ptw_rerr, "cache response retained the previous PTW error");
    mem.rd_rsp_error = 1'b0;
    check(l1i_bus.rvalid, "L1I response was not routed");
    check(l1i_bus.rdata == XLEN'('h1111_1111), "L1I response data mismatch");
    check(!l1i_bus.ptw_rvalid && !l1d_bus.rvalid && !l1d_bus.ptw_rvalid,
          "L1I response leaked to another read source");
    finish_response();

    // A wrong TLBD response must neither reach L1D nor release its L1D slot.
    drive_response(4'd4, XLEN'('hdead_0004));
    check(!l1d_bus.rvalid && !l1d_bus.ptw_rvalid,
          "wrong-ID response leaked into pending L1D request");
    finish_response();
    check(!l1d_bus.rready, "wrong-ID response released pending L1D slot");
    check(!l1d_bus.idle, "wrong-ID response advertised D-side completion");

    drive_response(4'd2, XLEN'('h2222_2222));
    check(!l1d_bus.idle, "D-side idle rose before final response acceptance");
    check(l1d_bus.rvalid && l1d_bus.rlast, "L1D response was not routed");
    check(l1d_bus.rdata == XLEN'('h2222_2222), "L1D response data mismatch");
    check(!l1d_bus.ptw_rvalid && !l1i_bus.rvalid && !l1i_bus.ptw_rvalid,
          "L1D response leaked to another read source");
    finish_response();

    // Repeat with a data PTW slot and inject the normal-L1D ID first.
    #1;
    check(l1d_bus.idle, "completed D-side request did not release IO fetch drain");
    submit_l1d(XLEN'('h8000_4000), 1'b1);
    @(negedge clock);
    mem.rd_req_ready = 1'b1;
    expect_issue(4'd4, XLEN'('h8000_4000));
    @(negedge clock);
    mem.rd_req_ready = 1'b0;

    drive_response(4'd2, XLEN'('hdead_0002));
    mem.rd_rsp_error = 1'b1;
    #1;
    check(!l1d_bus.ptw_rerr && !l1d_bus.rerr, "wrong-ID error reached pending data PTW");
    check(!l1d_bus.rvalid && !l1d_bus.ptw_rvalid,
          "wrong-ID response leaked into pending TLBD request");
    finish_response();
    check(!l1d_bus.rready, "wrong-ID response released pending TLBD slot");
    check(!l1d_bus.idle, "wrong-ID response advertised data PTW completion");

    drive_response(4'd4, XLEN'('h4444_4444));
    mem.rd_rsp_error = 1'b1;
    #1;
    check(l1d_bus.ptw_rerr && !l1d_bus.rerr,
          "data PTW error dropped or routed as ordinary data error");
    check(!l1d_bus.idle, "D-side idle rose before PTW response acceptance");
    check(l1d_bus.ptw_rvalid, $sformatf(
          "TLBD response not routed busy=%b issued=%b ptw=%b rsp_id=%0d",
          dut.l1d_slot_busy,
          dut.l1d_slot_issued,
          dut.l1d_slot_ptw,
          mem.rd_rsp_id
          ));
    check(!l1d_bus.rvalid && !l1i_bus.rvalid && !l1i_bus.ptw_rvalid,
          "TLBD response leaked to another read source");
    finish_response();

    #1;
    check(l1d_bus.idle, "completed data PTW did not release IO fetch drain");
    check(!l1d_bus.ptw_rerr && !l1d_bus.rerr,
          "error without valid response leaked after data PTW drain");
    mem.rd_rsp_error = 1'b0;
    // A reset cancels an unissued skid entry, not an accepted external read.
    // Leave nonzero address/attributes behind and then capture a fresh request.
    l1d_bus.rpbmt = 2'b10;
    l1d_bus.noallocate = 1;
    l1d_bus.arlen = 3;
    submit_l1d(XLEN'('h8000_5000), 1'b0);
    tick(2);
    check(
        dut.rd_skid_valid && mem.rd_req_pbmt == 2'b10
          && mem.rd_req_noallocate && mem.rd_req_len == 3,
        "warm reset did not start with occupied skid payload");
    @(negedge clock);
    reset = 1;
    tick(2);
    check(!dut.rd_skid_valid && !mem.rd_req_valid && l1d_bus.idle,
          "reset exposed a stale skid request");
    @(negedge clock);
    reset = 0;
    l1d_bus.rpbmt = 0;
    l1d_bus.noallocate = 0;
    l1d_bus.arlen = 0;
    tick(2);
    check(!mem.rd_req_valid, "stale request reappeared after reset");
    submit_l1i((XLEN'(1) << (XLEN - 1)) | XLEN'('h6000), 1'b0);
    tick(2);
    check(
        mem.rd_req_valid && mem.rd_req_pbmt == 0 && !mem.rd_req_noallocate
          && mem.rd_req_size == 2 && mem.rd_req_len == 0 && mem.rd_req_burst == 0,
        "post-reset request retained stale skid attributes");
    @(negedge clock);
    mem.rd_req_ready = 1;
    expect_issue(4'd1, (XLEN'(1) << (XLEN - 1)) | XLEN'('h6000));
    @(negedge clock);
    mem.rd_req_ready = 0;
    tick(2);
    check(!mem.rd_req_valid, "post-reset skid replayed an accepted request");
    // Keep VALID and identity unchanged across warm reset: only captured
    // resets, so stale identity must neither suppress nor duplicate capture.
    for (int kind = 0; kind < 2; kind++) begin
      for (int trial = 0; trial < 2; trial++) begin
        @(negedge clock);
        reset = 1;
        l1i_bus.arvalid = 1;
        l1i_bus.araddr = XLEN'('h8000_7000);
        l1i_bus.ar_ptw = 1'(kind);
        tick(2);
        @(negedge clock);
        reset = 0;
        #1;
        wait_l1i_ready();
        check(l1i_bus.rready, "same-identity request was suppressed after reset");
        tick(1);
        check(dut.l1i_captured && !l1i_bus.rready, "held request captured twice");
        tick(3);
        check(!l1i_bus.rready && dut.l1i_q_cnt == 0 && dut.rd_skid_valid,
              "held same-identity request was duplicated behind skid");
      end
    end
    @(negedge clock);
    reset = 1;
    l1i_bus.arvalid = 0;
    tick(2);
    if (`RAPT_L1D_MSHRS > 0) begin
      @(negedge clock);
      reset = 0;
      mem.rd_req_ready = 0;
      l1d_bus.ar_mshr = 1;
      l1d_bus.ar_mshr_id = 0;
      l1d_bus.noallocate = 0;
      submit_l1d(XLEN'('h80008000), 0);
      l1d_bus.ar_mshr_id = 1;
      l1d_bus.noallocate = 1;
      submit_l1d(XLEN'('h80009000), 0);
      l1d_bus.noallocate = 0;
      mem.rd_req_ready = 1;
      #1;
      check(!mem.rd_req_noallocate, "MSHR acquire lost its inclusive allocation attribute");
      expect_issue(4'd8, XLEN'('h80008000));
      @(negedge clock);
      #1;
      check(mem.rd_req_noallocate, "MSHR attribute did not stay with its buffered owner");
      expect_issue(4'd9, XLEN'('h80009000));
      @(negedge clock);
      mem.rd_req_ready = 0;
      // A flush cannot drop issued bus owners; responses may return out of order.
      cmu_bcast.flush_pipe = 1;
      tick(1);
      cmu_bcast.flush_pipe = 0;
      drive_response(4'd9, XLEN'('h9999));
      check(l1d_bus.rvalid && l1d_bus.r_mshr && l1d_bus.r_mshr_id == 1,
            "MSHR 1 response ownership lost");
      finish_response();
      check(!l1d_bus.idle, "MSHR 0 still outstanding");
      drive_response(4'd8, XLEN'('h8888));
      check(l1d_bus.rvalid && l1d_bus.r_mshr && l1d_bus.r_mshr_id == 0,
            "MSHR 0 response ownership lost");
      finish_response();
      check(l1d_bus.idle, "MSHR bus did not drain");
    end
    $display("PASS: bus read ownership and ID-interleaving checks passed");
    $finish;
  end
endmodule
