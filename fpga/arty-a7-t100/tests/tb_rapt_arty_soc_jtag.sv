`timescale 1ns / 1ps
module tb_rapt_arty_soc_jtag;
  logic cpu_clk = 0, cpu_rst = 1;
  logic jtag_tck = 0, jtag_tms = 1, jtag_tdi = 0;
  wire jtag_tdo;
  tap_bridge dut (.*);
  always #25 cpu_clk = ~cpu_clk;

  task automatic cycle(input logic ms, input logic di, output logic observed);
    jtag_tms = ms;
    jtag_tdi = di;
    #300;
    observed = jtag_tdo;
    jtag_tck = 1;
    #300;
    jtag_tck = 0;
    #300;
  endtask

  task automatic select_ir(input logic [4:0] instruction);
    logic unused_bit;
    cycle(1, 0, unused_bit);
    cycle(1, 0, unused_bit);
    cycle(0, 0, unused_bit);
    cycle(0, 0, unused_bit);
    for (int i = 0; i < 5; i++) cycle(i == 4, instruction[i], unused_bit);
    cycle(1, 0, unused_bit);
    cycle(0, 0, unused_bit);
  endtask

  task automatic scan_dr(input int width, input logic [40:0] request, output logic [40:0] response);
    logic unused_bit;
    cycle(1, 0, unused_bit);
    cycle(0, 0, unused_bit);
    cycle(0, 0, unused_bit);
    response = 0;
    for (int i = 0; i < width; i++) cycle(i == width - 1, request[i], response[i]);
    cycle(1, 0, unused_bit);
    cycle(0, 0, unused_bit);
  endtask

  initial begin
    logic unused_bit;
    logic [40:0] response;
    #200;
    cpu_rst = 0;
    repeat (6) cycle(1, 0, unused_bit);
    cycle(0, 0, unused_bit);
    scan_dr(32, 0, response);
    if (response[31:0] != 32'h10001913) $fatal(1, "IDCODE: %x", response);
    select_ir(5'h10);
    scan_dr(32, 0, response);
    if (response[31:0] != 32'h1071) $fatal(1, "DTMCS: %x", response);
    select_ir(5'h11);
    scan_dr(41, {7'h11, 32'b0, 2'b01}, response);
    cycle(0, 0, unused_bit);
    scan_dr(41, 0, response);
    if (response[33:2] != 32'h12345678 || response[1:0] != 0) $fatal(1, "DMI: %x", response);
    $display("PASS: sampled external JTAG IDCODE, DTMCS and pipelined DMI read at CPU 20 MHz");
    $finish;
  end
endmodule
