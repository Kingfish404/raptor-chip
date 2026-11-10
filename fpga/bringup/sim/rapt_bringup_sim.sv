module rapt_bringup_sim (
    input  logic clock_i,
    input  logic reset_i,
    input  logic host_rx_i,
    output logic host_tx_o
);
  logic chip_clock = 0;
  logic [2:0] half_ticks, clock_ticks = 0;
  logic enable, external_clock, chip_reset_n, irq, tck, tms, tdi, tdo, diag;
  logic sclk, cs_n, dq_oe;
  logic [7:0] dq_to_chip, dq_from_chip;
  logic [3:0] delay_cycles;
  logic [8:0] taps;
  always @(negedge clock_i) begin
    if (reset_i || !enable) begin
      chip_clock  <= 0;
      clock_ticks <= 0;
    end else if (clock_ticks + 1'b1 >= half_ticks) begin
      chip_clock  <= !chip_clock;
      clock_ticks <= 0;
    end else clock_ticks <= clock_ticks + 1'b1;
  end
  rapt_bringup_top #(
      .BitTicks(8)
  ) u_board (
      .clock_i(clock_i),
      .reset_i(reset_i),
      .host_rx_i(host_rx_i),
      .host_tx_o(host_tx_o),
      .chip_clock_i(chip_clock),
      .clock_locked_i(1'b1),
      .clock_enable_o(enable),
      .external_clock_o(external_clock),
      .clock_half_ticks_o(half_ticks),
      .input_taps_o(taps),
      .chip_reset_no(chip_reset_n),
      .chip_irq_o(irq),
      .jtag_tck_o(tck),
      .jtag_tms_o(tms),
      .jtag_tdi_o(tdi),
      .jtag_tdo_i(tdo),
      .diag_i(diag),
      .sclk_i(sclk),
      .cs_n_i(cs_n || u_dut.u_chip.u_chip.boot_flash),
      .dq_i(dq_from_chip),
      .dq_o(dq_to_chip),
      .dq_oe_o(dq_oe),
      .emulation_delay_o(delay_cycles)
  );
  // The carrier supplies a bridge, not a NOR. Exercise finite Flash failure
  // before JTAG selection using accelerated simulation-only startup/poll waits.
  rapt_bringup_emulated_chip #(
      .FlashPowerupCycles(2000),
      .FlashResetCycles(32),
      .FlashRecoveryCycles(4000),
      .FlashPollCycles(4096)
  ) u_dut (
      .clock_i(clock_i),
      .chip_clock_i(chip_clock),
      .reset_i(reset_i),
      .chip_reset_ni(chip_reset_n),
      .irq_i(irq),
      .tck_i(tck),
      .tms_i(tms),
      .tdi_i(tdi),
      .tdo_o(tdo),
      .diag_o(diag),
      .delay_i(delay_cycles),
      .dq_i(dq_to_chip),
      .dq_oe_i(dq_oe),
      .dq_o(dq_from_chip),
      .sclk_o(sclk),
      .cs_n_o(cs_n)
  );
endmodule
