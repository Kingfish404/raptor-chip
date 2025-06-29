`include "ysyx.svh"
`include "ysyx_soc.svh"
`include "ysyx_dpi_c.svh"


module rng_chip #(
    parameter bit [7:0] XLEN = `YSYX_XLEN
) (
    input clock,

    // rnp
    input  logic [XLEN-1:0] rnp_mdata,
    output logic [XLEN-1:0] rnp_cdata,

    output logic rnp_arvalid,
    input  logic rnp_arready,

    input  logic rnp_rvalid,
    output logic rnp_rready,

    output logic rnp_awvalid,
    input  logic rnp_awready,

    output logic [3:0] rnp_wstrb,
    output logic rnp_wvalid,
    input logic rnp_wready,

    input  logic rnp_bvalid,
    output logic rnp_bready,

    output logic [1:0] rnp_rwstate,

    input reset
);

  logic auto_master_out_awready_cpu;
  logic auto_master_out_awvalid_cpu;
  logic [3:0] auto_master_out_awid_cpu;
  logic [XLEN-1:0] auto_master_out_awaddr_cpu;
  logic [7:0] auto_master_out_awlen_cpu;
  logic [2:0] auto_master_out_awsize_cpu;
  logic [1:0] auto_master_out_awburst_cpu;
  logic auto_master_out_wready_cpu;
  logic auto_master_out_wvalid_cpu;
  logic [XLEN-1:0] auto_master_out_wdata_cpu;
  logic [3:0] auto_master_out_wstrb_cpu;
  logic auto_master_out_wlast_cpu;
  logic auto_master_out_bready_cpu;
  logic auto_master_out_bvalid_cpu;
  logic [3:0] auto_master_out_bid_cpu;
  logic [1:0] auto_master_out_bresp_cpu;
  logic auto_master_out_arready_cpu;
  logic auto_master_out_arvalid_cpu;
  logic [3:0] auto_master_out_arid_cpu;
  logic [XLEN-1:0] auto_master_out_araddr_cpu;
  logic [7:0] auto_master_out_arlen_cpu;
  logic [2:0] auto_master_out_arsize_cpu;
  logic [1:0] auto_master_out_arburst_cpu;
  logic auto_master_out_rready_cpu;
  logic auto_master_out_rvalid_cpu;
  logic [3:0] auto_master_out_rid_cpu;
  logic [XLEN-1:0] auto_master_out_rdata_cpu;
  logic [1:0] auto_master_out_rresp_cpu;
  logic auto_master_out_rlast_cpu;

  axi2rnp axi2rnp_inst (
      .clk(clock),
      .reset(reset),
      .axi_arready(auto_master_out_arready_cpu),
      .axi_arvalid(auto_master_out_arvalid_cpu),
      .axi_arid(auto_master_out_arid_cpu),
      .axi_araddr(auto_master_out_araddr_cpu),
      .axi_arlen(auto_master_out_arlen_cpu),
      .axi_arsize(auto_master_out_arsize_cpu),
      .axi_arburst(auto_master_out_arburst_cpu),
      .axi_rid(auto_master_out_rid_cpu),
      .axi_rready(auto_master_out_rready_cpu),
      .axi_rvalid(auto_master_out_rvalid_cpu),
      .axi_rdata(auto_master_out_rdata_cpu),
      .axi_rresp(auto_master_out_rresp_cpu),
      .axi_rlast(auto_master_out_rlast_cpu),
      .axi_awready(auto_master_out_awready_cpu),
      .axi_awvalid(auto_master_out_awvalid_cpu),
      .axi_awid(auto_master_out_awid_cpu),
      .axi_awaddr(auto_master_out_awaddr_cpu),
      .axi_awlen(auto_master_out_awlen_cpu),
      .axi_awsize(auto_master_out_awsize_cpu),
      .axi_awburst(auto_master_out_awburst_cpu),
      .axi_wready(auto_master_out_wready_cpu),
      .axi_wvalid(auto_master_out_wvalid_cpu),
      .axi_wdata(auto_master_out_wdata_cpu),
      .axi_wstrb(auto_master_out_wstrb_cpu),
      .axi_wlast(auto_master_out_wlast_cpu),
      .axi_bready(auto_master_out_bready_cpu),
      .axi_bvalid(auto_master_out_bvalid_cpu),
      .axi_bid(auto_master_out_bid_cpu),
      .axi_bresp(auto_master_out_bresp_cpu),
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

  ysyx cpu (  // src/CPU.scala:38:21
      .clock            (clock),
      .io_interrupt     (1'h0),
      .io_master_awready(auto_master_out_awready_cpu),
      .io_master_awvalid(auto_master_out_awvalid_cpu),
      .io_master_awid   (auto_master_out_awid_cpu),
      .io_master_awaddr (auto_master_out_awaddr_cpu),
      .io_master_awlen  (auto_master_out_awlen_cpu),
      .io_master_awsize (auto_master_out_awsize_cpu),
      .io_master_awburst(auto_master_out_awburst_cpu),

      .io_master_wready(auto_master_out_wready_cpu),
      .io_master_wvalid(auto_master_out_wvalid_cpu),
      .io_master_wdata (auto_master_out_wdata_cpu),
      .io_master_wstrb (auto_master_out_wstrb_cpu),
      .io_master_wlast (auto_master_out_wlast_cpu),

      .io_master_bready(auto_master_out_bready_cpu),
      .io_master_bvalid(auto_master_out_bvalid_cpu),
      .io_master_bid   (auto_master_out_bid_cpu),
      .io_master_bresp (auto_master_out_bresp_cpu),

      .io_master_arready(auto_master_out_arready_cpu),
      .io_master_arvalid(auto_master_out_arvalid_cpu),
      .io_master_arid   (auto_master_out_arid_cpu),
      .io_master_araddr (auto_master_out_araddr_cpu),
      .io_master_arlen  (auto_master_out_arlen_cpu),
      .io_master_arsize (auto_master_out_arsize_cpu),
      .io_master_arburst(auto_master_out_arburst_cpu),
      .io_master_rready (auto_master_out_rready_cpu),
      .io_master_rvalid (auto_master_out_rvalid_cpu),
      .io_master_rid    (auto_master_out_rid_cpu),
      .io_master_rdata  (auto_master_out_rdata_cpu),
      .io_master_rresp  (auto_master_out_rresp_cpu),
      .io_master_rlast  (auto_master_out_rlast_cpu),


`ifdef YSYX_USE_SLAVE
      .io_slave_awready(  /* unused */),
      .io_slave_awvalid(1'h0),
      .io_slave_awid   (4'h0),
      .io_slave_awaddr ('h0),
      .io_slave_awlen  (8'h0),
      .io_slave_awsize (3'h0),
      .io_slave_awburst(2'h0),
      .io_slave_wready (  /* unused */),
      .io_slave_wvalid (1'h0),
      .io_slave_wdata  ('h0),
      .io_slave_wstrb  (4'h0),
      .io_slave_wlast  (1'h0),
      .io_slave_bready (1'h0),
      .io_slave_bvalid (  /* unused */),
      .io_slave_bid    (  /* unused */),
      .io_slave_bresp  (  /* unused */),
      .io_slave_arready(  /* unused */),
      .io_slave_arvalid(1'h0),
      .io_slave_arid   (4'h0),
      .io_slave_araddr ('h0),
      .io_slave_arlen  (8'h0),
      .io_slave_arsize (3'h0),
      .io_slave_arburst(2'h0),
      .io_slave_rready (1'h0),
      .io_slave_rvalid (  /* unused */),
      .io_slave_rid    (  /* unused */),
      .io_slave_rdata  (  /* unused */),
      .io_slave_rresp  (  /* unused */),
      .io_slave_rlast  (  /* unused */),
`endif

      .reset(reset)
  );

endmodule

// verilator lint_off UNDRIVEN
// verilator lint_off PINCONNECTEMPTY
// verilator lint_off DECLFILENAME
// verilator lint_off UNUSEDSIGNAL
module wrapSoC #(
    parameter bit [7:0] XLEN = `YSYX_XLEN
) (
    input clock,
    input reset
);
  // rnp
  logic [XLEN-1:0] rnp_mdata;
  logic [XLEN-1:0] rnp_cdata;
  logic rnp_arvalid;
  logic rnp_arready;
  logic rnp_rvalid;
  logic rnp_rready;
  logic rnp_awvalid;
  logic rnp_awready;
  logic [3:0] rnp_wstrb;
  logic rnp_wvalid;
  logic rnp_wready;
  logic rnp_bvalid;
  logic rnp_bready;
  logic [1:0] rnp_rwstate;

  logic auto_master_out_awready_cpu;
  logic auto_master_out_awvalid_cpu;
  logic [3:0] auto_master_out_awid_cpu;
  logic [XLEN-1:0] auto_master_out_awaddr_cpu;
  logic [7:0] auto_master_out_awlen_cpu;
  logic [2:0] auto_master_out_awsize_cpu;
  logic [1:0] auto_master_out_awburst_cpu;
  logic auto_master_out_wready_cpu;
  logic auto_master_out_wvalid_cpu;
  logic [XLEN-1:0] auto_master_out_wdata_cpu;
  logic [3:0] auto_master_out_wstrb_cpu;
  logic auto_master_out_wlast_cpu;
  logic auto_master_out_bready_cpu;
  logic auto_master_out_bvalid_cpu;
  logic [3:0] auto_master_out_bid_cpu;
  logic [1:0] auto_master_out_bresp_cpu;
  logic auto_master_out_arready_cpu;
  logic auto_master_out_arvalid_cpu;
  logic [3:0] auto_master_out_arid_cpu;
  logic [XLEN-1:0] auto_master_out_araddr_cpu;
  logic [7:0] auto_master_out_arlen_cpu;
  logic [2:0] auto_master_out_arsize_cpu;
  logic [1:0] auto_master_out_arburst_cpu;
  logic auto_master_out_rready_cpu;
  logic auto_master_out_rvalid_cpu;
  logic [3:0] auto_master_out_rid_cpu;
  logic [XLEN-1:0] auto_master_out_rdata_cpu;
  logic [1:0] auto_master_out_rresp_cpu;
  logic auto_master_out_rlast_cpu;

  logic auto_master_out_awready_soc;
  logic auto_master_out_awvalid_soc;
  logic [3:0] auto_master_out_awid_soc;
  logic [XLEN-1:0] auto_master_out_awaddr_soc;
  logic [7:0] auto_master_out_awlen_soc;
  logic [2:0] auto_master_out_awsize_soc;
  logic [1:0] auto_master_out_awburst_soc;
  logic auto_master_out_wready_soc;
  logic auto_master_out_wvalid_soc;
  logic [XLEN-1:0] auto_master_out_wdata_soc;
  logic [3:0] auto_master_out_wstrb_soc;
  logic auto_master_out_wlast_soc;
  logic auto_master_out_bready_soc;
  logic auto_master_out_bvalid_soc;
  logic [3:0] auto_master_out_bid_soc;
  logic [1:0] auto_master_out_bresp_soc;
  logic auto_master_out_arready_soc;
  logic auto_master_out_arvalid_soc;
  logic [3:0] auto_master_out_arid_soc;
  logic [XLEN-1:0] auto_master_out_araddr_soc;
  logic [7:0] auto_master_out_arlen_soc;
  logic [2:0] auto_master_out_arsize_soc;
  logic [1:0] auto_master_out_arburst_soc;
  logic auto_master_out_rready_soc;
  logic auto_master_out_rvalid_soc;
  logic [3:0] auto_master_out_rid_soc;
  logic [XLEN-1:0] auto_master_out_rdata_soc;
  logic [1:0] auto_master_out_rresp_soc;
  logic auto_master_out_rlast_soc;

  rng_chip chip (
      .clock(clock),
      .reset(reset),
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

  rnp2axi rnp2axi_inst (
      .clk(clock),
      .reset(reset),
      .axi_arready(auto_master_out_arready_soc),
      .axi_arvalid(auto_master_out_arvalid_soc),
      .axi_arid(auto_master_out_arid_soc),
      .axi_araddr(auto_master_out_araddr_soc),
      .axi_arlen(auto_master_out_arlen_soc),
      .axi_arsize(auto_master_out_arsize_soc),
      .axi_arburst(auto_master_out_arburst_soc),
      .axi_rid(auto_master_out_rid_soc),
      .axi_rready(auto_master_out_rready_soc),
      .axi_rvalid(auto_master_out_rvalid_soc),
      .axi_rdata(auto_master_out_rdata_soc),
      .axi_rresp(auto_master_out_rresp_soc),
      .axi_rlast(auto_master_out_rlast_soc),
      .axi_awready(auto_master_out_awready_soc),
      .axi_awvalid(auto_master_out_awvalid_soc),
      .axi_awid(auto_master_out_awid_soc),
      .axi_awaddr(auto_master_out_awaddr_soc),
      .axi_awlen(auto_master_out_awlen_soc),
      .axi_awsize(auto_master_out_awsize_soc),
      .axi_awburst(auto_master_out_awburst_soc),
      .axi_wready(auto_master_out_wready_soc),
      .axi_wvalid(auto_master_out_wvalid_soc),
      .axi_wdata(auto_master_out_wdata_soc),
      .axi_wstrb(auto_master_out_wstrb_soc),
      .axi_wlast(auto_master_out_wlast_soc),
      .axi_bready(auto_master_out_bready_soc),
      .axi_bvalid(auto_master_out_bvalid_soc),
      .axi_bid(auto_master_out_bid_soc),
      .axi_bresp(auto_master_out_bresp_soc),
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


  ysyx_npc_soc perip (
      .clock(clock),
      .arburst(auto_master_out_arburst_soc),
      .arsize(auto_master_out_arsize_soc),
      .arlen(auto_master_out_arlen_soc),
      .arid(auto_master_out_arid_soc),
      .araddr(auto_master_out_araddr_soc),
      .arvalid(auto_master_out_arvalid_soc),
      .out_arready(auto_master_out_arready_soc),
      .out_rid(auto_master_out_rid_soc),
      .out_rlast(auto_master_out_rlast_soc),
      .out_rdata(auto_master_out_rdata_soc),
      .out_rresp(auto_master_out_rresp_soc),
      .out_rvalid(auto_master_out_rvalid_soc),
      .rready(auto_master_out_rready_soc),
      .awburst(auto_master_out_awburst_soc),
      .awsize(auto_master_out_awsize_soc),
      .awlen(auto_master_out_awlen_soc),
      .awid(auto_master_out_awid_soc),
      .awaddr(auto_master_out_awaddr_soc),
      .awvalid(auto_master_out_awvalid_soc),
      .out_awready(auto_master_out_awready_soc),
      .wlast(auto_master_out_wlast_soc),
      .wdata(auto_master_out_wdata_soc),
      .wstrb(auto_master_out_wstrb_soc),
      .wvalid(auto_master_out_wvalid_soc),
      .out_wready(auto_master_out_wready_soc),
      .out_bid(auto_master_out_bid_soc),
      .out_bresp(auto_master_out_bresp_soc),
      .out_bvalid(auto_master_out_bvalid_soc),
      .bready(auto_master_out_bready_soc),
      .reset(reset)
  );
endmodule


// verilator lint_on PINCONNECTEMPTY
// verilator lint_on UNDRIVEN
// verilator lint_on DECLFILENAME
// verilator lint_on UNUSEDSIGNAL
