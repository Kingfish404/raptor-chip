`include "rapt.svh"
`include "rapt_soc_if.svh"

// Check functional admission independently of the non-synthesis ID observer.
module tb_axi_master_storage;
  localparam int XLEN = `RAPT_XLEN;
  logic clock = 0, reset = 1;
  mem_link_if #(
      .XLEN(XLEN),
      .ID_W(4)
  ) mem ();
  axi4_if #(
      .XLEN(XLEN),
      .ID_W(4)
  ) axi ();
  rapt_axi_master #(
      .XLEN(XLEN),
      .MAX_READ_OUTSTANDING(3)
  ) dut (
      .clock,
      .reset,
      .mem,
      .axi
  );
  always #5 clock = ~clock;
  `include "tb_common.svh"

  task automatic request(input logic [3:0] id);
    mem.rd_req_valid = 1;
    mem.rd_req_id = id;
    #1;
    check(mem.rd_req_ready && axi.arvalid && axi.arid == id, "read not accepted");
    tick(1);
    mem.rd_req_valid = 0;
  endtask

  task automatic respond(input logic [3:0] id, input bit last);
    axi.rvalid = 1;
    axi.rid = id;
    axi.rlast = last;
    #1;
    check(mem.rd_rsp_valid && mem.rd_rsp_id == id && mem.rd_rsp_last == last,
          "read response changed");
    tick(1);
    axi.rvalid = 0;
  endtask

  initial begin
    mem.rd_req_valid=0;
    mem.rd_req_id=0;
    mem.rd_req_addr=XLEN'('h80000000);
    mem.rd_req_size=3'($clog2(XLEN/8));
    mem.rd_req_len=1;
    mem.rd_req_burst=1;
    mem.rd_req_pbmt=0;
    mem.rd_req_noallocate=0;
    mem.rd_rsp_ready=1;
    mem.wr_req_valid=0;
    mem.wr_req_id=0;
    mem.wr_req_addr=0;
    mem.wr_req_size=0;
    mem.wr_req_data=0;
    mem.wr_req_strb=0;
    mem.wr_req_zero=0;
    mem.wr_req_pbmt=0;
    mem.wr_rsp_ready=1;
    axi.arready=1;
    axi.rvalid=0;
    axi.rid=0;
    axi.rdata=XLEN'('h12345678);
    axi.rresp=0;
    axi.rlast=0;
    axi.awready=1;
    axi.wready=1;
    axi.bvalid=0;
    axi.bid=0;
    axi.bresp=0;
    tick(3);
    reset = 0;
    tick(1);
    request(1);
    request(1);
    request(2);
`ifndef SYNTHESIS
    check(dut.read_id_outstanding[1] == 2 && dut.read_id_outstanding[2] == 1,
          "ID observer lost same-ID requests");
`endif
    mem.rd_req_valid=1;
    mem.rd_req_id=3;
    #1;
    check(!mem.rd_req_ready && !axi.arvalid, "capacity counter was removed");
    respond(1, 0);
    #1;
    check(!mem.rd_req_ready, "non-last beat released capacity");
    respond(2, 1);
    #1;
    check(mem.rd_req_ready && axi.arvalid, "last beat did not release capacity");
    // Simultaneous accepted request / final response: occupancy stays two.
    respond(1, 1);
    mem.rd_req_valid = 0;
    check(dut.read_outstanding == 2, "simultaneous handshake changed occupancy");
    // R backpressure must retain both aggregate and per-ID ownership.
    mem.rd_rsp_ready = 0;
    respond(1, 1);
    check(dut.read_outstanding == 2, "stalled R released capacity");
    mem.rd_rsp_ready = 1;
    respond(3, 1);
    respond(1, 1);
    check(dut.read_outstanding == 0, "responses did not drain aggregate count");
`ifndef SYNTHESIS
    for (int id = 0; id < 16; id++)
    check(dut.read_id_outstanding[id] == 0, "ID observer did not drain");
`endif
    $display("PASS: AXI capacity and ownership XLEN=%0d", XLEN);
    $finish;
  end
  initial begin
    #10000;
    $fatal(1, "AXI storage watchdog");
  end
endmodule
