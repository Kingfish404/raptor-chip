`timescale 1ns / 1ps

// Exercise actual 115200-baud serial pins through the FPGA export/synthesis path.
module tb_rapt_arty_loader;
  localparam int RamBytes = 262144;
  localparam realtime NominalBit = 1.0e9 / 115200.0;
  realtime host_bit = NominalBit;
  logic clock = 0, reset = 1, uart_rx = 1;
  wire uart_tx, run, load_write, clear;
  wire [31:0] load_addr;
  wire [7:0] load_data;
  logic clear_busy = 0;
  logic [31:0] load_rdata;
  byte unsigned ram[RamBytes];
  int writes = 0, replies = 0, clear_cycles = 0;
  logic [7:0] reply_kind;
  logic [31:0] reply_data;
  logic [7:0] kinds[512];
  logic [31:0] values[512];
  always #5 clock = !clock;

  rapt_arty_loader u_dut (
      .clock(clock),
      .reset(reset),
      .uart_rx_i(uart_rx),
      .uart_tx_o(uart_tx),
      .run_o(run),
      .load_write_o(load_write),
      .load_addr_o(load_addr),
      .load_data_o(load_data),
      .clear_o(clear),
      .clear_busy_i(clear_busy),
      .load_rdata_i(load_rdata)
  );
  always @(posedge clock) begin
    if (clear) begin
      foreach (ram[i]) ram[i] = 0;
      clear_cycles = 8;
    end else if (clear_cycles != 0) clear_cycles--;
    clear_busy <= clear_cycles != 0;
    if (load_write) begin
      if (load_addr < 32'h8000_0000 || load_addr >= 32'h8004_0000)
        $fatal(1, "loader emitted out-of-range write %h", load_addr);
      ram[int'(load_addr-32'h8000_0000)] = load_data;
      writes++;
    end
    for (int i = 0; i < 4; i++)
    load_rdata[8*i+:8] <= ram[int'((load_addr-32'h8000_0000)&32'h3_fffc)+i];
  end

  task automatic send_byte(input logic [7:0] value);
    uart_rx = 0;
    #host_bit;
    for (int i = 0; i < 8; i++) begin
      uart_rx = value[i];
      #host_bit;
    end
    uart_rx = 1;
    #host_bit;
  endtask
  task automatic header(input byte command, input logic [31:0] address, input int length);
    send_byte(8'ha5);
    send_byte(command);
    for (int i = 0; i < 4; i++) send_byte(address[8*i+:8]);
    send_byte(8'(length));
    send_byte(8'(length >> 8));
  endtask
  initial begin : receive
    logic [7:0] packet[6];
    forever begin
      for (int j = 0; j < 6; j++) begin
        @(negedge uart_tx);
        #(NominalBit * 1.5);
        for (int i = 0; i < 8; i++) begin
          packet[j][i] = uart_tx;
          #NominalBit;
        end
        if (!uart_tx) $fatal(1, "UART stop bit");
      end
      if (packet[0] != 8'h5a) $fatal(1, "UART magic %h", packet[0]);
      reply_kind = packet[1];
      reply_data = {packet[5], packet[4], packet[3], packet[2]};
      kinds[replies] = reply_kind;
      values[replies] = reply_data;
      replies++;
    end
  end
  task automatic expect_reply(input int previous, input byte kind, input logic [31:0] value);
    wait (replies > previous);
    $display("[loader] reply %c %08h", kinds[previous], values[previous]);
    if (kinds[previous] != kind || values[previous] != value)
      $fatal(1, "expected %c %h, received %c %h", kind, value, kinds[previous], values[previous]);
    #NominalBit;
  endtask
  task automatic command(input byte cmd, input logic [31:0] addr, input byte kind,
                         input logic [31:0] expected);
    int previous = replies;
    header(cmd, addr, 0);
    expect_reply(previous, kind, expected);
  endtask
  task automatic write_block(input logic [31:0] address, input int length);
    int previous = replies;
    int before_writes = writes;
    header("W", address, length);
    for (int i = 0; i < length; i++) send_byte(8'(i ^ (i >> 8) ^ 8'ha5));
    expect_reply(previous, "A", "W");
    if (writes - before_writes != length) $fatal(1, "write count %0d", writes - before_writes);
    for (int i = 0; i < length; i++)
      if (ram[int'(address-32'h8000_0000)+i] != 8'(i ^ (i >> 8) ^ 8'ha5))
        $fatal(1, "write byte mismatch at %h", address + i);
    command("R", address & 32'hffff_fffc, "R", 32'ha6a7_a4a5);
  endtask
  initial begin
    if (!$value$plusargs("HOST_BIT=%f", host_bit)) host_bit = NominalBit;
    repeat (16) @(negedge clock);
    reset = 0;
    #(NominalBit * 3.17);
    command("A", 0, "A", "A");
    command("S", 0, "S", 32'h0001_0000);
    command("Z", 0, "A", "Z");
    if ($test$plusargs("READ_FIRST")) command("R", 32'h8000_0000, "R", 0);
    write_block(32'h8000_0000, 16);
    if (!$test$plusargs("QUICK")) begin
      write_block(32'h8000_0100, 256);
      write_block(32'h8000_1000, 4096);
      write_block(32'h8003_fff0, 16);
      command("R", 32'h8004_0000, "E", "R");
      command("R", 32'h7fff_fffc, "E", "R");
      command("R", 32'hffff_fffc, "E", "R");
      begin
        int previous;
        previous = replies;
        header("W", 32'h8003_fff0, 17);
        expect_reply(previous, "E", "W");
      end
      command("A", 0, "A", "A");
    end
    $display("RAPT_LOADER_PASS host_bit=%0.3f writes=%0d", host_bit, writes);
    $finish;
  end
  initial begin
    #1_000_000_000;
    $fatal(1, "loader timeout");
  end
endmodule
