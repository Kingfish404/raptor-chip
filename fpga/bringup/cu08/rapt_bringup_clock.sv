// 100 MHz reference, 1 GHz MMCM VCO. Runtime integer divide = 20 * half_ticks.
// Reconfigure only with clock disabled and chip held reset (enforced by control).
module rapt_bringup_clock (
    input logic clock_i,
    input logic reset_i,
    input logic enable_i,
    input logic external_i,
    input logic external_clock_i,
    input logic [2:0] half_ticks_i,
    output wire chip_clock_o,
    output logic locked_o
);
  wire feedback_raw, feedback, mmcm_clock, locked, drdy;
  logic [2:0] applied_q;
  logic [3:0] state_q;
  logic den, dwe, mmcm_reset;
  logic [ 6:0] daddr;
  logic [15:0] di;
  logic [ 5:0] half_divide;
  (* ASYNC_REG = "TRUE" *)logic [ 1:0] lock_sync;
  assign half_divide = 6'(10 * int'(half_ticks_i));
  assign mmcm_reset  = reset_i || state_q < 5;
  always_comb begin
    den = state_q == 1 || state_q == 3;
    dwe = den;
    daddr = state_q == 1 ? 7'h08 : 7'h09;
    // CLKOUT0 counter register bit 12 enables the divider (integer mode).
    di = state_q == 1 ? {3'b0, 1'b1, half_divide, half_divide} : 16'b0;
    locked_o = state_q == 5 && (external_i || lock_sync[1]);
  end
  always_ff @(posedge clock_i) begin
    lock_sync <= {lock_sync[0], locked};
    if (reset_i) begin
      applied_q <= 0;
      state_q   <= 0;
    end else begin
      case (state_q)
        0: begin
          applied_q <= half_ticks_i;
          state_q   <= 1;
        end
        1: state_q <= 2;
        2: if (drdy) state_q <= 3;
        3: state_q <= 4;
        4: if (drdy) state_q <= 5;
        5: if (half_ticks_i != applied_q && !enable_i) state_q <= 0;
        default: state_q <= 0;
      endcase
    end
  end
  BUFG u_feedback (
      .I(feedback_raw),
      .O(feedback)
  );
  MMCME4_ADV #(
      .CLKIN1_PERIOD(10.0),
      .DIVCLK_DIVIDE(1),
      .CLKFBOUT_MULT_F(10.0),
      .CLKOUT0_DIVIDE_F(100.0),
      .COMPENSATION("AUTO"),
      .STARTUP_WAIT("FALSE")
  ) u_mmcm (
      .CLKIN1(clock_i),
      .CLKIN2(1'b0),
      .CLKINSEL(1'b1),
      .CLKFBIN(feedback),
      .CLKFBOUT(feedback_raw),
      .CLKOUT0(mmcm_clock),
      .LOCKED(locked),
      .RST(mmcm_reset),
      .PWRDWN(1'b0),
      .DCLK(clock_i),
      .DADDR(daddr),
      .DI(di),
      .DEN(den),
      .DWE(dwe),
      .DO(),
      .DRDY(drdy),
      .PSCLK(clock_i),
      .PSEN(1'b0),
      .PSINCDEC(1'b0),
      .PSDONE(),
      .CDDCREQ(1'b0),
      .CDDCDONE(),
      .CLKFBSTOPPED(),
      .CLKINSTOPPED()
  );
  // BUFGCTRL prevents runt pulses. Source changes are accepted only with CE off.
  BUFGCTRL #(
      .INIT_OUT(0),
      .PRESELECT_I0("TRUE")
  ) u_mux (
      .I0(mmcm_clock),
      .I1(external_clock_i),
      .S0(!external_i),
      .S1(external_i),
      .CE0(enable_i && locked_o),
      .CE1(enable_i && locked_o),
      .IGNORE0(1'b0),
      .IGNORE1(1'b0),
      .O(chip_clock_o)
  );
endmodule
