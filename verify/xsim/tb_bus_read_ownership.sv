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
    l1i_bus.awvalid = 1'b0;
    l1i_bus.awaddr = '0;
    l1i_bus.wvalid = 1'b0;
    l1i_bus.wdata = '0;
    l1i_bus.wstrb = '0;
    l1i_bus.aw_ptw = 1'b0;

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
    l1d_bus.aw_ptw = 1'b0;

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
    check(l1i_bus.rvalid && l1i_bus.rlast, "L1I response was not routed");
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
      submit_l1d(XLEN'('h80008000), 0);
      l1d_bus.ar_mshr_id = 1;
      submit_l1d(XLEN'('h80009000), 0);
      mem.rd_req_ready = 1;
      expect_issue(4'd8, XLEN'('h80008000));
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
