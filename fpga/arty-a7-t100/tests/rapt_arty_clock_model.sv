`timescale 1ns / 1ps

// Ideal MMCM outputs for simulation of the exact FPGA-exported top.
module rapt_arty_clocks (
    input  wire  clk100,
    input  wire  reset,
    output logic core_clock = 0,
    output wire  board_clock,
    output logic flash_clock = 0,
    output logic locked = 0
);
  logic [4:0] lock_count = 0;
  assign board_clock = clk100;
  always #25 core_clock = !core_clock;
  always #50 flash_clock = !flash_clock;
  always @(posedge clk100) begin
    if (reset) begin
      lock_count <= 0;
      locked <= 0;
    end else if (!locked) begin
      lock_count <= lock_count + 1'b1;
      if (&lock_count) locked <= 1;
    end
  end
endmodule
