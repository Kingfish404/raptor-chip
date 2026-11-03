`timescale 1ns / 1ps
`include "rapt.svh"
`include "rapt_if.svh"

module tb_sample_window;
  localparam int X = `RAPT_XLEN;
  localparam int Width = rapt_pkg::CommitWidth;
  localparam logic [63:0] UserRoot = X == 64 ? 64'h800000000009452a : 64'h8009452a;
  localparam logic [63:0] UserThread = X == 64 ? 64'h3fe0ec5880 : 64'h0ec5880;
  logic clk = 0, reset = 1;
  always #5 clk = ~clk;
  logic cfg_wr = 0;
  logic [15:0] cfg_waddr = 0, cfg_raddr = 0;
  logic [63:0] cfg_wdata = 0, cfg_rdata;
  logic cpu_reset, bus_idle = 1, allow_quiescence = 1;
  rapt_sample_if #(.XLEN(X)) sample ();
  assign sample.quiescent = sample.halt_req && allow_quiescence;
  assign sample.drain_ready = {3'b111, sample.quiescent};
  assign sample.restore_fire = 0;
  assign sample.gpr_data = X'(64'h123456789abcdef0);
  rapt_sample_window dut (
      .clk,
      .reset,
      .cfg_wr,
      .cfg_waddr,
      .cfg_raddr,
      .cfg_wdata,
      .cfg_rdata,
      .bus_idle,
      .writeback_error(1'b0),
      .device_activity(1'b0),
      .cpu_reset,
      .sample
  );

  task automatic wr(input logic [15:0] addr, input logic [63:0] data);
    @(negedge clk);
    cfg_wr = 1;
    cfg_waddr = addr;
    cfg_wdata = data;
    @(negedge clk);
    cfg_wr = 0;
  endtask

  task automatic rd(input logic [15:0] addr, output logic [63:0] data);
    @(negedge clk);
    cfg_raddr = addr;
    repeat (2) @(negedge clk);
    data = cfg_rdata;
  endtask

  task automatic replay(input int warmup, input bit user_domain = 0);
    logic [63:0] value, count, cycles, previous, row_pc, digest;
    int sent, batch, rows;
    wr(16'h0010, 64'(warmup));
    wr(16'h0018, 128);
    wr(16'h0020, 64'h80001000);
    wr(16'h0028, 64'h0f000244);
    wr(16'h00c8, 64'(user_domain));
    wr(16'h00d0, UserRoot);
    wr(16'h00d8, 64'(user_domain));
    wr(16'h00e0, UserThread);
    wr(16'h0008, 1);
    if (cpu_reset || !sample.restore_armed) $fatal(1, "Replay did not leave reset");
    sample.pc[0] = X'(64'h0f000244);
    sample.count = 1;
    sample.mret = 1;
    @(negedge clk);
    sample.count = 0;
    sample.mret = 0;
    sample.privilege = 0;
    sample.satp_root = X'(UserRoot);
    sample.thread_pointer = X'(UserThread);
    sent = 0;
    while (!sample.halt_req) begin
      if (user_domain && sent % 17 == 16) begin
        sample.count = $clog2(Width+1)'(Width);
        sample.privilege = 1;
        repeat (3) @(negedge clk);
        sample.privilege = 0;
        sample.satp_root = X'(64'h8000000000001111);
        repeat (2) @(negedge clk);
        sample.satp_root = X'(UserRoot);
        sample.thread_pointer = X'(64'h76543210);
        repeat (3) @(negedge clk);
        sample.thread_pointer = X'(UserThread);
      end
      batch = (sent / 7) % Width + 1;
      sample.count = (sent % 13 == 12) ? '0 : $clog2(Width+1)'(batch);
      for (int c = 0; c < Width; c++) sample.pc[c] = X'(64'h80001000 + 2 * (sent + c));
      sent += int'(sample.count);
      @(negedge clk);
      if (sample.count == 0) begin
        sample.count = $clog2(Width + 1)'(batch);
        for (int c = 0; c < Width; c++) sample.pc[c] = X'(64'h80001000 + 2 * (sent + c));
        sent += batch;
        @(negedge clk);
      end
    end
    sample.count = 0;
    repeat (8) @(negedge clk);
    rd(16'h0078, value);
    rows = int'(value);
    if (rows < 2 || rows > 131) $fatal(1, "Invalid observation row count %d", rows);
    previous = 0;
    for (int r = 0; r < rows; r++) begin
      rd(16'(16'h1000 + r * 32), count);
      rd(16'(16'h1008 + r * 32), cycles);
      rd(16'(16'h1010 + r * 32), row_pc);
      rd(16'(16'h1018 + r * 32), value);
      if (r != 0 && count <= previous) $fatal(1, "Retirement boundaries are not ordered");
      if (count != 0 && row_pc != 64'h80001000 + (count - 1) * 2)
        $fatal(1, "Wrong last PC at boundary %d", count);
      digest = 0;
      for (int i = 0; i < int'(count); i++)
      digest = {digest[56:0], digest[63:57]} ^ (64'h80001000 + 2 * i) ^ 64'h9e37_79b9_7f4a_7c15;
      if (digest != value) $fatal(1, "Ordered PC digest mismatch");
      previous = count;
    end
    rd(16'h0090, value);
    if (value != 0) $fatal(1, "Valid window failed: %d", value);
    rd(16'h00c0, value);
    if (value != 64'h80001000 + 2 * warmup) $fatal(1, "Wrong measurement start PC");
    wr(16'h0008, 3);
    repeat (8) @(negedge clk);
    if (!cpu_reset) $fatal(1, "CPU reset was not held after drain");
  endtask

  task automatic drain_watchdog;
    logic [63:0] value;
    wr(16'h0008, 3);
    repeat (8) @(negedge clk);
    if (!cpu_reset) $fatal(1, "Watchdog setup did not hold reset");
    wr(16'h0060, 20);
    allow_quiescence = 0;
    wr(16'h0008, 1);
    sample.pc[0] = X'(64'h0f000244);
    sample.count = 1;
    sample.mret = 1;
    @(negedge clk);
    sample.count = 0;
    sample.mret = 0;
    wr(16'h0008, 2);
    repeat (32) @(negedge clk);
    rd(16'h0090, value);
    if (value != 8) $fatal(1, "Drain watchdog did not report its own error: %d", value);
    rd(16'h0008, value);
    if (!(value & 8) || (value & 4) || cpu_reset || !sample.halt_req)
      $fatal(1, "Unsafe drain must fail while keeping halt asserted and reset deasserted");
    rd(16'h00e8, value);
    if (value < 20) $fatal(1, "Drain elapsed cycles were not exposed");
    rd(16'h00f0, value);
    if (value != 14) $fatal(1, "Drain readiness bits were not exposed");
    wr(16'h0008, 3);
    repeat (8) @(negedge clk);
    if (cpu_reset) $fatal(1, "Reset crossed an unsafe drain boundary");
    allow_quiescence = 1;
    repeat (8) @(negedge clk);
    if (!cpu_reset) $fatal(1, "Safe drain did not release requested reset");
  endtask

  initial begin
    sample.count = 0;
    sample.mret = 0;
    sample.privilege = 0;
    sample.satp_root = 0;
    for (int c = 0; c < Width; c++) sample.pc[c] = 0;
    repeat (3) @(negedge clk);
    reset = 0;
    replay(17);
    replay(0);
    replay(17, 1);
    wr(16'h0018, 0);
    wr(16'h0008, 1);
    if (!cpu_reset) $fatal(1, "Zero length configuration ran");
    wr(16'h0018, 128);
    wr(16'h0060, 5);
    wr(16'h0008, 1);
    repeat (20) @(negedge clk);
    if (!sample.halt_req) $fatal(1, "Restore watchdog failed");
    drain_watchdog();
    $display("PASS: sample window RV%0d CW%0d boundaries, faults, digest, reset, watchdog", X,
             Width);
    $finish;
  end

  initial begin
    #1000000;
    $fatal(1, "Testbench timeout");
  end
endmodule
