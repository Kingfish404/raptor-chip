// Fixed 8N1 byte transport for the board command/console framing protocol.
module rapt_arty_uart #(
    parameter int ClockHz = 100_000_000,
    parameter int Baud = 115200
) (
    input logic clock,
    input logic reset,
    input logic rx_i,
    output logic tx_o,
    input logic [7:0] tx_data_i,
    input logic tx_valid_i,
    output logic tx_ready_o,
    output logic [7:0] rx_data_o,
    output logic rx_valid_o,
    output logic rx_error_o
);
  localparam int Ticks = (ClockHz + Baud / 2) / Baud;
  localparam int TickBits = $clog2(Ticks + 1);
  (* ASYNC_REG = "TRUE" *) logic [1:0] rx_sync_q = '1;
  logic [TickBits-1:0] tx_tick_q, rx_tick_q;
  logic [9:0] tx_shift_q;
  logic [7:0] rx_shift_q;
  logic [3:0] tx_bits_q, rx_bits_q;
  logic rx_active_q;

  assign tx_ready_o = tx_bits_q == 0;
  assign tx_o = tx_ready_o ? 1'b1 : tx_shift_q[0];

  always_ff @(posedge clock) begin
    rx_sync_q  <= {rx_sync_q[0], rx_i};
    rx_valid_o <= 1'b0;
    rx_error_o <= 1'b0;
    if (reset) begin
      tx_tick_q   <= '0;
      tx_shift_q  <= '1;
      tx_bits_q   <= '0;
      rx_tick_q   <= '0;
      rx_bits_q   <= '0;
      rx_shift_q  <= '0;
      rx_active_q <= 1'b0;
      rx_data_o   <= '0;
    end else begin
      if (tx_ready_o) begin
        if (tx_valid_i) begin
          tx_shift_q <= {1'b1, tx_data_i, 1'b0};
          tx_bits_q  <= 4'd10;
          tx_tick_q  <= TickBits'(Ticks - 1);
        end
      end else if (tx_tick_q != 0) tx_tick_q <= tx_tick_q - 1'b1;
      else begin
        tx_shift_q <= {1'b1, tx_shift_q[9:1]};
        tx_bits_q  <= tx_bits_q - 1'b1;
        tx_tick_q  <= TickBits'(Ticks - 1);
      end

      if (!rx_active_q) begin
        if (!rx_sync_q[1]) begin
          rx_active_q <= 1'b1;
          rx_bits_q   <= '0;
          rx_tick_q   <= TickBits'(Ticks / 2);
        end
      end else if (rx_tick_q != 0) rx_tick_q <= rx_tick_q - 1'b1;
      else begin
        rx_tick_q <= TickBits'(Ticks - 1);
        rx_bits_q <= rx_bits_q + 1'b1;
        if (rx_bits_q == 0 && rx_sync_q[1]) rx_active_q <= 1'b0;
        else if (rx_bits_q >= 1 && rx_bits_q <= 8) rx_shift_q[rx_bits_q-1] <= rx_sync_q[1];
        else if (rx_bits_q == 9) begin
          rx_active_q <= 1'b0;
          rx_data_o   <= rx_shift_q;
          rx_valid_o  <= rx_sync_q[1];
          rx_error_o  <= !rx_sync_q[1];
        end
      end
    end
  end
endmodule
