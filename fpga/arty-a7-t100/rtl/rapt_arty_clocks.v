// Device clock primitives stay outside Slang's integer-only black-box interface.
module rapt_arty_clocks (
    input  wire clk100,
    input  wire reset,
    output wire core_clock,
    output wire board_clock,
    output wire flash_clock,
    output wire locked
);
  wire feedback, feedback_raw, core_raw, board_raw, flash_raw;
  MMCME2_BASE #(
      .CLKIN1_PERIOD(10.0),
      .CLKFBOUT_MULT_F(10.0),
      .DIVCLK_DIVIDE(1),
      .CLKOUT0_DIVIDE_F(50.0),
      .CLKOUT1_DIVIDE(10),
      .CLKOUT2_DIVIDE(100),
      .STARTUP_WAIT("FALSE")
  ) u_mmcm (
      .CLKIN1(clk100),
      .CLKFBIN(feedback),
      .RST(reset),
      .PWRDWN(1'b0),
      .CLKFBOUT(feedback_raw),
      .CLKFBOUTB(),
      .CLKOUT0(core_raw),
      .CLKOUT0B(),
      .CLKOUT1(board_raw),
      .CLKOUT1B(),
      .CLKOUT2(flash_raw),
      .CLKOUT2B(),
      .CLKOUT3(),
      .CLKOUT3B(),
      .CLKOUT4(),
      .CLKOUT5(),
      .CLKOUT6(),
      .LOCKED(locked)
  );
  BUFG u_feedback (
      .I(feedback_raw),
      .O(feedback)
  );
  BUFG u_core_clock (
      .I(core_raw),
      .O(core_clock)
  );
  BUFG u_board_clock (
      .I(board_raw),
      .O(board_clock)
  );
  BUFG u_flash_clock (
      .I(flash_raw),
      .O(flash_clock)
  );
endmodule
