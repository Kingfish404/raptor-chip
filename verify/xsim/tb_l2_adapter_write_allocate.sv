`include "rapt.svh"
`include "rapt_soc_if.svh"

module tb_l2_adapter_write_allocate;
  localparam int XLEN = `RAPT_XLEN;
  localparam int IdW = 4;
  localparam int LineBeats = 1 << `RAPT_L2_LINE_LEN;
  localparam logic [XLEN-1:0] LineAddr = XLEN'('h80000200);
  localparam logic [XLEN-1:0] ZeroAddr = XLEN'('h80000240);
  localparam logic [XLEN-1:0] StoreData = XLEN'('h123456789abcdef0);
  localparam logic [XLEN-1:0] MergedWord = ((LineAddr + XLEN'(1)) & ~XLEN'('hff))
      | (StoreData & XLEN'('hff));

  logic clock = 1'b0;
  logic reset = 1'b1;
  mem_link_if #(
      .XLEN(XLEN),
      .ID_W(IdW)
  ) mem ();
  axi4_if #(
      .XLEN(XLEN),
      .ID_W(IdW)
  ) axi_s ();
  axi4_if #(
      .XLEN(XLEN),
      .ID_W(IdW)
  ) axi_m ();

  rapt_axi_master #(
      .XLEN(XLEN),
      .ID_W(IdW)
  ) adapter (
      .clock,
      .reset,
      .mem,
      .axi(axi_s)
  );
  rapt_l2 #(
      .XLEN(XLEN),
      .ID_W(IdW)
  ) dut (
      .clock,
      .reset,
      .cbo_inval_i(1'b0),
      .cbo_block_i('0),
      .axi_s,
      .axi_m
  );

  always #5 clock = ~clock;
  `include "tb_common.svh"

  initial begin
    bit accepted;
    bit got_response;
    check(`RAPT_L2_N_WAYS == 8 && `RAPT_L2_LEN == 10,
          "adapter allocation test requires the BOOM L2 geometry");
`ifndef RAPT_L2_STORE_WRITEBACK
    fail("adapter allocation test requires bufferable L2 stores");
`endif
    mem.rd_req_valid = 1'b0;
    mem.rd_req_id = '0;
    mem.rd_req_addr = '0;
    mem.rd_req_size = 3'($clog2(XLEN / 8));
    mem.rd_req_len = 8'd0;
    mem.rd_req_burst = 2'b01;
    mem.rd_req_pbmt = 2'b00;
    mem.rd_req_noallocate = 1'b0;
    mem.rd_rsp_ready = 1'b1;
    mem.wr_req_valid = 1'b0;
    mem.wr_req_id = '0;
    mem.wr_req_addr = '0;
    mem.wr_req_size = 3'($clog2(XLEN / 8));
    mem.wr_req_data = '0;
    mem.wr_req_strb = '0;
    mem.wr_req_zero = 1'b0;
    mem.wr_req_pbmt = 2'b00;
    mem.wr_rsp_ready = 1'b1;
    axi_m.arready = 1'b0;
    axi_m.rid = '0;
    axi_m.rdata = '0;
    axi_m.rresp = 2'b00;
    axi_m.rlast = 1'b1;
    axi_m.rvalid = 1'b0;
    axi_m.awready = 1'b0;
    axi_m.wready = 1'b0;
    axi_m.bid = '0;
    axi_m.bresp = 2'b00;
    axi_m.bvalid = 1'b0;
    tick(4);
    reset = 1'b0;
    for (int cycle = 0; cycle < (1 << `RAPT_L2_LEN) + 64 && !axi_s.awready; cycle++) tick(1);
    check(axi_s.awready, "directory reset wipe timed out");

    mem.wr_req_valid = 1'b1;
    mem.wr_req_id = 4'h5;
    mem.wr_req_addr = LineAddr + XLEN'(XLEN / 8);
    mem.wr_req_data = StoreData;
    mem.wr_req_strb = (XLEN / 8)'(1);
    #1;
    check(mem.wr_req_ready, "adapter did not accept the cacheable store");
    tick(1);
    mem.wr_req_valid = 1'b0;
    #1;
    check(axi_s.awvalid && axi_s.awcache == 4'hf,
          "adapter stripped the L2 write-back cache attribute");
    accepted = 1'b0;
    for (int cycle = 0; cycle < 64 && !accepted; cycle++) begin
      check(!axi_m.awvalid && !mem.wr_rsp_valid, "store miss bypassed L2 allocation");
      if (axi_m.arvalid) begin
        check(axi_m.araddr == LineAddr && axi_m.arlen == 8'(LineBeats - 1) && axi_m.arid == 4'h5,
              "adapter store miss requested the wrong refill");
        axi_m.arready = 1'b1;
        tick(1);
        axi_m.arready = 1'b0;
        accepted = 1'b1;
      end else tick(1);
    end
    check(accepted, "adapter store miss did not request a refill");
    for (int beat = 0; beat < LineBeats; beat++) begin
      axi_m.rid = 4'h5;
      axi_m.rdata = LineAddr + XLEN'(beat);
      axi_m.rlast = beat == LineBeats - 1;
      axi_m.rvalid = 1'b1;
      check(!mem.wr_rsp_valid, "adapter store completed before line install");
      accepted = 1'b0;
      for (int cycle = 0; cycle < 64 && !accepted; cycle++) begin
        @(posedge clock);
        accepted = axi_m.rready;
      end
      check(accepted, "store miss did not accept refill data");
      #1;
      axi_m.rvalid = 1'b0;
    end
    got_response = 1'b0;
    for (int cycle = 0; cycle < 64 && !got_response; cycle++) begin
      if (mem.wr_rsp_valid) begin
        check(mem.wr_rsp_id == 4'h5 && !mem.wr_rsp_error,
              "allocated store returned the wrong adapter response");
        got_response = 1'b1;
      end else tick(1);
    end
    check(got_response && !axi_m.awvalid, "allocated store did not complete locally");
    tick(2);

    mem.rd_req_valid = 1'b1;
    mem.rd_req_id = 4'h3;
    mem.rd_req_addr = LineAddr + XLEN'(XLEN / 8);
    accepted = 1'b0;
    for (int cycle = 0; cycle < 64 && !accepted; cycle++) begin
      @(posedge clock);
      accepted = mem.rd_req_ready;
    end
    check(accepted, "adapter read was not accepted after store allocation");
    #1;
    mem.rd_req_valid = 1'b0;
    got_response = 1'b0;
    for (int cycle = 0; cycle < 64 && !got_response; cycle++) begin
      check(!axi_m.arvalid, "allocated store line missed on the next read");
      if (mem.rd_rsp_valid) begin
        check(
            mem.rd_rsp_id == 4'h3 && mem.rd_rsp_data == MergedWord
                  && !mem.rd_rsp_error && mem.rd_rsp_last,
            "adapter read did not see the merged store byte");
        got_response = 1'b1;
      end else tick(1);
    end
    check(got_response, "adapter read after store allocation timed out");

    // The real adapter encodes ZERO as one aligned, full-strobe line burst.
    // BOOM's PutFullData policy must install it without an outer read or write.
    tick(2);
    mem.wr_req_valid = 1'b1;
    mem.wr_req_zero = 1'b1;
    mem.wr_req_id = 4'h6;
    mem.wr_req_addr = ZeroAddr + XLEN'(7);
    accepted = 1'b0;
    for (int cycle = 0; cycle < 64 && !accepted; cycle++) begin
      @(posedge clock);
      accepted = mem.wr_req_ready;
    end
    check(accepted, "adapter ZERO request was not accepted");
    #1;
    mem.wr_req_valid = 1'b0;
    mem.wr_req_zero = 1'b0;
    got_response = 1'b0;
    for (int cycle = 0; cycle < 128 && !got_response; cycle++) begin
      check(!axi_m.arvalid && !axi_m.awvalid, "adapter ZERO unexpectedly accessed external memory");
      if (mem.wr_rsp_valid) begin
        check(mem.wr_rsp_id == 4'h6 && !mem.wr_rsp_error,
              "adapter ZERO returned the wrong local response");
        got_response = 1'b1;
      end else tick(1);
    end
    check(got_response, "adapter ZERO local completion timed out");
    tick(2);

    for (int word = 0; word < 2; word++) begin
      mem.rd_req_valid = 1'b1;
      mem.rd_req_id = 4'(word + 7);
      mem.rd_req_addr = ZeroAddr + XLEN'(word == 0 ? 0 : (LineBeats - 1) * (XLEN / 8));
      accepted = 1'b0;
      for (int cycle = 0; cycle < 64 && !accepted; cycle++) begin
        @(posedge clock);
        accepted = mem.rd_req_ready;
      end
      check(accepted, "adapter ZERO line read was not accepted");
      #1;
      mem.rd_req_valid = 1'b0;
      got_response = 1'b0;
      for (int cycle = 0; cycle < 64 && !got_response; cycle++) begin
        check(!axi_m.arvalid && !axi_m.awvalid, "adapter ZERO line was not resident in L2");
        if (mem.rd_rsp_valid) begin
          check(
              mem.rd_rsp_id == 4'(word + 7) && mem.rd_rsp_data == '0
                    && !mem.rd_rsp_error && mem.rd_rsp_last,
              "adapter ZERO line returned nonzero data");
          got_response = 1'b1;
        end else tick(1);
      end
      check(got_response, "adapter ZERO line read timed out");
      tick(2);
    end
    $display("PASS: adapter store and ZERO allocate in BOOM L2 RV%0d", XLEN);
    $finish;
  end

  initial begin
    #200000;
    $fatal(1, "L2 adapter write allocation watchdog");
  end
endmodule
