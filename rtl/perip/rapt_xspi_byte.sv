// rapt_xspi_byte: one octal SDR byte per SCLK cycle.
//
// Data changes while SCLK is low and both ends sample on the rising edge. The
// half period is in core clocks (minimum 2), so a transfer takes
// 2 * half_period_i core clocks per byte with no gap between bytes. done_o
// pulses during the last SCLK-high cycle; data_o holds the byte sampled at the
// preceding rising edge.
module rapt_xspi_byte (
    input logic clock,
    input logic reset,
    input logic active_i,
    input logic valid_i,
    input logic write_i,
    input logic [7:0] data_i,
    input logic [3:0] half_period_i,
    output logic [7:0] data_o,
    output logic done_o,
    output logic sclk_o,
    output logic cs_n_o,
    output logic [7:0] dq_o,
    output logic dq_oe_o,
    input logic [7:0] dq_i
);
  logic [3:0] count_q;
  logic busy_q;

  assign done_o = busy_q && sclk_o && count_q == '0;

  always_ff @(posedge clock) begin
    if (reset) cs_n_o <= 1'b1;
    else cs_n_o <= !active_i;
    if (reset || !active_i) begin
      count_q <= '0;
      busy_q <= 1'b0;
      sclk_o <= 1'b0;
      dq_o <= '0;
      dq_oe_o <= 1'b0;
      data_o <= '0;
    end else if (!busy_q) begin
      // CS_N falls before the first byte is launched.
      if (valid_i && !cs_n_o) begin
        dq_o <= data_i;
        dq_oe_o <= write_i;
        busy_q <= 1'b1;
        count_q <= half_period_i - 4'd2;
      end
    end else if (count_q != '0) begin
      count_q <= count_q - 4'd1;
    end else begin
      count_q <= half_period_i - 4'd1;
      sclk_o <= !sclk_o;
      if (!sclk_o) data_o <= dq_i;
      else busy_q <= 1'b0;
    end
  end
endmodule
