// Isolate the production UART/parser for RTL and synthesis-path regressions.
module rapt_arty_loader (
    input logic clock,
    input logic reset,
    input logic uart_rx_i,
    output logic uart_tx_o,
    output logic run_o,
    output logic load_write_o,
    output logic [31:0] load_addr_o,
    output logic [7:0] load_data_o,
    output logic clear_o,
    input logic clear_busy_i,
    input logic [31:0] load_rdata_i
);
  logic [7:0] rx_data, tx_data;
  logic rx_valid, rx_error, tx_valid, tx_ready;
  rapt_arty_uart u_uart (
      .clock(clock),
      .reset(reset),
      .rx_i(uart_rx_i),
      .tx_o(uart_tx_o),
      .tx_data_i(tx_data),
      .tx_valid_i(tx_valid),
      .tx_ready_o(tx_ready),
      .rx_data_o(rx_data),
      .rx_valid_o(rx_valid),
      .rx_error_o(rx_error)
  );
  rapt_arty_host #(
      .InternalJoin(1'b1)
  ) u_host (
      .clock(clock),
      .reset(reset),
      .boot_flash_o(),
      .link_delay_o(),
      .rx_data_i(rx_data),
      .rx_valid_i(rx_valid),
      .rx_error_i(rx_error),
      .tx_data_o(tx_data),
      .tx_valid_o(tx_valid),
      .tx_ready_i(tx_ready),
      .run_o(run_o),
      .load_write_o(load_write_o),
      .load_addr_o(load_addr_o),
      .load_data_o(load_data_o),
      .clear_o(clear_o),
      .clear_busy_i(clear_busy_i),
      .load_rdata_i(load_rdata_i),
      .console_valid_i(1'b0),
      .console_data_i('0),
      .console_ready_o(),
      .finish_i(1'b0),
      .finish_code_i('0),
      .link_count_i('0),
      .host_req_o(),
      .host_write_o(),
      .host_addr_o(),
      .host_wdata_o(),
      .host_ready_i(1'b1),
      .host_done_i(1'b1),
      .host_rdata_i(32'h7654_3210),
      .host_error_i(1'b0)
  );
endmodule
