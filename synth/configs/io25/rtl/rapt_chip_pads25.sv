// 25-signal integration: shared serial backends, two local UARTs and three
// GPIOs. Package contact duplication and physical protection are flow-owned.
module rapt_chip_pads25 #(
    parameter int XLEN = `RAPT_XLEN,
    parameter logic [23:0] FlashStorageOffset = 24'h000000,
    parameter int unsigned FlashWriteStart = 32'h00000000,
    parameter int unsigned FlashWriteEnd = 32'h00800000,
    parameter int unsigned CoreClockHz = 100_000_000,
    parameter int unsigned FlashHalfPeriod = CoreClockHz > 80_000_000
        ? (CoreClockHz + 9_999_999) / 10_000_000 : 8,
    parameter int unsigned FlashPowerupCycles = CoreClockHz + 1,
    parameter int unsigned FlashResetCycles = CoreClockHz / 10000 + 1,
    parameter int unsigned FlashRecoveryCycles = CoreClockHz + 1,
    parameter int unsigned FlashPollCycles = CoreClockHz / 2
) (
    input wire pad_clk,
    input wire pad_reset_n,
    input wire pad_irq,
    output wire pad_xspi_sclk,
    output wire pad_xspi_cs_n,
    inout wire [7:0] pad_xspi_dq,
    input wire pad_jtag_tck,
    input wire pad_jtag_tms,
    input wire pad_jtag_tdi,
    output wire pad_jtag_tdo,
    inout wire pad_diag,
    output wire pad_uart0_tx,
    input wire pad_uart0_rx,
    output wire pad_uart1_tx,
    input wire pad_uart1_rx,
    inout wire pad_gpio0,
    inout wire pad_gpio1,
    inout wire pad_gpio2
);
  localparam int PullUp   = 1;
  localparam int PullDown = 2;

  logic clk, rst_n, irq, sclk, cs_n, tck, tms, tdi, tdo, diag, diag_oe, ds;
  logic [7:0] dq_in, dq_out, dq_oe;
  logic [1:0] uart_rx, uart_tx;
  logic [2:0] gpio_in, gpio_out, gpio_oe;

  rapt_pad_in u_pad_clk (
      .pad(pad_clk),
      .c_o(clk)
  );
  rapt_pad_in #(
      .Pull(PullUp)
  ) u_pad_reset_n (
      .pad(pad_reset_n),
      .c_o(rst_n)
  );
  rapt_pad_in #(
      .Pull(PullDown)
  ) u_pad_irq (
      .pad(pad_irq),
      .c_o(irq)
  );
  rapt_pad_in #(
      .Pull(PullDown)
  ) u_pad_jtag_tck (
      .pad(pad_jtag_tck),
      .c_o(tck)
  );
  rapt_pad_in #(
      .Pull(PullUp)
  ) u_pad_jtag_tms (
      .pad(pad_jtag_tms),
      .c_o(tms)
  );
  rapt_pad_in #(
      .Pull(PullUp)
  ) u_pad_jtag_tdi (
      .pad(pad_jtag_tdi),
      .c_o(tdi)
  );
  rapt_pad_out u_pad_xspi_sclk (
      .i_i(sclk),
      .pad(pad_xspi_sclk)
  );
  rapt_pad_out u_pad_xspi_cs_n (
      .i_i(cs_n),
      .pad(pad_xspi_cs_n)
  );
  rapt_pad_out u_pad_jtag_tdo (
      .i_i(tdo),
      .pad(pad_jtag_tdo)
  );
  rapt_pad_bidi #(
      .Pull(PullDown)
  ) u_pad_diag (
      .i_i(diag),
      .oe_i(diag_oe),
      .c_o(ds),
      .pad(pad_diag)
  );

  for (genvar i = 0; i < 8; i++) begin : g_dq
    rapt_pad_bidi #(
        .Pull(PullDown)
    ) u_pad_xspi_dq (
        .i_i(dq_out[i]),
        .oe_i(dq_oe[i]),
        .c_o(dq_in[i]),
        .pad(pad_xspi_dq[i])
    );
  end

  rapt_pad_out u_pad_uart0_tx (
      .i_i(uart_tx[0]),
      .pad(pad_uart0_tx)
  );
  rapt_pad_in u_pad_uart0_rx (
      .pad(pad_uart0_rx),
      .c_o(uart_rx[0])
  );
  rapt_pad_out u_pad_uart1_tx (
      .i_i(uart_tx[1]),
      .pad(pad_uart1_tx)
  );
  rapt_pad_in u_pad_uart1_rx (
      .pad(pad_uart1_rx),
      .c_o(uart_rx[1])
  );
  rapt_pad_bidi u_pad_gpio0 (
      .i_i(gpio_out[0]),
      .oe_i(gpio_oe[0]),
      .c_o(gpio_in[0]),
      .pad(pad_gpio0)
  );
  rapt_pad_bidi u_pad_gpio1 (
      .i_i(gpio_out[1]),
      .oe_i(gpio_oe[1]),
      .c_o(gpio_in[1]),
      .pad(pad_gpio1)
  );
  rapt_pad_bidi u_pad_gpio2 (
      .i_i(gpio_out[2]),
      .oe_i(gpio_oe[2]),
      .c_o(gpio_in[2]),
      .pad(pad_gpio2)
  );

  rapt_chip #(
      .XLEN(XLEN),
      .FlashStorageOffset(FlashStorageOffset),
      .FlashWriteStart(FlashWriteStart),
      .FlashWriteEnd(FlashWriteEnd),
      .CoreClockHz(CoreClockHz),
      .FlashHalfPeriod(FlashHalfPeriod),
      .FlashPowerupCycles(FlashPowerupCycles),
      .FlashResetCycles(FlashResetCycles),
      .FlashRecoveryCycles(FlashRecoveryCycles),
      .FlashPollCycles(FlashPollCycles),
      .LocalIo(1'b1)
  ) u_chip (
      .clk_i(clk),
      .rst_ni(rst_n),
      .irq_i(irq),
      .xspi_sclk_o(sclk),
      .xspi_cs_no(cs_n),
      .xspi_dq_i(dq_in),
      .xspi_ds_i(ds),
      .xspi_dq_o(dq_out),
      .xspi_dq_oe_o(dq_oe),
      .jtag_tck_i(tck),
      .jtag_tms_i(tms),
      .jtag_tdi_i(tdi),
      .jtag_tdo_o(tdo),
      .diag_o(diag),
      .diag_oe_o(diag_oe),
      .uart_rx_i(uart_rx),
      .uart_tx_o(uart_tx),
      .gpio_i(gpio_in),
      .gpio_o(gpio_out),
      .gpio_oe_o(gpio_oe)
  );
endmodule
