`include "npc_macro.v"

// Universal Asynchronous Receiver-Transmitter
module ysyx_UART(
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

  reg [19:0] lfsr = 101;
  wire ifsr_ready = `ysyx_IFSR_ENABLE ? lfsr[19] : 1;
  always @(posedge clk ) begin lfsr <= {lfsr[18:0], lfsr[19] ^ lfsr[18]}; end
  always @(posedge clk) begin
    rdata_o <= 0; rvalid_o <= 0;
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
    end else begin
      wready_o <= 0;
    end
  end
endmodule //ysyx_UART

// Core Local INTerrupt controller
module ysyx_CLINT(
  input clk, rst,

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

  reg [63:0] mtime;
  reg [19:0] lfsr;
  wire ifsr_ready = `ysyx_IFSR_ENABLE ? lfsr[19] : 1;
  always @(posedge clk ) begin lfsr <= {lfsr[18:0], lfsr[19] ^ lfsr[18]}; end
  always @(posedge clk) begin
    if (rst) begin mtime <= 0; lfsr <= 101; end
    else begin mtime <= mtime + 1; end
    rdata_o <= 0; rvalid_o <= 0; wready_o <= 0;
    if (arvalid & !rvalid_o & rready) begin
      if (ifsr_ready)
      begin
        case (araddr)
          `ysyx_BUS_RTC_ADDR:     rdata_o <= mtime[31:0];
          `ysyx_BUS_RTC_ADDR_UP:  rdata_o <= mtime[63:32];
        endcase
        npc_difftest_skip_ref();
        rvalid_o <= 1;
      end
    end
    if (wvalid & !wready_o & bready) begin
      if (ifsr_ready)
      begin wready_o <= 1; end
    end
  end
endmodule //ysyx_CLINT

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
