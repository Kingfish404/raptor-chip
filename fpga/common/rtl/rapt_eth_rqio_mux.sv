// L2 Ethernet packet demux/mux separating RQIO host-QEMU tunnel frames
// (EtherType 0x88B5 raw L2 or unprivileged IPv4/UDP + ARP when UdpMode=1)
// from standard guest virtio-net Ethernet frames, plus a synchronous stream
// adapter for rapt_native_eth / rapt_rk_ethernet.
module rapt_eth_rqio_mux #(
    parameter logic [15:0] RqioEtherType = 16'h88b5,
    parameter bit UdpMode = 1'b0,
    parameter logic [47:0] BridgeMac = 48'h0215_5041_5202,  // 02:52:41:50:15:02 LE
    parameter logic [31:0] BridgeIp = 32'hc0a8_325d,        // 192.168.50.93 BE
    parameter logic [15:0] RqioUdpPort = 16'd9885
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
    // Demuxed RQIO payload stream (L2 or L2+IPv4+UDP header stripped on RX,
    // full frame supplied on TX by rapt_qemu_io_bridge)
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
  typedef enum logic [2:0] {
    RxHdr,
    RxReplayHdr,
    RxForwardVnet,
    RxForwardRqio,
    RxUdpHdr,
    RxForwardUdpRqio,
    RxDropFrame
  } rx_state_t;

  rx_state_t rx_state_q;
  logic [7:0] hdr_buf_q[14];
  logic [3:0] hdr_idx_q, replay_idx_q;
  logic hdr_last_q;

  // UDP + ARP snoop state (active only when UdpMode == 1)
  logic [5:0] l3_idx_q;
  logic [15:0] udp_rem_q;
  logic udp_hdr_ok_q;
  logic [31:0] rx_src_ip_q, rx_dst_ip_q;
  logic [15:0] rx_src_port_q, rx_dst_port_q, rx_udp_len_q;
  logic [47:0] peer_mac_q;
  logic [15:0] peer_port_q;

  logic arp_snoop_q;
  logic [5:0] arp_idx_q;
  logic arp_oper_ok_q;
  logic [47:0] arp_sha_q, arp_req_mac_q;
  logic [31:0] arp_spa_q, arp_tpa_q, arp_req_ip_q;
  logic arp_reply_pending_q;
  logic arp_reply_done;

  wire [15:0] incoming_ethertype = {hdr_buf_q[12], mac_rx_data_i};
  wire [47:0] hdr_dst_mac = {
    hdr_buf_q[5], hdr_buf_q[4], hdr_buf_q[3], hdr_buf_q[2], hdr_buf_q[1], hdr_buf_q[0]
  };
  wire [47:0] hdr_src_mac = {
    hdr_buf_q[11], hdr_buf_q[10], hdr_buf_q[9], hdr_buf_q[8], hdr_buf_q[7], hdr_buf_q[6]
  };

  always_comb begin
    mac_rx_ready_o  = 1'b0;
    rqio_rx_data_o  = mac_rx_data_i;
    rqio_rx_valid_o = 1'b0;
    rqio_rx_last_o  = mac_rx_last_i;
    vnet_rx_data_o  = mac_rx_data_i;
    vnet_rx_valid_o = 1'b0;
    vnet_rx_last_o  = 1'b0;

    case (rx_state_q)
      RxHdr, RxUdpHdr, RxDropFrame: begin
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
      RxForwardUdpRqio: begin
        rqio_rx_valid_o = mac_rx_valid_i;
        rqio_rx_data_o  = mac_rx_data_i;
        rqio_rx_last_o  = mac_rx_last_i || (udp_rem_q == 16'd1);
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
      l3_idx_q <= '0;
      udp_rem_q <= '0;
      udp_hdr_ok_q <= 1'b0;
      rx_src_ip_q <= '0;
      rx_dst_ip_q <= '0;
      rx_src_port_q <= '0;
      rx_dst_port_q <= '0;
      rx_udp_len_q <= '0;
      peer_mac_q <= 48'hffff_ffff_ffff;
      peer_port_q <= RqioUdpPort;
      arp_snoop_q <= 1'b0;
      arp_idx_q <= '0;
      arp_oper_ok_q <= 1'b0;
      arp_sha_q <= '0;
      arp_spa_q <= '0;
      arp_tpa_q <= '0;
      arp_req_mac_q <= '0;
      arp_req_ip_q <= '0;
      arp_reply_pending_q <= 1'b0;
      for (int i = 0; i < 14; i++) hdr_buf_q[i] <= '0;
    end else begin
      if (arp_reply_done) arp_reply_pending_q <= 1'b0;

      case (rx_state_q)
        RxHdr: begin
          if (mac_rx_valid_i && mac_rx_ready_o) begin
            hdr_buf_q[hdr_idx_q] <= mac_rx_data_i;
            if (mac_rx_last_i) begin
              hdr_last_q <= 1'b1;
              replay_idx_q <= '0;
              arp_snoop_q <= 1'b0;
              rx_state_q <= RxReplayHdr;
            end else if (hdr_idx_q == 4'd13) begin
              hdr_last_q <= 1'b0;
              replay_idx_q <= '0;
              l3_idx_q <= 6'd14;
              arp_idx_q <= 6'd14;
              arp_oper_ok_q <= 1'b1;
              arp_snoop_q <= UdpMode && (incoming_ethertype == 16'h0806);
              if (incoming_ethertype == RqioEtherType) begin
                rx_state_q <= RxForwardRqio;
              end else if (UdpMode && hdr_dst_mac == BridgeMac
                           && incoming_ethertype == 16'h0800) begin
                udp_hdr_ok_q <= 1'b1;
                rx_state_q <= RxUdpHdr;
              end else if (UdpMode && hdr_dst_mac == BridgeMac
                           && incoming_ethertype != 16'h0806) begin
                rx_state_q <= RxDropFrame;
              end else begin
                rx_state_q <= RxReplayHdr;
              end
            end else begin
              hdr_idx_q <= hdr_idx_q + 1'b1;
            end
          end
        end

        RxUdpHdr: begin
          if (mac_rx_valid_i && mac_rx_ready_o) begin
            case (l3_idx_q)
              6'd14: if (mac_rx_data_i != 8'h45) udp_hdr_ok_q <= 1'b0;
              6'd20: if ((mac_rx_data_i & 8'h3f) != 8'h00) udp_hdr_ok_q <= 1'b0;
              6'd21: if (mac_rx_data_i != 8'h00) udp_hdr_ok_q <= 1'b0;
              6'd23: if (mac_rx_data_i != 8'd17) udp_hdr_ok_q <= 1'b0;
              6'd26: rx_src_ip_q[31:24] <= mac_rx_data_i;
              6'd27: rx_src_ip_q[23:16] <= mac_rx_data_i;
              6'd28: rx_src_ip_q[15:8]  <= mac_rx_data_i;
              6'd29: rx_src_ip_q[7:0]   <= mac_rx_data_i;
              6'd30: rx_dst_ip_q[31:24] <= mac_rx_data_i;
              6'd31: rx_dst_ip_q[23:16] <= mac_rx_data_i;
              6'd32: rx_dst_ip_q[15:8]  <= mac_rx_data_i;
              6'd33: rx_dst_ip_q[7:0]   <= mac_rx_data_i;
              6'd34: rx_src_port_q[15:8] <= mac_rx_data_i;
              6'd35: rx_src_port_q[7:0]  <= mac_rx_data_i;
              6'd36: rx_dst_port_q[15:8] <= mac_rx_data_i;
              6'd37: rx_dst_port_q[7:0]  <= mac_rx_data_i;
              6'd38: rx_udp_len_q[15:8]  <= mac_rx_data_i;
              6'd39: rx_udp_len_q[7:0]   <= mac_rx_data_i;
              default: ;
            endcase
            if (mac_rx_last_i) begin
              hdr_idx_q <= '0;
              rx_state_q <= RxHdr;
            end else if (l3_idx_q == 6'd41) begin
              if (udp_hdr_ok_q && rx_dst_ip_q == BridgeIp
                  && rx_dst_port_q == RqioUdpPort && rx_udp_len_q >= 16'd16) begin
                peer_mac_q <= hdr_src_mac;
                peer_port_q <= rx_src_port_q;
                udp_rem_q <= rx_udp_len_q - 16'd8;
                rx_state_q <= RxForwardUdpRqio;
              end else begin
                rx_state_q <= RxDropFrame;
              end
            end else begin
              l3_idx_q <= l3_idx_q + 6'd1;
            end
          end
        end

        RxForwardUdpRqio: begin
          if (mac_rx_valid_i && mac_rx_ready_o) begin
            if (mac_rx_last_i) begin
              hdr_idx_q <= '0;
              rx_state_q <= RxHdr;
            end else if (udp_rem_q == 16'd1) begin
              rx_state_q <= RxDropFrame;
            end else begin
              udp_rem_q <= udp_rem_q - 16'd1;
            end
          end
        end

        RxDropFrame: begin
          if (mac_rx_valid_i && mac_rx_ready_o && mac_rx_last_i) begin
            hdr_idx_q <= '0;
            rx_state_q <= RxHdr;
          end
        end

        RxReplayHdr: begin
          if (vnet_rx_ready_i) begin
            if (hdr_last_q && replay_idx_q == hdr_idx_q) begin
              hdr_idx_q <= '0;
              hdr_last_q <= 1'b0;
              arp_snoop_q <= 1'b0;
              rx_state_q <= RxHdr;
            end else if (replay_idx_q == 4'd13) begin
              rx_state_q <= RxForwardVnet;
            end else begin
              replay_idx_q <= replay_idx_q + 1'b1;
            end
          end
        end

        RxForwardVnet: begin
          if (mac_rx_valid_i && mac_rx_ready_o) begin
            if (arp_snoop_q) begin
              case (arp_idx_q)
                6'd14: if (mac_rx_data_i != 8'h00) arp_oper_ok_q <= 1'b0;
                6'd15: if (mac_rx_data_i != 8'h01) arp_oper_ok_q <= 1'b0;
                6'd16: if (mac_rx_data_i != 8'h08) arp_oper_ok_q <= 1'b0;
                6'd17: if (mac_rx_data_i != 8'h00) arp_oper_ok_q <= 1'b0;
                6'd18: if (mac_rx_data_i != 8'h06) arp_oper_ok_q <= 1'b0;
                6'd19: if (mac_rx_data_i != 8'h04) arp_oper_ok_q <= 1'b0;
                6'd20: if (mac_rx_data_i != 8'h00) arp_oper_ok_q <= 1'b0;
                6'd21: if (mac_rx_data_i != 8'h01) arp_oper_ok_q <= 1'b0;
                6'd22: arp_sha_q[7:0]   <= mac_rx_data_i;
                6'd23: arp_sha_q[15:8]  <= mac_rx_data_i;
                6'd24: arp_sha_q[23:16] <= mac_rx_data_i;
                6'd25: arp_sha_q[31:24] <= mac_rx_data_i;
                6'd26: arp_sha_q[39:32] <= mac_rx_data_i;
                6'd27: arp_sha_q[47:40] <= mac_rx_data_i;
                6'd28: arp_spa_q[31:24] <= mac_rx_data_i;
                6'd29: arp_spa_q[23:16] <= mac_rx_data_i;
                6'd30: arp_spa_q[15:8]  <= mac_rx_data_i;
                6'd31: arp_spa_q[7:0]   <= mac_rx_data_i;
                6'd38: arp_tpa_q[31:24] <= mac_rx_data_i;
                6'd39: arp_tpa_q[23:16] <= mac_rx_data_i;
                6'd40: arp_tpa_q[15:8]  <= mac_rx_data_i;
                6'd41: begin
                  if (arp_oper_ok_q && {arp_tpa_q[31:8], mac_rx_data_i} == BridgeIp) begin
                    peer_mac_q <= arp_sha_q;
                    arp_req_mac_q <= arp_sha_q;
                    arp_req_ip_q <= arp_spa_q;
                    arp_reply_pending_q <= 1'b1;
                  end
                  arp_snoop_q <= 1'b0;
                end
                default: ;
              endcase
              if (arp_idx_q < 6'd41) arp_idx_q <= arp_idx_q + 6'd1;
            end
            if (mac_rx_last_i) begin
              hdr_idx_q <= '0;
              arp_snoop_q <= 1'b0;
              rx_state_q <= RxHdr;
            end
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

  // Hardware 60-byte ARP Reply byte lookup for BridgeIp / BridgeMac
  function automatic logic [7:0] arp_reply_byte(input logic [5:0] idx, input logic [47:0] dst_mac,
                                                input logic [31:0] dst_ip);
    case (idx)
      6'd0:  return dst_mac[7:0];
      6'd1:  return dst_mac[15:8];
      6'd2:  return dst_mac[23:16];
      6'd3:  return dst_mac[31:24];
      6'd4:  return dst_mac[39:32];
      6'd5:  return dst_mac[47:40];
      6'd6:  return BridgeMac[7:0];
      6'd7:  return BridgeMac[15:8];
      6'd8:  return BridgeMac[23:16];
      6'd9:  return BridgeMac[31:24];
      6'd10: return BridgeMac[39:32];
      6'd11: return BridgeMac[47:40];
      6'd12: return 8'h08;
      6'd13: return 8'h06;
      6'd14: return 8'h00;
      6'd15: return 8'h01;
      6'd16: return 8'h08;
      6'd17: return 8'h00;
      6'd18: return 8'h06;
      6'd19: return 8'h04;
      6'd20: return 8'h00;
      6'd21: return 8'h02;  // ARP Reply
      6'd22: return BridgeMac[7:0];
      6'd23: return BridgeMac[15:8];
      6'd24: return BridgeMac[23:16];
      6'd25: return BridgeMac[31:24];
      6'd26: return BridgeMac[39:32];
      6'd27: return BridgeMac[47:40];
      6'd28: return BridgeIp[31:24];
      6'd29: return BridgeIp[23:16];
      6'd30: return BridgeIp[15:8];
      6'd31: return BridgeIp[7:0];
      6'd32: return dst_mac[7:0];
      6'd33: return dst_mac[15:8];
      6'd34: return dst_mac[23:16];
      6'd35: return dst_mac[31:24];
      6'd36: return dst_mac[39:32];
      6'd37: return dst_mac[47:40];
      6'd38: return dst_ip[31:24];
      6'd39: return dst_ip[23:16];
      6'd40: return dst_ip[15:8];
      6'd41: return dst_ip[7:0];
      default: return 8'h00;
    endcase
  endfunction

  // TX packet arbiter: ARP reply (0=rqio, 1=vnet, 2=arp) per complete frame
  logic tx_busy_q, tx_rr_q;
  logic [1:0] tx_sel_q, tx_pick;
  logic [5:0] tx_pos_q;

  always_comb begin
    if (UdpMode && arp_reply_pending_q) tx_pick = 2'd2;
    else if (rqio_tx_valid_i && vnet_tx_valid_i) tx_pick = {1'b0, tx_rr_q};
    else if (vnet_tx_valid_i) tx_pick = 2'd1;
    else tx_pick = 2'd0;
  end

  wire [1:0] tx_owner = tx_busy_q ? tx_sel_q : tx_pick;
  wire tx_any_valid = rqio_tx_valid_i || vnet_tx_valid_i || (UdpMode && arp_reply_pending_q);
  assign arp_reply_done = (tx_owner == 2'd2) && mac_tx_valid_o && mac_tx_ready_i && mac_tx_last_o;

  // On-the-fly learned peer_mac / BridgeMac / peer_port patch on outbound UDP RQIO TX
  logic [7:0] rqio_patched_tx_b;
  always_comb begin
    rqio_patched_tx_b = rqio_tx_data_i;
    if (UdpMode) begin
      case (tx_pos_q)
        6'd0:  rqio_patched_tx_b = peer_mac_q[7:0];
        6'd1:  rqio_patched_tx_b = peer_mac_q[15:8];
        6'd2:  rqio_patched_tx_b = peer_mac_q[23:16];
        6'd3:  rqio_patched_tx_b = peer_mac_q[31:24];
        6'd4:  rqio_patched_tx_b = peer_mac_q[39:32];
        6'd5:  rqio_patched_tx_b = peer_mac_q[47:40];
        6'd6:  rqio_patched_tx_b = BridgeMac[7:0];
        6'd7:  rqio_patched_tx_b = BridgeMac[15:8];
        6'd8:  rqio_patched_tx_b = BridgeMac[23:16];
        6'd9:  rqio_patched_tx_b = BridgeMac[31:24];
        6'd10: rqio_patched_tx_b = BridgeMac[39:32];
        6'd11: rqio_patched_tx_b = BridgeMac[47:40];
        6'd36: rqio_patched_tx_b = peer_port_q[15:8];
        6'd37: rqio_patched_tx_b = peer_port_q[7:0];
        default: rqio_patched_tx_b = rqio_tx_data_i;
      endcase
    end
  end

  assign mac_tx_valid_o = !reset && (tx_busy_q
      ? ((tx_sel_q == 2'd2) ? 1'b1 : (tx_sel_q == 2'd1) ? vnet_tx_valid_i : rqio_tx_valid_i)
      : tx_any_valid);
  assign mac_tx_data_o = (tx_owner == 2'd2) ? arp_reply_byte(tx_pos_q, arp_req_mac_q, arp_req_ip_q)
                       : (tx_owner == 2'd1) ? vnet_tx_data_i
                       : rqio_patched_tx_b;
  assign mac_tx_last_o = (tx_owner == 2'd2) ? (tx_pos_q == 6'd59)
                       : (tx_owner == 2'd1) ? vnet_tx_last_i
                       : rqio_tx_last_i;
  assign rqio_tx_ready_o = !reset && (tx_owner == 2'd0) && mac_tx_ready_i &&
                           (tx_busy_q || rqio_tx_valid_i);
  assign vnet_tx_ready_o = !reset && (tx_owner == 2'd1) && mac_tx_ready_i &&
                           (tx_busy_q || vnet_tx_valid_i);

  always_ff @(posedge clk) begin
    if (reset) begin
      tx_busy_q <= 1'b0;
      tx_sel_q <= 2'd0;
      tx_rr_q <= 1'b0;
      tx_pos_q <= '0;
    end else if (!tx_busy_q) begin
      if (mac_tx_valid_o && mac_tx_ready_i) begin
        if (tx_pick != 2'd2) tx_rr_q <= ~tx_pick[0];
        if (!mac_tx_last_o) begin
          tx_busy_q <= 1'b1;
          tx_sel_q <= tx_pick;
          tx_pos_q <= 6'd1;
        end else begin
          tx_pos_q <= '0;
        end
      end
    end else if (mac_tx_valid_o && mac_tx_ready_i) begin
      if (mac_tx_last_o) begin
        tx_busy_q <= 1'b0;
        tx_pos_q <= '0;
      end else if (tx_pos_q != 6'd63) begin
        tx_pos_q <= tx_pos_q + 6'd1;
      end
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
