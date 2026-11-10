`include "rapt_soc_if.svh"

module rapt_arty_board #(
    parameter int RamBytes = 262144,
    parameter int ClockHz = 100_000_000,
    parameter int Baud = 115200,
    parameter bit InternalJoin = 1'b0,
    parameter int unsigned FlashPowerupCycles = 10_000_001,
    parameter int unsigned FlashResetCycles = 1001,
    parameter int unsigned FlashRecoveryCycles = 10_000_001,
    parameter string RomFile = "mrom.hex"
) (
    input logic clock,
    input logic flash_clock,
    input logic reset,
    output logic [2:0] link_delay_o,
    input logic cpu_reset_i,
    input logic sclk_i,
    input logic cs_n_i,
    input logic [7:0] dq_i,
    output logic [7:0] dq_o,
    output logic dq_oe_o,
    input logic uart_rx_i,
    output logic uart_tx_o,
    output logic run_o,
    output logic link_active_o,
    output logic finished_o,
    output logic flash_ck_o,
    output logic flash_cs_n_o,
    output logic flash_reset_n_o,
    output logic [7:0] flash_dq_o,
    output logic [7:0] flash_dq_oe_o,
    input logic [7:0] flash_dq_i,
    input logic flash_dqs_i
);
  axi4_if #(.XLEN(32)) board ();
  logic [7:0] rx_data, tx_data, load_data, console_data;
  logic rx_valid, rx_error, tx_valid, tx_ready;
  logic load_write, clear, clear_busy, console_valid, console_ready, finish;
  logic [31:0] load_addr, load_rdata, finish_code;
  logic chip_reset;
  logic boot_flash, host_req, host_write, host_ready, host_done, host_error;
  logic [31:0] host_addr, host_wdata, host_rdata;
  (* ASYNC_REG = "TRUE" *)logic [ 2:0] cs_sync_q;
  logic [31:0] link_count_q;
  logic [24:0] activity_q;

  assign chip_reset = !run_o || cpu_reset_i;
  assign link_active_o = activity_q != 0;
  always_ff @(posedge clock) begin
    cs_sync_q <= {cs_sync_q[1:0], cs_n_i};
    if (reset || chip_reset) begin
      link_count_q <= '0;
      activity_q   <= '0;
      finished_o   <= 1'b0;
    end else begin
      if (finish) finished_o <= 1'b1;
      if (cs_sync_q[1] && !cs_sync_q[2]) begin
        link_count_q <= link_count_q + 1'b1;
        activity_q   <= 25'(ClockHz / 4);
      end else if (activity_q != 0) activity_q <= activity_q - 1'b1;
    end
  end

  rapt_xspi_target #(
      .XLEN(32),
      .MaxBeats(16)
  ) u_target (
      .clock(clock),
      .reset(reset || chip_reset),
      .sclk_i(sclk_i),
      .cs_n_i(cs_n_i),
      .dq_i(dq_i),
      .dq_o(dq_o),
      .dq_oe_o(dq_oe_o),
      .status_poll_o(),
      .axi(board)
  );

  rapt_arty_mem #(
      .RamBytes(RamBytes),
      .FlashPowerupCycles(FlashPowerupCycles),
      .FlashResetCycles(FlashResetCycles),
      .FlashRecoveryCycles(FlashRecoveryCycles),
      .RomFile (RomFile)
  ) u_mem (
      .clock(clock),
      .flash_clock(flash_clock),
      .reset(reset),
      .chip_reset_i(chip_reset),
      .boot_flash_i(boot_flash),
      .axi(board),
      .load_write_i(load_write),
      .load_addr_i(load_addr),
      .load_data_i(load_data),
      .clear_i(clear),
      .clear_busy_o(clear_busy),
      .load_rdata_o(load_rdata),
      .console_valid_o(console_valid),
      .console_data_o(console_data),
      .console_ready_i(console_ready),
      .finish_o(finish),
      .finish_code_o(finish_code),
      .host_req_i(host_req),
      .host_write_i(host_write),
      .host_ready_o(host_ready),
      .host_done_o(host_done),
      .host_error_o(host_error),
      .host_addr_i(host_addr),
      .host_wdata_i(host_wdata),
      .host_rdata_o(host_rdata),
      .flash_sclk_o(flash_ck_o),
      .flash_cs_n_o(flash_cs_n_o),
      .flash_reset_n_o(flash_reset_n_o),
      .flash_dq_o(flash_dq_o),
      .flash_dq_oe_o(flash_dq_oe_o),
      .flash_dq_i(flash_dq_i),
      .flash_dqs_i(flash_dqs_i)
  );

  rapt_arty_uart #(
      .ClockHz(ClockHz),
      .Baud(Baud)
  ) u_uart (
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
      .RamBytes(RamBytes),
      .InternalJoin(InternalJoin)
  ) u_host (
      .clock(clock),
      .reset(reset),
      .boot_flash_o(boot_flash),
      .link_delay_o(link_delay_o),
      .rx_data_i(rx_data),
      .rx_valid_i(rx_valid),
      .rx_error_i(rx_error),
      .tx_data_o(tx_data),
      .tx_valid_o(tx_valid),
      .tx_ready_i(tx_ready),
      .run_o(run_o),
      .load_write_o(load_write),
      .load_addr_o(load_addr),
      .load_data_o(load_data),
      .clear_o(clear),
      .clear_busy_i(clear_busy),
      .load_rdata_i(load_rdata),
      .console_valid_i(console_valid),
      .console_data_i(console_data),
      .console_ready_o(console_ready),
      .finish_i(finish),
      .finish_code_i(finish_code),
      .link_count_i(link_count_q),
      .host_req_o(host_req),
      .host_write_o(host_write),
      .host_ready_i(host_ready),
      .host_done_i(host_done),
      .host_error_i(host_error),
      .host_addr_o(host_addr),
      .host_wdata_o(host_wdata),
      .host_rdata_i(host_rdata)
  );
endmodule
