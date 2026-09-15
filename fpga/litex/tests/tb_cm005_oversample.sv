`timescale 1ns / 1ps
module tb_cm005_oversample;
  reg cm005_sample_clk = 0, eth_rx_clk = 0, eth_rx_rst = 1;
  // Alternating sample intervals exercise +/-20 ps duty-cycle variation.
  initial
    forever begin
      #0.78;
      cm005_sample_clk = 1;
      #0.82;
      cm005_sample_clk = 0;
    end
  reg [1:0] sample_count = 0;
  always @(posedge cm005_sample_clk) begin
    sample_count <= sample_count+1;
    eth_rx_clk <= sample_count<2;
  end
  reg phy_clock = 0, phy_control = 0;
  reg [3:0] phy_data = 0;
  realtime clock_extra = 0, data_extra = 0;
  wire phy_clock_sampled, phy_control_sampled;
  wire [3:0] phy_data_sampled;
  assign #(clock_extra) phy_clock_sampled=phy_clock;
  assign #(data_extra) phy_control_sampled=phy_control;
  assign #(data_extra) phy_data_sampled=phy_data;
  wire rx_valid, rx_last, rx_error, rx_fault;
  wire [7:0] rx_data, sampled_clock;
  cm005_oversample dut (
      .cm005_sample_clk,
      .eth_rx_clk,
      .eth_rx_rst,
      .phy_clock(phy_clock_sampled),
      .phy_control(phy_control_sampled),
      .phy_data(phy_data_sampled),
      .rx_valid,
      .rx_last,
      .rx_error,
      .rx_data,
      .rx_ready(1'b1),
      .rx_fault,
      .sampled_clock
  );
  bit [9:0] expected[$];
  bit [9:0] wanted;
  integer received=0;
  always @(posedge eth_rx_clk)
    if (!eth_rx_rst && rx_valid) begin
      if (expected.size() == 0) $fatal(1, "unexpected byte %h", rx_data);
      wanted = expected.pop_front();
      if ({rx_error, rx_last, rx_data} !== wanted)
        $fatal(
            1,
            "RX got=%h expected=%h sampled_clock=%h",
            {
              rx_error, rx_last, rx_data
            },
            wanted,
            sampled_clock
        );
      received++;
    end
  task automatic send_nibble(input bit [3:0] data, input bit error_bit);
    phy_data=data;
    phy_control=1;
    #20;
    phy_control = 1 ^ error_bit;
    #20;
  endtask
  initial begin
    #200;
    for (integer phase = 0; phase < 576; phase++) begin
      realtime setup_time;
      setup_time=(phase/64%3==0) ? 0.8 : ((phase/64%3==1) ? 2.0 : 19.2);
      // Combined with the 460 ps clock IDELAY, cover 25/460/775 ps
      // relative clock/data delay, including the routed aperture range.
      clock_extra=(phase/192==2) ? 0.315 : 0.0;
      data_extra=(phase/192==0) ? 0.435 : 0.0;
      eth_rx_rst=1;
      phy_clock=0;
      phy_control=0;
      phy_data=0;
      repeat (10) @(negedge eth_rx_clk);
      eth_rx_rst = 0;
      #((phase % 64) * 0.1);
      fork : frame_session
        begin
          forever begin
            #20;
            phy_clock = ~phy_clock;
          end
        end
        begin
          repeat (8) @(negedge phy_clock);
          #(20.0 - setup_time);
          for (integer i = 0; i < 8; i++) begin
            bit [7:0] data;
            bit error_bit;
            data=i*37+phase;
            error_bit=(phase%64==3 && i==5);
            expected.push_back({error_bit, (i == 7), data});
            send_nibble(data[3:0], 1'b0);
            send_nibble(data[7:4], error_bit);
          end
          phy_control = 0;
          repeat (32) @(negedge phy_clock);
        end
      join_any
      disable frame_session;
      if (expected.size() != 0 || rx_fault) $fatal(1, "phase %0d incomplete/fault", phase);
    end
    if (received != 4608) $fatal(1, "received %0d", received);
    $display(
        "PASS CM005 oversample primitives: RX=4608, 64 phases x 3 apertures x 3 skew bounds, +/-20ps sampling variation, RX_ER, frame ends, resets");
    $finish;
  end
  initial begin
    #3000000;
    $fatal(1, "timeout");
  end
endmodule
