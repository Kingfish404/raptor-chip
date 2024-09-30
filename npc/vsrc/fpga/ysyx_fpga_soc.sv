module ysyx_fpga_soc (
    input clock,
    input reset,

    output IO,

    input  uart_rx,
    output uart_tx
);
  parameter bit [7:0] ADDR_W = 32, DATA_W = 32;
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

  parameter count_value = 13_499_999;  // 计时 0.5S 所需要的计数次数

  reg [23:0] count_value_reg;
  reg IO_voltage_reg = 1'b0;

  always @(posedge clock) begin
    if (count_value_reg <= count_value) begin
      count_value_reg <= count_value_reg + 1'b1;
    end else begin
      count_value_reg <= 23'b0;
      IO_voltage_reg  <= ~IO_voltage_reg;
    end
  end
  assign IO = IO_voltage_reg;

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
endmodule
