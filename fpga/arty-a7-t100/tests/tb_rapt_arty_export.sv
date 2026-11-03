`timescale 1ns / 1ps

// No SoC or board internals are referenced: load, verify, boot and finish via pins.
module tb_rapt_arty_export;
  localparam realtime BitPeriod = 1.0e9 / 115200.0;
  logic clk100 = 0;
  logic [1:0] btn = 1;
  logic uart_rx = 1;
  wire uart_tx;
  wire [3:0] led;
  wire [7:0] flash_dq, link_dq;
  wire link_sclk, link_cs_n;
  int replies = 0, half_period = 4;
  int boot_wait_ns = 20_000_000;
  logic [7:0] kinds[512];
  logic [31:0] values[512];
  bit finish_seen = 0;
  logic [31:0] finish_code;
  byte unsigned image_bytes[$];
  always #5 clk100 = !clk100;
  rapt_arty_top u_dut (
      .clk100(clk100),
      .btn(btn),
      .boot_switch(1'b0),
      .led(led),
      .uart_rx(uart_rx),
      .uart_tx(uart_tx),
      .chip_sclk(link_sclk),
      .chip_cs_n(link_cs_n),
      .chip_dq(link_dq),
      .board_sclk(link_sclk),
      .board_cs_n(link_cs_n),
      .board_dq(link_dq),
      .jtag_tck(1'b0),
      .jtag_tms(1'b1),
      .jtag_tdi(1'b1),
      .jtag_tdo(),
      .flash_ck(),
      .flash_cs_n(),
      .flash_reset_n(),
      .flash_dqs(1'b0),
      .flash_dq(flash_dq)
  );
  // This test boots RAM; the separately validated flash-model bench covers NOR.
  assign flash_dq = 8'hff;
  task automatic send_byte(input logic [7:0] value);
    uart_rx = 0;
    #BitPeriod;
    for (int i = 0; i < 8; i++) begin
      uart_rx = value[i];
      #BitPeriod;
    end
    uart_rx = 1;
    #BitPeriod;
  endtask
  task automatic header(input byte cmd, input logic [31:0] address, input int length);
    send_byte(8'ha5);
    send_byte(cmd);
    for (int i = 0; i < 4; i++) send_byte(address[8*i+:8]);
    send_byte(8'(length));
    send_byte(8'(length >> 8));
  endtask
  initial begin : receive
    logic [7:0] packet[6];
    forever begin
      for (int j = 0; j < 6; j++) begin
        @(negedge uart_tx);
        #(BitPeriod * 1.5);
        for (int i = 0; i < 8; i++) begin
          packet[j][i] = uart_tx;
          #BitPeriod;
        end
        if (uart_tx !== 1'b1) $fatal(1, "UART stop bit");
      end
      if (packet[0] !== 8'h5a) $fatal(1, "UART packet marker");
      case (packet[1])
        "C": $write("%c", packet[2]);
        "F": begin
          finish_code = {packet[5], packet[4], packet[3], packet[2]};
          finish_seen = 1;
        end
        default: begin
          kinds[replies]  = packet[1];
          values[replies] = {packet[5], packet[4], packet[3], packet[2]};
          replies++;
        end
      endcase
    end
  end
  task automatic expect_reply(input int previous, input byte kind, input logic [31:0] value);
    wait (replies > previous);
    if (kinds[previous] !== kind || values[previous] !== value)
      $fatal(1, "reply %c %h, expected %c %h", kinds[previous], values[previous], kind, value);
    $display("[export] reply %c %h", kind, value);
    #BitPeriod;
  endtask
  task automatic command(input byte cmd, input logic [31:0] address, input byte kind,
                         input logic [31:0] expected);
    int previous = replies;
    header(cmd, address, 0);
    expect_reply(previous, kind, expected);
  endtask
  initial begin
    string image;
    int handle, value, previous;
    logic [31:0] word_value;
    if (!$value$plusargs("IMG=%s", image)) $fatal(1, "IMG required");
    if (!$value$plusargs("HALF=%d", half_period)) half_period = 4;
    if (!$value$plusargs("BOOT_NS=%d", boot_wait_ns)) boot_wait_ns = 20_000_000;
    handle = $fopen(image, "rb");
    if (!handle) $fatal(1, "cannot open %s", image);
    while (!$feof(
        handle
    )) begin
      value = $fgetc(handle);
      if (value >= 0) image_bytes.push_back(8'(value));
    end
    $fclose(handle);
    if (image_bytes.size() == 0 || image_bytes.size() > 65535) $fatal(1, "image size");
    #1000;
    btn = 0;
    wait (led[0]);
    #2000;
    command("A", 0, "A", "A");
    // PINS joins only the external ports. The internal variant floats those
    // DQ ports and ignores its board-side input pins.
    command("S", 0, "S", $test$plusargs("PINS") ? 32'b0 : 32'h0001_0000);
    command("Z", 0, "A", "Z");
    previous = replies;
    header("W", 32'h8000_0000, image_bytes.size());
    foreach (image_bytes[i]) send_byte(image_bytes[i]);
    expect_reply(previous, "A", "W");
    word_value = {image_bytes[3], image_bytes[2], image_bytes[1], image_bytes[0]};
    command("R", 32'h8000_0000, "R", word_value);
    previous = replies;
    header("W", 32'h8003_fff0, 4);
    for (int i = 0; i < 4; i++) send_byte(8'(half_period >> (8 * i)));
    expect_reply(previous, "A", "W");
    command("G", 0, "A", "G");
    if (led[1] !== 1'b1) $fatal(1, "core reset did not release");
    // Bound the actual CPU boot independently of the UART-loading watchdog.
    // Query while running so a stalled link is preserved before A clears it.
    for (int attempt = 0; attempt < boot_wait_ns / 10000 && !finish_seen; attempt++) begin
      #10000;
    end
    if (!finish_seen) begin
      previous = replies;
      header("S", 0, 0);
      wait (replies > previous);
      $display("[export] stalled boot status=%h led=%b", values[previous], led);
      #BitPeriod;
      previous = replies;
      header("L", 0, 0);
      wait (replies > previous);
      $fatal(1, "CPU boot timeout: frames=%0d", values[previous]);
    end
    if (finish_code !== 32'h0000_5555) $fatal(1, "finisher %h", finish_code);
    previous = replies;
    header("L", 0, 0);
    wait (replies > previous);
    if (kinds[previous] !== "L" || $isunknown(values[previous]) || values[previous] == 0)
      $fatal(1, "no link frames");
    #BitPeriod;
    command("A", 0, "A", "A");
    command("R", 32'h8003_fff4, "R", 32'(half_period));
    $display("RAPT_EXPORT_BOOT_PASS half=%0d frames=%0d finisher=%h", half_period,
             values[previous], finish_code);
    $finish;
  end
  initial begin
    #1_000_000_000;
    $fatal(1, "exported board timeout");
  end
endmodule
