`timescale 1ns / 1ps

// Reset-controller unit fixture. The CPU/pad stub is intentional; the separate
// CPU test exercises the actual chip, pad ownership and external XIP protocol.
module rapt_chip_pads25 #(
    parameter logic [23:0] FlashStorageOffset = 0,
    parameter int unsigned FlashWriteStart = 0,
    parameter int unsigned FlashWriteEnd = 0,
    parameter int unsigned CoreClockHz = 0,
    parameter int unsigned FlashHalfPeriod = 0,
    parameter int unsigned FlashPowerupCycles = 0,
    parameter int unsigned FlashResetCycles = 0,
    parameter int unsigned FlashRecoveryCycles = 0,
    parameter int unsigned FlashPollCycles = 0
) (
    input wire pad_clk,
    pad_reset_n,
    pad_irq,
    output wire pad_xspi_sclk,
    pad_xspi_cs_n,
    inout wire [7:0] pad_xspi_dq,
    input wire pad_jtag_tck,
    pad_jtag_tms,
    pad_jtag_tdi,
    output wire pad_jtag_tdo,
    inout wire pad_diag,
    input wire pad_uart0_rx,
    pad_uart1_rx,
    output wire pad_uart0_tx,
    pad_uart1_tx,
    inout wire pad_gpio0,
    pad_gpio1,
    pad_gpio2
);
  assign pad_xspi_sclk = 0;
  assign pad_xspi_cs_n = 1;
  assign pad_xspi_dq = 'z;
  assign pad_diag = 1'bz;
  assign pad_jtag_tdo = 0;
  assign pad_uart0_tx = 1;
  assign pad_uart1_tx = 1;
  assign {pad_gpio2, pad_gpio1, pad_gpio0} = 3'bzzz;
  initial begin
    if (FlashStorageOffset != 24'h800000 || FlashWriteStart != 32'h800000
        || FlashWriteEnd != 32'h1000000)
      $fatal(1, "Board protection parameters changed");
  end
endmodule

module tb_native_rom_reset;
  logic clk100 = 0;
  logic [1:0] btn = 0;
  wire shared_reset_n, ds;
  wire [7:0] dq;
  wire [2:0] gpio;
  always #5 clk100 = !clk100;
  rapt_arty_native_top dut (
      .clk100,
      .btn,
      .led(),
      .jtag_tck(1'b0),
      .jtag_tms(1'b1),
      .jtag_tdi(1'b1),
      .jtag_tdo(),
      .flash_ck(),
      .flash_cs_n(),
      .flash_reset_n(shared_reset_n),
      .flash_dqs(ds),
      .flash_dq(dq),
      .uart0_rx(1'b1),
      .uart0_tx(),
      .uart1_rx(1'b1),
      .uart1_tx(),
      .gpio
  );
  task automatic expect_reset(input logic expected);
    #20_000;
    if (shared_reset_n !== expected)
      $fatal(1, "Reset mismatch %b expected %b", shared_reset_n, expected);
  endtask
  initial begin
    expect_reset(1);
    btn[1] = 1;
    #1;
    if (shared_reset_n !== 0) $fatal(1, "BTN1 reset did not assert asynchronously");
    #2000;
    btn[1] = 0;
    expect_reset(1);
    btn[0] = 1;
    #1;
    if (shared_reset_n !== 0) $fatal(1, "Clock reset did not assert asynchronously");
    #2000;
    btn[0] = 0;
    expect_reset(1);
    $display("NATIVE_ROM_RESET_PASS automatic/reset/relock");
    $finish;
  end
endmodule
