// CU08 oscillator is 100 MHz. Both emulation domains remain related.
module rapt_chip25_clocks (
    input wire clock_i,
    input wire reset_i,
    output wire board_clock_o,
    output wire chip_clock_o,
    output wire locked_o
);
  wire feedback_raw, feedback, board_raw, chip_raw;
  MMCME4_BASE #(
      .CLKIN1_PERIOD(10.0),
      .DIVCLK_DIVIDE(1),
      .CLKFBOUT_MULT_F(10.0),
      .CLKOUT0_DIVIDE_F(100.0),
      .CLKOUT1_DIVIDE(10)
  ) u_mmcm (
      .CLKIN1(clock_i),
      .CLKFBIN(feedback),
      .RST(reset_i),
      .PWRDWN(1'b0),
      .CLKFBOUT(feedback_raw),
      .CLKFBOUTB(),
      .CLKOUT0(chip_raw),
      .CLKOUT0B(),
      .CLKOUT1(board_raw),
      .CLKOUT1B(),
      .CLKOUT2(),
      .CLKOUT2B(),
      .CLKOUT3(),
      .CLKOUT3B(),
      .CLKOUT4(),
      .CLKOUT5(),
      .CLKOUT6(),
      .LOCKED(locked_o)
  );
  BUFG u_feedback (
      .I(feedback_raw),
      .O(feedback)
  );
  BUFG u_board_clock (
      .I(board_raw),
      .O(board_clock_o)
  );
  BUFG u_chip_clock (
      .I(chip_raw),
      .O(chip_clock_o)
  );
endmodule
