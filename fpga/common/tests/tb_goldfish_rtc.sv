`timescale 1ns / 1ps
module tb_goldfish_rtc;
  localparam int ClockHz = 50_000_000;  // 20 ns per clock tick

  logic clk;
  logic reset;
  logic rd_i;
  logic wr_i;
  logic [4:0] addr_i;
  logic [31:0] wdata_i;
  logic [31:0] rdata_o;
  logic irq_o;

  initial clk = 1'b0;
  always #10 clk = ~clk;

  rapt_goldfish_rtc #(
      .ClockHz(ClockHz)
  ) dut (
      .clk(clk),
      .reset(reset),
      .rd_i(rd_i),
      .wr_i(wr_i),
      .addr_i(addr_i),
      .wdata_i(wdata_i),
      .rdata_o(rdata_o),
      .irq_o(irq_o)
  );

  task automatic write_reg(input logic [4:0] a, input logic [31:0] d);
    @(negedge clk);
    addr_i  = a;
    wdata_i = d;
    wr_i    = 1'b1;
    @(negedge clk);
    wr_i = 1'b0;
  endtask

  task automatic read_reg(input logic [4:0] a, output logic [31:0] d);
    @(negedge clk);
    addr_i = a;
    rd_i   = 1'b1;
    @(posedge clk);
    d = rdata_o;
    @(negedge clk);
    rd_i = 1'b0;
  endtask

  logic [31:0] lo0, hi0, lo1, hi1, st;

  initial begin
    reset   = 1'b1;
    rd_i    = 1'b0;
    wr_i    = 1'b0;
    addr_i  = 5'd0;
    wdata_i = 32'd0;
    repeat (4) @(negedge clk);
    reset = 1'b0;

    // 1. Verify monotonic 20 ns/tick progression from 0.
    repeat (5) @(negedge clk);
    read_reg(5'h00, lo0);
    read_reg(5'h04, hi0);
    repeat (10) @(negedge clk);
    read_reg(5'h00, lo1);
    read_reg(5'h04, hi1);
    if (hi0 != 32'd0 || hi1 != 32'd0) $fatal(1, "expected zero upper 32 bits");
    if (lo1 <= lo0) $fatal(1, "time did not advance monotonically: lo0=%0d lo1=%0d", lo0, lo1);
    if ((lo1 - lo0) != 32'd280) begin
      $fatal(1, "unexpected delta across 14 ticks: got %0d expected 280", lo1 - lo0);
    end

    // 2. Test setting time via TIME_HIGH + TIME_LOW and atomic latching across 32-bit wrap.
    write_reg(5'h04, 32'h0000_0005);
    write_reg(5'h00, 32'hFFFF_FFDC);
    // One tick elapses before read_reg asserts rd_i, advancing counter to 0x0000_0005_FFFF_FFF0;
    // on read_reg's posedge it reads 0xFFFF_FFF0, latches 0x0000_0005, and wraps to 0x6_0000_0004.
    read_reg(5'h00, lo0);
    // Wait several cycles so live TIME_HIGH is definitely 0x0000_0006.
    repeat (5) @(negedge clk);
    read_reg(5'h04, hi0);
    if (lo0 != 32'hFFFF_FFF0 || hi0 != 32'h0000_0005) begin
      $fatal(1, "atomic latch failed across wrap: hi=%08x lo=%08x", hi0, lo0);
    end
    // Now read again to verify counter wrapped cleanly into 0x0000_0006.
    read_reg(5'h00, lo1);
    read_reg(5'h04, hi1);
    if (hi1 != 32'h0000_0006 || lo1 == 32'd0) begin
      $fatal(1, "post-wrap time mismatch: hi=%08x lo=%08x", hi1, lo1);
    end

    // 3. Test alarm arming, firing, IRQ assertion, and CLEAR_INTERRUPT.
    write_reg(5'h04, 32'h0000_0010);
    write_reg(5'h00, 32'h0000_1000);
    write_reg(5'h10, 32'd1);  // IRQ_ENABLED = 1
    write_reg(5'h0C, 32'h0000_0010);  // ALARM_HIGH
    write_reg(5'h08, 32'h0000_10C8);  // ALARM_LOW (+200 ns = 10 ticks)

    read_reg(5'h18, st);
    if (st != 32'd1) $fatal(1, "ALARM_STATUS not armed: %0d", st);
    if (irq_o != 1'b0) $fatal(1, "IRQ asserted prematurely");

    repeat (12) @(negedge clk);
    if (irq_o != 1'b1) $fatal(1, "alarm IRQ did not assert");
    read_reg(5'h18, st);
    if (st != 32'd0) $fatal(1, "ALARM_STATUS still armed after firing");

    write_reg(5'h1C, 32'd1);  // CLEAR_INTERRUPT
    @(negedge clk);
    if (irq_o != 1'b0) $fatal(1, "CLEAR_INTERRUPT did not deassert irq_o");

    // 4. Test CLEAR_ALARM cancels armed alarm before firing.
    write_reg(5'h04, 32'h0000_0020);
    write_reg(5'h00, 32'h0000_2000);
    write_reg(5'h0C, 32'h0000_0020);
    write_reg(5'h08, 32'h0000_2100);
    read_reg(5'h18, st);
    if (st != 32'd1) $fatal(1, "ALARM_STATUS not armed before CLEAR_ALARM");
    write_reg(5'h14, 32'd1);  // CLEAR_ALARM
    read_reg(5'h18, st);
    if (st != 32'd0) $fatal(1, "CLEAR_ALARM did not disarm");
    repeat (20) @(negedge clk);
    if (irq_o != 1'b0) $fatal(1, "disarmed alarm fired IRQ");

    // 5. Test IRQ_ENABLED masking (pending latched, irq_o rises when enabled).
    write_reg(5'h10, 32'd0);  // IRQ_ENABLED = 0
    write_reg(5'h04, 32'h0000_0030);
    write_reg(5'h00, 32'h0000_3000);
    write_reg(5'h0C, 32'h0000_0030);
    write_reg(5'h08, 32'h0000_3064);  // +100 ns = 5 ticks
    repeat (8) @(negedge clk);
    if (irq_o != 1'b0) $fatal(1, "IRQ asserted while IRQ_ENABLED=0");
    write_reg(5'h10, 32'd1);  // IRQ_ENABLED = 1
    @(negedge clk);
    if (irq_o != 1'b1) $fatal(1, "masked pending IRQ did not surface when enabled");
    write_reg(5'h1C, 32'd1);  // CLEAR_INTERRUPT
    @(negedge clk);
    if (irq_o != 1'b0) $fatal(1, "CLEAR_INTERRUPT failed after unmask");

    $display("PASS Goldfish RTC: monotonic time, atomic latch, set time, alarm/IRQ, clear");
    $finish;
  end

  initial begin
    #1000000;
    $fatal(1, "Goldfish RTC watchdog timeout");
  end
endmodule
