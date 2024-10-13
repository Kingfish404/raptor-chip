`default_nettype none
//`define DBG

module SoC #(
    parameter bit[1023:0] RAM_FILE = "",
    parameter bit[31:0] CLK_FREQ = 50_000_000,
    parameter bit[31:0] BAUD_RATE = 9600,
    parameter bit[31:0] RAM_ADDR_WIDTH = 13  // RAM depth: 2^13 in 4 bytes words
) (
    input wire clk,
    input wire rst,
    // I/O
    output wire [5:0] led,
    input wire uart_rx,
    output wire uart_tx,
    input wire btn
);
  localparam bit [7:0] BitW = 32;
  wire auto_master_out_awready;
  wire auto_master_out_awvalid;
  wire [3:0] auto_master_out_awid;
  wire [BitW-1:0] auto_master_out_awaddr;
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
  wire [BitW-1:0] auto_master_out_araddr;
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
      .clock            (clk),
      .reset            (rst),
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


  ysyx_soc_perip #(
      .CLK_FREQ(CLK_FREQ),
      .RAM_FILE(`RAM_FILE),
      .RAM_ADDR_WIDTH(`RAM_ADDR_WIDTH),
      .BAUD_RATE(`UART_BAUD_RATE)
  ) perip (
      .clk(clk),
      .rst(rst),

      .led(led),
      .uart_rx(uart_rx),
      .uart_tx(uart_tx),
      .btn(btn),

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
endmodule


// Memory and Universal Asynchronous Receiver-Transmitter (UART)
module ysyx_soc_perip #(
    parameter bit[1023:0] RAM_FILE = "",
    parameter bit[31:0] CLK_FREQ = 50_000_000,
    parameter bit[31:0] BAUD_RATE = 9600,
    parameter bit[31:0] RAM_ADDR_WIDTH = 13  // RAM depth: 2^13 in 4 bytes words
) (
    input wire clk,
    input wire rst,

    output wire [5:0] led,
    input wire uart_rx,
    output wire uart_tx,
    input wire btn,

    input wire [1:0] arburst,
    input wire [2:0] arsize,
    input wire [7:0] arlen,
    input wire [3:0] arid,
    input wire [AddrW-1:0] araddr,
    input wire arvalid,
    output reg arready_o,

    output reg [3:0] rid,
    output reg rlast_o,
    output reg [DataW-1:0] rdata_o,
    output reg [1:0] rresp_o,
    output reg rvalid_o,
    input wire rready,

    input wire [1:0] awburst,
    input wire [2:0] awsize,
    input wire [7:0] awlen,
    input wire [3:0] awid,
    input wire [AddrW-1:0] awaddr,
    input wire awvalid,
    output wire awready_o,

    input wire wlast,
    input wire [DataW-1:0] wdata,
    input wire [7:0] wstrb,
    input wire wvalid,
    output reg wready_o,

    output reg [3:0] bid,
    output reg [1:0] bresp_o,
    output reg bvalid_o,
    input wire bready
);
  localparam bit [7:0] AddrW = 32, DataW = 64;

  reg [31:0] mem_rdata_buf[2];
  reg [2:0] state = 0, state_w = 0;
  reg is_writing = 0;

  // read transaction
  assign arready_o = (state == 'b000);

  assign rid = arid;
  assign rlast_o = 1'b1;
  assign rdata_o[31:0] = mem_rdata_buf[0];
  assign rdata_o[63:32] = mem_rdata_buf[1];
  assign rresp_o = 2'b00;
  assign rvalid_o = (state == 'b101);

  // write transaction
  assign awready_o = (state_w == 'b000);
  assign wready_o = (state_w == 'b011 & wvalid);

  assign bid = awid;
  assign bresp_o = 2'b00;
  assign bvalid_o = (state_w == 'b100);
  wire [7:0] wmask = (
    ({{8{awsize == 3'b000}} & 8'h1 }) |
    ({{8{awsize == 3'b001}} & 8'h3 }) |
    ({{8{awsize == 3'b010}} & 8'hf }) |
    (8'h00)
  );
  reg [31:0] ram_addrA;  // ram port A address
  reg [2:0] ram_reA;  // ram port A read enable
  wire [31:0] ram_doutA;  // data from ram port A

  wire [31:0] ram_addrW;
  reg [3:0] ram_weA;  // ram port A write enable
  reg [31:0] ram_dinA;  // data to ram port A
  logic [31:0] wdata_aligned, rdata_aligned;
  logic [3:0] wstrb_aligned;

  assign ram_addrA = araddr;
  assign ram_reA = (
    {{3{arsize == 3'b000}} & 3'b001} |
    {{3{arsize == 3'b001}} & 3'b010} |
    {{3{arsize == 3'b010}} & 3'b111} |
    3'b000);
  assign mem_rdata_buf[0] = rdata_aligned;
  assign mem_rdata_buf[1] = rdata_aligned;
  assign rdata_aligned = ram_doutA;

  assign ram_addrW = awaddr;
  assign ram_weA = {wvalid, wvalid, wvalid, wvalid} & (
    (ram_addrW[2:2] == 0) ? wstrb[3:0] : wstrb[7:4]);
  assign ram_dinA = (ram_addrW[2:2] == 0) ? wdata[31:0] : wdata[63:32];

  RAMIO #(
      .ADDR_WIDTH(RAM_ADDR_WIDTH),  // RAM depth: 2^x in 4 bytes words
      .DATA_FILE(RAM_FILE),  // initial memory content
      .CLK_FREQ(CLK_FREQ),
      .BAUD_RATE(BAUD_RATE)
  ) ramio (
      .rst(rst),
      .clk(clk),

      // port A: data memory, read / write byte addressable ram
      .addrA(ram_addrA[RAM_ADDR_WIDTH+1:0]),  // +1 because byte addressed
      .reA(ram_reA),  // read: reA[2] sign extended, b01 - byte, b10 - half word, b11 - word
      .doutA(ram_doutA),  // data out from 'ram_addrA' depending on 'ram_reA' one cycle later

      .addrW(ram_addrW[RAM_ADDR_WIDTH+1:0]),
      .weA(ram_weA),  // write: b01 - byte, b10 - half word, b11 - word
      .dinA(ram_dinA),  // data to write to 'ram_addrA' depending on 'ram_weA'

      // I/O
      .led(led),
      .btn(btn),
      .uart_tx(uart_tx),
      .uart_rx(uart_rx)
  );

  always @(posedge clk) begin
    if (rst) begin
      state   <= 'b000;
      state_w <= 'b000;
    end else begin
      case (state)
        'b000: begin
          // wait for arvalid
          if (arvalid) begin
            state <= 'b101;
          end
          if (arvalid) begin
            if ((araddr & 'b100) == 0) begin
            end else begin
            end
          end
        end
        'b001: begin
          // send rvalid
          state <= 'b010;
        end
        'b010: begin
          // send rready or wait for wlast
          begin
            state <= 'b011;
          end
        end
        'b011: begin
          // wait for rready
          if (rready) begin
            state <= 0;
          end
        end
        'b100: begin
          // wait for bready
          if (bready) begin
            state <= 0;
            is_writing <= 0;
          end
        end
        'b101: begin
          state <= 'b000;
        end
        default: begin
          state <= 'b000;
        end
      endcase

      case (state_w)
        'b000: begin
          // wait for arvalid
          if (awvalid) begin
            state_w <= 'b001;
          end
          if (awvalid) begin
            is_writing <= 1;
          end
        end
        'b001: begin
          // send rvalid
          state_w <= 'b010;
        end
        'b010: begin
          // send rready or wait for wlast
          if (is_writing) begin
            if (wlast) begin
              state_w <= 'b011;
            end
          end else begin
            state_w <= 'b011;
          end
        end
        'b011: begin
          // wait for rready
          if (is_writing) begin
            state_w <= 'b100;
          end
        end
        'b100: begin
          // wait for bready
          if (bready) begin
            state_w <= 0;
            is_writing <= 0;
          end
        end
        'b101: begin
          state_w <= 'b000;
        end
        default: begin
          state_w <= 'b000;
        end
      endcase
    end
  end
endmodule  //ysyx_MEM_SRAM



`undef DBG
`default_nettype wire
