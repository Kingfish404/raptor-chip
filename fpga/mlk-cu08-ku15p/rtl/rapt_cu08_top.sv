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
      .CLKFBOUT_MULT_F(10.0),
      .CLKOUT0_DIVIDE_F(1000.0 / (ClockHz / 1.0e6)),
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
  logic peripheral_rd, peripheral_wr;
  logic [15:0] peripheral_raddr, peripheral_waddr;
  logic [31:0] peripheral_wdata, peripheral_rdata;
  logic [3:0] peripheral_wstrb;
`ifdef NATIVE_WITH_CM005_BRIDGE
  // The forwarder runs before DDR calibration and independently of CPU reset.
  // Its fixed 50 MHz system clock shares the native core PLL; PHY clocks remain
  // local to each CM005 port. Only the board power/reset domain resets it.
  (* keep_hierarchy = "yes" *)
  rapt_cm005_bridge cm005_bridge (
      .clk100(clk_ref),
      .cpu_resetn,
      .native_clk(clk),
      .native_reset(reset),
      .native_rd(peripheral_rd),
      .native_wr(peripheral_wr),
      .native_raddr(peripheral_raddr),
      .native_waddr(peripheral_waddr),
      .native_wdata(peripheral_wdata),
      .native_wstrb(peripheral_wstrb),
      .native_rdata(peripheral_rdata),
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
`endif
  rapt_native_soc #(
      .WithDdr(`NATIVE_DDR),
      .WithPeripheral(`NATIVE_CM005_BRIDGE),
      .RamBytes(`NATIVE_RAM_BYTES),
      .ClockHz(ClockHz),
      .RomFile(`NATIVE_ROM_FILE)
  ) soc (
      .clk,
      .reset(reset || !ddr_ready),
      .peripheral_rd,
      .peripheral_wr,
      .peripheral_raddr,
      .peripheral_waddr,
      .peripheral_wdata,
      .peripheral_wstrb,
      .peripheral_rdata,
      .peripheral_irq(1'b0),
      .uart_rx(serial_rx),
      .uart_tx(serial_tx),
      .writeback_error,
      .ddr
  );
  logic [25:0] heartbeat = 0;
  always_ff @(posedge clk) begin
    if (reset) heartbeat <= 0;
    else heartbeat <= heartbeat + 1'b1;
  end
  assign user_led = {writeback_error, heartbeat[25], ddr_ready, !reset, locked};
endmodule
