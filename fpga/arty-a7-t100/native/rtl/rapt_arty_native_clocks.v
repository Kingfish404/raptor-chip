// 100 MHz reference, 1 GHz VCO; whole-chip clock is declared by CoreClockHz.
// Keep real-valued device primitive parameters outside the Slang export.
module rapt_arty_native_clocks #(
    parameter integer CoreClockHz = 10000000
) (
    input wire clock_i,
    input wire reset_i,
    output wire core_clock_o,
    output wire locked_o
);
  wire feedback_raw, feedback, core_raw;
  localparam integer OutputDivide = 1000000000 / CoreClockHz;
  MMCME2_BASE #(
      .CLKIN1_PERIOD(10.0),
      .CLKFBOUT_MULT_F(10.0),
      .DIVCLK_DIVIDE(1),
      .CLKOUT0_DIVIDE_F(OutputDivide),
      .STARTUP_WAIT("FALSE")
  ) u_mmcm (
      .CLKIN1(clock_i),
      .CLKFBIN(feedback),
      .RST(reset_i),
      .PWRDWN(1'b0),
      .CLKFBOUT(feedback_raw),
      .CLKOUT0(core_raw),
      .LOCKED(locked_o)
  );
  BUFG u_feedback (
      .I(feedback_raw),
      .O(feedback)
  );
  BUFG u_core_clock (
      .I(core_raw),
      .O(core_clock_o)
  );
endmodule
