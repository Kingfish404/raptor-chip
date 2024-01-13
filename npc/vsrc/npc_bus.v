`include "npc_macro.v"

module ysyx_BUS_ARBITER(
  input clk, rst,

  // ifu
  input reg [DATA_W-1:0] ifu_araddr,
  input reg ifu_arvalid,
  output ifu_arready_o,

  output [DATA_W-1:0] ifu_rdata_o,
  output [1:0] ifu_rresp_o,
  output ifu_rvalid_o,
  input ifu_rready,

  // lsu:load
  input reg [DATA_W-1:0] lsu_araddr,
  input reg lsu_arvalid,
  output lsu_arready_o,

  output [DATA_W-1:0] lsu_rdata_o,
  output [1:0] lsu_rresp_o,
  output lsu_rvalid_o,
  input lsu_rready,

  // lsu:store
  input reg [DATA_W-1:0] lsu_awaddr,
  input reg lsu_awvalid,
  output lsu_awready_o,

  input reg [DATA_W-1:0] lsu_wdata,
  input reg [7:0] lsu_wstrb,
  input reg lsu_wvalid,
  output lsu_wready_o,

  output [1:0] lsu_bresp_o,
  output lsu_bvalid_o,
  input lsu_bready
);
  parameter ADDR_W = 32, DATA_W = 32;

  reg [ADDR_W-1:0] araddr;
  reg arvalid;
  wire arready_o;
  wire [DATA_W-1:0] rdata_o;

  wire [1:0] rresp_o;
  wire rvalid_o;
  reg rready;

  reg [ADDR_W-1:0] awaddr;
  reg awvalid;
  wire awready_o;

  reg [DATA_W-1:0] wdata;
  reg [7:0] wstrb;
  reg wvalid;
  reg wready_o;

  wire [1:0] bresp_o;
  reg bvalid_o, bready;

  assign arvalid = ifu_arvalid | lsu_arvalid | lsu_awvalid;

  always @(*) begin
    araddr = 0;
    ifu_arready_o = 0;
    lsu_arready_o = 0;

    ifu_rdata_o = 0; ifu_rresp_o = 0; ifu_rvalid_o = 0;
    lsu_rdata_o = 0; lsu_rresp_o = 0; 
    rready = 0; awaddr = 0; awvalid = 0; wvalid = 0;
    lsu_awready_o = 0;
    lsu_bresp_o = 0; lsu_bvalid_o = 0; bready = 0;

    lsu_wready_o = wready_o;
    lsu_rvalid_o = rvalid_o;

    wstrb = 0; wdata = 0;
    if (ifu_arvalid) begin
      araddr = ifu_araddr;
      ifu_arready_o = arready_o;

      ifu_rdata_o = rdata_o;
      ifu_rresp_o = rresp_o;
      ifu_rvalid_o = rvalid_o;
      rready = ifu_rready;
    end else if (lsu_arvalid) begin
      araddr = lsu_araddr;
      lsu_arready_o = arready_o;

      lsu_rdata_o = rdata_o;
      lsu_rresp_o = rresp_o;
      rready = lsu_rready;
    end else if (lsu_awvalid) begin
      awaddr = lsu_awaddr;
      lsu_awready_o = awready_o;

      wdata = lsu_wdata;
      wstrb = lsu_wstrb;
      wvalid = lsu_wvalid;

      lsu_bresp_o = bresp_o;
      lsu_bvalid_o = bvalid_o;
      bready = lsu_bready;
    end
  end

  reg [19:0] lfsr = 1;
  wire ifsr_ready = `ysyx_IFSR_ENABLE ? lfsr[19] : 1;
  always @(posedge clk ) begin lfsr <= {lfsr[18:0], lfsr[19] ^ lfsr[18]}; end
  ysyx_MEM_SRAM #(.ADDR_W(ADDR_W), .DATA_W(DATA_W)) ifu_sram(
    .clk(clk),
    .araddr(araddr), .arvalid(arvalid), .arready_o(arready_o),
    .rdata_o(rdata_o), .rresp_o(rresp_o), .rvalid_o(rvalid_o), .rready(rready),
    .awaddr(awaddr), .awvalid(awvalid), .awready_o(awready_o),
    .wdata(wdata), .wstrb(wstrb), .wvalid(wvalid), .wready_o(wready_o),
    .bresp_o(bresp_o), .bvalid_o(bvalid_o), .bready(bready)
  );
endmodule

module ysyx_MEM_SRAM(
  input clk,

  input [ADDR_W-1:0] araddr,
  input arvalid,
  output reg arready_o,

  output reg [DATA_W-1:0] rdata_o,
  output reg [1:0] rresp_o,
  output reg rvalid_o,
  input rready,

  input [ADDR_W-1:0] awaddr,
  input awvalid,
  output reg awready_o,

  input [DATA_W-1:0] wdata,
  input [7:0] wstrb,
  input wvalid,
  output reg wready_o,

  output reg [1:0] bresp_o,
  output reg bvalid_o,
  input bready
);
  parameter ADDR_W = 32, DATA_W = 32;

  reg [31:0] mem_rdata_buf [0:1];
  reg [19:0] lfsr = 101;
  wire ifsr_ready = `ysyx_IFSR_ENABLE ? lfsr[19] : 1;
  always @(posedge clk ) begin lfsr <= {lfsr[18:0], lfsr[19] ^ lfsr[18]}; end
  always @(posedge clk) begin
    mem_rdata_buf[0] <= 0;
    rdata_o <= 0; rvalid_o <= 0; wready_o <= 0;
    if (arvalid & !rvalid_o & rready) begin
      if (ifsr_ready)
      begin
        pmem_read(araddr, mem_rdata_buf[0]);
        rdata_o <= mem_rdata_buf[0];
        rvalid_o <= 1;
      end
    end
    if (wvalid & !wready_o & bready) begin
      if (ifsr_ready)
      begin
        pmem_write(awaddr, wdata, wstrb);
        wready_o <= 1;
      end
    end
  end
endmodule //ysyx_EXU_LSU_SRAM
