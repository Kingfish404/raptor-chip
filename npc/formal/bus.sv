`include "ysyx.svh"

module formal_bus (
    input clock,
    input reset,

    // AXI4 Master
    output [1:0] io_master_arburst,
    output [2:0] io_master_arsize,
    output [7:0] io_master_arlen,
    output [3:0] io_master_arid,
    output [XLEN-1:0] io_master_araddr,
    output io_master_arvalid,
    input reg io_master_arready,

    input reg [3:0] io_master_rid,
    input reg io_master_rlast,
    input reg [XLEN-1:0] io_master_rdata,
    input reg [1:0] io_master_rresp,
    input reg io_master_rvalid,
    output io_master_rready,

    output [1:0] io_master_awburst,
    output [2:0] io_master_awsize,
    output [7:0] io_master_awlen,
    output [3:0] io_master_awid,
    output [XLEN-1:0] io_master_awaddr,
    output io_master_awvalid,
    input reg io_master_awready,

    output io_master_wlast,
    output [XLEN-1:0] io_master_wdata,
    output [3:0] io_master_wstrb,
    output io_master_wvalid,
    input reg io_master_wready,

    input reg [3:0] io_master_bid,
    input reg [1:0] io_master_bresp,
    input reg io_master_bvalid,
    output io_master_bready,

    // ifu
    input [XLEN-1:0] ifu_araddr,
    input ifu_arvalid,
    input ifu_required,
    output [XLEN-1:0] bus_ifu_rdata,
    output bus_ifu_rvalid,

    // lsu:load
    input [XLEN-1:0] lsu_araddr,
    input lsu_arvalid,
    input [7:0] lsu_rstrb,
    output [XLEN-1:0] bus_lsu_rdata,
    output bus_lsu_rvalid,

    // lsu:store
    input [XLEN-1:0] lsu_awaddr,
    input lsu_awvalid,
    input [XLEN-1:0] lsu_wdata,
    input [7:0] lsu_wstrb,
    input lsu_wvalid,
    output bus_lsu_wready
);
  parameter bit [7:0] XLEN = `YSYX_XLEN;

  ysyx_bus bus (
      .clock(clock),

      .io_master_arburst(io_master_arburst),
      .io_master_arsize(io_master_arsize),
      .io_master_arlen(io_master_arlen),
      .io_master_arid(io_master_arid),
      .io_master_araddr(io_master_araddr),
      .io_master_arvalid(io_master_arvalid),
      .io_master_arready(io_master_arready),

      .io_master_rid(io_master_rid),
      .io_master_rlast(io_master_rlast),
      .io_master_rdata(io_master_rdata),
      .io_master_rresp(io_master_rresp),
      .io_master_rvalid(io_master_rvalid),
      .io_master_rready(io_master_rready),

      .io_master_awburst(io_master_awburst),
      .io_master_awsize(io_master_awsize),
      .io_master_awlen(io_master_awlen),
      .io_master_awid(io_master_awid),
      .io_master_awaddr(io_master_awaddr),
      .io_master_awvalid(io_master_awvalid),
      .io_master_awready(io_master_awready),

      .io_master_wlast (io_master_wlast),
      .io_master_wdata (io_master_wdata),
      .io_master_wstrb (io_master_wstrb),
      .io_master_wvalid(io_master_wvalid),
      .io_master_wready(io_master_wready),

      .io_master_bid(io_master_bid),
      .io_master_bresp(io_master_bresp),
      .io_master_bvalid(io_master_bvalid),
      .io_master_bready(io_master_bready),

      .ifu_araddr(ifu_araddr),
      .ifu_arvalid(ifu_arvalid),
      .ifu_required(ifu_required),
      .out_ifu_rdata(bus_ifu_rdata),
      .out_ifu_rvalid(bus_ifu_rvalid),

      .lsu_araddr(lsu_araddr),
      .lsu_arvalid(lsu_arvalid),
      .lsu_rstrb(lsu_rstrb),
      .out_lsu_rdata(bus_lsu_rdata),
      .out_lsu_rvalid(bus_lsu_rvalid),

      .lsu_awaddr(lsu_awaddr),
      .lsu_awvalid(lsu_awvalid),
      .lsu_wdata(lsu_wdata),
      .lsu_wstrb(lsu_wstrb),
      .lsu_wvalid(lsu_wvalid),
      .out_lsu_wready(bus_lsu_wready),

      .reset(reset)
  );

`ifdef FORMAL
  always @(*) begin
    if (XLEN == 32) begin
      arsize_assert : assert (io_master_arsize != 3'b011);
      awsize_assert : assert (io_master_awsize != 3'b011);
    end
  end
`endif  // FORMAL
endmodule
