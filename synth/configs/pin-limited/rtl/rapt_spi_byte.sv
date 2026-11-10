// Mode-0 SPI, MSB first. IO0 is MOSI, IO1 is MISO, IO2/3 hold WP#/HOLD# high.
// CS setup, last falling edge and CS hold are separated by core clock edges.
module rapt_spi_byte #(
    parameter int unsigned HalfPeriod = 10
) (
    input logic clock,
    input logic reset,
    input logic active_i,
    input logic valid_i,
    input logic [7:0] data_i,
    output logic [7:0] data_o,
    output logic done_o,
    output logic sclk_o,
    output logic cs_n_o,
    output logic [7:0] dq_o,
    output logic [7:0] dq_oe_o,
    input logic [7:0] dq_i
);
  localparam int CountBits = $clog2(HalfPeriod + 1);
  logic [CountBits-1:0] count_q;
  logic [2:0] bit_q;
  logic [7:0] tx_q;
  logic busy_q;
  logic mosi_q, cs_n_q;

  assign cs_n_o = reset || cs_n_q;

  assign dq_o = {4'b0, 2'b11, 1'b0, mosi_q};
  // IO1 must never be driven, including command/address and controller reset.
  assign dq_oe_o = reset ? 8'h00 : 8'h0d;
  assign done_o = busy_q && sclk_o && count_q == 0 && bit_q == 0;

  always_ff @(posedge clock) begin
    if (reset || !active_i) begin
      cs_n_q <= 1'b1;
      sclk_o <= 1'b0;
      count_q <= '0;
      bit_q <= '0;
      tx_q <= '0;
      data_o <= '0;
      mosi_q <= 1'b0;
      busy_q <= 1'b0;
    end else begin
      cs_n_q <= 1'b0;
      if (!busy_q) begin
        if (valid_i && !cs_n_q) begin
          busy_q <= 1'b1;
          tx_q <= data_i;
          mosi_q <= data_i[7];
          bit_q <= 3'd7;
          count_q <= CountBits'(HalfPeriod - 1);
        end
      end else if (count_q != 0) count_q <= count_q - 1'b1;
      else begin
        count_q <= CountBits'(HalfPeriod - 1);
        sclk_o <= !sclk_o;
        if (!sclk_o) data_o <= {data_o[6:0], dq_i[1]};
        else if (bit_q == 0) busy_q <= 1'b0;
        else begin
          bit_q <= bit_q - 1'b1;
          tx_q <= {tx_q[6:0], 1'b0};
          mosi_q <= tx_q[6];
        end
      end
    end
  end

`ifndef SYNTHESIS
  initial if (HalfPeriod < 2) $fatal(1, "SPI HalfPeriod must be at least two");
`endif
endmodule
