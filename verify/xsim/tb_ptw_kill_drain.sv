`include "rapt.svh"

module tb_ptw_kill_drain;
  localparam int XLEN = 32;

  logic clock = 1'b0;
  logic reset = 1'b1;
  logic req_valid;
  logic kill;
  logic [31:0] vaddr;
  logic [`RAPT_CSR_SATP_PPN_W-1:0] satp_ppn;
  logic mmu_en;
  logic sbe;
  logic req_store;
  logic bus_arvalid;
  logic [31:0] bus_araddr;
  logic bus_arready;
  logic bus_rvalid;
  logic [31:0] bus_rdata;
  logic bus_awvalid;
  logic [31:0] bus_awaddr;
  logic bus_wvalid;
  logic [31:0] bus_wdata;
  logic [7:0] bus_wstrb;
  logic bus_wready;
  logic bus_werr;
  logic done;
  logic fault;
  logic [31:10] result_ptag;
  logic [31:12] result_vtag;
  logic [6:0] result_pte;
  logic busy;

  rapt_ptw #(.XLEN(XLEN)) dut (.*);

  always #5 clock = ~clock;

  `include "tb_common.svh"

  task automatic start_walk;
    begin
      req_valid = 1'b1;
      tick(1);
      req_valid = 1'b0;
      check(bus_arvalid, "PTW did not enter request state");
    end
  endtask

  initial begin
    req_valid = 1'b0;
    kill = 1'b0;
    vaddr = 32'h8040_1000;
    satp_ppn = 'h100;
    mmu_en = 1'b1;
    sbe = 1'b0;
    req_store = 1'b0;
    bus_arready = 1'b0;
    bus_rvalid = 1'b0;
    bus_rdata = '0;
    bus_wready = 1'b0;
    bus_werr = 1'b0;
    tick(4);
    reset = 1'b0;
    tick(1);

    start_walk();
    kill = 1'b1;
    #1;
    check(!bus_arvalid, "kill did not suppress an unaccepted PTW request");
    tick(1);
    kill = 1'b0;
    check(!busy && !done && !fault, "REQ-killed PTW did not cancel cleanly");

    start_walk();
    bus_arready = 1'b1;
    tick(1);
    bus_arready = 1'b0;
    check(busy && !bus_arvalid, "accepted PTW request did not enter wait state");
    kill = 1'b1;
    tick(1);
    kill = 1'b0;
    check(busy, "WAIT-killed PTW forgot its outstanding response");
    bus_rdata = 32'h1230_0043;
    bus_rvalid = 1'b1;
    tick(1);
    bus_rvalid = 1'b0;
    check(!busy && !done && !fault, "WAIT-killed PTW completed architecturally");

    start_walk();
    bus_arready = 1'b1;
    tick(1);
    bus_arready = 1'b0;
    bus_rdata = 32'h1230_0003;
    bus_rvalid = 1'b1;
    tick(1);
    bus_rvalid = 1'b0;
    check(bus_awvalid && bus_wvalid && busy, "PTW did not enter A/D update state");
    kill = 1'b1;
    tick(1);
    kill = 1'b0;
    check(bus_awvalid && bus_wvalid && busy, "killed A/D update did not remain drainable");
    bus_wready = 1'b1;
    tick(1);
    bus_wready = 1'b0;
    check(!busy && !done && !fault, "killed A/D update completed architecturally");

    $display("PASS: PTW kill and drain xsim checks passed");
    $finish;
  end
endmodule
