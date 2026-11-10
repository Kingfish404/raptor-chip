`timescale 1ns / 1ps
// Ideal MMCM model: preserve the declared core period without evaluating inert
// reference-clock ticks. The real device primitive is checked separately.
module rapt_arty_native_clocks #(
    parameter int unsigned CoreClockHz = 10_000_000
) (
    input logic clock_i,
    input logic reset_i,
    output logic core_clock_o = 0,
    output wire locked_o
);
  localparam realtime HalfPeriodNs = 500_000_000.0 / CoreClockHz;
  int lock_q = 0;
  assign locked_o = !reset_i && lock_q == 32;
  always begin
    #(HalfPeriodNs);
    if (reset_i) begin
      core_clock_o = 0;
      lock_q = 0;
    end else begin
      core_clock_o = !core_clock_o;
      if (lock_q < 32) lock_q++;
    end
  end
endmodule
