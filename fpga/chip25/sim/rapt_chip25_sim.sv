`timescale 1ns / 1ps
// Real shared fixture and synthesizable NOR target. Only clock sources are ideal.
// The host adapter uses the same pin JTAG/DMI/SBA operations as the Arty fixture.
module rapt_chip25_sim #(
    parameter bit FullWaits = 1'b0
) (
    input logic clk100,
    input logic [1:0] btn,
    input logic jtag_tck,
    input logic jtag_tms,
    input logic jtag_tdi,
    output wire jtag_tdo,
    output wire uart1_tx,
    output wire flash_reset_n,
    output wire host_ds_oe_o,
    output wire [31:0] programs_o,
    output wire [31:0] erases_o,
    output wire [31:0] octal_frames_o,
    output wire [31:0] last_program_o,
    output wire [31:0] last_erase_o,
    output int signed lane_min_ps_o[8],
    output int signed lane_max_ps_o[8],
    output int unsigned lane_count_o[8],
    output int unsigned lane_rise_count_o[8],
    output int unsigned lane_fall_count_o[8],
    output int unsigned core_period_ps_o[3],
    output int unsigned timing_ps_o[12]
);
  logic board_clock = 0, chip_clock = 0;
  always #5 board_clock = !board_clock;
  always #50 chip_clock = !chip_clock;
  wire [2:0] gpio;
  wire [1:0] uart_tx;
  string image_file;
  assign uart1_tx = uart_tx[1];
  rapt_chip25_fixture #(
      .FlashPowerupCycles(FullWaits ? 10000001 : 1000),
      .FlashRecoveryCycles(FullWaits ? 10000001 : 1000)
  ) u_fixture (
      .board_clock_i(board_clock),
      .chip_clock_i(chip_clock),
      .reset_ni(btn == 0),
      .host_rx_i(1'b1),
      .host_tx_o(),
      .uart_rx_i(2'b11),
      .uart_tx_o(uart_tx),
      .gpio(gpio),
      .jtag_tck_i(jtag_tck),
      .jtag_tms_i(jtag_tms),
      .jtag_tdi_i(jtag_tdi),
      .jtag_tdo_o(jtag_tdo),
      .chip_reset_no(flash_reset_n),
      .frame_active_o(),
      .programs_o(programs_o),
      .erases_o(erases_o),
      .last_program_o(last_program_o),
      .last_erase_o(last_erase_o),
      .octal_frames_o(octal_frames_o)
  );
  assign host_ds_oe_o = u_fixture.u_chip.u_pad_diag.oe_i;
  rapt_native_monitor u_monitor (
      .core_clock_i(chip_clock),
      .reset_n_i(flash_reset_n),
      .cs_n_i(u_fixture.cs_n),
      .ck_i(u_fixture.ck),
      .source_ds_i(u_fixture.g_flash.ds),
      .source_dq_i(u_fixture.return_data),
      .source_oe_i(u_fixture.return_oe),
      .receiver_ds_i(u_fixture.u_chip.u_chip.u_backend.u_flash.u_nor.u_frame.ds_i),
      .receiver_dq_i(u_fixture.dq),
      .receiver_oe_i(u_fixture.return_oe),
      .host_oe_i(u_fixture.u_chip.dq_oe),
      .target_dq_i(u_fixture.dq),
      .target_host_oe_i(u_fixture.u_chip.dq_oe),
      .lane_min_ps_o(lane_min_ps_o),
      .lane_max_ps_o(lane_max_ps_o),
      .lane_count_o(lane_count_o),
      .lane_rise_count_o(lane_rise_count_o),
      .lane_fall_count_o(lane_fall_count_o),
      .core_period_ps_o(core_period_ps_o),
      .timing_ps_o(timing_ps_o)
  );
  initial begin
    if (!$value$plusargs("NATIVE_FLASH_IMAGE=%s", image_file))
      $fatal(1, "NATIVE_FLASH_IMAGE must name an explicit sparse backing image");
    #1;
    $readmemh(image_file, u_fixture.g_flash.u_flash.memory);
  end
  always @(posedge chip_clock) begin
    if (host_ds_oe_o) $fatal(1, "Native emulation enabled its real DIAG pad output");
  end
endmodule
