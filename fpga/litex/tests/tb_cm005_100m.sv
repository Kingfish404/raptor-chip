`timescale 1ns / 1ps
module tb_cm005_100m;
  reg eth_tx_clk = 0, eth_rx_clk = 0, tx_shifted = 0;
  reg eth_tx_rst = 1, eth_rx_rst = 1;
  always #20 eth_tx_clk = ~eth_tx_clk;
  always #20 eth_rx_clk = ~eth_rx_clk;
  initial begin
    #10;
    forever #20 tx_shifted = ~tx_shifted;
  end
  reg tx_valid = 0, tx_last = 0, tx_error = 0;
  reg [7:0] tx_data=0;
  wire tx_ready;
  wire txc, tx_ctl;
  wire [3:0] tx_pins;
  reg [3:0] rx_pins=0;
  reg rx_ctl=0;
  wire rx_valid, rx_last;
  wire [7:0] rx_data;
  wire rx_error;
  reg rx_ready=1;
  cm005_100m dut (
      .eth_tx_clk,
      .eth_rx_clk,
      .eth_tx_rst,
      .eth_rx_rst,
      .tx_shifted,
      .txc,
      .tx_valid,
      .tx_last,
      .tx_error,
      .tx_ready,
      .tx_data(tx_pins),
      .tx_ctl,
      .tx_data_1(tx_data),
      .rx_data(rx_pins),
      .rx_ctl,
      .rx_data_1(rx_data),
      .rx_valid,
      .rx_last,
      .rx_error,
      .rx_ready
  );

  byte tx_expected[$];
  bit [8:0] rx_expected[$];
  bit high_nibble=0;
  byte tx_want, tx_discard;
  bit [8:0] rx_want;
  integer tx_received = 0, rx_received = 0;
  reg [3:0] rising_nibble;
  reg rising_valid;
  realtime last_tx_change = 0, last_txc = 0;
  always @(tx_pins or tx_ctl) begin
    if (!eth_tx_rst && $time > 1000 && $realtime - last_txc < 1.2)
      $fatal(1, "TX hold window violated");
    last_tx_change = $realtime;
  end
  always @(txc) begin
    if (!eth_tx_rst && $time > 1000 && $realtime - last_tx_change < 1.2)
      $fatal(1, "TX setup window violated");
    last_txc = $realtime;
  end
  always @(posedge txc) begin
    #0.001;
    rising_nibble=tx_pins;
    rising_valid=tx_ctl;
    if (!eth_tx_rst && tx_ctl) begin
      if (tx_expected.size() == 0) $fatal(1, "unexpected TX nibble");
      tx_want = tx_expected[0];
      if (tx_pins !== (high_nibble ? tx_want[7:4] : tx_want[3:0])) $fatal(1, "TX nibble mismatch");
      if (high_nibble) begin
        tx_discard = tx_expected.pop_front();
        tx_received++;
      end
      high_nibble = ~high_nibble;
    end else if (!eth_tx_rst && high_nibble) $fatal(1, "TX truncated byte");
  end
  always @(negedge txc) begin
    #0.001;
    if (!eth_tx_rst && (tx_ctl !== rising_valid || (tx_ctl && tx_pins !== rising_nibble)))
      $fatal(1, "100M nibble/control not repeated on falling edge");
  end
  always @(posedge eth_rx_clk)
    if (!eth_rx_rst && rx_valid && rx_ready) begin
      if (rx_expected.size() == 0) $fatal(1, "unexpected RX byte");
      rx_want = rx_expected.pop_front();
      if ({rx_last, rx_data} !== rx_want || rx_error)
        $fatal(
            1, "RX mismatch got=%h/%b expected=%h error=%b", rx_data, rx_last, rx_want, rx_error
        );
      rx_received++;
    end
  function automatic byte pattern(input integer i);
    return i * 37 + 8'h53;
  endfunction
  initial begin
    #200;
    @(negedge eth_tx_clk);
    eth_tx_rst=0;
    eth_rx_rst=0;
    repeat (20) @(negedge eth_tx_clk);
    fork
      begin
        for (integer p = 0; p < 4; p++) begin
          for (integer i = 0; i < 128; i++) begin
            tx_expected.push_back(pattern(i + p));
            tx_valid=1;
            tx_data=pattern(i+p);
            tx_last=(i==127);
            do @(posedge eth_tx_clk); while (!tx_ready);
            @(negedge eth_tx_clk);
          end
          tx_valid=0;
          tx_last=0;
          repeat (24) @(negedge eth_tx_clk);
        end
      end
      begin
        // Data transitions 2 ns before each RX rising edge. The PHY
        // input delay is included by the production IDELAYE3 model.
        #18;
        for (integer p = 0; p < 4; p++) begin
          for (integer i = 0; i < 128; i++) begin
            rx_expected.push_back({(i == 127), pattern(i + p)});
            rx_ctl=1;
            rx_pins=pattern(i+p)&15;
            #40;
            rx_pins = (pattern(i + p) >> 4) & 15;
            #40;
          end
          rx_ctl = 0;
          #960;
        end
      end
    join
    repeat (20) @(negedge eth_tx_clk);
    if(tx_expected.size()!=0 || rx_expected.size()!=0 || tx_received!=512 || rx_received!=512)
      $fatal(1, "missing bytes TX=%0d RX=%0d", tx_received, rx_received);
    $display("PASS CM005 100M primitives: TX=512 RX=512, frame ends, repeated nibbles, setup/hold");
    $finish;
  end
  initial begin
    #100000;
    $fatal(1, "timeout");
  end
endmodule
