`timescale 1ns / 1ps
// Run with the selected Vivado's unisims_ver library; tests real MMCM DRP.
module tb_bringup_clock;
  logic clock = 0;
  logic external_clock = 0;
  logic reset = 1;
  logic enable = 0;
  logic use_external = 0;
  logic [2:0] half_ticks = 5;
  wire chip_clock, locked;
  always #5 clock = !clock;
  always #20 external_clock = !external_clock;
  rapt_bringup_clock u_dut (
      .clock_i(clock),
      .reset_i(reset),
      .enable_i(enable),
      .external_i(use_external),
      .external_clock_i(external_clock),
      .half_ticks_i(half_ticks),
      .chip_clock_o(chip_clock),
      .locked_o(locked)
  );
  task automatic check_period(input realtime expected);
    realtime first_edge, period;
    repeat (4) @(posedge chip_clock);
    first_edge = $realtime;
    @(posedge chip_clock);
    period = $realtime - first_edge;
    if (period < expected * 0.999 || period > expected * 1.001)
      $fatal(1, "clock period %f ns, expected %f", period, expected);
  endtask
  initial begin
    repeat (20) @(negedge clock);
    reset = 0;
    wait (locked);
    enable = 1;
    check_period(100.0);
    for (int half_period = 1; half_period <= 6; half_period++) begin
      @(negedge clock) enable = 0;
      repeat (20) @(negedge clock);
      half_ticks = 3'(half_period);
      repeat (10) @(negedge clock);
      wait (locked);
      enable = 1;
      check_period(20.0 * half_period);
    end
    @(negedge clock) enable = 0;
    repeat (20) @(negedge clock);
    use_external = 1;
    repeat (20) @(negedge clock);
    enable = 1;
    check_period(40.0);
    $display("bringup MMCM DRP: 6 dividers and external clock PASS");
    $finish;
  end
  initial begin
    #2_000_000;
    $fatal(1, "MMCM lock/clock timeout");
  end
endmodule
