`timescale 1ns / 1ps
`include "native_ddr_model.svh"

module tb_native_boot;
  localparam int BitClocks = ((`NATIVE_CLOCK_HZ + 115200 * 8) / (115200 * 16)) * 16;
  logic clk = 0, reset = 1, rx = 1, tx, writeback_error;
  always #5 clk = ~clk;
  axi4_if ddr ();
  rapt_native_soc #(
      .WithDdr(`NATIVE_DDR),
      .RamBytes(`NATIVE_RAM_BYTES),
      .ClockHz(`NATIVE_CLOCK_HZ),
      .RomFile(`NATIVE_ROM_FILE)
  ) dut (
      .clk,
      .reset,
      .uart_rx(rx),
      .uart_tx(tx),
      .writeback_error,
      .ddr
  );
  native_ddr_model memory (
      .clk,
      .reset,
      .axi(ddr)
  );
  byte unsigned received[$];
  byte unsigned payload[4096];
  string payload_file;
  int payload_size;
  logic [31:0] crc;
  wire [`RAPT_XLEN-1:0] trace_araddr = dut.core.io_master_araddr;
  wire [2:0] trace_arsize = dut.core.io_master_arsize;
  wire [7:0] trace_arlen = dut.core.io_master_arlen;
  wire trace_arvalid = dut.core.io_master_arvalid;
  wire trace_arready = dut.core.io_master_arready;
  wire [1:0] trace_rresp = dut.core.io_master_rresp;
  wire trace_rvalid = dut.core.io_master_rvalid;
  wire trace_rready = dut.core.io_master_rready;
  initial begin
    if ($test$plusargs("TRACE")) begin
      $dumpfile("native_boot.vcd");
      $dumpvars(1, tb_native_boot);
    end
  end

  task automatic send_byte(input byte unsigned value);
    @(negedge clk);
    rx = 0;
    repeat (BitClocks) @(negedge clk);
    for (int i = 0; i < 8; i++) begin
      rx = value[i];
      repeat (BitClocks) @(negedge clk);
    end
    rx = 1;
    repeat (BitClocks) @(negedge clk);
  endtask
  task automatic send_word(input logic [31:0] value);
    for (int i = 0; i < 4; i++) send_byte(value[i*8+:8]);
  endtask
  task automatic header(input byte unsigned op, input logic [31:0] address,
                        input logic [31:0] count, input logic [31:0] checksum = 0);
    send_byte("R");
    send_byte("A");
    send_byte("P");
    send_byte("T");
    send_byte(op);
    send_word(address);
    send_word(count);
    send_word(checksum);
  endtask
  task automatic expect_byte(input byte unsigned expected);
    byte unsigned actual;
    wait (received.size() != 0);
    actual = received.pop_front();
    if (actual != expected) begin
      // Allow the ROM's trap diagnostic to finish before stopping the test.
      repeat (500000) @(posedge clk);
      $fatal(1, "UART byte %h expected %h", actual, expected);
    end
  endtask
  task automatic expect_string(input string value);
    for (int i = 0; i < value.len(); i++) expect_byte(value[i]);
  endtask
  initial
    forever begin
      byte unsigned value;
      @(negedge tx);
      repeat (BitClocks / 2) @(posedge clk);
      if (tx !== 0) $fatal(1, "boot UART false start");
      for (int i = 0; i < 8; i++) begin
        repeat (BitClocks) @(posedge clk);
        value[i] = tx;
      end
      repeat (BitClocks) @(posedge clk);
      if (tx !== 1) $fatal(1, "boot UART framing");
      received.push_back(value);
      $write("%c", value);
    end
  always @(posedge clk) begin
    if (!reset && writeback_error) $fatal(1, "CPU writeback error");
    if (!reset && trace_rvalid && trace_rready && trace_rresp != 0)
      $display(
          "AXI read error: address=%h size=%d len=%d response=%d",
          dut.bus.ra,
          dut.bus.rsize,
          dut.bus.rlen,
          trace_rresp
      );
  end
  initial begin
    if (!$value$plusargs(
            "PAYLOAD=%s", payload_file
        ) || !$value$plusargs(
            "PAYLOAD_SIZE=%d", payload_size
        ) || payload_size > 4096)
      $fatal(1, "payload arguments required");
    $readmemh(payload_file, payload);
    repeat (20) @(negedge clk);
    reset = 0;
    expect_string($sformatf(
                  "Raptor native %s RV%0d\r\nRAPT ready\r\n", `NATIVE_BOARD_STRING, `RAPT_XLEN));
    // Invalid destination and corrupted transport checksum must be rejected.
    header(1, 'h20000000, 1);
    expect_byte("E");
    expect_byte(2);
    header(1, 'h80000000, 1, 0);
    send_byte('h55);
    expect_byte("E");
    expect_byte(3);
    header(3, 'h80000000, 4096);
    expect_byte("K");
    crc = '1;
    for (int i = 0; i < payload_size; i++) begin
      crc ^= {24'b0, payload[i]};
      for (int b = 0; b < 8; b++) crc = (crc >> 1) ^ (crc[0] ? 32'hedb88320 : 0);
    end
    header(1, 'h80000000, 32'(payload_size), ~crc);
    for (int i = 0; i < payload_size; i++) send_byte(payload[i]);
    expect_byte("K");
    header(2, 'h80000000, 0);
    expect_byte("K");
    expect_string("NATIVE PAYLOAD PASS\r\n");
    $display("PASS native CPU boot RV%0d DDR=%0d: ROM, upload, CRC, RAM test, fence.i, payload",
             `RAPT_XLEN, `NATIVE_DDR);
    $finish;
  end
  initial begin
    repeat (20_000_000) @(posedge clk);
    $fatal(1, "native boot watchdog");
  end
endmodule
