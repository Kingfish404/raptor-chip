`timescale 1ns / 1ps
module tb_native_clocks;
  logic reference = 0, reset = 1;
  always #5 reference = !reference;
  wire [4:0] locked;
  logic [4:0] checked = 0;
  function automatic int frequency(input int index);
    case (index)
      0: return 10_000_000;
      1: return 20_000_000;
      2: return 25_000_000;
      3: return 50_000_000;
      default: return 100_000_000;
    endcase
  endfunction
  for (genvar n = 0; n < 5; n++) begin : g_clock
    localparam int Hz = frequency(n);
    localparam realtime PeriodNs = 1_000_000_000.0 / Hz;
    wire clock_out;
    realtime before_edge, elapsed;
    rapt_arty_native_clocks #(
        .CoreClockHz(Hz)
    ) dut (
        .clock_i(reference),
        .reset_i(reset),
        .core_clock_o(clock_out),
        .locked_o(locked[n])
    );
    initial begin
      @(posedge locked[n]);
      repeat (8) @(posedge clock_out);
      repeat (16) begin
        before_edge = $realtime;
        @(posedge clock_out);
        elapsed = $realtime - before_edge;
        if (elapsed < PeriodNs - 0.02 || elapsed > PeriodNs + 0.02)
          $fatal(1, "Native clock frequency mismatch Hz=%0d period=%0.3f", Hz, elapsed);
      end
      checked[n] = 1;
    end
  end
  initial begin
    #200;
    reset = 0;
    wait (&checked);
    reset = 1;
    #200;
    if (|locked) $fatal(1, "Native MMCM lock did not fall under reset");
    reset = 0;
    wait (&locked);
    $display("NATIVE_CLOCKS_PASS: 10/20/25/50/100 MHz, reset and relock");
    $finish;
  end
  initial begin
    #2_000_000;
    $fatal(1, "Native device clock test timeout");
  end
endmodule
