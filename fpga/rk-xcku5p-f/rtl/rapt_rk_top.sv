// axi4_if is supplied by the shared Raptor RTL compilation unit.
`include "native_config.svh"

module rapt_rk_top (
    input wire sys_clk_p,
    input wire sys_clk_n,
    input wire cpu_resetn,
    input wire serial_rx,
    output wire serial_tx,
`ifdef NATIVE_WITH_ETHERNET
    input wire eth_rxc,
    eth_rx_ctl,
    input wire [3:0] eth_rxd,
    output wire eth_txc,
    eth_tx_ctl,
    output wire [3:0] eth_txd,
    output wire eth_mdc,
    inout wire eth_mdio,
`endif
`ifdef NATIVE_WITH_DDR
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
    inout wire [3:0] ddram_dm,
    inout wire [31:0] ddram_dq,
    inout wire [3:0] ddram_dqs_p,
    inout wire [3:0] ddram_dqs_n,
`endif
    output wire fan_enable,
    output wire [3:0] user_led
);
  localparam int  ClockHz   = `NATIVE_CLOCK_HZ;
  // Share the main MMCM for TX125/ref300. MIG and RX each use one more;
  // the debug hub reuses the core clock without an additional MMCM divider.
  localparam real PllVcoMHz = `NATIVE_ETHERNET ? 1500.0 : 1000.0;
  wire eth_tx_raw, eth_delay_raw;
  wire clk_in, clk_ref, clk_fb, clk_fb_buf, clk_raw, clk, locked;
  IBUFDS input_buf (
      .I(sys_clk_p),
      .IB(sys_clk_n),
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
  // Power-on reset is always available; KEY1 can optionally assert reset.
  wire pll_reset = (por_count != 0) || (`NATIVE_USE_RESET_BUTTON && !cpu_resetn);
  MMCME4_ADV #(
      .BANDWIDTH("OPTIMIZED"),
      .CLKIN1_PERIOD(5.0),
      .DIVCLK_DIVIDE(1),
      .CLKFBOUT_MULT_F(PllVcoMHz / 200.0),
      .CLKOUT0_DIVIDE_F(PllVcoMHz / (ClockHz / 1.0e6)),
      .CLKOUT1_DIVIDE(12),
      .CLKOUT2_DIVIDE(5),
      .STARTUP_WAIT("FALSE")
  ) pll (
      .CLKIN1(clk_ref),
      .CLKIN2(1'b0),
      .CLKINSEL(1'b1),
      .CLKFBIN(clk_fb_buf),
      .CLKFBOUT(clk_fb),
      .CLKOUT0(clk_raw),
      .CLKOUT1(eth_tx_raw),
      .CLKOUT2(eth_delay_raw),
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
  rapt_rk_ddr ddr_subsystem (
      .clk,
      .reset,
      .ready(ddr_ready),
      .bus(ddr),
      .sys_clk(clk_in),
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
  wire peripheral_rd, peripheral_wr, peripheral_irq;
  wire [15:0] peripheral_raddr, peripheral_waddr;
  wire [31:0] peripheral_wdata, peripheral_rdata;
  wire [3:0] peripheral_wstrb;
`ifdef NATIVE_WITH_ETHERNET
  wire eth_tx_clk, eth_delay_clk;
  BUFG eth_tx_buffer (
      .I(eth_tx_raw),
      .O(eth_tx_clk)
  );
  BUFG eth_delay_buffer (
      .I(eth_delay_raw),
      .O(eth_delay_clk)
  );
  rapt_rk_ethernet ethernet (
      .clk,
      .reset,
      .tx_clk(eth_tx_clk),
      .delay_clk(eth_delay_clk),
      .clock_locked(locked),
      .rd(peripheral_rd),
      .wr(peripheral_wr),
      .raddr(peripheral_raddr),
      .waddr(peripheral_waddr),
      .wdata(peripheral_wdata),
      .wstrb(peripheral_wstrb),
      .rdata(peripheral_rdata),
      .irq(peripheral_irq),
      .eth_rxc,
      .eth_rx_ctl,
      .eth_rxd,
      .eth_txc,
      .eth_tx_ctl,
      .eth_txd,
      .eth_mdc,
      .eth_mdio
  );
`else
  assign peripheral_irq = 0;
  assign peripheral_rdata = 0;
`endif
  rapt_native_soc #(
      .WithDdr(`NATIVE_DDR),
      .WithPeripheral(`NATIVE_ETHERNET),
      .RamBytes(`NATIVE_RAM_BYTES),
      .ClockHz(ClockHz),
      .RomFile(`NATIVE_ROM_FILE)
  ) soc (
      .clk,
      .reset(reset || !ddr_ready),
      .uart_rx(serial_rx),
      .uart_tx(serial_tx),
      .writeback_error,
      .peripheral_rd,
      .peripheral_wr,
      .peripheral_raddr,
      .peripheral_waddr,
      .peripheral_wdata,
      .peripheral_wstrb,
      .peripheral_rdata,
      .peripheral_irq,
      .ddr
  );
  logic [25:0] heartbeat = 0;
  always_ff @(posedge clk) begin
    if (reset) heartbeat <= 0;
    else heartbeat <= heartbeat + 1'b1;
  end
  assign fan_enable = 1'b1;
  assign user_led = {writeback_error, heartbeat[25], ddr_ready, !reset};
endmodule
