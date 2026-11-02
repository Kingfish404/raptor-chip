module rapt_sample_sim_top (
    input logic clk,
    reset,
    output logic cpu_reset,
    writeback_error,
    input logic host_awvalid,
    input logic [63:0] host_awaddr,
    input logic [3:0] host_awid,
    input logic [7:0] host_awlen,
    input logic [2:0] host_awsize,
    input logic [1:0] host_awburst,
    input logic [3:0] host_awcache,
    input logic host_wvalid,
    input logic [63:0] host_wdata,
    input logic [7:0] host_wstrb,
    input logic host_wlast,
    input logic host_bready,
    input logic host_arvalid,
    input logic [63:0] host_araddr,
    input logic [3:0] host_arid,
    input logic [7:0] host_arlen,
    input logic [2:0] host_arsize,
    input logic [1:0] host_arburst,
    input logic [3:0] host_arcache,
    input logic host_rready,
    output logic host_awready,
    output logic host_wready,
    output logic [3:0] host_bid,
    output logic [1:0] host_bresp,
    output logic host_bvalid,
    output logic host_arready,
    output logic [3:0] host_rid,
    output logic [63:0] host_rdata,
    output logic [1:0] host_rresp,
    output logic host_rlast,
    output logic host_rvalid,
    output logic ddr_awvalid,
    output logic [63:0] ddr_awaddr,
    output logic [3:0] ddr_awid,
    output logic [7:0] ddr_awlen,
    output logic [2:0] ddr_awsize,
    output logic [1:0] ddr_awburst,
    output logic [3:0] ddr_awcache,
    output logic ddr_wvalid,
    output logic [63:0] ddr_wdata,
    output logic [7:0] ddr_wstrb,
    output logic ddr_wlast,
    output logic ddr_bready,
    output logic ddr_arvalid,
    output logic [63:0] ddr_araddr,
    output logic [3:0] ddr_arid,
    output logic [7:0] ddr_arlen,
    output logic [2:0] ddr_arsize,
    output logic [1:0] ddr_arburst,
    output logic [3:0] ddr_arcache,
    output logic ddr_rready,
    input logic ddr_awready,
    input logic ddr_wready,
    input logic [3:0] ddr_bid,
    input logic [1:0] ddr_bresp,
    input logic ddr_bvalid,
    input logic ddr_arready,
    input logic [3:0] ddr_rid,
    input logic [63:0] ddr_rdata,
    input logic [1:0] ddr_rresp,
    input logic ddr_rlast,
    input logic ddr_rvalid
);
  axi4_if host ();
  axi4_if ddr ();
  assign host.awvalid = host_awvalid;
  assign host.awaddr = host_awaddr;
  assign host.awid = host_awid;
  assign host.awlen = host_awlen;
  assign host.awsize = host_awsize;
  assign host.awburst = host_awburst;
  assign host.awcache = host_awcache;
  assign host.wvalid = host_wvalid;
  assign host.wdata = host_wdata;
  assign host.wstrb = host_wstrb;
  assign host.wlast = host_wlast;
  assign host.bready = host_bready;
  assign host.arvalid = host_arvalid;
  assign host.araddr = host_araddr;
  assign host.arid = host_arid;
  assign host.arlen = host_arlen;
  assign host.arsize = host_arsize;
  assign host.arburst = host_arburst;
  assign host.arcache = host_arcache;
  assign host.rready = host_rready;
  assign host_awready = host.awready;
  assign host_wready = host.wready;
  assign host_bid = host.bid;
  assign host_bresp = host.bresp;
  assign host_bvalid = host.bvalid;
  assign host_arready = host.arready;
  assign host_rid = host.rid;
  assign host_rdata = host.rdata;
  assign host_rresp = host.rresp;
  assign host_rlast = host.rlast;
  assign host_rvalid = host.rvalid;
  assign ddr_awvalid = ddr.awvalid;
  assign ddr_awaddr = ddr.awaddr;
  assign ddr_awid = ddr.awid;
  assign ddr_awlen = ddr.awlen;
  assign ddr_awsize = ddr.awsize;
  assign ddr_awburst = ddr.awburst;
  assign ddr_awcache = ddr.awcache;
  assign ddr_wvalid = ddr.wvalid;
  assign ddr_wdata = ddr.wdata;
  assign ddr_wstrb = ddr.wstrb;
  assign ddr_wlast = ddr.wlast;
  assign ddr_bready = ddr.bready;
  assign ddr_arvalid = ddr.arvalid;
  assign ddr_araddr = ddr.araddr;
  assign ddr_arid = ddr.arid;
  assign ddr_arlen = ddr.arlen;
  assign ddr_arsize = ddr.arsize;
  assign ddr_arburst = ddr.arburst;
  assign ddr_arcache = ddr.arcache;
  assign ddr_rready = ddr.rready;
  assign ddr.awready = ddr_awready;
  assign ddr.wready = ddr_wready;
  assign ddr.bid = ddr_bid;
  assign ddr.bresp = ddr_bresp;
  assign ddr.bvalid = ddr_bvalid;
  assign ddr.arready = ddr_arready;
  assign ddr.rid = ddr_rid;
  assign ddr.rdata = ddr_rdata;
  assign ddr.rresp = ddr_rresp;
  assign ddr.rlast = ddr_rlast;
  assign ddr.rvalid = ddr_rvalid;
  rapt_native_soc #(
      .WithDdr(1),
      .ClockHz(50000000),
      .RomFile(`NATIVE_ROM_FILE)
  ) soc (
      .clk,
      .reset,
      .uart_rx(1'b1),
      .uart_tx(),
      .writeback_error,
      .peripheral_rd(),
      .peripheral_wr(),
      .peripheral_raddr(),
      .peripheral_waddr(),
      .peripheral_wdata(),
      .peripheral_wstrb(),
      .peripheral_rdata(32'b0),
      .peripheral_irq(1'b0),
      .replay(host),
      .ddr
  );
  assign cpu_reset = soc.replay_reset;
endmodule
