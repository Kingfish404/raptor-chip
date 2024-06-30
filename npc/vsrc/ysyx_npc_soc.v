`include "ysyx_macro.v"

module ysyxSoC (
    input clock,
    reset
);
  parameter integer ADDR_W = 32, DATA_W = 32;
  wire auto_master_out_awready;
  wire auto_master_out_awvalid;
  wire [3:0] auto_master_out_awid;
  wire [ADDR_W-1:0] auto_master_out_awaddr;
  wire [7:0] auto_master_out_awlen;
  wire [2:0] auto_master_out_awsize;
  wire [1:0] auto_master_out_awburst;
  wire auto_master_out_wready;
  wire auto_master_out_wvalid;
  wire [63:0] auto_master_out_wdata;
  wire [7:0] auto_master_out_wstrb;
  wire auto_master_out_wlast;
  wire auto_master_out_bready;
  wire auto_master_out_bvalid;
  wire [3:0] auto_master_out_bid;
  wire [1:0] auto_master_out_bresp;
  wire auto_master_out_arready;
  wire auto_master_out_arvalid;
  wire [3:0] auto_master_out_arid;
  wire [ADDR_W-1:0] auto_master_out_araddr;
  wire [7:0] auto_master_out_arlen;
  wire [2:0] auto_master_out_arsize;
  wire [1:0] auto_master_out_arburst;
  wire auto_master_out_rready;
  wire auto_master_out_rvalid;
  wire [3:0] auto_master_out_rid;
  wire [63:0] auto_master_out_rdata;
  wire [1:0] auto_master_out_rresp;
  wire auto_master_out_rlast;

  ysyx cpu (  // src/CPU.scala:38:21
      .clock            (clock),
      .reset            (reset),
      .io_interrupt     (1'h0),
      .io_master_awready(auto_master_out_awready),
      .io_master_awvalid(auto_master_out_awvalid),
      .io_master_awid   (auto_master_out_awid),
      .io_master_awaddr (auto_master_out_awaddr),
      .io_master_awlen  (auto_master_out_awlen),
      .io_master_awsize (auto_master_out_awsize),
      .io_master_awburst(auto_master_out_awburst),
      .io_master_wready (auto_master_out_wready),
      .io_master_wvalid (auto_master_out_wvalid),
      .io_master_wdata  (auto_master_out_wdata),
      .io_master_wstrb  (auto_master_out_wstrb),
      .io_master_wlast  (auto_master_out_wlast),
      .io_master_bready (auto_master_out_bready),
      .io_master_bvalid (auto_master_out_bvalid),
      .io_master_bid    (auto_master_out_bid),
      .io_master_bresp  (auto_master_out_bresp),
      .io_master_arready(auto_master_out_arready),
      .io_master_arvalid(auto_master_out_arvalid),
      .io_master_arid   (auto_master_out_arid),
      .io_master_araddr (auto_master_out_araddr),
      .io_master_arlen  (auto_master_out_arlen),
      .io_master_arsize (auto_master_out_arsize),
      .io_master_arburst(auto_master_out_arburst),
      .io_master_rready (auto_master_out_rready),
      .io_master_rvalid (auto_master_out_rvalid),
      .io_master_rid    (auto_master_out_rid),
      .io_master_rdata  (auto_master_out_rdata),
      .io_master_rresp  (auto_master_out_rresp),
      .io_master_rlast  (auto_master_out_rlast),
      .io_slave_awready (  /* unused */),
      .io_slave_awvalid (1'h0),
      .io_slave_awid    (4'h0),
      .io_slave_awaddr  (32'h0),
      .io_slave_awlen   (8'h0),
      .io_slave_awsize  (3'h0),
      .io_slave_awburst (2'h0),
      .io_slave_wready  (  /* unused */),
      .io_slave_wvalid  (1'h0),
      .io_slave_wdata   (64'h0),
      .io_slave_wstrb   (8'h0),
      .io_slave_wlast   (1'h0),
      .io_slave_bready  (1'h0),
      .io_slave_bvalid  (  /* unused */),
      .io_slave_bid     (  /* unused */),
      .io_slave_bresp   (  /* unused */),
      .io_slave_arready (  /* unused */),
      .io_slave_arvalid (1'h0),
      .io_slave_arid    (4'h0),
      .io_slave_araddr  (32'h0),
      .io_slave_arlen   (8'h0),
      .io_slave_arsize  (3'h0),
      .io_slave_arburst (2'h0),
      .io_slave_rready  (1'h0),
      .io_slave_rvalid  (  /* unused */),
      .io_slave_rid     (  /* unused */),
      .io_slave_rdata   (  /* unused */),
      .io_slave_rresp   (  /* unused */),
      .io_slave_rlast   (  /* unused */)
  );

  ysyx_MEM_SRAM sram (
      .clk(clock),
      .arburst(auto_master_out_arburst),
      .arsize(auto_master_out_arsize),
      .arlen(auto_master_out_arlen),
      .arid(auto_master_out_arid),
      .araddr(auto_master_out_araddr),
      .arvalid(auto_master_out_arvalid),
      .arready_o(auto_master_out_arready),
      .rid(auto_master_out_rid),
      .rlast_o(auto_master_out_rlast),
      .rdata_o(auto_master_out_rdata),
      .rresp_o(auto_master_out_rresp),
      .rvalid_o(auto_master_out_rvalid),
      .rready(auto_master_out_rready),
      .awburst(auto_master_out_awburst),
      .awsize(auto_master_out_awsize),
      .awlen(auto_master_out_awlen),
      .awid(auto_master_out_awid),
      .awaddr(auto_master_out_awaddr),
      .awvalid(auto_master_out_awvalid),
      .awready_o(auto_master_out_awready),
      .wlast(auto_master_out_wlast),
      .wdata(auto_master_out_wdata),
      .wstrb(auto_master_out_wstrb),
      .wvalid(auto_master_out_wvalid),
      .wready_o(auto_master_out_wready),
      .bid(auto_master_out_bid),
      .bresp_o(auto_master_out_bresp),
      .bvalid_o(auto_master_out_bvalid),
      .bready(auto_master_out_bready)
  );
endmodule  //ysyxSoCNPC

// Universal Asynchronous Receiver-Transmitter
module ysyx_UART (
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
  always @(posedge clk) begin
    lfsr <= {lfsr[18:0], lfsr[19] ^ lfsr[18]};
  end
  always @(posedge clk) begin
    rdata_o  <= 0;
    rvalid_o <= 0;
    wready_o <= 0;
    if (arvalid & !rvalid_o & rready) begin
      if (ifsr_ready) begin
        rdata_o  <= 0;
        rvalid_o <= 1;
      end
    end
    if (wvalid & bready) begin
      if (ifsr_ready & !wready_o) begin
        $write("%c", wdata[7:0]);
        npc_difftest_skip_ref();
        wready_o <= 1;
      end
    end
  end
endmodule  //ysyx_UART

module ysyx_MEM_SRAM (
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
    output awready_o,

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
  parameter integer ADDR_W = 32, DATA_W = 64;

  reg [31:0] mem_rdata_buf[2];
  reg [2:0] state = 0;
  reg is_writing = 0;

  reg [19:0] lfsr = 101;
  wire ifsr_ready = `ysyx_IFSR_ENABLE ? lfsr[19] : 1;

  // read transaction
  assign arready_o = (state == 'b01 & arvalid);
  assign rdata_o[31:0] = mem_rdata_buf[0];
  assign rdata_o[63:32] = mem_rdata_buf[1];
  assign rvalid_o = (state == 'b10);

  // write transaction
  assign awready_o = (state == 'b01 & awvalid);
  assign wready_o = (state == 'b11 & wvalid);
  assign bvalid_o = (state == 'b100);

  always @(posedge clk) begin
    lfsr <= {lfsr[18:0], lfsr[19] ^ lfsr[18]};
  end
  always @(posedge clk) begin
    if (ifsr_ready) begin
      case (state)
        'b00: begin
          // wait for arvalid
          if (arvalid | awvalid) begin
            state <= 1;
          end
          if (arvalid) begin
            if ((araddr & 'b100) == 0) begin
              pmem_read(araddr, mem_rdata_buf[0]);
            end else begin
              pmem_read(araddr, mem_rdata_buf[1]);
            end
            // pmem_read(araddr & ~'h4, mem_rdata_buf[0]);
            // pmem_read(araddr & ~'h4 + 4, mem_rdata_buf[1]);
          end
          if (awvalid) begin
            is_writing <= 1;
          end
        end
        'b01: begin
          // send rvalid
          state <= 2;
        end
        'b10: begin
          // send rready or wait for wlast
          if (is_writing) begin
            if ((awaddr & 'b100) == 0) begin
              pmem_write(awaddr, wdata[31:0], {{4'b0}, {wstrb[3:0]}});
            end else begin
              pmem_write(awaddr, wdata[31:0], {{4'b0}, {wstrb[7:4]}});
            end
            if (wlast) begin
              state <= 3;
            end
          end else begin
            state <= 3;
          end
        end
        'b11: begin
          // wait for rready
          if (!is_writing & rready) begin
            state <= 0;
          end else if (is_writing) begin
            state <= 'b100;
          end
        end
        'b100: begin
          // wait for bready
          if (bready) begin
            state <= 0;
            is_writing <= 0;
          end
        end
      endcase
    end
  end
endmodule  //ysyx_MEM_SRAM
