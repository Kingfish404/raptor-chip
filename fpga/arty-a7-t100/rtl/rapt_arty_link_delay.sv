// Optional integer-board-clock propagation delay for the internal pin model.
// Zero bypasses the pipeline; change the setting only while the SoC is reset.
module rapt_arty_link_delay (
    input logic clock,
    input logic reset,
    input logic [2:0] cycles_i,
    input logic chip_sclk_i,
    input logic chip_cs_n_i,
    input logic [7:0] chip_dq_i,
    output logic board_sclk_o,
    output logic board_cs_n_o,
    output logic [7:0] board_dq_o,
    input logic [7:0] board_dq_i,
    input logic board_oe_i,
    output logic [7:0] chip_dq_o,
    output logic chip_oe_o
);
  logic [6:0] sclk_q, cs_n_q, oe_q;
  logic [7:0] forward_q[7], reverse_q[7];
  always_ff @(posedge clock) begin
    if (reset) begin
      sclk_q <= '0;
      cs_n_q <= '1;
      oe_q   <= '0;
      for (int i = 0; i < 7; i++) begin
        forward_q[i] <= '0;
        reverse_q[i] <= '0;
      end
    end else begin
      sclk_q <= {sclk_q[5:0], chip_sclk_i};
      cs_n_q <= {cs_n_q[5:0], chip_cs_n_i};
      oe_q <= {oe_q[5:0], board_oe_i};
      forward_q[0] <= chip_dq_i;
      reverse_q[0] <= board_dq_i;
      for (int i = 1; i < 7; i++) begin
        forward_q[i] <= forward_q[i-1];
        reverse_q[i] <= reverse_q[i-1];
      end
    end
  end
  always_comb begin
    board_sclk_o = chip_sclk_i;
    board_cs_n_o = chip_cs_n_i;
    board_dq_o = chip_dq_i;
    chip_dq_o = board_dq_i;
    chip_oe_o = board_oe_i;
    if (cycles_i != 0) begin
      board_sclk_o = sclk_q[cycles_i-1'b1];
      board_cs_n_o = cs_n_q[cycles_i-1'b1];
      board_dq_o = forward_q[cycles_i-1'b1];
      chip_dq_o = reverse_q[cycles_i-1'b1];
      chip_oe_o = oe_q[cycles_i-1'b1];
    end
  end
endmodule
