// Direct native Flash fixture. The processor reaches the device without a bridge.
module rapt_arty_native_top #(
    parameter int unsigned CoreClockHz = 10_000_000,
    parameter int unsigned FlashHalfPeriod = CoreClockHz > 80_000_000
        ? (CoreClockHz + 9_999_999) / 10_000_000 : 8,
    parameter int unsigned FlashPowerupCycles = CoreClockHz + 1,
    parameter int unsigned FlashResetCycles = CoreClockHz / 10000 + 1,
    parameter int unsigned FlashRecoveryCycles = CoreClockHz + 1,
    parameter int unsigned FlashPollCycles = CoreClockHz / 2
) (
    input wire clk100,
    input wire [1:0] btn,
    output wire [3:0] led,
    input wire jtag_tck,
    input wire jtag_tms,
    input wire jtag_tdi,
    output wire jtag_tdo,
    output wire flash_ck,
    output wire flash_cs_n,
    output wire flash_reset_n,
    // The real chip pad retains its DIAG output/OE; preserve the full I/O boundary.
    inout wire flash_dqs,
    inout wire [7:0] flash_dq,
    input wire uart0_rx,
    output wire uart0_tx,
    input wire uart1_rx,
    output wire uart1_tx,
    inout wire [2:0] gpio
);
  wire core_clock, locked;
  wire reset_n = locked && !btn[1];
  wire chip_reset_n;
  logic [5:0] release_q = 0;

  rapt_arty_native_clocks #(
      .CoreClockHz(CoreClockHz)
  ) u_clocks (
      .clock_i(clk100),
      .reset_i(btn[0]),
      .core_clock_o(core_clock),
      .locked_o(locked)
  );

  // Chip and target share reset. Clock lock and the reset button only reset
  // the system; boot selection comes exclusively from retained SBA control.
  always_ff @(posedge core_clock or negedge reset_n) begin
    if (!reset_n) release_q <= 0;
    else release_q <= {release_q[4:0], 1'b1};
  end
  assign chip_reset_n = release_q[5] && reset_n;
  assign flash_reset_n = chip_reset_n;
  assign led = {uart1_tx, 1'b1, chip_reset_n, locked};

  rapt_chip_pads25 #(
      .CoreClockHz(CoreClockHz),
      .FlashStorageOffset(24'h800000),
      .FlashWriteStart(32'h00800000),
      .FlashWriteEnd(32'h01000000),
      .FlashHalfPeriod(FlashHalfPeriod),
      .FlashPowerupCycles(FlashPowerupCycles),
      .FlashResetCycles(FlashResetCycles),
      .FlashRecoveryCycles(FlashRecoveryCycles),
      .FlashPollCycles(FlashPollCycles)
  ) u_chip (
      .pad_clk(core_clock),
      .pad_reset_n(chip_reset_n),
      .pad_irq(1'b0),
      .pad_xspi_sclk(flash_ck),
      .pad_xspi_cs_n(flash_cs_n),
      .pad_xspi_dq(flash_dq),
      .pad_jtag_tck(jtag_tck),
      .pad_jtag_tms(jtag_tms),
      .pad_jtag_tdi(jtag_tdi),
      .pad_jtag_tdo(jtag_tdo),
      .pad_diag(flash_dqs),
      .pad_uart0_rx(uart0_rx),
      .pad_uart0_tx(uart0_tx),
      .pad_uart1_rx(uart1_rx),
      .pad_uart1_tx(uart1_tx),
      .pad_gpio0(gpio[0]),
      .pad_gpio1(gpio[1]),
      .pad_gpio2(gpio[2])
  );
endmodule
