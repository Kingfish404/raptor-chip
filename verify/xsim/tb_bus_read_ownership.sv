`include "rapt.svh"
`include "rapt_if.svh"
`include "rapt_soc_if.svh"

module tb_bus_read_ownership;
  localparam int XLEN = 32;
  localparam int IdW = 4;

  logic clock = 1'b0;
  logic reset = 1'b1;

  mem_link_if #(.XLEN(XLEN), .ID_W(IdW)) mem ();
  l1i_bus_if #(.XLEN(XLEN)) l1i_bus ();
  l1d_bus_if #(.XLEN(XLEN)) l1d_bus ();
  csr_bcast_if #(.XLEN(XLEN)) csr_bcast ();
  cmu_bcast_if #(.XLEN(XLEN)) cmu_bcast ();

  rapt_bus #(.XLEN(XLEN)) dut (
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

  task automatic submit_l1d(input logic [31:0] address, input logic is_ptw);
    begin
      @(negedge clock);
      l1d_bus.araddr = address;
      l1d_bus.ar_ptw = is_ptw;
      l1d_bus.arvalid = 1'b1;
      #1;
      check(l1d_bus.rready, "L1D request was not captured");
      @(posedge clock);
      @(negedge clock);
      l1d_bus.arvalid = 1'b0;
    end
  endtask

  task automatic submit_l1i(input logic [31:0] address, input logic is_ptw);
    begin
      @(negedge clock);
      l1i_bus.araddr = address;
      l1i_bus.ar_ptw = is_ptw;
      l1i_bus.arvalid = 1'b1;
      #1;
      check(l1i_bus.rready, "L1I request was not captured");
      @(posedge clock);
      @(negedge clock);
      l1i_bus.arvalid = 1'b0;
      @(posedge clock);
    end
  endtask

  task automatic expect_issue(
      input logic [3:0] expected_id,
      input logic [31:0] expected_address);
    begin
      for (int wait_cycle = 0; wait_cycle < 16; wait_cycle++) begin
        #1;
        if (mem.rd_req_valid) begin
            check(mem.rd_req_id == expected_id,
              $sformatf("read request ID mismatch got=%0d expected=%0d addr=%08x",
                mem.rd_req_id, expected_id, mem.rd_req_addr));
            check(mem.rd_req_addr == expected_address,
              $sformatf("read request address mismatch got=%08x expected=%08x id=%0d",
                mem.rd_req_addr, expected_address, mem.rd_req_id));
          @(posedge clock);
          return;
        end
        @(negedge clock);
      end
      fail("timed out waiting for downstream read request");
    end
  endtask

  task automatic drive_response(
      input logic [3:0] response_id,
      input logic [31:0] response_data,
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
    l1d_bus.ar_ptw = 1'b0;
    l1d_bus.awvalid = 1'b0;
    l1d_bus.awaddr = '0;
    l1d_bus.wvalid = 1'b0;
    l1d_bus.wdata = '0;
    l1d_bus.wstrb = '0;
    l1d_bus.aw_ptw = 1'b0;

    csr_bcast.dmmu_en = 1'b0;
    cmu_bcast.flush_pipe = 1'b0;

    tick(4);
    reset = 1'b0;
    tick(1);

    // Queue one request from each independent source while downstream stalls.
    submit_l1d(32'h8000_1000, 1'b0);
    submit_l1i(32'h8000_2000, 1'b0);
    submit_l1i(32'h8000_3000, 1'b1);

    @(negedge clock);
    mem.rd_req_ready = 1'b1;
    expect_issue(4'd2, 32'h8000_1000);
    expect_issue(4'd1, 32'h8000_2000);
    expect_issue(4'd3, 32'h8000_3000);
    @(negedge clock);
    mem.rd_req_ready = 1'b0;

    // L1I and instruction PTW may complete before the older L1D request.
    drive_response(4'd3, 32'h3333_3333);
    check(l1i_bus.ptw_rvalid, "TLBI response was not routed to instruction PTW");
    check(!l1i_bus.rvalid && !l1d_bus.rvalid && !l1d_bus.ptw_rvalid,
          "TLBI response leaked to another read source");
    finish_response();

    drive_response(4'd1, 32'h1111_1111);
    check(l1i_bus.rvalid && l1i_bus.rlast, "L1I response was not routed");
    check(l1i_bus.rdata == 32'h1111_1111, "L1I response data mismatch");
    check(!l1i_bus.ptw_rvalid && !l1d_bus.rvalid && !l1d_bus.ptw_rvalid,
          "L1I response leaked to another read source");
    finish_response();

    // A wrong TLBD response must neither reach L1D nor release its L1D slot.
    drive_response(4'd4, 32'hdead_0004);
    check(!l1d_bus.rvalid && !l1d_bus.ptw_rvalid,
          "wrong-ID response leaked into pending L1D request");
    finish_response();
    check(!l1d_bus.rready, "wrong-ID response released pending L1D slot");

    drive_response(4'd2, 32'h2222_2222);
    check(l1d_bus.rvalid && l1d_bus.rlast, "L1D response was not routed");
    check(l1d_bus.rdata == 32'h2222_2222, "L1D response data mismatch");
    check(!l1d_bus.ptw_rvalid && !l1i_bus.rvalid && !l1i_bus.ptw_rvalid,
          "L1D response leaked to another read source");
    finish_response();

    // Repeat with a data PTW slot and inject the normal-L1D ID first.
    submit_l1d(32'h8000_4000, 1'b1);
    @(negedge clock);
    mem.rd_req_ready = 1'b1;
    expect_issue(4'd4, 32'h8000_4000);
    @(negedge clock);
    mem.rd_req_ready = 1'b0;

    drive_response(4'd2, 32'hdead_0002);
    check(!l1d_bus.rvalid && !l1d_bus.ptw_rvalid,
          "wrong-ID response leaked into pending TLBD request");
    finish_response();
    check(!l1d_bus.rready, "wrong-ID response released pending TLBD slot");

    drive_response(4'd4, 32'h4444_4444);
    check(l1d_bus.ptw_rvalid,
        $sformatf("TLBD response not routed busy=%b issued=%b ptw=%b rsp_id=%0d",
            dut.l1d_slot_busy, dut.l1d_slot_issued,
            dut.l1d_slot_ptw, mem.rd_rsp_id));
    check(!l1d_bus.rvalid && !l1i_bus.rvalid && !l1i_bus.ptw_rvalid,
          "TLBD response leaked to another read source");
    finish_response();

    submit_l1d(32'h8000_5000, 1'b0);
    $display("PASS: bus read ownership and ID-interleaving checks passed");
    $finish;
  end
endmodule
