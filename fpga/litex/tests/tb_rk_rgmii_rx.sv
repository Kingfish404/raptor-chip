`timescale 1ns / 1ps
module tb_rk_rgmii_rx;
  // Routed inverted RX clock: falling edge captures low, rising captures high.
  reg eth_rx_clk = 1, eth_rx_rst = 1;
  initial begin
    #2.6;
    forever begin
      eth_rx_clk = ~eth_rx_clk;
      #4;
    end
  end
  reg [3:0] rx_pins = 0;
  reg rx_ctl = 0, rx_ready = 1;
  wire [7:0] rx_data;
  wire rx_valid, rx_last, rx_last_be, rx_error;
  rk_rgmii_rx dut (.*);
  bit [9:0] expected[$];
  bit [9:0] wanted;
  integer received = 0, frames = 0;
  real skew = 0;

  always @(posedge eth_rx_clk) begin
    #0.2;
    if (!eth_rx_rst && rx_valid) begin
      if (expected.size() == 0) $fatal(1, "unexpected RX byte");
      wanted = expected.pop_front();
      if (rx_data !== wanted[7:0])
        $fatal(1, "RX byte %0d: got %02x expected %02x", received, rx_data, wanted[7:0]);
      if (rx_last !== wanted[8] || rx_last_be !== wanted[8])
        $fatal(1, "RX last/last_be mismatch at byte %0d", received);
      if (rx_error !== wanted[9]) $fatal(1, "RX error mismatch at byte %0d", received);
      received++;
      if (rx_last) frames++;
    end
  end

  task send_frame(input integer length, input integer seed, input integer error_at);
    reg [7:0] value;
    for (integer i = 0; i < length; i++) begin
      // Preamble/SFD followed by asymmetric data exposes inter-byte mixing.
      value = i < 7 ? 8'h55 : i == 7 ? 8'hd5 : i * 37 + seed;
      expected.push_back({(error_at >= 0 && i >= error_at), (i == length - 1), value});
      rx_pins = value[3:0];
      rx_ctl = 1;
      #4;
      rx_pins = value[7:4];
      rx_ctl = (i != error_at);
      #4;
    end
    rx_pins = 0;
    rx_ctl = 0;
    #96;  // Minimum 12-byte inter-frame gap.
  endtask

  initial begin
    if (!$value$plusargs("SKEW=%f", skew)) skew = 0;
    #200;
    eth_rx_rst = 0;
    #(800 + skew);
    send_frame(72, 3, -1);
    send_frame(1526, 71, -1);
    send_frame(73, 13, 17);
    send_frame(72, 5, -1);
    eth_rx_rst = 1;
    #32;
    eth_rx_rst = 0;
    #96;
    send_frame(72, 17, 71);
    send_frame(72, 19, -1);
    #128;
    if (expected.size() != 0 || frames != 6 || received != 1887)
      $fatal(1, "missing RX frames/bytes: %0d/%0d", frames, received);
    $display("PASS RK RGMII RX primitives: skew=%0.1f, bytes=%0d, frames=%0d", skew, received,
             frames);
    $finish;
  end
  initial begin
    #30000;
    $fatal(1, "timeout");
  end
endmodule
