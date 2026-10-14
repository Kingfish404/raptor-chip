`timescale 1ns / 1ps
module tb_native_uart;
  logic clk = 0, reset = 1, rx = 1, tx, irq, rd = 0, wr = 0;
  logic [2:0] addr = 0;
  logic [7:0] wdata = 0, rdata, value;
  always #5 clk = ~clk;
  rapt_native_uart #(.ClockHz(1843200)) dut (.*);
  task automatic write_reg(input logic [2:0] a, input logic [7:0] d);
    @(negedge clk);
    addr = a;
    wdata = d;
    wr = 1;
    @(negedge clk);
    wr = 0;
  endtask
  task automatic read_reg(input logic [2:0] a, output logic [7:0] d);
    @(negedge clk);
    addr = a;
    rd = 1;
    @(posedge clk);
    d = rdata;
    @(negedge clk);
    rd = 0;
  endtask
  task automatic send_byte(input logic [7:0] data, input bit stop = 1);
    @(negedge clk);
    rx = 0;
    repeat (16) @(negedge clk);
    for (int i = 0; i < 8; i++) begin
      rx = data[i];
      repeat (16) @(negedge clk);
    end
    rx = stop;
    repeat (16) @(negedge clk);
    rx = 1;
    repeat (8) @(negedge clk);
  endtask
  task automatic expect_tx(input logic [7:0] expected);
    @(negedge tx);
    repeat (8) @(negedge clk);
    if (tx != 0) $fatal(1, "TX start bit");
    for (int i = 0; i < 8; i++) begin
      repeat (16) @(negedge clk);
      if (tx != expected[i]) $fatal(1, "TX data bit %0d", i);
    end
    repeat (16) @(negedge clk);
    if (tx != 1) $fatal(1, "TX stop bit");
  endtask
  initial begin
    repeat (5) @(negedge clk);
    reset = 0;
    read_reg(5, value);
    if (value != 'h60) $fatal(1, "reset LSR");
    write_reg(3, 'h83);
    write_reg(0, 2);
    read_reg(0, value);
    if (value != 2) $fatal(1, "divisor latch");
    write_reg(0, 1);
    write_reg(3, 3);
    write_reg(1, 2);
    if (!irq) $fatal(1, "THRE interrupt enable");
    read_reg(2, value);
    if (value != 2 || irq) $fatal(1, "THRE IIR acknowledge");
    fork
      write_reg(0, 'ha6);
      expect_tx('ha6);
    join
    repeat (32) @(negedge clk);
    read_reg(5, value);
    if (value != 'h60) $fatal(1, "TX completion LSR");
    write_reg(1, 5);
    send_byte('h5a);
    if (!irq) $fatal(1, "RX interrupt missing");
    read_reg(2, value);
    if (value != 4) $fatal(1, "RX IIR");
    read_reg(0, value);
    if (value != 'h5a || irq) $fatal(1, "RX data/interrupt clear");
    for (int i = 0; i < 17; i++) send_byte(8'(i));
    read_reg(2, value);
    if (value != 6) $fatal(1, "overrun priority");
    read_reg(5, value);
    if (!(value & 2)) $fatal(1, "overrun LSR");
    for (int i = 0; i < 16; i++) begin
      read_reg(0, value);
      if (value != 8'(i)) $fatal(1, "RX FIFO order");
    end
    send_byte('hff, 0);
    read_reg(5, value);
    if (!(value & 8)) $fatal(1, "framing error");
    send_byte('h42);
    write_reg(2, 2);
    read_reg(5, value);
    if (value & 1) $fatal(1, "FIFO reset");
    $display("PASS native UART: serial data, divisor, IRQs, FIFO, overrun, framing");
    $finish;
  end
  initial begin
    #1000000;
    $fatal(1, "UART watchdog");
  end
endmodule
