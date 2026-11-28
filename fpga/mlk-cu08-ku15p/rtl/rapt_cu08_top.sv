// axi4_if is supplied by the shared Raptor RTL compilation unit.
`include "native_config.svh"

module rapt_cu08_top (
    input wire clk100,
    input wire cpu_resetn,
    input wire serial_rx,
    output wire serial_tx,
`ifdef NATIVE_WITH_DDR
    input logic clk100_ddr_p,
    input logic clk100_ddr_n,
    output wire [16:0] ddram_adr,
    output wire [1:0] ddram_ba,
    output wire ddram_bg,
    output wire ddram_act_n,
    output wire ddram_cke,
    output wire ddram_odt,
    output wire ddram_cs_n,
    output wire ddram_clk_p,
    output wire ddram_clk_n,
    output wire ddram_reset_n,
    inout wire [7:0] ddram_dm,
    inout wire [63:0] ddram_dq,
    inout wire [7:0] ddram_dqs_p,
    inout wire [7:0] ddram_dqs_n,
`endif
`ifdef NATIVE_WITH_CM005_BRIDGE
    input wire cm005_clocks_rx,
    output wire cm005_clocks_tx,
    input wire cm005_rx_ctl,
    input wire [3:0] cm005_rx_data,
    output wire cm005_tx_ctl,
    output wire [3:0] cm005_tx_data,
    output wire cm005_mdc,
    inout wire cm005_mdio,
    output wire cm005_reset_gate,
    input wire cm005_b_clocks_rx,
    output wire cm005_b_clocks_tx,
    input wire cm005_b_rx_ctl,
    input wire [3:0] cm005_b_rx_data,
    output wire cm005_b_tx_ctl,
    output wire [3:0] cm005_b_tx_data,
    output wire cm005_b_mdc,
    inout wire cm005_b_mdio,
