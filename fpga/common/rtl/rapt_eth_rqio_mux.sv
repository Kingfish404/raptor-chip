// L2 Ethernet packet demux/mux separating RQIO host-QEMU tunnel frames
// (EtherType 0x88B5 by default) from standard guest virtio-net Ethernet frames,
// plus a synchronous stream adapter for rapt_native_eth / rapt_rk_ethernet.
module rapt_eth_rqio_mux #(
    parameter logic [15:0] RqioEtherType = 16'h88b5
) (
    input logic clk,
    input logic reset,
    // Physical MAC RX byte stream
    input logic [7:0] mac_rx_data_i,
    input logic mac_rx_valid_i,
    input logic mac_rx_last_i,
    output logic mac_rx_ready_o,
    // Physical MAC TX byte stream
    output logic [7:0] mac_tx_data_o,
    output logic mac_tx_valid_o,
    output logic mac_tx_last_o,
    input logic mac_tx_ready_i,
    // Demuxed RQIO payload stream (14-byte Ethernet header stripped on RX,
    // full L2 frame supplied on TX by rapt_qemu_io_bridge)
    output logic [7:0] rqio_rx_data_o,
    output logic rqio_rx_valid_o,
    output logic rqio_rx_last_o,
    input logic rqio_rx_ready_i,
    input logic [7:0] rqio_tx_data_i,
    input logic rqio_tx_valid_i,
    input logic rqio_tx_last_i,
    output logic rqio_tx_ready_o,
    // Demuxed standard Ethernet frame stream for virtio-mmio NIC
    output logic [7:0] vnet_rx_data_o,
    output logic vnet_rx_valid_o,
    output logic vnet_rx_last_o,
    input logic vnet_rx_ready_i,
    input logic [7:0] vnet_tx_data_i,
    input logic vnet_tx_valid_i,
    input logic vnet_tx_last_i,
    output logic vnet_tx_ready_o
);
  typedef enum logic [1:0] {
    RxHdr,
    RxReplayHdr,
    RxForwardVnet,
    RxForwardRqio
  } rx_state_t;

  rx_state_t rx_state_q;
  logic [7:0] hdr_buf_q[14];
  logic [3:0] hdr_idx_q, replay_idx_q;
  logic hdr_last_q;

  wire [15:0] incoming_ethertype = {hdr_buf_q[12], mac_rx_data_i};

  always_comb begin
    mac_rx_ready_o  = 1'b0;
    rqio_rx_data_o  = mac_rx_data_i;
    rqio_rx_valid_o = 1'b0;
    rqio_rx_last_o  = mac_rx_last_i;
    vnet_rx_data_o  = mac_rx_data_i;
    vnet_rx_valid_o = 1'b0;
    vnet_rx_last_o  = 1'b0;

    case (rx_state_q)
      RxHdr: begin
        mac_rx_ready_o = !reset;
      end
      RxReplayHdr: begin
        vnet_rx_valid_o = 1'b1;
        vnet_rx_data_o  = hdr_buf_q[replay_idx_q];
        vnet_rx_last_o  = hdr_last_q && (replay_idx_q == hdr_idx_q);
      end
      RxForwardVnet: begin
        vnet_rx_valid_o = mac_rx_valid_i;
        vnet_rx_data_o  = mac_rx_data_i;
        vnet_rx_last_o  = mac_rx_last_i;
        mac_rx_ready_o  = vnet_rx_ready_i;
      end
      RxForwardRqio: begin
        rqio_rx_valid_o = mac_rx_valid_i;
        rqio_rx_data_o  = mac_rx_data_i;
        rqio_rx_last_o  = mac_rx_last_i;
        mac_rx_ready_o  = rqio_rx_ready_i;
      end
      default: ;
    endcase
  end

  always_ff @(posedge clk) begin
    if (reset) begin
      rx_state_q <= RxHdr;
      hdr_idx_q <= '0;
      replay_idx_q <= '0;
      hdr_last_q <= 1'b0;
      for (int i = 0; i < 14; i++) hdr_buf_q[i] <= '0;
    end else begin
      case (rx_state_q)
        RxHdr: begin
          if (mac_rx_valid_i && mac_rx_ready_o) begin
            hdr_buf_q[hdr_idx_q] <= mac_rx_data_i;
            if (mac_rx_last_i) begin
              // Runt frame shorter than 14-byte L2 header: replay to vnet or drop
              hdr_last_q <= 1'b1;
              replay_idx_q <= '0;
              rx_state_q <= RxReplayHdr;
            end else if (hdr_idx_q == 4'd13) begin
              hdr_last_q <= 1'b0;
              replay_idx_q <= '0;
              if (incoming_ethertype == RqioEtherType) rx_state_q <= RxForwardRqio;
              else rx_state_q <= RxReplayHdr;
            end else begin
              hdr_idx_q <= hdr_idx_q + 1'b1;
            end
          end
        end
        RxReplayHdr: begin
          if (vnet_rx_ready_i) begin
            if (hdr_last_q && replay_idx_q == hdr_idx_q) begin
              hdr_idx_q <= '0;
              hdr_last_q <= 1'b0;
              rx_state_q <= RxHdr;
            end else if (replay_idx_q == 4'd13) begin
              rx_state_q <= RxForwardVnet;
            end else begin
              replay_idx_q <= replay_idx_q + 1'b1;
            end
          end
        end
        RxForwardVnet: begin
          if (mac_rx_valid_i && mac_rx_ready_o && mac_rx_last_i) begin
            hdr_idx_q <= '0;
            rx_state_q <= RxHdr;
          end
        end
        RxForwardRqio: begin
          if (mac_rx_valid_i && mac_rx_ready_o && mac_rx_last_i) begin
            hdr_idx_q <= '0;
            rx_state_q <= RxHdr;
          end
        end
        default: rx_state_q <= RxHdr;
      endcase
    end
  end

  // TX packet arbiter: round-robin per complete Ethernet frame
  logic tx_busy_q, tx_sel_q, tx_rr_q;
  logic tx_pick;

  always_comb begin
    if (rqio_tx_valid_i && vnet_tx_valid_i) tx_pick = tx_rr_q;
    else if (vnet_tx_valid_i) tx_pick = 1'b1;
    else tx_pick = 1'b0;
  end

  wire tx_owner = tx_busy_q ? tx_sel_q : tx_pick;
  wire tx_any_valid = rqio_tx_valid_i || vnet_tx_valid_i;

  assign mac_tx_valid_o = !reset && (tx_busy_q ? (tx_sel_q ? vnet_tx_valid_i : rqio_tx_valid_i)
                                               : tx_any_valid);
  assign mac_tx_data_o  = tx_owner ? vnet_tx_data_i : rqio_tx_data_i;
  assign mac_tx_last_o  = tx_owner ? vnet_tx_last_i : rqio_tx_last_i;
  assign rqio_tx_ready_o = !reset && !tx_owner && mac_tx_ready_i &&
                           (tx_busy_q || rqio_tx_valid_i);
  assign vnet_tx_ready_o = !reset && tx_owner && mac_tx_ready_i &&
                           (tx_busy_q || vnet_tx_valid_i);

  always_ff @(posedge clk) begin
    if (reset) begin
      tx_busy_q <= 1'b0;
      tx_sel_q <= 1'b0;
      tx_rr_q <= 1'b0;
    end else if (!tx_busy_q) begin
      if (mac_tx_valid_o && mac_tx_ready_i) begin
        tx_rr_q <= ~tx_pick;
        if (!mac_tx_last_o) begin
          tx_busy_q <= 1'b1;
          tx_sel_q <= tx_pick;
        end
      end
    end else if (mac_tx_valid_o && mac_tx_ready_i && mac_tx_last_o) begin
      tx_busy_q <= 1'b0;
    end
  end
endmodule

// Adapts rapt_native_eth / rapt_rk_ethernet's synchronous register/BRAM port
// into clk-domain byte streams so board tops keep their proven RGMII/CDC block.
module rapt_native_eth_stream_bridge (
    input logic clk,
    input logic reset,
    // Optional CPU MDIO / status pass-through window (0x1800_0000)
    input logic host_rd_i,
    input logic host_wr_i,
    input logic [15:0] host_raddr_i,
    input logic [15:0] host_waddr_i,
    input logic [31:0] host_wdata_i,
    input logic [3:0] host_wstrb_i,
    output logic [31:0] host_rdata_o,
    // Downstream rapt_native_eth / rapt_rk_ethernet port
    output logic eth_rd_o,
    output logic eth_wr_o,
    output logic [15:0] eth_raddr_o,
    output logic [15:0] eth_waddr_o,
    output logic [31:0] eth_wdata_o,
    output logic [3:0] eth_wstrb_o,
    input logic [31:0] eth_rdata_i,
    // Stream interface toward rapt_eth_rqio_mux
    output logic [7:0] rx_data_o,
    output logic rx_valid_o,
    output logic rx_last_o,
    input logic rx_ready_i,
    input logic [7:0] tx_data_i,
    input logic tx_valid_i,
    input logic tx_last_i,
    output logic tx_ready_o
);
  typedef enum logic [2:0] {
    StInit,
    StPoll,
    StPollWait,
    StRxWordReq,
    StRxWordWait,
    StRxBytes,
    StRxPop
  } rx_fsm_t;

  // The MAC ignores TX buffer writes while a frame is in flight, so a sent
  // frame is followed by a TX status poll before the next frame is collected.
  typedef enum logic [1:0] {
    TxStCollect,
    TxStFlushWord,
    TxStKick,
    TxStWaitIdle
  } tx_fsm_t;

  rx_fsm_t rx_st_q;
  tx_fsm_t tx_st_q;
  logic [2:0] rx_slot_q;
  logic [11:0] rx_len_q, rx_pos_q;
  logic [31:0] rx_word_q, host_rdata_q;
  logic host_rd_pending_q;

  logic [10:0] tx_len_q;
  logic [31:0] tx_pack_q;
  logic tx_word_pending_q;
  logic [10:0] tx_word_idx_q;
  logic tx_poll_q;  // TX status read issued in the previous cycle

  wire host_busy = host_rd_i || host_wr_i;
  // Host reads keep the MAC's one-cycle latency; the copy holds the data while
  // later FSM reads change the shared read port.
  assign host_rdata_o = host_rd_pending_q ? eth_rdata_i : host_rdata_q;

  assign rx_valid_o = rx_st_q == StRxBytes;
  assign rx_data_o  = rx_word_q[(rx_pos_q[1:0]*8)+:8];
  assign rx_last_o  = (rx_st_q == StRxBytes) && (rx_pos_q + 12'd1 >= rx_len_q);

  assign tx_ready_o = !reset && (rx_st_q != StInit) && (tx_st_q == TxStCollect) &&
                      !tx_word_pending_q;

  logic fsm_rd, fsm_wr;
  logic [15:0] fsm_raddr, fsm_waddr;
  logic [31:0] fsm_wdata;
  logic [3:0] fsm_wstrb;

  always_comb begin
    fsm_rd = 1'b0;
    fsm_wr = 1'b0;
    fsm_raddr = 16'h0000;
    fsm_waddr = 16'h0000;
    fsm_wdata = 32'h0000_0000;
    fsm_wstrb = 4'hf;

    if (rx_st_q == StInit) begin
      fsm_wr = 1'b1;
      fsm_waddr = 16'h0008;
      fsm_wdata = 32'h0000_0001;
    end else if (tx_word_pending_q) begin
      fsm_wr = 1'b1;
      fsm_waddr = 16'h2000 + {3'b0, tx_word_idx_q[10:2], 2'b00};
      fsm_wdata = tx_pack_q;
    end else if (tx_st_q == TxStWaitIdle) begin
      fsm_rd = 1'b1;
      fsm_raddr = 16'h000c;
    end else if (tx_st_q == TxStKick) begin
      fsm_wr = 1'b1;
      fsm_waddr = 16'h0020;
      fsm_wdata = {21'b0, tx_len_q < 11'd60 ? 11'd60 : tx_len_q};
    end else if (rx_st_q == StPoll) begin
      fsm_rd = 1'b1;
      fsm_raddr = 16'h0018;
    end else if (rx_st_q == StRxWordReq) begin
      fsm_rd = 1'b1;
      fsm_raddr = 16'h4000 + {2'b0, rx_slot_q, rx_pos_q[10:2], 2'b00};
    end else if (rx_st_q == StRxPop) begin
      fsm_wr = 1'b1;
      fsm_waddr = 16'h001c;
      fsm_wdata = 32'h0000_0001;
    end
  end

  assign eth_rd_o    = host_busy ? host_rd_i    : fsm_rd;
  assign eth_wr_o    = host_busy ? host_wr_i    : fsm_wr;
  assign eth_raddr_o = host_busy ? host_raddr_i : fsm_raddr;
  assign eth_waddr_o = host_busy ? host_waddr_i : fsm_waddr;
  assign eth_wdata_o = host_busy ? host_wdata_i : fsm_wdata;
  assign eth_wstrb_o = host_busy ? host_wstrb_i : fsm_wstrb;

  always_ff @(posedge clk) begin
    if (reset) begin
      rx_st_q <= StInit;
      tx_st_q <= TxStCollect;
      rx_slot_q <= '0;
      rx_len_q <= '0;
      rx_pos_q <= '0;
      rx_word_q <= '0;
      host_rdata_q <= '0;
      host_rd_pending_q <= 1'b0;
      tx_len_q <= '0;
      tx_pack_q <= '0;
      tx_word_pending_q <= 1'b0;
      tx_word_idx_q <= '0;
      tx_poll_q <= 1'b0;
    end else begin
      host_rd_pending_q <= host_rd_i;
      if (host_rd_pending_q) host_rdata_q <= eth_rdata_i;
      tx_poll_q <= !host_busy && tx_st_q == TxStWaitIdle;

      // TX side
      if (tx_word_pending_q) begin
        if (!host_busy) begin
          tx_word_pending_q <= 1'b0;
          if (tx_st_q == TxStFlushWord) begin
            if (tx_len_q < 11'd60) begin
              // Zero-pad short frames to the 60-byte Ethernet minimum.
              tx_pack_q <= '0;
              tx_word_idx_q <= (tx_len_q + 11'd3) & ~11'd3;
              tx_len_q <= (tx_len_q + 11'd4) > 11'd60 ? 11'd60 : ((tx_len_q & ~11'd3) + 11'd4);
              tx_word_pending_q <= 1'b1;
            end else begin
              tx_st_q <= TxStKick;
            end
          end
        end
      end else begin
        case (tx_st_q)
          TxStCollect: begin
            if (tx_valid_i && tx_ready_o) begin
              automatic logic [31:0] next_pack;
              next_pack = tx_len_q[1:0] == 2'd0 ? 32'h0 : tx_pack_q;
              next_pack[(tx_len_q[1:0]*8)+:8] = tx_data_i;
              tx_pack_q <= next_pack;
              tx_word_idx_q <= tx_len_q;
              tx_len_q <= tx_len_q + 11'd1;
              if (tx_len_q[1:0] == 2'd3 || tx_last_i) begin
                tx_word_pending_q <= 1'b1;
                if (tx_last_i) tx_st_q <= TxStFlushWord;
              end
            end
          end
          TxStKick: begin
            if (!host_busy) begin
              tx_len_q <= '0;
              tx_pack_q <= '0;
              tx_st_q <= TxStWaitIdle;
            end
          end
          TxStWaitIdle: begin
            // eth_rdata_i holds the status read issued in the previous cycle.
            if (tx_poll_q && eth_rdata_i[1]) tx_st_q <= TxStCollect;
          end
          default: tx_st_q <= TxStCollect;
        endcase
      end

      // RX side
      case (rx_st_q)
        StInit: begin
          if (!host_busy) rx_st_q <= StPoll;
        end
        StPoll: begin
          if (!host_busy && !tx_word_pending_q && tx_st_q == TxStCollect) rx_st_q <= StPollWait;
        end
        StPollWait: begin
          if (eth_rdata_i[11:0] != 12'd0) begin
            rx_slot_q <= eth_rdata_i[18:16];
            rx_len_q <= eth_rdata_i[11:0];
            rx_pos_q <= '0;
            rx_st_q <= StRxWordReq;
          end else begin
            rx_st_q <= StPoll;
          end
        end
        StRxWordReq: begin
          if (!host_busy && !tx_word_pending_q && tx_st_q == TxStCollect) rx_st_q <= StRxWordWait;
        end
        StRxWordWait: begin
          rx_word_q <= eth_rdata_i;
          rx_st_q <= StRxBytes;
        end
        StRxBytes: begin
          if (rx_ready_i) begin
            if (rx_pos_q + 12'd1 >= rx_len_q) begin
              rx_st_q <= StRxPop;
            end else begin
              rx_pos_q <= rx_pos_q + 12'd1;
              if (rx_pos_q[1:0] == 2'd3) rx_st_q <= StRxWordReq;
            end
          end
        end
        StRxPop: begin
          if (!host_busy && !tx_word_pending_q && tx_st_q == TxStCollect) rx_st_q <= StPoll;
        end
        default: rx_st_q <= StInit;
      endcase
    end
  end
endmodule
