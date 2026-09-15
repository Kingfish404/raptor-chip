`timescale 1ns / 1ps
module tb_cm005_gigabit_oversample;
  reg cm005_sample_clk = 0, eth_rx_rst = 1;
`ifdef RX_CLOCK_BUFFERS
  wire eth_rx_clk;
  reg clock_reset=1;
`else
  reg eth_rx_clk = 0;
`endif
  // Exercise unequal sample intervals as well as unrelated RX frequency.
  initial
    forever begin
      #0.78;
      cm005_sample_clk = 1;
      #0.82;
      cm005_sample_clk = 0;
    end
`ifndef RX_CLOCK_BUFFERS
  reg [1:0] sample_count = 0;
  always @(posedge cm005_sample_clk) begin
    sample_count <= sample_count+1;
    eth_rx_clk <= sample_count<2;
  end
`endif
  reg phy_clock = 0, phy_control = 0;
  reg [3:0] phy_data = 0;
  realtime clock_extra = 0, data_extra = 0;
  realtime high_time = 4.0, low_time = 4.0, rise_setup = 2.0, fall_setup = 2.0;
  wire phy_clock_sampled, phy_control_sampled;
  wire [3:0] phy_data_sampled;
  assign #(clock_extra) phy_clock_sampled = phy_clock;
`ifdef RX_CONTROL_LANE_DELAY
`ifndef RX_CONTROL_DELAY_PS
  `define RX_CONTROL_DELAY_PS 800
`endif
  assign #(data_extra + 0.001 * `RX_CONTROL_DELAY_PS) phy_control_sampled = phy_control;
`else
  assign #(data_extra) phy_control_sampled = phy_control;
`endif
`ifdef RX_ODD_LANE_DELAY
  // Model the measured odd-lane lag independently of the decoder's word
  // alignment, including transitions spanning an ISERDES word boundary.
  assign #(data_extra) phy_data_sampled[0]=phy_data[0];
  assign #(data_extra+1.6) phy_data_sampled[1]=phy_data[1];
  assign #(data_extra) phy_data_sampled[2]=phy_data[2];
  assign #(data_extra+1.6) phy_data_sampled[3]=phy_data[3];
`else
  assign #(data_extra) phy_data_sampled = phy_data;
`endif
  wire rx_valid, rx_last, rx_error, rx_fault;
  wire [7:0] rx_data, sampled_clock;
  cm005_oversample dut (
`ifdef RX_CLOCK_BUFFERS
      .sample_raw(cm005_sample_clk),
      .clock_reset,
`else
      .cm005_sample_clk,
`endif
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
  integer active_corner = 0, active_phase = 0;
  always @(posedge eth_rx_clk)
    if (!eth_rx_rst && rx_valid) begin
      if (expected.size() == 0) $fatal(1, "unexpected byte %h", rx_data);
      wanted = expected.pop_front();
      if ({rx_error, rx_last, rx_data} !== wanted)
        $fatal(
            1,
            "RX got=%h expected=%h sampled_clock=%h corner=%0d phase=%0d setup=%0.3f/%0.3f clock_extra=%0.3f data_extra=%0.3f",
            {
              rx_error, rx_last, rx_data
            },
            wanted,
            sampled_clock,
            active_corner,
            active_phase,
            rise_setup,
            fall_setup,
            clock_extra,
            data_extra
        );
      received++;
    end
  task automatic send_byte(input bit [7:0] data, input bit error_bit);
    phy_data=data[3:0];
    phy_control=1;
    #(high_time + rise_setup - fall_setup);
    phy_data=data[7:4];
    phy_control=1 ^ error_bit;
    #(low_time + fall_setup - rise_setup);
  endtask
  initial begin
    #200;
    for (integer corner = 0; corner < 3; corner++) begin
      realtime period;
      active_corner=corner;
      period=(corner==0) ? 7.9992 : ((corner==1) ? 8.0 : 8.0008);
      high_time=period*((corner==0) ? 0.45 : ((corner==1) ? 0.5 : 0.55));
      low_time=period-high_time;
      for (integer phase = 0; phase < 576; phase++) begin
        active_phase=phase;
        rise_setup=(phase/64%3==0) ? 0.8 : ((phase/64%3==1) ? low_time/2 : low_time-0.8);
        fall_setup=(phase/64%3==0) ? 0.8 : ((phase/64%3==1) ? high_time/2 : high_time-0.8);
        // IDELAY contributes 460 ps; add the bounded path mismatch.
        clock_extra=(phase/192==2) ? 0.315 : 0.0;
        data_extra=(phase/192==0) ? 0.435 : 0.0;
        eth_rx_rst=1;
        phy_clock=0;
        phy_control=0;
        phy_data=0;
`ifdef RX_CLOCK_BUFFERS
        clock_reset = 1;
        #20;
        clock_reset = 0;
`endif
        repeat (10) @(negedge eth_rx_clk);
        eth_rx_rst = 0;
        #((phase % 64) * 0.1);
        fork : frame_session
          begin
            forever begin
              #(low_time);
              phy_clock = 1;
              #(high_time);
              phy_clock = 0;
            end
          end
          begin
            repeat (8) @(negedge phy_clock);
            #(low_time - rise_setup);
            // Two frames with exactly 12 byte-times of idle.
            for (integer frame = 0; frame < 2; frame++) begin
              for (integer i = 0; i < 16; i++) begin
                bit [7:0] data;
                bit error_bit;
                data=i*37+phase+frame;
                error_bit=(phase%64==3 && i==5);
                expected.push_back({error_bit, (i == 15), data});
                send_byte(data, error_bit);
              end
              phy_control = 0;
              #(12 * period);
            end
            repeat (32) @(negedge phy_clock);
          end
        join_any
        disable frame_session;
        if (expected.size() != 0 || rx_fault)
          $fatal(1, "corner %0d phase %0d incomplete/fault", corner, phase);
      end
    end
    if (received != 55296) $fatal(1, "received %0d", received);
    $display(
        "PASS CM005 gigabit oversample primitives: RX=55296, 64 phases x 3 apertures x 3 skew bounds x 3 frequency/duty corners, +/-20ps sampling variation, full-rate DDR, minimum IFG, RX_ER, frame ends, resets");
    $finish;
  end
  initial begin
    #5000000;
    $fatal(1, "timeout");
  end
endmodule
