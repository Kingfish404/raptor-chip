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

  // assign arvalid = ifu_arvalid | lsu_arvalid;

  always @(*) begin
    araddr = 0; arvalid = 0;
    ifu_arready_o = 0;
    lsu_arready_o = 0;

    ifu_rdata_o = 0; ifu_rresp_o = 0; ifu_rvalid_o = 0;
    lsu_rdata_o = 0; lsu_rresp_o = 0; 
    rready = 0; awaddr = 0; awvalid = 0; wvalid = 0;
    lsu_awready_o = 0;
    lsu_bresp_o = 0; lsu_bvalid_o = 0; bready = 0;

    lsu_wready_o = wready_o | uart_wready_o;
    lsu_rvalid_o = rvalid_o | clint_rvalid_o;

    wstrb = 0; wdata = 0;

    clint_arvalid = 0;
    uart_wvalid = 0;
    if (ifu_arvalid) begin
      arvalid = ifu_arvalid;
      araddr = ifu_araddr;
      ifu_arready_o = arready_o;

      ifu_rdata_o = rdata_o;
      ifu_rresp_o = rresp_o;
      ifu_rvalid_o = rvalid_o;
      rready = ifu_rready;
    end else if (lsu_arvalid) begin
      araddr = lsu_araddr; rready = lsu_rready;

      case (lsu_araddr)
        `ysyx_BUS_RTC_ADDR: begin
          clint_arvalid = lsu_arvalid;
          lsu_arready_o = clint_arready_o; lsu_rdata_o = clint_rdata_o; lsu_rresp_o = clint_rresp_o;
        end
        `ysyx_BUS_RTC_ADDR_UP: begin
          clint_arvalid = lsu_arvalid;
          lsu_arready_o = clint_arready_o; lsu_rdata_o = clint_rdata_o; lsu_rresp_o = clint_rresp_o;
        end
        `ysyx_BUS_FREQ_ADDR: begin
          clint_arvalid = lsu_arvalid;
          lsu_arready_o = clint_arready_o; lsu_rdata_o = clint_rdata_o; lsu_rresp_o = clint_rresp_o;
        end
        default: begin
          arvalid = lsu_arvalid;

          lsu_arready_o = arready_o;
          lsu_rdata_o = rdata_o;
          lsu_rresp_o = rresp_o;
        end
      endcase
    end else if (lsu_awvalid) begin
      awaddr = lsu_awaddr;

      wdata = lsu_wdata;
      wstrb = lsu_wstrb;
      bready = lsu_bready;
      uart_wvalid = 0;
      wvalid = 0;
      case (lsu_awaddr)
        `ysyx_BUS_SERIAL_PORT: begin
          lsu_awready_o = uart_awready_o;
          uart_wvalid = lsu_wvalid;

          lsu_bresp_o = uart_bresp_o;
          lsu_bvalid_o = uart_bvalid_o;
        end
        default: begin
          lsu_awready_o = awready_o;
          wvalid = lsu_wvalid;

          lsu_bresp_o = bresp_o;
          lsu_bvalid_o = bvalid_o;
        end
      endcase
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

  reg uart_wvalid;
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

  reg clint_arvalid;
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
