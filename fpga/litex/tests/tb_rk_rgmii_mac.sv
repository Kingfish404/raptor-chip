`timescale 1ns / 1ps
module tb_rk_rgmii_mac;
  reg eth_rx_clk = 1, eth_rx_rst = 1, sys_clk = 0, sys_rst = 1;
  initial begin
    #2.6;
    forever begin
      eth_rx_clk = ~eth_rx_clk;
      #4;
    end
  end
  always #10 sys_clk = ~sys_clk;
  reg [3:0] rx_pins = 0;
  reg rx_ctl = 0, rx_ready = 1;
  wire [31:0] rx_data;
  wire [3:0] rx_last_be, rx_error;
  wire rx_valid, rx_last;
  rk_rgmii_mac dut (.*);
  byte unsigned expected[$];
  bit expected_error[$];
  byte unsigned wanted;
  bit frame_error = 0, wanted_error;
  integer received = 0, frames = 0, count;
  real skew = 0;

  always @(posedge sys_clk) begin
    #0.2;
    if (!sys_rst && rx_valid && rx_ready) begin
      count = 4;
      if (rx_last) begin
        case (rx_last_be)
          4'b0001: count = 1;
          4'b0010: count = 2;
          4'b0100: count = 3;
          4'b1000: count = 4;
          default: $fatal(1, "invalid MAC last_be");
        endcase
      end
      for (integer lane = 0; lane < count; lane++) begin
        if (expected.size() == 0) $fatal(1, "unexpected MAC data");
        wanted = expected.pop_front();
        if (rx_data[8*lane+:8] !== wanted)
          $fatal(1, "MAC byte %0d: got %02x expected %02x", received, rx_data[8*lane+:8], wanted);
        received++;
      end
      frame_error |= |rx_error;
      if (rx_last) begin
        if (expected_error.size() == 0) $fatal(1, "unexpected MAC frame");
        wanted_error = expected_error.pop_front();
        if (frame_error !== wanted_error) $fatal(1, "MAC frame error mismatch");
        frame_error = 0;
        frames++;
      end
    end
  end

  task send_frame(input integer length, input integer preamble, input integer error_at,
                  input bit corrupt);
    byte unsigned packet[1526];
    reg [31:0] crc;
    integer total;
    crc = 32'hffffffff;
    total = preamble + 1 + length + 4;
    for (integer i = 0; i < preamble; i++) packet[i] = 8'h55;
    packet[preamble] = 8'hd5;
    for (integer i = 0; i < length; i++) begin
      packet[preamble+1+i] = i * 37 + length;
      crc ^= packet[preamble+1+i];
      for (integer bit_index = 0; bit_index < 8; bit_index++)
      crc = (crc >> 1) ^ ((crc & 1) ? 32'hedb88320 : 0);
    end
    crc = ~crc;
    for (integer i = 0; i < 4; i++) packet[preamble+1+length+i] = crc[8*i+:8];
    if (corrupt) packet[preamble+1+17] ^= 1;
    for (integer i = 0; i < length; i++) expected.push_back(packet[preamble+1+i]);
    expected_error.push_back(error_at >= 0 || corrupt);
    for (integer i = 0; i < total; i++) begin
      rx_pins = packet[i][3:0];
      rx_ctl = 1;
      #4;
      rx_pins = packet[i][7:4];
      rx_ctl = (i != error_at);
      #4;
    end
    rx_pins = 0;
    rx_ctl = 0;
    #96;
  endtask

  initial begin
    if (!$value$plusargs("SKEW=%f", skew)) skew = 0;
    #200;
    eth_rx_rst = 0;
    sys_rst = 0;
    #(800 + skew);
    send_frame(60, 7, -1, 0);
    send_frame(61, 6, -1, 0);
    send_frame(1514, 7, -1, 0);
    send_frame(60, 7, 8, 0);  // Error while CRC checker FIFO is filling.
    send_frame(60, 7, -1, 0);
    send_frame(60, 7, 71, 0);  // Error on final FCS byte.
    send_frame(60, 7, -1, 1);
    send_frame(60, 7, -1, 0);
    #2000;
    if (expected.size() != 0 || expected_error.size() != 0 || frames != 8 || received != 1935)
      $fatal(1, "missing MAC frames/bytes: %0d/%0d", frames, received);
    $display("PASS RK RGMII MAC: skew=%0.1f, bytes=%0d, frames=%0d, CRC/RX_ER/CDC", skew, received,
             frames);
    $finish;
  end
  initial begin
    #40000;
    $fatal(1, "timeout");
  end
endmodule
