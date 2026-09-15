`timescale 1ns / 1ps
module tb_cm005_gigabit_tx;
  reg tx_raw = 0, clock_reset = 1, eth_tx_rst = 1;
  wire eth_tx_clk, cm005_tx_serial_clk;
  always #2 tx_raw = ~tx_raw;
  reg tx_valid = 0, tx_last = 0, tx_error = 0;
  reg [7:0] tx_byte = 0;
  wire tx_ready, txc, tx_ctl;
  wire [3:0] tx_pins;
  cm005_gigabit_tx dut (.*);
  bit [8:0] expected[$];
  bit [8:0] wanted;
  reg [3:0] low;
  reg valid_low;
  integer received=0;
  realtime last_change = 0, last_clock = 0;
  always @(tx_pins or tx_ctl) begin
    if (!eth_tx_rst && $time > 1000 && $realtime - last_clock < 1.2)
      $fatal(1, "TX hold window violated");
    last_change = $realtime;
  end
  always @(txc) begin
    if (!eth_tx_rst && $time > 1000 && $realtime - last_change < 1.2)
      $fatal(1, "TX setup window violated");
    last_clock = $realtime;
  end
  always @(posedge txc) begin
    #0.001;
    low=tx_pins;
    valid_low=tx_ctl;
  end
  always @(negedge txc) begin
    #0.001;
    if (!eth_tx_rst) begin
      if (valid_low) begin
        if (expected.size() == 0) $fatal(1, "unexpected TX byte");
        wanted = expected.pop_front();
        if ({tx_pins, low} !== wanted[7:0]) $fatal(1, "TX byte mismatch");
        if (tx_ctl !== (valid_low ^ wanted[8])) $fatal(1, "TX control/error mismatch");
        received++;
      end else if (tx_ctl) $fatal(1, "TX control mismatch while idle");
    end
  end
  initial begin
    #203;
    clock_reset = 0;
    repeat (20) @(negedge eth_tx_clk);
    eth_tx_rst = 0;
    repeat (20) @(negedge eth_tx_clk);
    for (integer frame = 0; frame < 4; frame++) begin
      for (integer i = 0; i < 1518; i++) begin
        tx_byte=i*37+frame;
        tx_error=(i==17);
        expected.push_back({tx_error, tx_byte});
        tx_valid=1;
        tx_last=(i==1517);
        @(posedge eth_tx_clk);
        if (!tx_ready) $fatal(1, "gigabit PHY unexpectedly stalled");
        @(negedge eth_tx_clk);
      end
      tx_valid=0;
      tx_last=0;
      tx_error=0;
      repeat (12) @(negedge eth_tx_clk);
      if (frame == 1) begin
        // Actual BUFGCE_DIV primitives must recover clock alignment.
        eth_tx_rst=1;
        clock_reset=1;
        #17;
        clock_reset = 0;
        repeat (20) @(negedge eth_tx_clk);
        eth_tx_rst = 0;
      end
    end
    repeat (20) @(negedge eth_tx_clk);
    if (expected.size() != 0 || received != 6072) $fatal(1, "missing TX bytes: %0d", received);
    $display(
        "PASS CM005 gigabit TX primitives: TX=6072, BUFGCE_DIV startup/restart, full-rate DDR low/high nibbles, TX_ER, full-size frames, minimum IFG, functional setup/hold");
    $finish;
  end
  initial begin
    #100000;
    $fatal(1, "timeout");
  end
endmodule
