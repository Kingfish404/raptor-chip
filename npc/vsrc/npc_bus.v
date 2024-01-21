`include "npc_macro.v"

module ysyx_BUS_ARBITER(
  input clk, rst,

  // ifu
  input [DATA_W-1:0] ifu_araddr,
  input ifu_arvalid,
  output ifu_arready_o,

  output [DATA_W-1:0] ifu_rdata_o,
  output [1:0] ifu_rresp_o,
  output ifu_rvalid_o,
  input ifu_rready,

  // lsu:load
  input [DATA_W-1:0] lsu_araddr,
  input lsu_arvalid,
  output lsu_arready_o,

  output [DATA_W-1:0] lsu_rdata_o,
  output [1:0] lsu_rresp_o,
  output lsu_rvalid_o,
  input lsu_rready,

  // lsu:store
  input [DATA_W-1:0] lsu_awaddr,
  input lsu_awvalid,
  output lsu_awready_o,

  input [DATA_W-1:0] lsu_wdata,
  input [7:0] lsu_wstrb,
  input lsu_wvalid,
  output lsu_wready_o,

  output [1:0] lsu_bresp_o,
  output lsu_bvalid_o,
  input lsu_bready
);
  parameter ADDR_W = 32, DATA_W = 32;

  wire arready_o;
  wire [DATA_W-1:0] rdata_o;

  wire [1:0] rresp_o;
  wire rvalid_o;

  wire awready_o;

  wire wready_o;

  wire [1:0] sram_bresp_o;
  wire sram_bvalid_o;

  wire sram_arvalid = (ifu_arvalid | (lsu_arvalid & !clint_en));

  // read
  wire [ADDR_W-1:0] araddr = (ifu_arvalid) ? ifu_araddr : 
                  (lsu_arvalid) ? lsu_araddr : 0;
  wire rready = (ifu_arvalid) ? ifu_rready : 
                  (lsu_arvalid) ? lsu_rready : 0;

  // ifu read
  assign ifu_arready_o = (ifu_arvalid & (arready_o));
  assign ifu_rdata_o = ({DATA_W{ifu_arvalid}} & (rdata_o));
  assign ifu_rresp_o = ({2{ifu_arvalid}} & (rresp_o));
  assign ifu_rvalid_o = (ifu_arvalid & (rvalid_o));
  
  // lsu read
  wire clint_en = (lsu_araddr == `ysyx_BUS_RTC_ADDR) | (lsu_araddr == `ysyx_BUS_RTC_ADDR_UP);
  assign lsu_arready_o = (lsu_arvalid & (clint_arready_o | lsu_arvalid));
  assign lsu_rdata_o = ({DATA_W{lsu_arvalid}} & (
    ({DATA_W{clint_en}} & clint_rdata_o) | 
    ({DATA_W{!clint_en}} & rdata_o)
  ));
  assign lsu_rresp_o = clint_rresp_o | rresp_o;

  // lsu write
  wire uart_en = (lsu_awaddr == `ysyx_BUS_SERIAL_PORT);
  wire sram_en = (lsu_awaddr != `ysyx_BUS_SERIAL_PORT);
  wire uart_wvalid = (lsu_awvalid & (uart_en));
  wire sram_wvalid = (lsu_wvalid & (sram_en));
  wire awvalid = sram_wvalid;
  wire [ADDR_W-1:0] awaddr = lsu_awaddr;
  wire [DATA_W-1:0] wdata = lsu_wdata;
  wire [7:0] wstrb = lsu_wstrb;
  wire bready = lsu_bready;
  assign lsu_awready_o = (
    (uart_en & uart_awready_o) | 
    (sram_en & awready_o)
  );
  assign lsu_wready_o = wready_o | uart_wready_o;
  assign lsu_rvalid_o = rvalid_o | clint_rvalid_o;
  assign lsu_bvalid_o = (
    (uart_en & uart_bvalid_o) | 
    (sram_en & sram_bvalid_o)
  );
  assign lsu_bresp_o = (
    ({2{uart_en}} & uart_bresp_o) | 
    ({2{sram_en}} & sram_bresp_o)
  );

  reg [19:0] lfsr = 1;
  wire ifsr_ready = `ysyx_IFSR_ENABLE ? lfsr[19] : 1;
  always @(posedge clk ) begin lfsr <= {lfsr[18:0], lfsr[19] ^ lfsr[18]}; end
  ysyx_MEM_SRAM #(.ADDR_W(ADDR_W), .DATA_W(DATA_W)) sram(
    .clk(clk),
    .araddr(araddr), .arvalid(sram_arvalid), .arready_o(arready_o),
    .rdata_o(rdata_o), .rresp_o(rresp_o), .rvalid_o(rvalid_o), .rready(rready),
    .awaddr(awaddr), .awvalid(awvalid), .awready_o(awready_o),
    .wdata(wdata), .wstrb(wstrb), .wvalid(sram_wvalid), .wready_o(wready_o),
    .bresp_o(sram_bresp_o), .bvalid_o(sram_bvalid_o), .bready(bready)
  );

  wire [DATA_W-1:0] uart_rdata_o;
  wire [1:0] uart_rresp_o, uart_bresp_o;
  wire uart_arready_o, uart_rvalid_o, uart_awready_o, uart_wready_o, uart_bvalid_o;
  ysyx_UART #(.ADDR_W(ADDR_W), .DATA_W(DATA_W)) uart(
    .clk(clk),
    .araddr(0), .arvalid(0), .arready_o(uart_arready_o),
    .rdata_o(uart_rdata_o), .rresp_o(uart_rresp_o), .rvalid_o(uart_rvalid_o), .rready(0),
    .awaddr(awaddr), .awvalid(awvalid), .awready_o(uart_awready_o),
    .wdata(wdata), .wstrb(wstrb), .wvalid(uart_wvalid), .wready_o(uart_wready_o),
    .bresp_o(uart_bresp_o), .bvalid_o(uart_bvalid_o), .bready(bready)
  );

  wire clint_arvalid = (lsu_arvalid & clint_en);
  wire clint_arready_o;
  wire [DATA_W-1:0] clint_rdata_o;
  wire [1:0] clint_rresp_o, clint_bresp_o;
  wire clint_rvalid_o;
  wire clint_awready_o, clint_wready_o, clint_bvalid_o;
  ysyx_CLINT #(.ADDR_W(ADDR_W), .DATA_W(DATA_W)) clint(
    .clk(clk), .rst(rst),
    .araddr(araddr), .arvalid(clint_arvalid), .arready_o(clint_arready_o),
    .rdata_o(clint_rdata_o), .rresp_o(clint_rresp_o), .rvalid_o(clint_rvalid_o), .rready(rready),
    .awaddr(0), .awvalid(0), .awready_o(clint_awready_o),
    .wdata(0), .wstrb(0), .wvalid(0), .wready_o(clint_wready_o),
    .bresp_o(clint_bresp_o), .bvalid_o(clint_bvalid_o), .bready(0)
  );
endmodule
