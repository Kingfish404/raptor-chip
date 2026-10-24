`timescale 1ns / 1ps
// Run against AMD UNISIM IDDRE1/IDELAYE3, not behavioral DDR approximations.
module tb_rk_native_rx;
  reg clk = 1, reset = 1;
  initial begin
    #2.6;
    forever begin
      clk = ~clk;
      #4;
    end
  end
  reg [3:0] pins = 0;
  reg ctl = 0;
  wire [7:0] data;
  wire valid, error;
  rapt_rk_rgmii_rx dut (.*);
  bit [8:0] expected[$];
  bit [8:0] wanted;
  integer received = 0;
  real skew = 0;
  always @(posedge clk) begin
    #0.2;
    if (!reset && valid) begin
      if (expected.size() == 0) $fatal(1, "unexpected RX byte");
      wanted = expected.pop_front();
      if ({error, data} !== wanted)
        $fatal(1, "RX byte %0d: got %h/%b wanted %h", received, data, error, wanted);
      received++;
    end
  end
  task send_frame(input integer length, input integer seed, input integer error_at);
    reg [7:0] value;
    for (integer i = 0; i < length; i++) begin
      value = 8'(i * 37 + seed);
      expected.push_back({(i == error_at), value});
      pins = value[3:0];
      ctl = 1;
      #4;
      pins = value[7:4];
      ctl = i != error_at;
      #4;
    end
    pins = 0;
    ctl = 0;
    #96;
  endtask
  initial begin
    if (!$value$plusargs("SKEW=%f", skew)) skew = 0;
    #200;
    reset = 0;
    #(800 + skew);
    send_frame(72, 3, -1);
    send_frame(1526, 71, -1);
    send_frame(73, 13, 17);
    send_frame(72, 5, -1);
    reset = 1;
    #32;
    reset = 0;
    #96;
    send_frame(72, 17, 71);
    send_frame(72, 19, -1);
    #128;
    if (expected.size() != 0 || received != 1887) $fatal(1, "missing RX bytes %0d", received);
    $display("PASS native RGMII RX primitives: skew=%0.1f bytes=%0d", skew, received);
    $finish;
  end
  initial begin
    #30000;
    $fatal(1, "RX watchdog");
  end
endmodule
