`include "ysyx_macro.v"

// Universal Asynchronous Receiver-Transmitter
module ysyx_UART(
  input clk,

  input [1:0] arburst,
  input [2:0] arsize,
  input [7:0] arlen,
  input [3:0] arid,
  input [ADDR_W-1:0] araddr,
  input arvalid,
  output reg arready_o,

  output reg [3:0] rid,
  output reg rlast_o,
  output reg [DATA_W-1:0] rdata_o,
  output reg [1:0] rresp_o,
  output reg rvalid_o,
  input rready,

  input [1:0] awburst,
  input [2:0] awsize,
  input [7:0] awlen,
  input [3:0] awid,
  input [ADDR_W-1:0] awaddr,
  input awvalid,
  output reg awready_o,

  input wlast,
  input [DATA_W-1:0] wdata,
  input [7:0] wstrb,
  input wvalid,
  output reg wready_o,

  output reg [3:0] bid,
  output reg [1:0] bresp_o,
  output reg bvalid_o,
  input bready
);
  parameter ADDR_W = 32, DATA_W = 32;

  reg [19:0] lfsr = 101;
  wire ifsr_ready = `ysyx_IFSR_ENABLE ? lfsr[19] : 1;
  always @(posedge clk ) begin lfsr <= {lfsr[18:0], lfsr[19] ^ lfsr[18]}; end
  always @(posedge clk) begin
    rdata_o <= 0; rvalid_o <= 0; wready_o <= 0;
    if (arvalid & !rvalid_o & rready) begin
      if (ifsr_ready)
      begin
        rdata_o <= 0;
        rvalid_o <= 1;
      end
    end
    if (wvalid & bready) begin
      if (ifsr_ready & !wready_o)
      begin
        $write("%c", wdata[7:0]);
        npc_difftest_skip_ref();
        wready_o <= 1;
      end
    end
  end
endmodule //ysyx_UART

module ysyx_MEM_SRAM(
  input clk,

  input [1:0] arburst,
  input [2:0] arsize,
  input [7:0] arlen,
  input [3:0] arid,
  input [ADDR_W-1:0] araddr,
  input arvalid,
  output reg arready_o,

  output reg [3:0] rid,
  output reg rlast_o,
  output reg [DATA_W-1:0] rdata_o,
  output reg [1:0] rresp_o,
  output reg rvalid_o,
  input rready,

  input [1:0] awburst,
  input [2:0] awsize,
  input [7:0] awlen,
  input [3:0] awid,
  input [ADDR_W-1:0] awaddr,
  input awvalid,
  output reg awready_o,

  input wlast,
  input [DATA_W-1:0] wdata,
  input [7:0] wstrb,
  input wvalid,
  output reg wready_o,

  output reg [3:0] bid,
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
    if (arvalid & !rvalid_o & rready) begin
      if (ifsr_ready)
      begin
        pmem_read(araddr, mem_rdata_buf[0]);
        rdata_o <= mem_rdata_buf[0];
        rvalid_o <= 1;
      end
    end else begin
      rvalid_o <= 0; rdata_o <= 0;
    end
    if (wvalid & !wready_o & bready) begin
      if (ifsr_ready)
      begin
        pmem_write(awaddr, wdata, wstrb);
        wready_o <= 1;
      end
    end else begin
      wready_o <= 0;
    end
  end
endmodule //ysyx_MEM_SRAM
