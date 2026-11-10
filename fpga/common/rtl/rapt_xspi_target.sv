// rapt_xspi_target: board-side end of the pin-limited chip's octal link.
// The master is in synth/configs/pin-limited/rtl/rapt_axi_xspi.sv.
//
// clock oversamples SCLK and must be at least 4x faster than it. Read data is
// launched three clocks after SCLK falls, plus pad and board delay, and the chip
// samples one half period later; shorten the chip's half period only as far as
// that budget allows. A read burst is buffered whole before status is reported.
module rapt_xspi_target #(
    parameter int XLEN = `RAPT_XLEN,
    parameter int MaxBeats = 256
) (
    input logic clock,
    input logic reset,
    input logic sclk_i,
    input logic cs_n_i,
    input logic [7:0] dq_i,
    output logic [7:0] dq_o,
    output logic dq_oe_o,
    output logic status_poll_o,
    axi4_if.master axi
);
  localparam int Bytes = XLEN / 8;
  localparam int BeatBits = $clog2(MaxBeats);
  localparam logic [3:0] HeaderLast = 4'(5 + Bytes);
  localparam logic [3:0] DataLast = 4'(Bytes - 1);
  typedef enum logic [2:0] {
    RX_HEADER,
    RX_DATA,
    RX_STRB,
    RX_TURN,
    TX_STATUS,
    TX_DATA,
    FRAME_END
  } state_t;

  state_t state_q;
  logic [2:0] sclk_q;
  logic [1:0] cs_n_q;
  logic [7:0] dq_s0_q, rx_byte;
  logic sclk_rise, sclk_fall, frame;
  logic write_q, axi_done_q;
  logic [3:0] index_q;
  logic [7:0] len_q, beat_q;
  logic [XLEN-1:0] rx_word_q;
  logic [XLEN-1:0] rdata_mem[MaxBeats];
  logic [XLEN-1:0] wdata_mem[MaxBeats];
  logic [Bytes-1:0] wstrb_mem[MaxBeats];
  logic [8:0] w_tail_q, w_head_q, r_count_q;
  logic [1:0] resp_q;
  logic [XLEN-1:0] tx_word;
  logic [7:0] status_byte, last_tx_q;

  assign frame = !cs_n_q[1];
  assign status_poll_o = frame && sclk_rise && state_q == TX_STATUS;
  assign sclk_rise = sclk_q[1] && !sclk_q[2];
  assign sclk_fall = !sclk_q[1] && sclk_q[2];
  assign status_byte = axi_done_q ? {1'b1, 5'b0, resp_q} : '0;
  assign tx_word = rdata_mem[beat_q[BeatBits-1:0]];

  assign axi.rready = 1'b1;
  assign axi.bready = 1'b1;
  assign axi.wdata = wdata_mem[w_head_q[BeatBits-1:0]];
  assign axi.wstrb = wstrb_mem[w_head_q[BeatBits-1:0]];
  assign axi.wvalid = w_head_q != w_tail_q;
  assign axi.wlast = w_head_q[7:0] == len_q;

  always_ff @(posedge clock) begin
    sclk_q <= {sclk_q[1:0], sclk_i};
    cs_n_q <= {cs_n_q[0], cs_n_i};
    dq_s0_q <= dq_i;
    rx_byte <= dq_s0_q;
    if (reset || !frame) begin
      state_q <= RX_HEADER;
      index_q <= '0;
      beat_q <= '0;
      len_q <= '0;
      write_q <= 1'b0;
      axi_done_q <= 1'b0;
      w_tail_q <= '0;
      w_head_q <= '0;
      r_count_q <= '0;
      resp_q <= '0;
      dq_o <= '0;
      dq_oe_o <= 1'b0;
      last_tx_q <= '0;
      axi.arvalid <= 1'b0;
      axi.awvalid <= 1'b0;
      axi.araddr <= '0;
      axi.awaddr <= '0;
      axi.arid <= '0;
      axi.awid <= '0;
      axi.arlen <= '0;
      axi.awlen <= '0;
      axi.arsize <= '0;
      axi.awsize <= '0;
      axi.arburst <= '0;
      axi.awburst <= '0;
      axi.arcache <= '0;
      axi.awcache <= '0;
    end else begin
      if (axi.arvalid && axi.arready) axi.arvalid <= 1'b0;
      if (axi.awvalid && axi.awready) axi.awvalid <= 1'b0;
      if (axi.wvalid && axi.wready) w_head_q <= w_head_q + 9'd1;
      if (axi.rvalid) begin
        rdata_mem[r_count_q[BeatBits-1:0]] <= axi.rdata;
        r_count_q <= r_count_q + 9'd1;
        if (axi.rresp > resp_q) resp_q <= axi.rresp;
        if (axi.rlast) axi_done_q <= 1'b1;
      end
      if (axi.bvalid) begin
        resp_q <= axi.bresp;
        axi_done_q <= 1'b1;
      end

      if (sclk_rise) begin
        case (state_q)
          RX_HEADER: begin
            index_q <= index_q + 4'd1;
            case (index_q)
              4'd0: write_q <= rx_byte == 8'ha2;
              4'd1: ;
              4'd2: begin
                axi.arid <= rx_byte[3:0];
                axi.awid <= rx_byte[3:0];
              end
              4'd3: begin
                len_q <= rx_byte;
                axi.arlen <= rx_byte;
                axi.awlen <= rx_byte;
              end
              4'd4: begin
                axi.arsize <= rx_byte[2:0];
                axi.awsize <= rx_byte[2:0];
                axi.arburst <= rx_byte[4:3];
                axi.awburst <= rx_byte[4:3];
              end
              4'd5: begin
                axi.arcache <= rx_byte[3:0];
                axi.awcache <= rx_byte[3:0];
              end
              default: begin
                axi.araddr[8*(int'(index_q)-6)+:8] <= rx_byte;
                axi.awaddr[8*(int'(index_q)-6)+:8] <= rx_byte;
              end
            endcase
            if (index_q == HeaderLast) begin
              index_q <= '0;
              if (write_q) begin
                axi.awvalid <= 1'b1;
                state_q <= RX_DATA;
              end else begin
                axi.arvalid <= 1'b1;
                state_q <= RX_TURN;
              end
            end
          end
          RX_DATA: begin
            rx_word_q[8*int'(index_q)+:8] <= rx_byte;
            index_q <= index_q + 4'd1;
            if (index_q == DataLast) begin
              index_q <= '0;
              state_q <= RX_STRB;
            end
          end
          RX_STRB: begin
            wdata_mem[w_tail_q[BeatBits-1:0]] <= rx_word_q;
            wstrb_mem[w_tail_q[BeatBits-1:0]] <= rx_byte[Bytes-1:0];
            w_tail_q <= w_tail_q + 9'd1;
            if (w_tail_q[7:0] == len_q) state_q <= RX_TURN;
            else state_q <= RX_DATA;
          end
          RX_TURN: state_q <= TX_STATUS;
          TX_STATUS: if (last_tx_q[7]) begin
            state_q <= write_q ? FRAME_END : TX_DATA;
            index_q <= '0;
            beat_q <= '0;
          end
          default: ;
        endcase
      end

      if (sclk_fall) begin
        if (state_q == TX_STATUS) begin
          dq_o <= status_byte;
          last_tx_q <= status_byte;
          dq_oe_o <= 1'b1;
        end else if (state_q == TX_DATA) begin
          dq_o <= tx_word[8*int'(index_q)+:8];
          if (index_q == DataLast) begin
            index_q <= '0;
            beat_q <= beat_q + 8'd1;
            if (beat_q == len_q) state_q <= FRAME_END;
          end else index_q <= index_q + 4'd1;
        end else if (state_q == FRAME_END) begin
          dq_oe_o <= 1'b0;
        end
      end
    end
  end
endmodule
