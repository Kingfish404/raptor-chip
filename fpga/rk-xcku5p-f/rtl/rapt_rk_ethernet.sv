// Gigabit-only native RK Ethernet. TX is independent of the PHY's RX clock,
// so MDIO autonegotiation cannot deadlock waiting for a transmitted clock.
module rapt_rk_ethernet (
    input wire clk,
    reset,
    input wire tx_clk,
    delay_clk,
    clock_locked,
    input wire rd,
    wr,
    input wire [15:0] raddr,
    waddr,
    input wire [31:0] wdata,
    input wire [3:0] wstrb,
    output wire [31:0] rdata,
    output wire irq,
    input wire eth_rxc,
    eth_rx_ctl,
    input wire [3:0] eth_rxd,
    output wire eth_txc,
    eth_tx_ctl,
    output wire [3:0] eth_txd,
    output wire eth_mdc,
    inout wire eth_mdio
);
  wire rx_input, rx_fb, rx_raw, rx_clk, rx_locked;
  wire delay_ready;
  IBUF rx_input_buf (
      .I(eth_rxc),
      .O(rx_input)
  );
  MMCME4_ADV #(
      .CLKIN1_PERIOD(8.0),
      .DIVCLK_DIVIDE(1),
      .CLKFBOUT_MULT_F(8.0),
      .CLKOUT0_DIVIDE_F(8.0),
      .CLKOUT0_PHASE(-180.0),
      .STARTUP_WAIT("FALSE")
  ) rx_pll (
      // Internal feedback retains the RX distribution delay needed by the
      // inverted sample clock. An external feedback BUFG would cancel it.
      .CLKIN1(rx_input),
      .CLKIN2(1'b0),
      .CLKINSEL(1'b1),
      .CLKFBIN(rx_fb),
      .CLKFBOUT(rx_fb),
      .CLKOUT0(rx_raw),
      .LOCKED(rx_locked),
      .RST(reset),
      .PWRDWN(1'b0),
      .DADDR(7'b0),
      .DCLK(1'b0),
      .DEN(1'b0),
      .DI(16'b0),
      .DWE(1'b0),
      .PSCLK(1'b0),
      .PSEN(1'b0),
      .PSINCDEC(1'b0),
      .CDDCREQ(1'b0)
  );
  BUFG rx_buffer (
      .I(rx_raw),
      .O(rx_clk)
  );
  // IDELAYCTRL requires >=50 ns reset after its reference clock is stable.
  (* ASYNC_REG = "TRUE" *) logic [4:0] delay_release = 0;
  wire delay_reset = reset || !clock_locked;
  always_ff @(posedge delay_clk or posedge delay_reset) begin
    if (delay_reset) delay_release <= 0;
    else delay_release <= {delay_release[3:0], 1'b1};
  end
  logic [4:0] delay_count = 0;
  always_ff @(posedge delay_clk) begin
    if (!delay_release[4]) delay_count <= 0;
    else if (!delay_count[4]) delay_count <= delay_count + 1'b1;
  end
  IDELAYCTRL #(
      .SIM_DEVICE("ULTRASCALE_PLUS")
  ) delay_control (
      .REFCLK(delay_clk),
      .RST(!delay_count[4]),
      .RDY(delay_ready)
  );
  wire ready_async = clock_locked && rx_locked && delay_ready;
  (* ASYNC_REG = "TRUE" *) logic [2:0] ready_sync;
  always_ff @(posedge clk or negedge ready_async) begin
    if (!ready_async) ready_sync <= 0;
    else ready_sync <= {ready_sync[1:0], 1'b1};
  end
  wire enabled;
  wire queue_reset = reset || !enabled || !ready_sync[2];
  (* ASYNC_REG = "TRUE" *) logic [2:0] rx_release, tx_release;
  always_ff @(posedge rx_clk or posedge queue_reset) begin
    if (queue_reset) rx_release <= 0;
    else rx_release <= {rx_release[1:0], 1'b1};
  end
  always_ff @(posedge tx_clk or posedge queue_reset) begin
    if (queue_reset) tx_release <= 0;
    else tx_release <= {tx_release[1:0], 1'b1};
  end
  wire rx_reset = !rx_release[2];
  wire tx_reset = !tx_release[2];
  wire [2:0] mdio_control;
  wire mdio_input;
  assign eth_mdc = mdio_control[0];
  IOBUF mdio_buffer (
      .I(mdio_control[2]),
      .T(!mdio_control[1]),
      .O(mdio_input),
      .IO(eth_mdio)
  );
  wire [7:0] rx_data, tx_data, gmii_rxd, gmii_txd;
  wire rx_valid, rx_last, rx_error, rx_bad_fcs, tx_valid, tx_ready, tx_last;
  wire gmii_rx_dv, gmii_rx_er, gmii_tx_en, gmii_tx_er;
  rapt_native_eth #(
      .RxFcsBytes(4)
  ) packets (
      .clk,
      .reset,
      .clocks_ready(ready_sync[2]),
      .rd,
      .wr,
      .raddr,
      .waddr,
      .wdata,
      .wstrb,
      .rdata,
      .irq,
      .enabled,
      .mdio_control,
      .mdio_input,
      .rx_clk,
      .rx_reset,
      .rx_data,
      .rx_valid,
      .rx_last,
      .rx_error,
      .rx_bad_fcs,
      .tx_clk,
      .tx_reset,
      .tx_data,
      .tx_valid,
      .tx_last,
      .tx_ready
  );
  rapt_rk_rgmii_rx receive (
      .clk(rx_clk),
      .reset(rx_reset),
      .pins(eth_rxd),
      .ctl(eth_rx_ctl),
      .data(gmii_rxd),
      .valid(gmii_rx_dv),
      .error(gmii_rx_er)
  );
  eth_mac_1g mac (
      .rx_clk,
      .rx_rst(rx_reset),
      .tx_clk,
      .tx_rst(tx_reset),
      .tx_axis_tdata(tx_data),
      .tx_axis_tvalid(tx_valid),
      .tx_axis_tready(tx_ready),
      .tx_axis_tlast(tx_last),
      .tx_axis_tuser(1'b0),
      .rx_axis_tdata(rx_data),
      .rx_axis_tvalid(rx_valid),
      .rx_axis_tlast(rx_last),
      .rx_axis_tuser(rx_error),
      .gmii_rxd,
      .gmii_rx_dv,
      .gmii_rx_er,
      .gmii_txd,
      .gmii_tx_en,
      .gmii_tx_er,
      .rx_clk_enable(1'b1),
      .tx_clk_enable(1'b1),
      .rx_mii_select(1'b0),
      .tx_mii_select(1'b0),
      .rx_error_bad_frame(),
      .rx_error_bad_fcs(rx_bad_fcs),
      .rx_fcs_reg(),
      .tx_fcs_reg(),
      .ifg_delay(8'd12)
  );
  for (genvar b = 0; b < 4; b++) begin : g_tx
    ODDRE1 send_data (
        .C(tx_clk),
        .SR(tx_reset),
        .D1(gmii_txd[b]),
        .D2(gmii_txd[b+4]),
        .Q(eth_txd[b])
    );
  end
  ODDRE1 send_control (
      .C(tx_clk),
      .SR(tx_reset),
      .D1(gmii_tx_en),
      .D2(gmii_tx_en ^ gmii_tx_er),
      .Q(eth_tx_ctl)
  );
  // The PHY inserts TXDLY; the clock must run even while the MAC is disabled.
  ODDRE1 send_clock (
      .C(tx_clk),
      .SR(1'b0),
      .D1(1'b1),
      .D2(1'b0),
      .Q(eth_txc)
  );
endmodule
