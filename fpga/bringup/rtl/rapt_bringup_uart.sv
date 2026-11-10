// Fixed 8N1 byte transport. A packet reply paces the next host request.
module rapt_bringup_uart #(
    parameter int BitTicks = 100
) (
    input logic clock,
    input logic reset,
    input logic rx_i,
    output logic tx_o,
    output logic rx_valid_o,
    output logic [7:0] rx_data_o,
    input logic tx_valid_i,
    input logic [7:0] tx_data_i,
    output logic tx_ready_o
);
  (* ASYNC_REG = "TRUE" *) logic [1:0] rx_sync = '1;
  logic [15:0] rx_ticks, tx_ticks;
  logic [3:0] rx_bits, tx_bits;
  logic [7:0] rx_shift;
  logic [9:0] tx_shift;
  logic rx_active;
  assign tx_ready_o = tx_bits == 0;
  assign tx_o = tx_bits == 0 ? 1'b1 : tx_shift[0];
  always_ff @(posedge clock) begin
    rx_sync <= {rx_sync[0], rx_i};
    rx_valid_o <= 0;
    if (reset) begin
      rx_active <= 0;
      rx_ticks  <= 0;
      tx_ticks  <= 0;
      rx_bits   <= 0;
      tx_bits   <= 0;
      rx_shift  <= 0;
      tx_shift  <= '1;
      rx_data_o <= 0;
    end else begin
      if (!rx_active) begin
        if (!rx_sync[1]) begin
          rx_active <= 1;
          rx_ticks  <= 16'(BitTicks / 2 - 1);
          rx_bits   <= 0;
        end
      end else if (rx_ticks != 0) rx_ticks <= rx_ticks - 1'b1;
      else begin
        rx_ticks <= 16'(BitTicks - 1);
        rx_bits  <= rx_bits + 1'b1;
        if (rx_bits == 0 && rx_sync[1]) rx_active <= 0;
        else if (rx_bits >= 1 && rx_bits <= 8) rx_shift[rx_bits-1] <= rx_sync[1];
        else if (rx_bits == 9) begin
          rx_active  <= 0;
          rx_valid_o <= rx_sync[1];
          rx_data_o  <= rx_shift;
        end
      end
      if (tx_bits != 0) begin
        if (tx_ticks != 0) tx_ticks <= tx_ticks - 1'b1;
        else begin
          tx_ticks <= 16'(BitTicks - 1);
          tx_shift <= {1'b1, tx_shift[9:1]};
          tx_bits  <= tx_bits - 1'b1;
        end
      end else if (tx_valid_i) begin
        tx_shift <= {1'b1, tx_data_i, 1'b0};
        tx_ticks <= 16'(BitTicks - 1);
        tx_bits  <= 10;
      end
    end
  end
endmodule
