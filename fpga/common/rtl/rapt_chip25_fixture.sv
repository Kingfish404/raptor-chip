// Common FPGA emulation composition. Board wrappers supply clocks and pins.
// FlashMode selects the attached target. Bridge operation requires a JTAG
// boot-control write followed by ndmreset; the chip always powers up in ROM-XIP.
module rapt_chip25_fixture #(
    parameter bit FlashMode = 1'b1,
    parameter int unsigned CoreClockHz = 10_000_000,
    parameter string FlashInitFile = "",
    parameter string RomFile = "mrom.hex",
    parameter int unsigned FlashPowerupCycles = CoreClockHz + 1,
    parameter int unsigned FlashRecoveryCycles = CoreClockHz + 1
) (
    input logic board_clock_i,
    input logic chip_clock_i,
    input logic reset_ni,
    input logic host_rx_i,
    output wire host_tx_o,
    input logic [1:0] uart_rx_i,
    output wire [1:0] uart_tx_o,
    inout wire [2:0] gpio,
    input logic jtag_tck_i,
    input logic jtag_tms_i,
    input logic jtag_tdi_i,
    output wire jtag_tdo_o,
    output wire chip_reset_no,
    output wire frame_active_o,
    output wire [31:0] programs_o,
    output wire [31:0] erases_o,
    output wire [31:0] last_program_o,
    output wire [31:0] last_erase_o,
    output wire [31:0] octal_frames_o
);
  wire ck, cs_n, diag, run;
  wire [7:0] dq, return_data, return_oe;
  wire chip_reset_n = reset_ni && (FlashMode || run);
  assign chip_reset_no = chip_reset_n;
  assign frame_active_o = !cs_n;
  for (genvar lane = 0; lane < 8; lane++) begin : g_return
    assign dq[lane] = return_oe[lane] ? return_data[lane] : 1'bz;
  end
  if (FlashMode) begin : g_flash
    wire ds;
    // Both participants must describe the internal bidirectional connection
    // with explicit enables. An unconditional DS wire aliases the chip's
    // disabled DIAG driver during the generic tri-state lowering pass.
    assign diag = !cs_n ? ds : 1'bz;
    assign host_tx_o = 1;
    assign run = 1;
    rapt_xspi_flash_target #(
        .InitFile(FlashInitFile)
    ) u_flash (
        .clock(board_clock_i),
        .reset(!chip_reset_n),
        .sclk_i(ck),
        .cs_n_i(cs_n),
        .dq_i(dq),
        .dq_o(return_data),
        .dq_oe_o(return_oe),
        .ds_o(ds),
        .busy_o(),
        .programs_o(programs_o),
        .erases_o(erases_o),
        .last_program_o(last_program_o),
        .last_erase_o(last_erase_o),
        .octal_frames_o(octal_frames_o)
    );
  end else begin : g_bridge
    wire return_enable;
    assign return_oe = {8{return_enable}};
    assign programs_o = 0;
    assign erases_o = 0;
    assign last_program_o = 0;
    assign last_erase_o = 0;
    assign octal_frames_o = 0;
    // Reuse the existing Arty board RAM/ROM/console and common link target.
    // The external NOR bank is unconnected in this RAM/debug emulation mode.
    rapt_arty_board #(
        .InternalJoin(1'b1),
        .RomFile(RomFile)
    ) u_board (
        .clock(board_clock_i),
        .flash_clock(chip_clock_i),
        .reset(!reset_ni),
        .link_delay_o(),
        .cpu_reset_i(1'b0),
        .sclk_i(ck),
        .cs_n_i(cs_n),
        .dq_i(dq),
        .dq_o(return_data),
        .dq_oe_o(return_enable),
        .uart_rx_i(host_rx_i),
        .uart_tx_o(host_tx_o),
        .run_o(run),
        .link_active_o(),
        .finished_o(),
        .flash_ck_o(),
        .flash_cs_n_o(),
        .flash_reset_n_o(),
        .flash_dq_o(),
        .flash_dq_oe_o(),
        .flash_dq_i(8'hff),
        .flash_dqs_i(1'b0)
    );
  end
  rapt_chip_pads25 #(
      .CoreClockHz(CoreClockHz),
      .FlashStorageOffset(24'h800000),
      .FlashWriteStart(32'h00800000),
      .FlashWriteEnd(32'h01000000),
      .FlashPowerupCycles(FlashPowerupCycles),
      .FlashRecoveryCycles(FlashRecoveryCycles)
  ) u_chip (
      .pad_clk(chip_clock_i),
      .pad_reset_n(chip_reset_n),
      .pad_irq(1'b0),
      .pad_xspi_sclk(ck),
      .pad_xspi_cs_n(cs_n),
      .pad_xspi_dq(dq),
      .pad_diag(diag),
      .pad_jtag_tck(jtag_tck_i),
      .pad_jtag_tms(jtag_tms_i),
      .pad_jtag_tdi(jtag_tdi_i),
      .pad_jtag_tdo(jtag_tdo_o),
      .pad_uart0_rx(uart_rx_i[0]),
      .pad_uart0_tx(uart_tx_o[0]),
      .pad_uart1_rx(uart_rx_i[1]),
      .pad_uart1_tx(uart_tx_o[1]),
      .pad_gpio0(gpio[0]),
      .pad_gpio1(gpio[1]),
      .pad_gpio2(gpio[2])
  );
endmodule
