`timescale 1ns / 1ps
module tb_native_eth;
  logic clk = 0, rx_clk = 0, tx_clk = 0, reset = 1;
  always #10 clk = ~clk;
  always #4 rx_clk = ~rx_clk;
  always #4.13 tx_clk = ~tx_clk;
  logic ready = 1, rd = 0, wr = 0;
  logic [15:0] raddr = 0, waddr = 0;
  logic [31:0] wdata = 0, rdata;
  logic [3:0] wstrb = 15;
  logic irq, enabled;
  logic [2:0] mdio;
  logic [7:0] rx_data = 0, tx_data;
  logic rx_valid = 0, rx_last = 0, rx_error = 0, rx_bad_fcs = 0;
  logic tx_valid, tx_last, tx_ready = 0;
  wire queue_reset = reset || !enabled || !ready;
  rapt_native_eth dut (
      .clk,
      .reset,
      .clocks_ready(ready),
      .rd,
      .wr,
      .raddr,
      .waddr,
      .wdata,
      .wstrb,
      .rdata,
      .irq,
      .enabled,
      .mdio_control(mdio),
      .mdio_input(1'b1),
      .rx_clk,
      .rx_reset(queue_reset),
      .rx_data,
      .rx_valid,
      .rx_last,
      .rx_error,
      .rx_bad_fcs,
      .tx_clk,
      .tx_reset(queue_reset),
      .tx_data,
      .tx_valid,
      .tx_last,
      .tx_ready
  );
  task automatic write_reg(input logic [15:0] addr, input logic [31:0] data);
    @(negedge clk);
    wr = 1;
    waddr = addr;
    wdata = data;
    @(negedge clk);
    wr = 0;
  endtask
  task automatic read_reg(input logic [15:0] addr, output logic [31:0] data);
    @(negedge clk);
    rd = 1;
    raddr = addr;
    @(negedge clk);
    rd = 0;
    data = rdata;
  endtask
  task automatic check_reg(input logic [15:0] addr, input logic [31:0] expect_data);
    logic [31:0] data;
    read_reg(addr, data);
    if (data !== expect_data) $fatal(1, "MMIO %h got %h expected %h", addr, data, expect_data);
  endtask
  task automatic frame(input int length, input int seed, input int bad_at = -1);
    for (int i = 0; i < length; i++) begin
      @(negedge rx_clk);
      rx_data = 8'(i + seed);
      rx_valid = 1;
      rx_last = i == length-1;
      rx_error = i == bad_at;
    end
    @(negedge rx_clk);
    rx_valid = 0;
    rx_last = 0;
    rx_error = 0;
    repeat (12) @(negedge rx_clk);
  endtask
  task automatic consume(input int length, input int seed);
    logic [31:0] desc, data, expect_word;
    read_reg(16'h18, desc);
    if (desc[15:0] != length) $fatal(1, "RX descriptor length got %h", desc);
    for (int i = 0; i < length; i += 4) begin
      read_reg(16'(16'h4000 + desc[18:16] * 2048 + i), data);
      for (int b = 0; b < 4 && i + b < length; b++)
      if (data[b*8+:8] !== 8'(seed + i + b)) $fatal(1, "RX byte %0d mismatch", i + b);
    end
    write_reg(16'h1c, 1);
    repeat (4) @(negedge clk);
  endtask
  int tx_count = 0, tx_expected = 0, tx_seed = 0, tx_cycle = 0;
  logic check_tx = 0;
  logic [7:0] held_data;
  logic held_last, held_valid = 0;
  always @(negedge tx_clk) begin
    tx_cycle = tx_cycle + 1;
    tx_ready = tx_cycle % 5 != 0 && tx_cycle % 7 != 0;
  end
  always @(posedge tx_clk) begin
    if (queue_reset) held_valid = 0;
    else begin
      if (held_valid && (!tx_valid || tx_data !== held_data || tx_last !== held_last))
        $fatal(1, "TX changed under backpressure");
      held_valid = tx_valid && !tx_ready;
      held_data = tx_data;
      held_last = tx_last;
      if (tx_valid && tx_ready && check_tx) begin
        if (tx_data !== 8'(tx_seed + tx_count) || tx_last !== (tx_count == tx_expected - 1))
          $fatal(1, "TX byte/last mismatch index=%0d data=%h last=%b", tx_count, tx_data, tx_last);
        tx_count = tx_count + 1;
      end
    end
  end
  task automatic transmit(input int length, input int seed);
    logic [31:0] word_data, status;
    for (int i = 0; i < length; i += 4) begin
      for (int b = 0; b < 4; b++) word_data[b*8+:8] = 8'(seed + i + b);
      write_reg(16'(16'h2000 + i), word_data);
    end
    tx_count = 0;
    tx_expected = length;
    tx_seed = seed;
    check_tx = 1;
    write_reg(16'h20, 32'(length));
    // Busy writes and duplicate commits must not corrupt the active frame.
    write_reg(16'h2000, '1);
    write_reg(16'h20, 32'(length));
    wait (tx_count == length);
    repeat (8) @(negedge clk);
    check_tx = 0;
    read_reg(16'hc, status);
    if (!status[1]) $fatal(1, "TX ownership was not returned");
  endtask
  initial begin
    repeat (6) @(negedge clk);
    reset = 0;
    check_reg(0, 32'h524e4554);
    check_reg(4, 1);
    write_reg(16'h40, 7);
    check_reg(16'h40, 7);
    check_reg(16'h44, 1);
    write_reg(8, 1);
    write_reg(16'h10, 3);
    repeat (8) @(negedge clk);
    // A partial frame is invisible even if the CPU tries to pop it.
    fork
      frame(1536, 11);
      begin
        repeat (20) @(negedge clk);
        check_reg(16'h18, 0);
        if (irq) $fatal(1, "partial frame raised IRQ");
        write_reg(16'h1c, 1);
      end
    join
    if (!irq) $fatal(1, "missing RX interrupt");
    consume(1536, 11);
    frame(61, 23);
    consume(61, 23);
    frame(64, 29, 17);
    frame(1537, 31);
    frame(59, 33);
    repeat (8) @(negedge clk);
    check_reg(16'h18, 0);
    check_reg(16'h2c, 3);
    // Full queue drops whole packets; reuse wraps both ownership bits.
    for (int round_no = 0; round_no < 3; round_no++) begin
      for (int i = 0; i < 9; i++) frame(60 + i, round_no * 20 + i);
      for (int i = 0; i < 8; i++) consume(60 + i, round_no * 20 + i);
    end
    check_reg(16'h28, 26);
    check_reg(16'h30, 3);
    fork
      begin
        transmit(61, 72);
        transmit(1536, 91);
      end
      begin
        frame(65, 37);
        consume(65, 37);
      end
    join
    check_reg(16'h34, 2);
    check_reg(16'h38, 2);
    write_reg(16'h14, 2);
    repeat (3) @(negedge clk);
    if (irq) $fatal(1, "TX W1C interrupt not cleared");
    // Disable, lost clock and restart all clear ownership and old descriptors.
    frame(60, 1);
    write_reg(8, 0);
    repeat (6) @(negedge clk);
    write_reg(8, 1);
    repeat (6) @(negedge clk);
    check_reg(16'h18, 0);
    check_reg(16'h28, 0);
    frame(63, 9);
    consume(63, 9);
    @(negedge clk);
    ready = 0;
    repeat (8) @(negedge clk);
    ready = 1;
    repeat (8) @(negedge clk);
    check_reg(16'h18, 0);
    transmit(60, 2);
    $display("PASS native Ethernet: partial/max/unaligned/error/full/wrap/CDC/TX-stall/reset");
    $finish;
  end
  initial begin
    #1000000;
    $fatal(1, "packet engine watchdog");
  end
endmodule
