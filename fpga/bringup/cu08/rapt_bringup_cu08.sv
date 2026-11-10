module rapt_bringup_cu08 #(
    parameter bit Emulate = 1'b0
) (
    input wire clk100,
    input wire cpu_resetn,
    input wire serial_rx,
    output wire serial_tx,
    input wire external_clock,
    output wire pad_clk,
    output wire pad_reset_n,
    output wire pad_irq,
    input wire pad_xspi_sclk,
    input wire pad_xspi_cs_n,
    inout wire [7:0] pad_xspi_dq,
    output wire pad_jtag_tck,
    output wire pad_jtag_tms,
    output wire pad_jtag_tdi,
    input wire pad_jtag_tdo,
    input wire pad_diag
);
  logic [5:0] startup_q = 0;
  logic reset, enable, use_external, locked, chip_clock, chip_reset_n, irq;
  logic tck, tms, tdi, tdo, diag, sclk, cs_n, dq_oe;
  logic [2:0] half_ticks;
  logic [3:0] delay_cycles;
  logic [8:0] input_taps, last_taps_q;
  logic [7:0] dq_to_chip, dq_from_chip;
  always_ff @(posedge clk100) begin
    if (!cpu_resetn) startup_q <= 0;
    else if (startup_q != 63) startup_q <= startup_q + 1'b1;
    last_taps_q <= input_taps;
  end
  assign reset = startup_q != 63;
  rapt_bringup_clock u_clocking (
      .clock_i(clk100),
      .reset_i(reset),
      .enable_i(enable),
      .external_i(use_external),
      .external_clock_i(external_clock),
      .half_ticks_i(half_ticks),
      .chip_clock_o(chip_clock),
      .locked_o(locked)
  );
  rapt_bringup_top u_board (
      .clock_i(clk100),
      .reset_i(reset),
      .host_rx_i(serial_rx),
      .host_tx_o(serial_tx),
      .chip_clock_i(chip_clock),
      .clock_locked_i(locked),
      .clock_enable_o(enable),
      .external_clock_o(use_external),
      .clock_half_ticks_o(half_ticks),
      .input_taps_o(input_taps),
      .chip_reset_no(chip_reset_n),
      .chip_irq_o(irq),
      .jtag_tck_o(tck),
      .jtag_tms_o(tms),
      .jtag_tdi_o(tdi),
      .jtag_tdo_i(tdo),
      .diag_i(diag),
      .sclk_i(sclk),
      .cs_n_i(cs_n),
      .dq_i(dq_from_chip),
      .dq_o(dq_to_chip),
      .dq_oe_o(dq_oe),
      .emulation_delay_o(delay_cycles)
  );
  if (Emulate) begin : g_emulate
    // Keep an attached physical chip safe while exercising its RTL internally.
    assign {pad_clk, pad_reset_n, pad_irq, pad_jtag_tck} = 4'b0;
    assign {pad_jtag_tms, pad_jtag_tdi} = 2'b11;
    assign pad_xspi_dq = 8'hzz;
    rapt_bringup_emulated_chip u_model (
        .clock_i(clk100),
        .chip_clock_i(chip_clock),
        .reset_i(reset),
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
  end else begin : g_chip
    assign pad_clk = chip_clock;
    assign pad_reset_n = chip_reset_n;
    assign pad_irq = irq;
    assign pad_jtag_tck = tck;
    assign pad_jtag_tms = tms;
    assign pad_jtag_tdi = tdi;
    assign tdo = pad_jtag_tdo;
    assign diag = pad_diag;
    assign sclk = pad_xspi_sclk;
    assign cs_n = pad_xspi_cs_n;
    for (genvar i = 0; i < 8; i++) begin : g_dq
      wire raw_dq;
      IOBUF u_io (
          .IO(pad_xspi_dq[i]),
          .I (dq_to_chip[i]),
          .T (!dq_oe),
          .O (raw_dq)
      );
      // COUNT taps are deliberately uncalibrated; shmoo results determine margin.
      IDELAYE3 #(
          .DELAY_FORMAT("COUNT"),
          .DELAY_TYPE("VAR_LOAD"),
          .DELAY_SRC("IDATAIN"),
          .DELAY_VALUE(0),
          .UPDATE_MODE("ASYNC"),
          .SIM_DEVICE("ULTRASCALE_PLUS")
      ) u_delay (
          .CLK(clk100),
          .RST(reset),
          .IDATAIN(raw_dq),
          .DATAIN(1'b0),
          .DATAOUT(dq_from_chip[i]),
          .LOAD(last_taps_q != input_taps),
          .CNTVALUEIN(input_taps),
          .CNTVALUEOUT(),
          .CE(1'b0),
          .INC(1'b0),
          .EN_VTC(1'b0),
          .CASC_IN(1'b0),
          .CASC_RETURN(1'b0),
          .CASC_OUT()
      );
    end
  end
endmodule
