`default_nettype none
//`define DBG

`include "Config.v"

module Top (
    input wire sys_clk,  // 27 MHz
    input wire sys_rst,
    output wire [5:0] led,
    input wire uart_rx,
    output wire uart_tx,
    input wire btn
);

  wire soc_clk;
  wire lock;

`ifdef VERILATOR_SIM
  assign soc_clk = sys_clk;
  assign lock = 1;
`else
    Gowin_rPLL clk_rpll (
        .clkin(sys_clk),  // 27 MHz
        .clkout(soc_clk),  // 27 MHz
        .lock(lock)  //output lock
    );
`endif

  SoC #(
      .CLK_FREQ(27_000_000),
      .RAM_FILE(`RAM_FILE),
      .RAM_ADDR_WIDTH(`RAM_ADDR_WIDTH),
      .BAUD_RATE(`UART_BAUD_RATE)
  ) soc (
      .clk(soc_clk),
      .rst(sys_rst || !lock),
      .led(led),
      .uart_rx(uart_rx),
      .uart_tx(uart_tx),
      .btn(btn)
  );

endmodule

`undef DBG
`default_nettype wire