`endif
    output wire [4:0] user_led
);
  localparam int ClockHz = `NATIVE_CLOCK_HZ;
  wire clk_in, clk_ref, clk_fb, clk_fb_buf, clk_raw, clk, locked;
  IBUF input_buf (
      .I(clk100),
      .O(clk_in)
  );
  BUFG ref_buf (
      .I(clk_in),
      .O(clk_ref)
  );
  logic [15:0] por_count = '1;
  always_ff @(posedge clk_ref) begin
    if (por_count != 0) por_count <= por_count - 1'b1;
  end
  // CU08's reset-button pull-up has not been established on every revision.
  // Power-on reset is the default; enable the button explicitly at build time.
  wire pll_reset = (por_count != 0) || (`NATIVE_USE_RESET_BUTTON && !cpu_resetn);
  MMCME4_ADV #(
      .BANDWIDTH("OPTIMIZED"),
      .CLKIN1_PERIOD(10.0),
      .DIVCLK_DIVIDE(1),
      .CLKFBOUT_MULT_F(12.0),
      .CLKOUT0_DIVIDE_F(1200.0 / (ClockHz / 1.0e6)),
      .STARTUP_WAIT("FALSE")
  ) pll (
      .CLKIN1(clk_ref),
      .CLKIN2(1'b0),
      .CLKINSEL(1'b1),
      .CLKFBIN(clk_fb_buf),
      .CLKFBOUT(clk_fb),
      .CLKOUT0(clk_raw),
      .LOCKED(locked),
      .RST(pll_reset),
      .PWRDWN(1'b0),
      .DADDR(7'b0),
      .DCLK(1'b0),
      .DEN(1'b0),
      .DI(16'b0),
      .DWE(1'b0),
      .PSCLK(1'b0),
      .PSEN(1'b0),
      .PSINCDEC(1'b0),
      .CDDCDONE(),
      .CDDCREQ(1'b0)
  );
  BUFG feedback_buf (
      .I(clk_fb),
      .O(clk_fb_buf)
  );
  BUFG core_buf (
      .I(clk_raw),
      .O(clk)
  );
  (* ASYNC_REG = "TRUE" *) logic [2:0] reset_release = 0;
  always_ff @(posedge clk or negedge locked) begin
    if (!locked) reset_release <= 0;
    else reset_release <= {reset_release[1:0], 1'b1};
  end
  wire reset = !reset_release[2];
  logic ddr_ready, writeback_error;
  axi4_if ddr ();
`ifdef NATIVE_WITH_DDR
  // Avoid "memory": it is reserved by the MIG calibration BMM parser.
  rapt_cu08_ddr ddr_subsystem (
      .clk,
      .reset,
      .ready(ddr_ready),
      .bus(ddr),
      .clk100_ddr_p,
      .clk100_ddr_n,
      .ddram_adr,
      .ddram_ba,
      .ddram_bg,
      .ddram_act_n,
      .ddram_cke,
      .ddram_odt,
      .ddram_cs_n,
      .ddram_clk_p,
      .ddram_clk_n,
      .ddram_reset_n,
      .ddram_dm,
      .ddram_dq,
      .ddram_dqs_p,
      .ddram_dqs_n
  );
`else
  assign ddr_ready = 1'b1;
  assign ddr.awready = 0;
  assign ddr.wready = 0;
  assign ddr.bid = 0;
  assign ddr.bresp = 2'b11;
  assign ddr.bvalid = 0;
  assign ddr.arready = 0;
  assign ddr.rid = 0;
  assign ddr.rdata = 0;
  assign ddr.rresp = 2'b11;
  assign ddr.rlast = 0;
  assign ddr.rvalid = 0;
`endif
  logic peripheral_rd, peripheral_wr, peripheral_irq;
`ifdef NATIVE_WITH_SAMPLING
  axi4_if replay ();
  rapt_replay_jtag_port replay_transport (
      .clk,
      .reset(reset || !ddr_ready),
      .bus(replay)
  );
`endif
  logic [15:0] peripheral_raddr, peripheral_waddr;
  logic [31:0] peripheral_wdata, peripheral_rdata;
  logic [3:0] peripheral_wstrb;
`ifdef NATIVE_WITH_CM005_BRIDGE
`ifdef NATIVE_WITH_IO_SOC
  wire [31:0] cm_cpu_rx_data, cm_cpu_tx_data;
  wire [3:0] cm_cpu_rx_last_be, cm_cpu_tx_last_be;
  wire cm_cpu_rx_valid, cm_cpu_rx_last, cm_cpu_rx_ready;
  wire cm_cpu_tx_valid, cm_cpu_tx_last, cm_cpu_tx_ready;
  wire [7:0] io_eth_rx_data, io_eth_tx_data;
  wire io_eth_rx_valid, io_eth_rx_last, io_eth_rx_ready;
  wire io_eth_tx_valid, io_eth_tx_last, io_eth_tx_ready;

  rapt_eth_stream32_adapter cm005_io_adapt (
      .clk,
      .reset(reset || !ddr_ready),
      .rx32_data(cm_cpu_rx_data),
      .rx32_last_be(cm_cpu_rx_last_be),
      .rx32_valid(cm_cpu_rx_valid),
      .rx32_last(cm_cpu_rx_last),
      .rx32_ready(cm_cpu_rx_ready),
      .rx8_data(io_eth_rx_data),
      .rx8_valid(io_eth_rx_valid),
      .rx8_last(io_eth_rx_last),
      .rx8_ready(io_eth_rx_ready),
      .tx8_data(io_eth_tx_data),
      .tx8_valid(io_eth_tx_valid),
      .tx8_last(io_eth_tx_last),
      .tx8_ready(io_eth_tx_ready),
      .tx32_data(cm_cpu_tx_data),
      .tx32_last_be(cm_cpu_tx_last_be),
      .tx32_valid(cm_cpu_tx_valid),
      .tx32_last(cm_cpu_tx_last),
      .tx32_ready(cm_cpu_tx_ready)
  );
`elsif NATIVE_WITH_ETH_DMA
  axi4_if soc_ddr ();
  axi4_if eth_dma ();
  wire eth_ext_wr_valid;
  wire [63:0] eth_ext_wr_first, eth_ext_wr_last;
  wire [31:0] bridge_rdata, dma_rdata;
  wire bridge_irq, dma_irq;
  logic dma_rd_sel;
  wire [31:0] cm_cpu_rx_data, cm_cpu_tx_data;
  wire [3:0] cm_cpu_rx_last_be, cm_cpu_tx_last_be;
  wire cm_cpu_rx_valid, cm_cpu_rx_last, cm_cpu_rx_ready;
  wire cm_cpu_tx_valid, cm_cpu_tx_last, cm_cpu_tx_ready;
  wire [7:0] dma_rx_data, dma_tx_data;
  wire dma_rx_valid, dma_rx_last, dma_rx_ready;
  wire dma_tx_valid, dma_tx_last, dma_tx_ready;
  wire dma_enabled;

  always_ff @(posedge clk) begin
    if (peripheral_rd) dma_rd_sel <= (peripheral_raddr[15:12] == 4'h2);
  end
  assign peripheral_rdata = dma_rd_sel ? dma_rdata : bridge_rdata;
  assign peripheral_irq   = dma_irq;

  rapt_axi4_dma_arb eth_ddr_arb (
      .clk,
      .reset(reset || !ddr_ready),
      .m0(soc_ddr),
      .m1(eth_dma),
      .out(ddr)
  );

  rapt_eth_stream32_adapter cm005_dma_adapt (
      .clk,
      .reset(reset || !dma_enabled),
      .rx32_data(cm_cpu_rx_data),
      .rx32_last_be(cm_cpu_rx_last_be),
      .rx32_valid(cm_cpu_rx_valid),
      .rx32_last(cm_cpu_rx_last),
      .rx32_ready(cm_cpu_rx_ready),
      .rx8_data(dma_rx_data),
      .rx8_valid(dma_rx_valid),
      .rx8_last(dma_rx_last),
      .rx8_ready(dma_rx_ready),
      .tx8_data(dma_tx_data),
      .tx8_valid(dma_tx_valid),
      .tx8_last(dma_tx_last),
      .tx8_ready(dma_tx_ready),
      .tx32_data(cm_cpu_tx_data),
      .tx32_last_be(cm_cpu_tx_last_be),
      .tx32_valid(cm_cpu_tx_valid),
      .tx32_last(cm_cpu_tx_last),
      .tx32_ready(cm_cpu_tx_ready)
  );

  rapt_eth_axi_dma #(
      .RingDepth(64),
      .RxFcsBytes(0)
  ) cu08_eth_dma (
      .clk,
      .reset(reset || !ddr_ready),
      .clocks_ready(1'b1),
      .rd(peripheral_rd && (peripheral_raddr[15:12] == 4'h2)),
      .wr(peripheral_wr && (peripheral_waddr[15:12] == 4'h2)),
      .raddr({4'h0, peripheral_raddr[11:0]}),
      .waddr({4'h0, peripheral_waddr[11:0]}),
      .wdata(peripheral_wdata),
      .wstrb(peripheral_wstrb),
      .rdata(dma_rdata),
      .irq(dma_irq),
      .enabled(dma_enabled),
      .mdio_control(),
      .mdio_input(1'b1),
      .mac_rx_data(dma_rx_data),
      .mac_rx_valid(dma_rx_valid),
      .mac_rx_last(dma_rx_last),
      .mac_rx_error(1'b0),
      .mac_rx_ready(dma_rx_ready),
      .mac_tx_data(dma_tx_data),
      .mac_tx_valid(dma_tx_valid),
      .mac_tx_last(dma_tx_last),
      .mac_tx_ready(dma_tx_ready),
      .m_axi_awid(eth_dma.awid),
      .m_axi_awaddr(eth_dma.awaddr),
      .m_axi_awlen(eth_dma.awlen),
      .m_axi_awsize(eth_dma.awsize),
      .m_axi_awburst(eth_dma.awburst),
      .m_axi_awcache(eth_dma.awcache),
      .m_axi_awvalid(eth_dma.awvalid),
      .m_axi_awready(eth_dma.awready),
      .m_axi_wdata(eth_dma.wdata),
      .m_axi_wstrb(eth_dma.wstrb),
      .m_axi_wlast(eth_dma.wlast),
      .m_axi_wvalid(eth_dma.wvalid),
      .m_axi_wready(eth_dma.wready),
      .m_axi_bid(eth_dma.bid),
      .m_axi_bresp(eth_dma.bresp),
      .m_axi_bvalid(eth_dma.bvalid),
      .m_axi_bready(eth_dma.bready),
      .m_axi_arid(eth_dma.arid),
      .m_axi_araddr(eth_dma.araddr),
      .m_axi_arlen(eth_dma.arlen),
      .m_axi_arsize(eth_dma.arsize),
      .m_axi_arburst(eth_dma.arburst),
      .m_axi_arcache(eth_dma.arcache),
      .m_axi_arvalid(eth_dma.arvalid),
      .m_axi_arready(eth_dma.arready),
      .m_axi_rid(eth_dma.rid),
      .m_axi_rdata(eth_dma.rdata),
      .m_axi_rresp(eth_dma.rresp),
      .m_axi_rlast(eth_dma.rlast),
      .m_axi_rvalid(eth_dma.rvalid),
      .m_axi_rready(eth_dma.rready),
      .ext_wr_valid_o(eth_ext_wr_valid),
      .ext_wr_first_o(eth_ext_wr_first),
      .ext_wr_last_o(eth_ext_wr_last)
  );
`endif
  // The forwarder runs before DDR calibration and independently of CPU reset.
  // Its fixed 50 MHz system clock shares the native core PLL; PHY clocks remain
  // local to each CM005 port. Only the board power/reset domain resets it.
  (* keep_hierarchy = "yes" *)
  rapt_cm005_bridge cm005_bridge (
      .clk100(clk_ref),
      .cpu_resetn,
      .native_clk(clk),
      .native_reset(reset),
`ifdef NATIVE_WITH_IO_SOC
      .native_rd(peripheral_rd),
      .native_wr(peripheral_wr),
      .native_raddr(peripheral_raddr),
      .native_waddr(peripheral_waddr),
      .native_wdata(peripheral_wdata),
      .native_wstrb(peripheral_wstrb),
      .native_rdata(peripheral_rdata),
      .native_irq(peripheral_irq),
      .cpu_rx_data(cm_cpu_rx_data),
      .cpu_rx_last_be(cm_cpu_rx_last_be),
      .cpu_rx_valid(cm_cpu_rx_valid),
      .cpu_rx_last(cm_cpu_rx_last),
      .cpu_rx_ready(cm_cpu_rx_ready),
      .cpu_tx_data(cm_cpu_tx_data),
      .cpu_tx_last_be(cm_cpu_tx_last_be),
      .cpu_tx_valid(cm_cpu_tx_valid),
      .cpu_tx_last(cm_cpu_tx_last),
      .cpu_tx_ready(cm_cpu_tx_ready),
`elsif NATIVE_WITH_ETH_DMA
      .native_rd(peripheral_rd && (peripheral_raddr[15:12] == 4'h0)),
      .native_wr(peripheral_wr && (peripheral_waddr[15:12] == 4'h0)),
      .native_raddr(peripheral_raddr),
      .native_waddr(peripheral_waddr),
      .native_wdata(peripheral_wdata),
      .native_wstrb(peripheral_wstrb),
      .native_rdata(bridge_rdata),
      .native_irq(bridge_irq),
      .cpu_rx_data(cm_cpu_rx_data),
      .cpu_rx_last_be(cm_cpu_rx_last_be),
      .cpu_rx_valid(cm_cpu_rx_valid),
      .cpu_rx_last(cm_cpu_rx_last),
      .cpu_rx_ready(cm_cpu_rx_ready),
      .cpu_tx_data(cm_cpu_tx_data),
      .cpu_tx_last_be(cm_cpu_tx_last_be),
      .cpu_tx_valid(cm_cpu_tx_valid),
      .cpu_tx_last(cm_cpu_tx_last),
      .cpu_tx_ready(cm_cpu_tx_ready),
`else
      .native_rd(peripheral_rd),
      .native_wr(peripheral_wr),
      .native_raddr(peripheral_raddr),
      .native_waddr(peripheral_waddr),
      .native_wdata(peripheral_wdata),
      .native_wstrb(peripheral_wstrb),
      .native_rdata(peripheral_rdata),
      .native_irq(peripheral_irq),
`endif
      .cm005_clocks_rx,
      .cm005_clocks_tx,
      .cm005_rx_ctl,
      .cm005_rx_data,
      .cm005_tx_ctl,
      .cm005_tx_data,
      .cm005_mdc,
      .cm005_mdio,
      .cm005_reset_gate,
      .cm005_b_clocks_rx,
      .cm005_b_clocks_tx,
      .cm005_b_rx_ctl,
      .cm005_b_rx_data,
      .cm005_b_tx_ctl,
      .cm005_b_tx_data,
      .cm005_b_mdc,
      .cm005_b_mdio
  );
`else
  assign peripheral_rdata = '0;
  assign peripheral_irq = 1'b0;
`endif
`ifdef NATIVE_WITH_IO_SOC
  rapt_native_io_soc #(
      .WithDdr(`NATIVE_DDR),
      .WithPeripheral(`NATIVE_CM005_BRIDGE),
      .WithLocalVirtioNet(`NATIVE_LOCAL_VIRTIO_NET),
      .WithQemuBridge(`NATIVE_QEMU_BRIDGE),
      .CoherentDma(1'b1),
      .RqioUdpMode(1'b1),
      .FilterUnicast(1'b1),
      .LocalMac(48'h0115_5041_5202),
      .BridgeMac(48'h0215_5041_5202),
      .BridgeIp(32'hc0a8_325d),
      .HostIp(32'hc0a8_3201),
      .RamBytes(`NATIVE_RAM_BYTES),
      .ClockHz(ClockHz),
      .RomFile(`NATIVE_ROM_FILE)
  ) soc (
      .clk(clk),
      .reset(reset || !ddr_ready),
      .uart_rx(serial_rx),
      .uart_tx(serial_tx),
      .writeback_error(writeback_error),
      .peripheral_rd(peripheral_rd),
      .peripheral_wr(peripheral_wr),
      .peripheral_raddr(peripheral_raddr),
      .peripheral_waddr(peripheral_waddr),
      .peripheral_wdata(peripheral_wdata),
      .peripheral_wstrb(peripheral_wstrb),
      .peripheral_rdata(peripheral_rdata),
      .peripheral_irq(peripheral_irq),
      .eth_link_up_i(locked),
      .eth_rx_data_i(io_eth_rx_data),
      .eth_rx_valid_i(io_eth_rx_valid),
      .eth_rx_last_i(io_eth_rx_last),
      .eth_rx_ready_o(io_eth_rx_ready),
      .eth_tx_data_o(io_eth_tx_data),
      .eth_tx_valid_o(io_eth_tx_valid),
      .eth_tx_last_o(io_eth_tx_last),
      .eth_tx_ready_i(io_eth_tx_ready),
      .bridge_use_slip_i(1'b0),
      .slip_rx_data_i(8'h00),
      .slip_rx_valid_i(1'b0),
      .slip_rx_ready_o(),
      .slip_tx_data_o(),
      .slip_tx_valid_o(),
      .slip_tx_ready_i(1'b1),
      .ddr(ddr)
  );
`else
  rapt_native_soc #(
      .WithDdr(`NATIVE_DDR),
      .WithPeripheral(`NATIVE_CM005_BRIDGE),
      .RamBytes(`NATIVE_RAM_BYTES),
      .ClockHz(ClockHz),
      .RomFile(`NATIVE_ROM_FILE)
  ) soc (
`ifdef NATIVE_WITH_SAMPLING
      .replay,
`endif
      .clk,
      .reset(reset || !ddr_ready),
      .peripheral_rd,
      .peripheral_wr,
      .peripheral_raddr,
      .peripheral_waddr,
      .peripheral_wdata,
      .peripheral_wstrb,
      .peripheral_rdata,
      .peripheral_irq,
      .uart_rx(serial_rx),
      .uart_tx(serial_tx),
      .writeback_error,
`ifdef NATIVE_WITH_ETH_DMA
      .ext_wr_valid_i(eth_ext_wr_valid),
      .ext_wr_first_i(eth_ext_wr_first),
      .ext_wr_last_i(eth_ext_wr_last),
      .ddr(soc_ddr)
`else
      .ddr
`endif
  );
`endif
  logic [25:0] heartbeat = 0;
  always_ff @(posedge clk) begin
    if (reset) heartbeat <= 0;
    else heartbeat <= heartbeat + 1'b1;
  end
  assign user_led = {writeback_error, heartbeat[25], ddr_ready, !reset, locked};
endmodule
