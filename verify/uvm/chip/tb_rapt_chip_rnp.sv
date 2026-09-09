`timescale 1ns/1ps
module tb_rapt_chip_rnp;
  import uvm_pkg::*;
  import rapt_chip_pkg::*;
  bit clock=0;
  always #5 clock=~clock;
  rapt_chip_if bus(clock);
  logic [31:0] rnp_mdata,rnp_cdata;
  logic rnp_arvalid,rnp_arready,rnp_rvalid,rnp_rready;
  logic rnp_awvalid,rnp_awready,rnp_wvalid,rnp_wready,rnp_bvalid,rnp_bready;
  logic [3:0] rnp_wstrb;
  logic [1:0] rnp_rwstate;
  rng_chip dut (
    .clock(clock), .reset(bus.reset),
    .rnp_mdata(rnp_mdata),
    .rnp_cdata(rnp_cdata),
    .rnp_arvalid(rnp_arvalid),
    .rnp_arready(rnp_arready),
    .rnp_rvalid(rnp_rvalid),
    .rnp_rready(rnp_rready),
    .rnp_awvalid(rnp_awvalid),
    .rnp_awready(rnp_awready),
    .rnp_wstrb(rnp_wstrb),
    .rnp_wvalid(rnp_wvalid),
    .rnp_wready(rnp_wready),
    .rnp_bvalid(rnp_bvalid),
    .rnp_bready(rnp_bready),
    .rnp_rwstate(rnp_rwstate)
  );
  // Actual board-side protocol bridge. Stimulus crosses the package RNP pins.
  rnp2axi host_bridge (
    .clk(clock), .reset(bus.reset),
    .axi_arburst(bus.arburst),
    .axi_arsize(bus.arsize),
    .axi_arlen(bus.arlen),
    .axi_arid(bus.arid),
    .axi_araddr(bus.araddr),
    .axi_arvalid(bus.arvalid),
    .axi_arready(bus.arready),
    .axi_rid(bus.rid),
    .axi_rlast(bus.rlast),
    .axi_rdata(bus.rdata),
    .axi_rresp(bus.rresp),
    .axi_rvalid(bus.rvalid),
    .axi_rready(bus.rready),
    .axi_awburst(bus.awburst),
    .axi_awsize(bus.awsize),
    .axi_awlen(bus.awlen),
    .axi_awid(bus.awid),
    .axi_awaddr(bus.awaddr),
    .axi_awvalid(bus.awvalid),
    .axi_awready(bus.awready),
    .axi_wlast(bus.wlast),
    .axi_wdata(bus.wdata),
    .axi_wstrb(bus.wstrb),
    .axi_wvalid(bus.wvalid),
    .axi_wready(bus.wready),
    .axi_bid(bus.bid),
    .axi_bresp(bus.bresp),
    .axi_bvalid(bus.bvalid),
    .axi_bready(bus.bready),
    .rnp_mdata(rnp_mdata),
    .rnp_cdata(rnp_cdata),
    .rnp_arvalid(rnp_arvalid),
    .rnp_arready(rnp_arready),
    .rnp_rvalid(rnp_rvalid),
    .rnp_rready(rnp_rready),
    .rnp_awvalid(rnp_awvalid),
    .rnp_awready(rnp_awready),
    .rnp_wstrb(rnp_wstrb),
    .rnp_wvalid(rnp_wvalid),
    .rnp_wready(rnp_wready),
    .rnp_bvalid(rnp_bvalid),
    .rnp_bready(rnp_bready),
    .rnp_rwstate(rnp_rwstate)
  );
  assign bus.arcache=0;
  assign bus.awcache=0;
  assign bus.jtag_tdo=0;
  initial begin
    uvm_config_db#(virtual rapt_chip_if)::set(null,"*","vif",bus);
    run_test("chip_test");
  end
endmodule
