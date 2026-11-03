`timescale 1ns / 1ps

// Short four-state diagnosis of the exact exported or mapped design.
// Only the host run latch is forced, after board reset; all SoC/link logic runs.
module tb_rapt_arty_startup;
  logic clk100 = 0;
  logic [1:0] btn = 1;
  wire [3:0] led;
  wire [7:0] flash_dq, chip_dq, board_dq;
  int frames = 0;
  int byte_index = 0;
  int ticks = 10;
  always #5 clk100 = !clk100;
  rapt_arty_top u_dut (
      .clk100(clk100),
      .btn(btn),
      .boot_switch(1'b0),
      .led(led),
      .uart_rx(1'b1),
      .uart_tx(),
      .chip_sclk(),
      .chip_cs_n(),
      .chip_dq(chip_dq),
      .board_sclk(1'b0),
      .board_cs_n(1'b1),
      .board_dq(board_dq),
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
  assign flash_dq = 8'hff;
  always @(negedge u_dut.\g_internal.u_chip.u_chip.u_offchip.u_byte.cs_n_o ) begin
    frames++;
    byte_index = 0;
    $display("STARTUP_FRAME time=%0t count=%0d", $time, frames);
    $fflush();
  end
  always @(posedge u_dut.\g_internal.u_chip.u_chip.u_offchip.u_byte.sclk_o ) begin
    if ($test$plusargs("LINK_TRACE"))
      $display(
          "STARTUP_BYTE frame=%0d byte=%0d oe=%b tx=%h rx=%h",
          frames,
          byte_index,
          u_dut.\g_internal.u_chip.u_chip.u_offchip.u_byte.dq_oe_o ,
          u_dut.\g_internal.u_chip.u_chip.u_offchip.u_byte.dq_o ,
          u_dut.\u_board.u_target.dq_o
      );
    byte_index++;
  end
  initial begin
    if (!$value$plusargs("TICKS=%d", ticks)) ticks = 10;
    #1000;
    btn = 0;
    wait (led[0] === 1'b1);
    #2000;
    force u_dut.\u_board.u_host.run_o = 1'b1;
    $display("STARTUP_RUN time=%0t", $time);
    $fflush();
    repeat (ticks) begin
      #10000;
      $display("STARTUP_STATE time=%0t led=%b frames=%0d", $time, led, frames);
      $fflush();
    end
    if (ticks < 10) begin
      $display("STARTUP_CAPTURE_DONE frames=%0d", frames);
      $finish;
    end
    // Empty RAM should reach board_boot after the first data load and continue
    // fetching its wait-message path. Eight frames alone only prove ROM fetch.
    if (frames < 10) $fatal(1, "startup stalled before board_boot: frames=%0d", frames);
    $display("RAPT_STARTUP_PASS");
    $finish;
  end
  initial begin
    #200000;
    $fatal(1, "clock/reset startup timeout led=%b", led);
  end
endmodule
