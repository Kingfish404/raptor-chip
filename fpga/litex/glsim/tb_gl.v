`timescale 1ns/1ps
// Gate-level functional sim testbench for the routed KU15P netlist.
// Drives clk100 (100 MHz) + reset, ties serial_rx idle, decodes serial_tx
// UART @115200 and prints the probe-firmware output so we can see whether
// the MM/SD/DC deadlock reproduces in the synthesized netlist.
module tb;
  reg  clk100     = 1'b0;
  reg  cpu_resetn = 1'b0;
  reg  serial_rx  = 1'b1;
  wire serial_tx;

  // 100 MHz oscillator
  always #5 clk100 = ~clk100;

  mlk_cu07_ku15p dut (
      .clk100     (clk100),
      .cpu_resetn (cpu_resetn),
      .serial_rx  (serial_rx),
      .serial_tx  (serial_tx)
  );

  // External reset: hold low ~2 us, then release. (Main reset comes from
  // the MMCM lock internally; this just exercises cpu_resetn cleanly.)
  initial begin
    cpu_resetn = 1'b0;
    #2000;
    cpu_resetn = 1'b1;
  end

  // ---- UART RX decoder @ 115200 baud (8N1) ----
  localparam real BITNS = 8680.55; // 1e9 / 115200
  integer i;
  reg [7:0] b;
  integer nchars = 0;
  initial begin
    // wait until serial line is a settled '1' (idle) before decoding
    wait (serial_tx === 1'b1);
    forever begin
      @(negedge serial_tx);     // start bit edge
      #(BITNS*1.5);             // move to centre of data bit 0
      for (i = 0; i < 8; i = i + 1) begin
        b[i] = serial_tx;
        #(BITNS);
      end
      nchars = nchars + 1;
      if (b >= 8'h20 && b < 8'h7f) $write("%c", b);
      else if (b == 8'h0a)        $write("\n");
      else if (b == 8'h0d)        ; // swallow CR
      else                        $write("<%02x>", b);
      $fflush;
    end
  end

  // Watchdog / overall time limit
  initial begin
    #16000000; // 16 ms of sim time
    $display("\n[TB] 16ms timeout reached; chars decoded = %0d", nchars);
    $finish;
  end
endmodule
