`timescale 1ns / 1ps
// Real board wrapper and real chip; only the clock primitive and external device are models.
module rapt_arty_native_sim #(
    parameter int unsigned CoreClockHz = 10_000_000,
    parameter int BoardDelayNs = 20,
    parameter int ReturnDelayNs = BoardDelayNs,
    parameter int ReturnDqSkewNs = 0,
    parameter bit FullWaits = 0
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
  wire flash_ck, flash_cs_n, flash_dqs;
  wire model_ck, model_cs_n, model_reset_n;
  wire [7:0] flash_dq, model_input, delayed_host_oe;
  wire [7:0] model_data, model_oe, returned_oe;
  wire [2:0] gpio;
  wire [3:0] led;
  wire uart0_tx;
  wire flash_active = u_board.u_chip.u_chip.boot_flash;
  logic model_ds;
  string image_file;
  assign #(BoardDelayNs) model_ck = flash_ck;
  assign #(BoardDelayNs) model_cs_n = flash_cs_n;
  assign #(BoardDelayNs) model_reset_n = flash_reset_n;
  assign #(ReturnDelayNs) flash_dqs = flash_active ? model_ds : 1'bz;
  for (genvar lane = 0; lane < 8; lane++) begin : g_dq
    wire return_data, return_oe;
    assign #(BoardDelayNs + lane) model_input[lane] = flash_dq[lane];
    assign #(BoardDelayNs + lane) delayed_host_oe[lane] = u_board.u_chip.dq_oe[lane];
    assign #(ReturnDelayNs + ReturnDqSkewNs + lane) return_data = model_data[lane];
    assign #(ReturnDelayNs + ReturnDqSkewNs + lane) return_oe = model_oe[lane];
    assign flash_dq[lane] = return_oe ? return_data : 1'bz;
    assign returned_oe[lane] = return_oe;
  end
  rapt_arty_native_top #(
      .CoreClockHz(CoreClockHz),
      .FlashPowerupCycles(FullWaits ? CoreClockHz + 1 : 1000),
      .FlashRecoveryCycles(FullWaits ? CoreClockHz + 1 : 1000)
  ) u_board (
      .clk100,
      .btn,
      .led,
      .jtag_tck,
      .jtag_tms,
      .jtag_tdi,
      .jtag_tdo,
      .flash_ck,
      .flash_cs_n,
      .flash_reset_n,
      .flash_dqs,
      .flash_dq,
      .uart0_rx(1'b1),
      .uart0_tx,
      .uart1_rx(1'b1),
      .uart1_tx,
      .gpio
  );
  rapt_xspi_profile1_model #(
      .MemoryBytes(16 * 1024 * 1024),
      .ProtectedPrefix(32'h00800000)
  ) flash (
      .reset_n_i(model_reset_n),
      .sclk_i(model_ck),
      // No bridge peer is attached to this NOR fixture. Park its protocol
      // model without resetting the retained octal mode while the core halts
      // in bridge mode, then reconnect it on return to Flash.
      .cs_n_i(model_cs_n || !flash_active),
      .dq_i(model_input),
      .host_oe_i(delayed_host_oe),
      .missing_ds_i(1'b0),
      .drop_after_i(4'b0),
      .pause_i(1'b0),
      .deny_wren_i(1'b0),
      .fail_mutation_i(1'b0),
      .flags_i(8'b0),
      .dq_o(model_data),
      .dq_oe_o(model_oe),
      .ds_o(model_ds)
  );
  rapt_native_monitor #(
      .CoreClockHz(CoreClockHz)
  ) u_monitor (
      .core_clock_i(u_board.core_clock),
      .reset_n_i(model_reset_n),
      .cs_n_i(model_cs_n || !flash_active),
      .ck_i(model_ck),
      .source_ds_i(model_ds),
      .source_dq_i(model_data),
      .source_oe_i(model_oe),
      .receiver_ds_i(u_board.u_chip.u_chip.u_backend.u_flash.u_nor.u_frame.ds_i),
      .receiver_dq_i(u_board.u_chip.u_chip.u_backend.u_flash.u_nor.u_frame.dq_i),
      .receiver_oe_i(returned_oe),
      .host_oe_i(u_board.u_chip.dq_oe),
      .target_dq_i(model_input),
      .target_host_oe_i(delayed_host_oe),
      .lane_min_ps_o,
      .lane_max_ps_o,
      .lane_count_o,
      .lane_rise_count_o,
      .lane_fall_count_o,
      .core_period_ps_o,
      .timing_ps_o
  );
  assign host_ds_oe_o = u_board.u_chip.u_pad_diag.oe_i;
  // DS is an input in Flash mode; the bridge uses the same pad for heartbeat.
  always @(host_ds_oe_o or flash_active) begin
    if (flash_active && host_ds_oe_o)
      $fatal(1, "Native fixture enabled its real DS/DIAG output in Flash mode");
  end
  assign programs_o = 32'(flash.programs);
  assign erases_o = 32'(flash.erases);
  assign octal_frames_o = 32'(flash.octal_frames);
  assign last_program_o = flash.last_program_address;
  assign last_erase_o = flash.last_erase_address;
  initial begin
    if (!$value$plusargs("NATIVE_FLASH_IMAGE=%s", image_file))
      $fatal(1, "NATIVE_FLASH_IMAGE must name an explicit boot image");
    #1;
    $readmemh(image_file, flash.mem);
  end
  always @(posedge u_board.core_clock) begin
    if (flash_active && u_board.u_chip.diag_oe) $fatal(1, "Native fixture drove its DS input");
    if (!flash_reset_n && (u_board.u_chip.dq_oe != 0 || !flash_cs_n || flash_ck))
      $fatal(1, "External reset did not release native serial pins");
  end
endmodule
