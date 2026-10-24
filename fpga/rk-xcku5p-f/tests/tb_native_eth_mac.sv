`timescale 1ns / 1ps
module tb_native_eth_mac;
  logic clk = 0, rx_clk = 0, tx_clk = 0, reset = 1;
  always #10 clk = ~clk;
  always #4 rx_clk = ~rx_clk;
  always #4.1 tx_clk = ~tx_clk;
  logic rd = 0, wr = 0;
  logic [15:0] raddr = 0, waddr = 0;
  logic [31:0] wdata = 0, rdata;
  wire enabled, irq;
  wire [7:0] rx_data, tx_data, gmii_txd;
  wire rx_valid, rx_last, rx_error, rx_bad_fcs, tx_valid, tx_last, tx_ready;
  wire gmii_tx_en, gmii_tx_er;
  logic [7:0] gmii_rxd = 0;
  logic gmii_rx_dv = 0, gmii_rx_er = 0;
  wire queue_reset = reset || !enabled;
  rapt_native_eth #(
      .RxFcsBytes(4)
  ) dut (
      .clk,
      .reset,
      .clocks_ready(1'b1),
      .rd,
      .wr,
      .raddr,
      .waddr,
      .wdata,
      .wstrb(4'hf),
      .rdata,
      .irq,
      .enabled,
      .mdio_control(),
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
  eth_mac_1g mac (
      .rx_clk,
      .rx_rst(queue_reset),
      .tx_clk,
      .tx_rst(queue_reset),
      .tx_axis_tdata(tx_data),
      .tx_axis_tvalid(tx_valid),
      .tx_axis_tready(tx_ready),
      .tx_axis_tlast(tx_last),
      .tx_axis_tuser(1'b0),
      .rx_axis_tdata(rx_data),
      .rx_axis_tvalid(rx_valid),
      .rx_axis_tlast(rx_last),
      .rx_axis_tuser(rx_error),
      .gmii_rxd,
      .gmii_rx_dv,
      .gmii_rx_er,
      .gmii_txd,
      .gmii_tx_en,
      .gmii_tx_er,
      .rx_clk_enable(1'b1),
      .tx_clk_enable(1'b1),
      .rx_mii_select(1'b0),
      .tx_mii_select(1'b0),
      .rx_error_bad_frame(),
      .rx_error_bad_fcs(rx_bad_fcs),
      .rx_fcs_reg(),
      .tx_fcs_reg(),
      .ifg_delay(8'd12)
  );
  task automatic write_reg(input logic [15:0] addr, input logic [31:0] value);
    @(negedge clk);
    wr = 1;
    waddr = addr;
    wdata = value;
    @(negedge clk);
    wr = 0;
  endtask
  task automatic read_reg(input logic [15:0] addr, output logic [31:0] value);
    @(negedge clk);
    rd = 1;
    raddr = addr;
    @(negedge clk);
    rd = 0;
    value = rdata;
  endtask
  byte unsigned frame_bytes[$];
  int frames = 0;
  bit transmitting = 0;
  always @(negedge tx_clk) begin
    if (gmii_tx_en) begin
      if (gmii_tx_er) $fatal(1, "MAC TX underrun/error");
      frame_bytes.push_back(gmii_txd);
    end
    if (transmitting && !gmii_tx_en) frames++;
    transmitting = gmii_tx_en;
  end
  task automatic send(input int length, input int seed);
    logic [31:0] word_data, crc;
    int before_frames;
    frame_bytes.delete();
    before_frames = frames;
    for (int i = 0; i < length; i += 4) begin
      for (int b = 0; b < 4; b++) word_data[b*8+:8] = 8'(seed + 37 * (i + b));
      write_reg(16'('h2000 + i), word_data);
    end
    write_reg('h20, 32'(length));
    wait (frames != before_frames);
    if (frame_bytes.size() != (length < 60 ? 60 : length) + 12)
      $fatal(1, "wire length/padding mismatch %0d", frame_bytes.size());
    for (int i = 0; i < 8; i++)
      if (frame_bytes[i] != (i == 7 ? 8'hd5 : 8'h55)) $fatal(1, "preamble mismatch");
    // Independent bitwise Ethernet CRC checks TX including padding and FCS.
    crc = '1;
    for (int i = 8; i < frame_bytes.size(); i++) begin
      for (int b = 0; b < 8; b++) begin
        if (crc[0] ^ frame_bytes[i][b]) crc = (crc >> 1) ^ 32'hedb88320;
        else crc = crc >> 1;
      end
    end
    if (crc != 32'hdebb20e3) $fatal(1, "independent TX CRC mismatch %h", crc);
  endtask
  task automatic replay(input int corrupt_at = -1, input int error_at = -1, input int truncate = 0);
    for (int i = 0; i < frame_bytes.size() - truncate; i++) begin
      @(negedge rx_clk);
      gmii_rxd = frame_bytes[i] ^ (i == corrupt_at ? 8'h40 : 8'h00);
      gmii_rx_dv = 1;
      gmii_rx_er = i == error_at;
    end
    @(negedge rx_clk);
    gmii_rx_dv = 0;
    gmii_rx_er = 0;
    repeat (16) @(negedge clk);
  endtask
  task automatic consume(input int length, input int seed);
    logic [31:0] desc, word_data;
    int padded;
    padded = length < 60 ? 60 : length;
    read_reg('h18, desc);
    if (desc[15:0] != 16'(padded)) $fatal(1, "RX descriptor %h", desc);
    for (int i = 0; i < padded; i += 4) begin
      read_reg(16'('h4000 + int'(desc[18:16]) * 2048 + i), word_data);
      for (int b = 0; b < 4 && i + b < padded; b++) begin
        if (word_data[b*8+:8] !== (i + b < length ? 8'(seed + 37 * (i + b)) : 8'b0))
          $fatal(1, "MAC RX byte %0d mismatch", i + b);
      end
    end
    write_reg('h1c, 1);
  endtask
  task automatic empty;
    logic [31:0] desc;
    read_reg('h18, desc);
    if (desc != 0) $fatal(1, "bad frame published: %h", desc);
  endtask
  initial begin
    repeat (8) @(negedge clk);
    reset = 0;
    write_reg(8, 1);
    write_reg('h10, 3);
    send(42, 7);
    replay();
    consume(42, 7);
    send(61, 19);
    replay();
    consume(61, 19);
    replay(29);
    empty();  // Wrong CRC, data otherwise valid.
    replay(-1, 17);
    empty();  // PHY RX_ER during the frame.
    replay(-1, -1, 25);
    empty();  // Runt / truncated FCS.
    send(1514, 53);
    replay();
    consume(1514, 53);
    send(1536, 73);
    replay();
    consume(1536, 73);
    $display("PASS native MAC: independent TX CRC, padding, RX CRC/error/runt, max frame");
    $finish;
  end
  initial begin
    #1000000;
    $fatal(1, "MAC watchdog");
  end
endmodule
