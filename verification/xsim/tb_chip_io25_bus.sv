`include "rapt_soc_if.svh"
`timescale 1ns / 1ps

module tb_chip_io25_bus;
  localparam int XLEN  = `RAPT_XLEN;
  localparam int Bytes = XLEN / 8;
  logic clock = 0, reset = 1;
  always #5 clock = !clock;
  logic [1:0] rx = '1, tx, irq;
  logic [2:0] gpio_in = 0, gpio_out, gpio_oe;
  logic [31:0] value;
  int checks = 0;
  axi4_if #(.XLEN(XLEN)) host ();
  axi4_if #(.XLEN(XLEN)) external_bus ();

  rapt_chip_local_io #(
      .XLEN(XLEN),
      .CoreClockHz(1_843_200)
  ) dut (
      .clock,
      .reset,
      .axi(host),
      .backend(external_bus),
      .uart_rx_i(rx),
      .uart_tx_o(tx),
      .uart_irq_o(irq),
      .gpio_i(gpio_in),
      .gpio_o(gpio_out),
      .gpio_oe_o(gpio_oe)
  );

  task automatic tick;
    @(posedge clock);
    #1;
  endtask

  task automatic read_start(input logic [31:0] address, input int size, input int length);
    @(negedge clock);
    host.araddr = XLEN'(address);
    host.arsize = 3'(size);
    host.arlen = 8'(length);
    host.arid = 4'ha;
    host.arvalid = 1;
    #1;
    while (!host.arready) @(negedge clock);
    tick();
    host.arvalid = 0;
  endtask

  task automatic read_finish(input logic [31:0] address, input logic [1:0] response,
                             output logic [31:0] data);
    logic [XLEN-1:0] held;
    #1;
    while (!host.rvalid) tick();
    held = host.rdata;
    repeat (7) begin
      tick();
      if (!host.rvalid || host.rdata !== held || host.rresp != response || host.rid != 4'ha)
        $fatal(1, "Read response changed under backpressure");
    end
    data = 32'(held >> (8 * int'(address % Bytes)));
    @(negedge clock);
    host.rready = 1;
    tick();
    host.rready = 0;
    checks++;
  endtask

  task automatic read_reg(input logic [31:0] address, input int size, input logic [1:0] response,
                          output logic [31:0] data);
    read_start(address, size, 0);
    read_finish(address, response, data);
  endtask

  task automatic write_start(input logic [31:0] address, input int size, input int length);
    @(negedge clock);
    host.awaddr = XLEN'(address);
    host.awsize = 3'(size);
    host.awlen = 8'(length);
    host.awid = 4'h5;
    host.awvalid = 1;
    #1;
    while (!host.awready) @(negedge clock);
    tick();
    host.awvalid = 0;
  endtask

  task automatic write_beat(input logic [31:0] address, input logic [31:0] data,
                            input logic [Bytes-1:0] strobe, input bit last);
    repeat (3) tick();
    @(negedge clock);
    host.wdata = XLEN'(data) << (8 * int'(address % Bytes));
    host.wstrb = strobe;
    host.wlast = last;
    host.wvalid = 1;
    #1;
    while (!host.wready) @(negedge clock);
    tick();
    host.wvalid = 0;
  endtask

  task automatic write_finish(input logic [1:0] response);
    while (!host.bvalid) tick();
    repeat (5) begin
      tick();
      if (!host.bvalid || host.bid != 4'h5 || host.bresp != response)
        $fatal(1, "Write response changed under backpressure");
    end
    @(negedge clock);
    host.bready = 1;
    tick();
    host.bready = 0;
    checks++;
  endtask

  task automatic write_reg(input logic [31:0] address, input int size, input logic [31:0] data,
                           input logic [1:0] response);
    logic [Bytes-1:0] strobe;
    strobe = Bytes'((1 << (1 << size)) - 1) << int'(address % Bytes);
    write_start(address, size, 0);
    write_beat(address, data, strobe, 1);
    write_finish(response);
  endtask

  task automatic send_byte(input int port, input logic [7:0] data);
    @(negedge clock);
    rx[port] = 0;
    repeat (16) @(negedge clock);
    for (int i = 0; i < 8; i++) begin
      rx[port] = data[i];
      repeat (16) @(negedge clock);
    end
    rx[port] = 1;
    repeat (24) @(negedge clock);
  endtask

  task automatic expect_tx(input int port, input logic [7:0] data, input int ticks);
    @(negedge tx[port]);
    repeat (ticks / 2) @(negedge clock);
    if (tx[port]) $fatal(1, "UART TX start bit");
    for (int i = 0; i < 8; i++) begin
      repeat (ticks) @(negedge clock);
      if (tx[port] != data[i]) $fatal(1, "UART%0d TX bit %0d", port, i);
    end
    repeat (ticks) @(negedge clock);
    if (!tx[port]) $fatal(1, "UART TX stop bit");
    checks++;
  endtask

  initial begin
    host.araddr = 0;
    host.arid = 0;
    host.arlen = 0;
    host.arsize = 0;
    host.arburst = 1;
    host.arcache = 0;
    host.arvalid = 0;
    host.rready = 0;
    host.awaddr = 0;
    host.awid = 0;
    host.awlen = 0;
    host.awsize = 0;
    host.awburst = 1;
    host.awcache = 0;
    host.awvalid = 0;
    host.wdata = 0;
    host.wstrb = 0;
    host.wlast = 1;
    host.wvalid = 0;
    host.bready = 0;
    external_bus.arready = 0;
    external_bus.rvalid = 0;
    external_bus.rlast = 0;
    external_bus.rdata = 0;
    external_bus.rid = 0;
    external_bus.rresp = 0;
    external_bus.awready = 0;
    external_bus.wready = 0;
    external_bus.bvalid = 0;
    external_bus.bid = 0;
    external_bus.bresp = 0;
    repeat (5) tick();
    reset = 0;
    tick();
    if (gpio_oe != 0 || tx != 3 || irq != 0) $fatal(1, "Unsafe reset pin state");
    gpio_in = 5;
    repeat (3) tick();
    read_reg('h10000200, 2, 0, value);
    if (value != 5) $fatal(1, "GPIO input synchronization");
    write_reg('h10000204, 2, 7, 0);
    write_reg('h10000208, 2, 7, 0);
    if (gpio_oe != 0) $fatal(1, "Open drain drove a high level");
    write_reg('h10000204, 2, 2, 0);
    if (gpio_oe != 5 || gpio_out != 2) $fatal(1, "Open drain low/release directions");
    write_reg('h1000020c, 2, 0, 0);
    if (gpio_oe != 7) $fatal(1, "GPIO push-pull direction");
    read_reg('h1000020c, 2, 0, value);
    if (value != 0) $fatal(1, "RV64 upper-word register lane");
    write_start('h10000204, 2, 0);
    write_beat('h10000204, 0, '0, 1);
    write_finish(0);
    if (gpio_out != 2) $fatal(1, "Zero-strobe write changed GPIO");
    write_reg('h10000204, 0, 7, 2);
    write_reg('h10000200, 2, 7, 2);
    write_reg('h10000210, 2, 7, 2);
    write_reg('h10000204, 2, 7, 0);
    write_start('h10000204, 2, 1);
    write_beat('h10000204, 0, Bytes'(15) << int'('h10000204 % Bytes), 0);
    write_beat('h10000204, 0, Bytes'(15) << int'('h10000204 % Bytes), 1);
    write_finish(2);
    if (gpio_out != 7) $fatal(1, "Rejected burst changed GPIO");
    read_start('h10000200, 2, 2);
    for (int i = 0; i < 3; i++) begin
      if (host.rlast != (i == 2)) $fatal(1, "Rejected read burst length");
      read_finish('h10000200, 2, value);
      if (value != 0) $fatal(1, "Rejected burst exposed peripheral data");
    end
    read_reg('h10000210, 2, 2, value);
    read_reg('h10000008, 0, 2, value);
    read_reg('h10000001, 2, 2, value);
    read_reg('h10000000, 3, 2, value);
    write_reg('h10000001, 2, 255, 2);
    write_reg('h10000000, 3, 255, 2);
    write_start('h10000000, 0, 0);
    write_beat('h10000000, 255, Bytes'(2), 1);
    write_finish(2);
    write_start('h10000204, 2, 0);
    write_beat('h10000204, 0, Bytes'(15) << int'('h10000204 % Bytes), 0);
    write_finish(2);
    if (gpio_out != 7) $fatal(1, "Malformed WLAST changed GPIO");

    // W may arrive first and must stay unconsumed until the matching AW.
    @(negedge clock);
    host.wdata = XLEN'(3) << (8 * int'('h10000204 % Bytes));
    host.wstrb = Bytes'(1) << int'('h10000204 % Bytes);
    host.wlast = 1;
    host.wvalid = 1;
    repeat (3) begin
      tick();
      if (host.wready) $fatal(1, "W consumed before AW");
    end
    write_start('h10000204, 2, 0);
    tick();
    host.wvalid = 0;
    write_finish(0);
    if (gpio_out != 3) $fatal(1, "Early W/partial-strobe write lost");

    write_reg('h10000001, 0, 1, 0);
    write_reg('h10000101, 0, 1, 0);
    send_byte(0, 'h5a);
    send_byte(0, 'hc3);
    if (irq != 1) $fatal(1, "UART0 RX IRQ isolation");
    read_start('h10000000, 0, 1);
    read_finish('h10000000, 2, value);
    read_finish('h10000000, 2, value);
    read_start('h10000000, 0, 0);
    send_byte(0, 'h7c);
    read_finish('h10000000, 0, value);
    if (value != 'h5a) $fatal(1, "RX data snapshot changed under stall");
    read_reg('h10000000, 0, 0, value);
    if (value != 'hc3) $fatal(1, "RBR read side effect was repeated");
    read_reg('h10000000, 0, 0, value);
    if (value != 'h7c || irq != 0) $fatal(1, "UART0 RX FIFO/IRQ completion");
    send_byte(1, 'h96);
    if (irq != 2) $fatal(1, "UART1 RX IRQ isolation");
    read_reg('h10000100, 0, 0, value);
    if (value != 'h96 || irq != 0) $fatal(1, "UART1 RX data");
    // UART1 changes to 32 clocks/bit; UART0 remains at 16.
    write_reg('h10000103, 0, 'h83, 0);
    write_reg('h10000100, 0, 2, 0);
    write_reg('h10000101, 0, 0, 0);
    write_reg('h10000103, 0, 3, 0);
    fork
      expect_tx(0, 'ha6, 16);
      expect_tx(1, 'h39, 32);
      begin
        write_reg('h10000000, 0, 'ha6, 0);
        write_reg('h10000100, 0, 'h39, 0);
      end
    join

    // Backpressure at the serial target must not redirect an external read.
    fork
      read_start('h30000100, 2, 2);
      begin
        repeat (5) tick();
        if (host.arready || !external_bus.arvalid) $fatal(1, "External AR stall lost");
        external_bus.arready = 1;
      end
    join
    external_bus.arready = 0;
    host.araddr = XLEN'('h10000000);
    external_bus.rid = 4'ha;
    external_bus.rvalid = 1;
    for (int i = 0; i < 3; i++) begin
      external_bus.rdata = XLEN'('h12345678 + i);
      external_bus.rlast = i == 2;
      if (i < 2) begin
        host.awvalid = 1;
        host.awaddr = XLEN'('h10000204);
        #1;
        if (host.awready || external_bus.awvalid) $fatal(1, "Read route released before RLAST");
        host.awvalid = 0;
      end
      read_finish('h30000100, 0, value);
      if (value != 32'('h12345678 + i)) $fatal(1, "External R ownership changed");
    end
    external_bus.rvalid = 0;
    external_bus.awready = 1;
    write_start('h0f000000, 2, 0);
    external_bus.awready = 0;
    external_bus.wready = 1;
    write_beat('h0f000000, 'h5678, Bytes'(15), 1);
    external_bus.wready = 0;
    external_bus.bid = 5;
    external_bus.bresp = 2;
    external_bus.bvalid = 1;
    write_finish(2);
    external_bus.bvalid = 0;

    // A late local AW must not withdraw an already offered external AR.
    read_reg('h10000204, 2, 0, value);
    @(negedge clock);
    host.araddr = XLEN'('h30000100);
    host.arid = 4'ha;
    host.arlen = 0;
    host.arsize = 2;
    host.arvalid = 1;
    tick();
    @(negedge clock);
    host.awaddr = XLEN'('h10000204);
    host.awid = 5;
    host.awlen = 0;
    host.awsize = 2;
    host.awvalid = 1;
    repeat (4) begin
      tick();
      if (!external_bus.arvalid || host.awready || external_bus.awvalid
          || external_bus.araddr != XLEN'('h30000100) || external_bus.arid != 4'ha)
        $fatal(1, "Late local AW displaced stalled external AR");
    end
    @(negedge clock);
    external_bus.arready = 1;
    tick();
    host.arvalid = 0;
    external_bus.arready = 0;
    external_bus.rid = 4'ha;
    external_bus.rdata = XLEN'('h31415926);
    external_bus.rlast = 1;
    external_bus.rvalid = 1;
    read_finish('h30000100, 0, value);
    if (value != 'h31415926) $fatal(1, "Stalled read data lost");
    external_bus.rvalid = 0;
    write_start('h10000204, 2, 0);
    write_beat('h10000204, 3, Bytes'(15) << int'('h10000204 % Bytes), 1);
    write_finish(0);

    // Symmetrically, a late local AR cannot consume a stalled external AW.
    @(negedge clock);
    host.awaddr = XLEN'('h0f000000);
    host.awid = 5;
    host.awlen = 0;
    host.awsize = 2;
    host.awvalid = 1;
    tick();
    @(negedge clock);
    host.araddr = XLEN'('h10000204);
    host.arid = 4'ha;
    host.arlen = 0;
    host.arsize = 2;
    host.arvalid = 1;
    repeat (4) begin
      tick();
      if (!external_bus.awvalid || host.arready || external_bus.arvalid
          || external_bus.awaddr != XLEN'('h0f000000) || external_bus.awid != 5)
        $fatal(1, "Late local AR displaced stalled external AW");
    end
    @(negedge clock);
    external_bus.awready = 1;
    tick();
    host.awvalid = 0;
    external_bus.awready = 0;
    external_bus.wready = 1;
    write_beat('h0f000000, 'h5678, Bytes'(15), 1);
    external_bus.wready = 0;
    external_bus.bid = 5;
    external_bus.bresp = 0;
    external_bus.bvalid = 1;
    write_finish(0);
    external_bus.bvalid = 0;
    read_start('h10000204, 2, 0);
    read_finish('h10000204, 0, value);
    if (value != 3) $fatal(1, "Queued local read data lost");

    // A reset after AW cancels the pending GPIO mutation and all pin enables.
    write_start('h10000204, 2, 0);
    reset = 1;
    #1;
    if (gpio_oe != 0 || tx != 3 || host.wready || host.bvalid || host.rvalid)
      $fatal(1, "Reset did not revoke peripheral ownership");
    repeat (4) tick();
    reset = 0;
    read_reg('h10000204, 2, 0, value);
    if (value != 0 || gpio_oe != 0) $fatal(1, "Canceled write replayed after reset");
    if (external_bus.arvalid || external_bus.awvalid || external_bus.wvalid)
      $fatal(1, "Local transactions reached the serial backend");
    $display("PASS: chip IO25 bus RV%0d, %0d checks", XLEN, checks);
    $finish;
  end

  initial begin
    repeat (20_000) tick();
    $fatal(1, "IO25 bus watchdog");
  end
endmodule
