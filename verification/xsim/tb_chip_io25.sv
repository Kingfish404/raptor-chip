`include "rapt_soc_if.svh"
`timescale 1ns / 1ps

// All stimulus and success observations use the real chip pads. Gate runs also
// inspect the pad OEN pins to distinguish an undriven value from a driven one.
module tb_chip_io25;
  localparam int XLEN = `RAPT_XLEN;
  logic clock = 0, reset_n = 0;
  logic jtag_tck = 0, jtag_tms = 1, jtag_tdi = 1;
  logic [1:0] rx = 3;
  wire [1:0] tx;
  wire sclk, cs_n, tdo, diag;
  wire [7:0] dq;
  tri1 gpio0, gpio1, gpio2;
  wire [2:0] gpio = {gpio2, gpio1, gpio0};
  wire [7:0] host_oe;
  wire [2:0] gpio_oe;
  wire secondary_oe;
  logic [7:0] target_dq, target_oe;
  logic target_ds;
  int cycles = 0, phase = 0, diag_edges = 0, bridge_reads = 0;
  int tx_count[2] = '{default: 0};
  bit settled = 0, idcode_ok = 0, trap_seen = 0;
  wire sim_finish;
  wire [31:0] sim_exit_code;
  // The real IO model's weak pulls need 10 us. Let pad bias and asynchronous
  // reset distribute before the first clock edge.
  initial begin
    #20us;
    forever #5ns clock = ~clock;
  end
  for (genvar lane = 0; lane < 8; lane++) begin : g_return
    assign dq[lane] = target_oe[lane] ? target_dq[lane] : 1'bz;
  end
  assign diag = reset_n ? target_ds : 1'bz;

  rapt_chip_pads25 #(
      .FlashPowerupCycles(2000),
      .FlashRecoveryCycles(4000)
  ) chip (
      .pad_clk(clock),
      .pad_reset_n(reset_n),
      .pad_irq(1'b0),
      .pad_xspi_dq(dq),
      .pad_xspi_sclk(sclk),
      .pad_xspi_cs_n(cs_n),
      .pad_jtag_tck(jtag_tck),
      .pad_jtag_tms(jtag_tms),
      .pad_jtag_tdi(jtag_tdi),
      .pad_jtag_tdo(tdo),
      .pad_diag(diag),
      .pad_uart0_tx(tx[0]),
      .pad_uart0_rx(rx[0]),
      .pad_uart1_tx(tx[1]),
      .pad_uart1_rx(rx[1]),
      .pad_gpio0(gpio0),
      .pad_gpio1(gpio1),
      .pad_gpio2(gpio2)
  );
  assign host_oe = chip.dq_oe;
  assign gpio_oe = chip.gpio_oe;
  assign secondary_oe = 0;

  rapt_xspi_profile1_model flash (
      .reset_n_i(reset_n),
      .sclk_i(sclk),
      .cs_n_i(cs_n),
      .dq_i(dq),
      .host_oe_i(host_oe),
      .missing_ds_i(1'b0),
      .drop_after_i(4'b0),
      .pause_i(1'b0),
      .deny_wren_i(1'b0),
      .fail_mutation_i(1'b0),
      .flags_i(8'b0),
      .dq_o(target_dq),
      .dq_oe_o(target_oe),
      .ds_o(target_ds)
  );

  initial begin
    string image;
    int fd, value, count;
    if (!$value$plusargs("FLASH_IMAGE=%s", image)) $fatal(1, "missing FLASH_IMAGE");
    fd = $fopen(image, "rb");
    if (fd == 0) $fatal(1, "cannot open image");
    #1;
    count = 0;
    value = $fgetc(fd);
    while (value >= 0) begin
      flash.mem[count] = 8'(value);
      count++;
      value = $fgetc(fd);
    end
    $fclose(fd);
    if (count == 0 || count > 65536) $fatal(1, "invalid image size");
    $display("IMAGE_LOADED bytes=%0d", count);
  end

  initial begin
    if ($test$plusargs("WAVE")) begin
      $dumpfile("io25_accept.vcd");
      $dumpvars(1, tb_chip_io25);
      $dumpvars(0, flash);
    end
  end

  task automatic tick;
    @(posedge clock);
    #1;
  endtask

  task automatic jtag_cycle(input logic tms, input logic tdi, output logic sampled);
    jtag_tms = tms;
    jtag_tdi = tdi;
    #50;
    sampled = tdo;
    jtag_tck = 1;
    #50;
    jtag_tck = 0;
  endtask

  task automatic read_idcode;
    logic sampled;
    logic [31:0] value;
    repeat (6) jtag_cycle(1, 1, sampled);
    jtag_cycle(0, 1, sampled);
    jtag_cycle(1, 1, sampled);
    jtag_cycle(0, 1, sampled);
    jtag_cycle(0, 1, sampled);
    for (int i = 0; i < 32; i++) begin
      jtag_cycle(i == 31, 1, sampled);
      value[i] = sampled;
    end
    jtag_cycle(1, 1, sampled);
    jtag_cycle(0, 1, sampled);
    if (value !== 32'h10001913) $fatal(1, "IDCODE mismatch %h", value);
    idcode_ok = 1;
    $display("IDCODE_OK phase=%0d value=%h time=%0t", phase, value, $time);
  endtask

  task automatic send_byte(input int port, input logic [7:0] value);
    @(negedge clock);
    rx[port] = 0;
    repeat (16) @(negedge clock);
    for (int i = 0; i < 8; i++) begin
      rx[port] = value[i];
      repeat (16) @(negedge clock);
    end
    rx[port] = 1;
    repeat (24) @(negedge clock);
  endtask

  for (genvar port = 0; port < 2; port++) begin : g_uart_check
    initial
      forever begin
        logic [7:0] expected;
        expected = port == 0 ? 8'ha6 : 8'h39;
        @(negedge tx[port]);
        if (settled && reset_n) begin
          repeat (8) @(negedge clock);
          if (tx[port] !== 0) $fatal(1, "UART%0d start", port);
          for (int i = 0; i < 8; i++) begin
            repeat (16) @(negedge clock);
            if (tx[port] !== expected[i]) $fatal(1, "UART%0d bit%0d", port, i);
          end
          repeat (16) @(negedge clock);
          if (tx[port] !== 1) $fatal(1, "UART%0d stop", port);
          tx_count[port]++;
          $display("UART_OK phase=%0d port=%0d byte=%h", phase, port, expected);
        end
      end
  end

  always @(posedge diag) if (reset_n) diag_edges++;
  always @(posedge clock) begin
    cycles++;
    if (reset_n && gpio_oe === 7 && gpio === 5) trap_seen = 1;
    if (cycles > 2_000_000) $fatal(1, "watchdog phase=%0d gpio=%b", phase, gpio);
  end
  always @(negedge clock) begin
    #1;
    if (settled) begin
      if ($isunknown({sclk, cs_n, tx, host_oe, gpio_oe, secondary_oe}))
        $fatal(1, "unknown observable control at %0t", $time);
      if (secondary_oe !== 0) $fatal(1, "secondary GPIO driver");
      if ((target_oe & host_oe) != 0) $fatal(1, "Flash contention");
      if ($isunknown(dq & (target_oe | host_oe))) $fatal(1, "active octal X");
      if (gpio_oe === 7 && gpio === 2) $fatal(1, "firmware signaled failure");
    end
  end

  initial begin
    for (int boot = 1; boot <= 2; boot++) begin
      phase = boot;
      settled = 0;
      idcode_ok = 0;
      // Account for pad/reset-tree flight time when choosing the pin phase.
      #1ns;
      reset_n = 0;
      trap_seen = 0;
      repeat (20) tick();
      if (host_oe !== 0 || gpio_oe !== 0 || secondary_oe !== 0
          || cs_n !== 1 || sclk !== 0 || tx !== 3 || diag !== 0)
        $fatal(
            1,
            "unsafe settled reset host_oe=%h gpio_oe=%b secondary=%b cs=%b sclk=%b tx=%b diag=%b",
            host_oe,
            gpio_oe,
            secondary_oe,
            cs_n,
            sclk,
            tx,
            diag
        );
      settled = 1;
      $display("RESET_OK phase=%0d time=%0t", phase, $time);
      @(negedge clock);
      #1ns;
      reset_n = 1;
      read_idcode();
      while (!(gpio_oe === 7 && gpio === 1)) tick();
      $display("GPIO_READY phase=%0d time=%0t", phase, $time);
      fork
        send_byte(0, 'h5a);
        send_byte(1, 'h96);
      join
      while (!trap_seen) tick();
      if (!idcode_ok || gpio_oe !== 7 || gpio !== 5
          || tx_count[0] != boot || tx_count[1] != boot || flash.array_frames == 0)
        $fatal(1, "incomplete IO/trap result");
      $display("HIT GOOD TRAP phase=%0d gpio=%b uart0=%0d uart1=%0d cycles=%0d", phase, gpio,
               tx_count[0], tx_count[1], cycles);
      repeat (30) tick();
      @(negedge clock);
    end
    if (diag_edges == 0) $fatal(1, "Flash DS did not toggle");
    $display("PASS: IO25 reset IDCODE ROM-XIP good trap, boots=2 cycles=%0d reads=%0d diag=%0d",
             cycles, flash.array_frames, diag_edges);
    $finish;
  end
endmodule
