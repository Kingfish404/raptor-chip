// Identical pad interface in simulation and FPGA emulation. Delay is measured
// in board clock periods, independently applied in both directions, including OE.
module rapt_bringup_emulated_chip #(
    parameter int unsigned FlashPowerupCycles = 100_000_001,
    parameter int unsigned FlashResetCycles = 10_001,
    parameter int unsigned FlashRecoveryCycles = 100_000_001,
    parameter int unsigned FlashPollCycles = 50_000_000
) (
    input logic clock_i,
    input logic chip_clock_i,
    input logic reset_i,
    input logic chip_reset_ni,
    input logic irq_i,
    input logic tck_i,
    input logic tms_i,
    input logic tdi_i,
    output wire tdo_o,
    output wire diag_o,
    input logic [3:0] delay_i,
    input logic [7:0] dq_i,
    input logic dq_oe_i,
    output logic [7:0] dq_o,
    output logic sclk_o,
    output logic cs_n_o
);
  wire sclk, cs_n;
  wire [7:0] dq;
  logic [9:0] forward_q[15];
  logic [8:0] reverse_q[15];
  logic [8:0] reverse_data;
  assign {cs_n_o, sclk_o, dq_o} = delay_i == 0 ? {cs_n, sclk, dq} : forward_q[delay_i-1];
  assign reverse_data = delay_i == 0 ? {dq_oe_i, dq_i} : reverse_q[delay_i-1];
  assign dq = reverse_data[8] ? reverse_data[7:0] : 8'hzz;
  always_ff @(posedge clock_i) begin
    if (reset_i) begin
      for (int i = 0; i < 15; i++) begin
        forward_q[i] <= {1'b1, 9'b0};
        reverse_q[i] <= 0;
      end
    end else begin
      forward_q[0] <= {cs_n, sclk, dq};
      reverse_q[0] <= {dq_oe_i, dq_i};
      for (int i = 1; i < 15; i++) begin
        forward_q[i] <= forward_q[i-1];
        reverse_q[i] <= reverse_q[i-1];
      end
    end
  end
  // Both backends are present. The host selects bridge boot through JTAG;
  // irq_i remains an interrupt throughout reset and operation.
  rapt_chip_pads #(
      .FlashPowerupCycles(FlashPowerupCycles),
      .FlashResetCycles(FlashResetCycles),
      .FlashRecoveryCycles(FlashRecoveryCycles),
      .FlashPollCycles(FlashPollCycles)
  ) u_chip (
      .pad_clk(chip_clock_i),
      .pad_reset_n(chip_reset_ni),
      .pad_irq(irq_i),
      .pad_xspi_sclk(sclk),
      .pad_xspi_cs_n(cs_n),
      .pad_xspi_dq(dq),
      .pad_jtag_tck(tck_i),
      .pad_jtag_tms(tms_i),
      .pad_jtag_tdi(tdi_i),
      .pad_jtag_tdo(tdo_o),
      .pad_diag(diag_o)
  );
endmodule
