// 16 bytes: magic, op, sequence, status, address LE32, data LE32, aux LE16,
// CRC16-CCITT LE16 (initial FFFF, polynomial 1021) over the first 14 bytes.
// Requests A5; replies 5A. One outstanding operation, no unsolicited bytes.
module rapt_bringup_protocol #(
    parameter int BitTicks = 100
) (
    input logic clock,
    input logic reset,
    input logic rx_i,
    output logic tx_o,
    output logic request_o,
    output logic [7:0] op_o,
    output logic [31:0] addr_o,
    output logic [31:0] data_o,
    output logic [15:0] aux_o,
    input logic done_i,
    input logic [7:0] status_i,
    input logic [31:0] result_i
);
  logic rx_valid, tx_ready, tx_valid;
  logic [7:0] rx_data, tx_data;
  logic [127:0] packet_q, reply_q;
  logic [4:0] rx_index, tx_index;
  logic [15:0] crc_q;
  logic [23:0] idle_ticks;
  typedef enum logic [2:0] {
    RECEIVE,
    CHECK,
    EXECUTE,
    BUILD,
    SEND,
    GAP
  } state_t;
  state_t state_q;
  function automatic logic [15:0] crc_byte(input logic [15:0] c, input logic [7:0] b);
    logic [15:0] v;
    v = c ^ {b, 8'b0};
    for (int i = 0; i < 8; i++) v = v[15] ? (v << 1) ^ 16'h1021 : v << 1;
    return v;
  endfunction
  function automatic logic [15:0] reply_crc(input logic [111:0] p);
    logic [15:0] v;
    v = 16'hffff;
    for (int i = 0; i < 14; i++) v = crc_byte(v, p[8*i+:8]);
    return v;
  endfunction
  rapt_bringup_uart #(
      .BitTicks(BitTicks)
  ) u_uart (
      .clock(clock),
      .reset(reset),
      .rx_i(rx_i),
      .tx_o(tx_o),
      .rx_valid_o(rx_valid),
      .rx_data_o(rx_data),
      .tx_ready_o(tx_ready),
      .tx_valid_i(tx_valid),
      .tx_data_i(tx_data)
  );
  assign op_o = packet_q[15:8];
  assign addr_o = packet_q[63:32];
  assign data_o = packet_q[95:64];
  assign aux_o = packet_q[111:96];
  assign tx_valid = state_q == SEND;
  assign tx_data = reply_q[8*int'(tx_index)+:8];
  always_ff @(posedge clock) begin
    request_o <= 0;
    if (reset) begin
      state_q <= RECEIVE;
      packet_q <= 0;
      reply_q <= 0;
      rx_index <= 0;
      tx_index <= 0;
      idle_ticks <= 0;
      crc_q <= 16'hffff;
    end else begin
      idle_ticks <= idle_ticks + 1'b1;
      case (state_q)
        RECEIVE: begin
          if (idle_ticks == 24'(BitTicks * 200)) begin
            rx_index <= 0;
            crc_q <= 16'hffff;
          end
          if (rx_valid) begin
            idle_ticks <= 0;
            if (rx_index != 0 || rx_data == 8'ha5) begin
              packet_q[8*int'(rx_index)+:8] <= rx_data;
              if (rx_index < 14) crc_q <= crc_byte(crc_q, rx_data);
              if (rx_index == 15) state_q <= CHECK;
              else rx_index <= rx_index + 1'b1;
            end
          end
        end
        CHECK: begin
          reply_q <= {16'b0, packet_q[111:32], 8'b0, packet_q[23:8], 8'h5a};
          if (packet_q[127:112] != crc_q || packet_q[31:24] != 0) begin
            reply_q[31:24] <= 1;
            state_q <= BUILD;
          end else begin
            request_o <= 1;
            state_q   <= EXECUTE;
          end
        end
        EXECUTE:
        if (done_i) begin
          reply_q[31:24] <= status_i;
          reply_q[95:64] <= result_i;
          state_q <= BUILD;
        end
        BUILD: begin
          reply_q[127:112] <= reply_crc(reply_q[111:0]);
          tx_index <= 0;
          state_q <= SEND;
        end
        SEND: if (tx_ready) state_q <= GAP;
        GAP:
        if (tx_ready) begin
          if (tx_index == 15) begin
            rx_index <= 0;
            crc_q <= 16'hffff;
            idle_ticks <= 0;
            state_q <= RECEIVE;
          end else begin
            tx_index <= tx_index + 1'b1;
            state_q  <= SEND;
          end
        end
        default: state_q <= RECEIVE;
      endcase
    end
  end
endmodule
