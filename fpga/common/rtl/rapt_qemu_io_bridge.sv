// FPGA-to-QEMU Remote I/O + IRQ + AXI4-DMA Bridge (RQIO v1 protocol).
// Serializes CPU MMIO reads/writes into RQIO packets over either L2 Ethernet
// (EtherType 0x88B5 primary) or RFC-1055 SLIP + CRC16-CCITT (UART/JTAG fallback),
// while concurrently servicing host QEMU DMA_READ / DMA_WRITE bursts to RAM/DDR
// and asynchronous 32-line PLIC interrupt updates without deadlocking MMIO!
module rapt_qemu_io_bridge #(
    parameter int XLEN = `RAPT_XLEN,
    parameter logic [47:0] LocalMac = 48'h0105_5041_5202,  // 02:52:41:50:05:01 LE
    parameter logic [47:0] DefaultHostMac = 48'hffff_ffff_ffff,
    parameter logic [15:0] RqioEtherType = 16'h88b5
) (
    input logic clk,
    input logic reset,
    input logic use_slip_i,
    // CPU MMIO slave port (variable latency; stalls CPU while DMA stays live)
    input logic mmio_valid_i,
    input logic mmio_write_i,
    input logic [31:0] mmio_addr_i,
    input logic [1:0] mmio_size_i,
    input logic [63:0] mmio_wdata_i,
    input logic [7:0] mmio_wstrb_i,
    output logic mmio_ready_o,
    output logic [63:0] mmio_rdata_o,
    output logic mmio_err_o,
    // Asynchronous 32-bit PLIC IRQ vector from host QEMU devices
    output logic [31:0] irq_mask_o,
    // AXI4 DMA master toward system RAM / DDR
    axi4_if.master dma,
    // L2 Ethernet payload RX (14B header already stripped by rapt_eth_rqio_mux)
    // and full L2 frame TX (14B header prepended here)
    input logic [7:0] eth_rx_data_i,
    input logic eth_rx_valid_i,
    input logic eth_rx_last_i,
    output logic eth_rx_ready_o,
    output logic [7:0] eth_tx_data_o,
    output logic eth_tx_valid_o,
    output logic eth_tx_last_o,
    input logic eth_tx_ready_i,
    // SLIP + CRC16 byte-stream fallback (UART / JTAG tunnel)
    input logic [7:0] slip_rx_data_i,
    input logic slip_rx_valid_i,
    output logic slip_rx_ready_o,
    output logic [7:0] slip_tx_data_o,
    output logic slip_tx_valid_o,
    input logic slip_tx_ready_i
);
  localparam int         Bytes           = XLEN / 8;
  localparam int         ByteBits        = $clog2(Bytes);
  localparam int         MaxDmaChunk     = 256;

  // RQIO v1 message types (little-endian wire fields, Magic = 0x5152 -> "RQ")
  localparam logic [7:0] Magic0          = 8'h52;          // 'R'
  localparam logic [7:0] Magic1          = 8'h51;          // 'Q'
  localparam logic [7:0] ProtoVer        = 8'h01;
  localparam logic [7:0] MsgMmioReq      = 8'h01;
  localparam logic [7:0] MsgMmioResp     = 8'h02;
  localparam logic [7:0] MsgDmaReadReq   = 8'h03;
  localparam logic [7:0] MsgDmaReadResp  = 8'h04;
  localparam logic [7:0] MsgDmaWriteReq  = 8'h06;
  localparam logic [7:0] MsgDmaWriteResp = 8'h05;
  localparam logic [7:0] MsgIrqUpdate    = 8'h07;

  // SLIP special bytes
  localparam logic [7:0] SlipEnd         = 8'hc0;
  localparam logic [7:0] SlipEsc         = 8'hdb;
  localparam logic [7:0] SlipEscEnd      = 8'hdc;
  localparam logic [7:0] SlipEscEsc      = 8'hdd;

  function automatic logic [15:0] crc16_step(input logic [15:0] crc, input logic [7:0] b);
    logic [15:0] c;
    c = crc ^ {b, 8'h00};
    for (int i = 0; i < 8; i++) begin
      if (c[15]) c = (c << 1) ^ 16'h1021;
      else c = c << 1;
    end
    return c;
  endfunction

  function automatic logic [7:0] l2_hdr_byte(input logic [3:0] idx, input logic [47:0] dst_mac);
    case (idx)
      4'd0:  return dst_mac[7:0];
      4'd1:  return dst_mac[15:8];
      4'd2:  return dst_mac[23:16];
      4'd3:  return dst_mac[31:24];
      4'd4:  return dst_mac[39:32];
      4'd5:  return dst_mac[47:40];
      4'd6:  return LocalMac[7:0];
      4'd7:  return LocalMac[15:8];
      4'd8:  return LocalMac[23:16];
      4'd9:  return LocalMac[31:24];
      4'd10: return LocalMac[39:32];
      4'd11: return LocalMac[47:40];
      4'd12: return RqioEtherType[15:8];
      default: return RqioEtherType[7:0];
    endcase
  endfunction

  // Packet buffers (one inbound RX message, one outbound TX message)
  logic [7:0] rx_buf [0:319];
  logic [7:0] tx_buf [0:319];

  // RX collector (handles either Ethernet payload stream or SLIP+CRC16 stream)
  logic rx_msg_valid_q, rx_msg_ack;
  logic [8:0] rx_len_q, rx_msg_len_q;
  logic slip_esc_q;
  logic [15:0] slip_rx_crc_q;

  assign eth_rx_ready_o  = !reset && !use_slip_i && !rx_msg_valid_q;
  assign slip_rx_ready_o = !reset && use_slip_i && !rx_msg_valid_q;

  always_ff @(posedge clk) begin
    if (reset) begin
      rx_msg_valid_q <= 1'b0;
      rx_len_q <= '0;
      rx_msg_len_q <= '0;
      slip_esc_q <= 1'b0;
      slip_rx_crc_q <= 16'hffff;
    end else begin
      if (rx_msg_valid_q && rx_msg_ack) begin
        rx_msg_valid_q <= 1'b0;
      end else if (!rx_msg_valid_q) begin
        if (!use_slip_i) begin
          if (eth_rx_valid_i && eth_rx_ready_o) begin
            if (rx_len_q < 9'd319) begin
              rx_buf[rx_len_q] <= eth_rx_data_i;
              rx_len_q <= rx_len_q + 9'd1;
            end
            if (eth_rx_last_i) begin
              if ((rx_len_q + 9'd1) >= 9'd8) begin
                rx_msg_len_q <= rx_len_q + 9'd1;
                rx_msg_valid_q <= 1'b1;
              end
              rx_len_q <= '0;
            end
          end
        end else if (slip_rx_valid_i && slip_rx_ready_o) begin
          if (slip_rx_data_i == SlipEnd) begin
            // CRC-16/CCITT-FALSE over payload plus its big-endian CRC leaves a zero residue.
            if (rx_len_q >= 9'd10 && slip_rx_crc_q == 16'h0000) begin
              rx_msg_len_q <= rx_len_q - 9'd2;
              rx_msg_valid_q <= 1'b1;
            end
            rx_len_q <= '0;
            slip_esc_q <= 1'b0;
            slip_rx_crc_q <= 16'hffff;
          end else if (slip_rx_data_i == SlipEsc) begin
            slip_esc_q <= 1'b1;
          end else begin
            automatic logic [7:0] dec_b = slip_rx_data_i;
            if (slip_esc_q) begin
              if (slip_rx_data_i == SlipEscEnd) dec_b = SlipEnd;
              else if (slip_rx_data_i == SlipEscEsc) dec_b = SlipEsc;
              slip_esc_q <= 1'b0;
            end
            if (rx_len_q < 9'd319) begin
              rx_buf[rx_len_q] <= dec_b;
              rx_len_q <= rx_len_q + 9'd1;
              slip_rx_crc_q <= crc16_step(slip_rx_crc_q, dec_b);
            end
          end
        end
      end
    end
  end

  // TX sender (transmits tx_buf[0..tx_msg_len_q-1] over Ethernet or SLIP+CRC16)
  typedef enum logic [2:0] {
    TxIdle,
    TxEthHdr,
    TxEthPayload,
    TxSlipStartEnd,
    TxSlipBody,
    TxSlipCrc0,
    TxSlipCrc1,
    TxSlipFinalEnd
  } tx_state_t;

  tx_state_t tx_st_q;
  logic tx_start;
  // tx_start is registered: the sender still reads tx_buf in the cycle it is seen.
  wire tx_idle = (tx_st_q == TxIdle) && !tx_start;
  logic [8:0] tx_msg_len, tx_msg_len_q, tx_pos_q;
  logic [3:0] tx_hdr_idx_q;
  logic tx_esc_second_q;
  logic [15:0] tx_crc_q;

  wire [8:0] eth_pad_payload_len = (tx_msg_len_q < 9'd46) ? 9'd46 : tx_msg_len_q;
  wire [7:0] cur_tx_payload_b = (tx_pos_q < tx_msg_len_q) ? tx_buf[tx_pos_q] : 8'h00;

  logic [7:0] slip_raw_b;
  always_comb begin
    if (tx_st_q == TxSlipCrc0) slip_raw_b = tx_crc_q[15:8];
    else if (tx_st_q == TxSlipCrc1) slip_raw_b = tx_crc_q[7:0];
    else slip_raw_b = tx_buf[tx_pos_q];
  end
  wire slip_needs_esc = (slip_raw_b == SlipEnd) || (slip_raw_b == SlipEsc);
  wire [7:0] slip_esc_second_b = (slip_raw_b == SlipEnd) ? SlipEscEnd : SlipEscEsc;

  assign eth_tx_valid_o = !reset && (tx_st_q == TxEthHdr || tx_st_q == TxEthPayload);
  assign eth_tx_data_o  = (tx_st_q == TxEthHdr) ? l2_hdr_byte(tx_hdr_idx_q, DefaultHostMac)
                                                : cur_tx_payload_b;
  assign eth_tx_last_o  = (tx_st_q == TxEthPayload) && (tx_pos_q + 9'd1 >= eth_pad_payload_len);

  assign slip_tx_valid_o = !reset && (tx_st_q == TxSlipStartEnd || tx_st_q == TxSlipBody
                        || tx_st_q == TxSlipCrc0 || tx_st_q == TxSlipCrc1
                        || tx_st_q == TxSlipFinalEnd);
  always_comb begin
    if (tx_st_q == TxSlipStartEnd || tx_st_q == TxSlipFinalEnd) begin
      slip_tx_data_o = SlipEnd;
    end else if (slip_needs_esc) begin
      slip_tx_data_o = tx_esc_second_q ? slip_esc_second_b : SlipEsc;
    end else begin
      slip_tx_data_o = slip_raw_b;
    end
  end

  always_ff @(posedge clk) begin
    if (reset) begin
      tx_st_q <= TxIdle;
      tx_msg_len_q <= '0;
      tx_pos_q <= '0;
      tx_hdr_idx_q <= '0;
      tx_esc_second_q <= 1'b0;
      tx_crc_q <= 16'hffff;
    end else begin
      case (tx_st_q)
        TxIdle: begin
          if (tx_start) begin
            tx_msg_len_q <= tx_msg_len;
            tx_pos_q <= '0;
            tx_hdr_idx_q <= '0;
            tx_esc_second_q <= 1'b0;
            tx_crc_q <= 16'hffff;
            tx_st_q <= use_slip_i ? TxSlipStartEnd : TxEthHdr;
          end
        end
        TxEthHdr: begin
          if (eth_tx_ready_i) begin
            if (tx_hdr_idx_q == 4'd13) tx_st_q <= TxEthPayload;
            else tx_hdr_idx_q <= tx_hdr_idx_q + 4'd1;
          end
        end
        TxEthPayload: begin
          if (eth_tx_ready_i) begin
            if (tx_pos_q + 9'd1 >= eth_pad_payload_len) tx_st_q <= TxIdle;
            else tx_pos_q <= tx_pos_q + 9'd1;
          end
        end
        TxSlipStartEnd: begin
          if (slip_tx_ready_i) tx_st_q <= TxSlipBody;
        end
        TxSlipBody: begin
          if (slip_tx_ready_i) begin
            if (slip_needs_esc && !tx_esc_second_q) begin
              tx_esc_second_q <= 1'b1;
            end else begin
              tx_esc_second_q <= 1'b0;
              tx_crc_q <= crc16_step(tx_crc_q, slip_raw_b);
              if (tx_pos_q + 9'd1 >= tx_msg_len_q) tx_st_q <= TxSlipCrc0;
              else tx_pos_q <= tx_pos_q + 9'd1;
            end
          end
        end
        TxSlipCrc0: begin
          if (slip_tx_ready_i) begin
            if (slip_needs_esc && !tx_esc_second_q) tx_esc_second_q <= 1'b1;
            else begin
              tx_esc_second_q <= 1'b0;
              tx_st_q <= TxSlipCrc1;
            end
          end
        end
        TxSlipCrc1: begin
          if (slip_tx_ready_i) begin
            if (slip_needs_esc && !tx_esc_second_q) tx_esc_second_q <= 1'b1;
            else begin
              tx_esc_second_q <= 1'b0;
              tx_st_q <= TxSlipFinalEnd;
            end
          end
        end
        TxSlipFinalEnd: begin
          if (slip_tx_ready_i) tx_st_q <= TxIdle;
        end
        default: tx_st_q <= TxIdle;
      endcase
    end
  end

  // Main Bridge Control + Concurrent AXI4 DMA Engine
  typedef enum logic [3:0] {
    BrIdle,
    BrPrepMmioTx,
    BrSendMmioTx,
    BrDmaReadAr,
    BrDmaReadR,
    BrPrepDmaReadTx,
    BrDmaWriteAw,
    BrDmaWriteW,
    BrDmaWriteB,
    BrPrepDmaWriteTx
  } br_state_t;

  br_state_t br_st_q;
  logic mmio_inflight_q, mmio_done_q, mmio_err_q;
  logic [15:0] mmio_seq_q, dma_seq_q;
  logic [63:0] mmio_rdata_q;
  logic [31:0] irq_mask_q;

  logic [63:0] dma_cur_addr_q;
  logic [15:0] dma_total_len_q, dma_idx_q;
  logic dma_err_q;
  logic [4:0] build_idx_q;

  assign mmio_ready_o = mmio_done_q;
  assign mmio_rdata_o = mmio_rdata_q;
  assign mmio_err_o   = mmio_err_q;
  assign irq_mask_o   = irq_mask_q;

  wire [ByteBits-1:0] wr_lane = dma_cur_addr_q[ByteBits-1:0];
  wire [7:0] wr_data_byte = rx_buf[9'd16 + dma_idx_q[8:0]];

  assign dma.arvalid = !reset && (br_st_q == BrDmaReadAr);
  assign dma.araddr  = XLEN'(dma_cur_addr_q);
  assign dma.arid    = 4'd2;
  assign dma.arlen   = 8'd0;
  assign dma.arsize  = 3'd0;
  assign dma.arburst = 2'b01;
  assign dma.arcache = 4'b0010;
  assign dma.rready  = !reset && (br_st_q == BrDmaReadR);

  assign dma.awvalid = !reset && (br_st_q == BrDmaWriteAw);
  assign dma.awaddr  = XLEN'(dma_cur_addr_q);
  assign dma.awid    = 4'd2;
  assign dma.awlen   = 8'd0;
  assign dma.awsize  = 3'd0;
  assign dma.awburst = 2'b01;
  assign dma.awcache = 4'b0010;

  assign dma.wvalid  = !reset && (br_st_q == BrDmaWriteW);
  assign dma.wdata   = XLEN'(wr_data_byte) << (int'(wr_lane) * 8);
  assign dma.wstrb   = Bytes'(1) << wr_lane;
  assign dma.wlast   = 1'b1;
  assign dma.bready  = !reset && (br_st_q == BrDmaWriteB);

  // Parsed header fields of rx_buf when rx_msg_valid_q is high
  wire rx_hdr_ok = (rx_buf[0] == Magic0) && (rx_buf[1] == Magic1) && (rx_buf[2] == ProtoVer);
  wire [7:0] rx_type = rx_buf[3];
  wire [15:0] rx_seq = {rx_buf[5], rx_buf[4]};
  wire [15:0] rx_dma_len = {rx_buf[7], rx_buf[6]};
  wire [63:0] rx_dma_addr = {
    rx_buf[15], rx_buf[14], rx_buf[13], rx_buf[12],
    rx_buf[11], rx_buf[10], rx_buf[9],  rx_buf[8]
  };

  always_ff @(posedge clk) begin
    if (reset) begin
      br_st_q <= BrIdle;
      mmio_inflight_q <= 1'b0;
      mmio_done_q <= 1'b0;
      mmio_err_q <= 1'b0;
      mmio_seq_q <= 16'd1;
      dma_seq_q <= '0;
      mmio_rdata_q <= '0;
      irq_mask_q <= '0;
      dma_cur_addr_q <= '0;
      dma_total_len_q <= '0;
      dma_idx_q <= '0;
      dma_err_q <= 1'b0;
      build_idx_q <= '0;
      rx_msg_ack <= 1'b0;
      tx_start <= 1'b0;
      tx_msg_len <= '0;
    end else begin
      rx_msg_ack <= 1'b0;
      tx_start <= 1'b0;
      if (mmio_done_q) mmio_done_q <= 1'b0;

      case (br_st_q)
        BrIdle: begin
          // Always prioritize incoming host packets (DMA_READ_REQ, DMA_WRITE_REQ,
          // IRQ_UPDATE, MMIO_RESP) so host QEMU synchronous DMA inside an MMIO
          // handler can NEVER deadlock against an in-flight CPU MMIO request!
          if (rx_msg_valid_q && !rx_msg_ack) begin
            if (!rx_hdr_ok) begin
              rx_msg_ack <= 1'b1;
            end else if (rx_type == MsgIrqUpdate && rx_msg_len_q >= 9'd12) begin
              irq_mask_q <= {rx_buf[11], rx_buf[10], rx_buf[9], rx_buf[8]};
              rx_msg_ack <= 1'b1;
            end else if (rx_type == MsgMmioResp && rx_msg_len_q >= 9'd20) begin
              irq_mask_q <= {rx_buf[11], rx_buf[10], rx_buf[9], rx_buf[8]};
              if (mmio_inflight_q && rx_seq == mmio_seq_q) begin
                mmio_rdata_q <= {
                  rx_buf[19], rx_buf[18], rx_buf[17], rx_buf[16],
                  rx_buf[15], rx_buf[14], rx_buf[13], rx_buf[12]
                };
                mmio_err_q <= rx_buf[6] != 8'd0;
                mmio_done_q <= 1'b1;
                mmio_inflight_q <= 1'b0;
                mmio_seq_q <= mmio_seq_q + 16'd1;
              end
              rx_msg_ack <= 1'b1;
            end else if (rx_type == MsgDmaReadReq && rx_msg_len_q >= 9'd16 && tx_idle) begin
              automatic
              logic [15:0]
              clen = (rx_dma_len > 16'(MaxDmaChunk)) ? 16'(MaxDmaChunk) : rx_dma_len;
              dma_seq_q <= rx_seq;
              dma_cur_addr_q <= rx_dma_addr;
              dma_total_len_q <= clen;
              dma_idx_q <= '0;
              dma_err_q <= 1'b0;
              rx_msg_ack <= 1'b1;
              if (clen == 16'd0) begin
                build_idx_q <= '0;
                br_st_q <= BrPrepDmaReadTx;
              end else begin
                br_st_q <= BrDmaReadAr;
              end
            end else if (rx_type == MsgDmaWriteReq && rx_msg_len_q >= 9'd16 && tx_idle) begin
              automatic
              logic [15:0]
              clen = (rx_dma_len > 16'(MaxDmaChunk)) ? 16'(MaxDmaChunk) : rx_dma_len;
              dma_seq_q <= rx_seq;
              dma_cur_addr_q <= rx_dma_addr;
              dma_total_len_q <= clen;
              dma_idx_q <= '0;
              dma_err_q <= 1'b0;
              if (clen == 16'd0) begin
                rx_msg_ack <= 1'b1;
                build_idx_q <= '0;
                br_st_q <= BrPrepDmaWriteTx;
              end else begin
                br_st_q <= BrDmaWriteAw;
              end
            end else if (rx_type != MsgDmaReadReq && rx_type != MsgDmaWriteReq) begin
              rx_msg_ack <= 1'b1;
            end
          end else if (mmio_valid_i && !mmio_inflight_q && !mmio_done_q && tx_idle) begin
            mmio_inflight_q <= 1'b1;
            build_idx_q <= '0;
            br_st_q <= BrPrepMmioTx;
          end
        end

        BrPrepMmioTx: begin
          // Assemble 20-byte MSG_MMIO_REQ in tx_buf[0..19] one byte per cycle
          case (build_idx_q)
            5'd0:  tx_buf[0]  <= Magic0;
            5'd1:  tx_buf[1]  <= Magic1;
            5'd2:  tx_buf[2]  <= ProtoVer;
            5'd3:  tx_buf[3]  <= MsgMmioReq;
            5'd4:  tx_buf[4]  <= mmio_seq_q[7:0];
            5'd5:  tx_buf[5]  <= mmio_seq_q[15:8];
            5'd6:  tx_buf[6]  <= {5'b0, mmio_size_i, mmio_write_i};
            5'd7:  tx_buf[7]  <= mmio_wstrb_i;
            5'd8:  tx_buf[8]  <= mmio_addr_i[7:0];
            5'd9:  tx_buf[9]  <= mmio_addr_i[15:8];
            5'd10: tx_buf[10] <= mmio_addr_i[23:16];
            5'd11: tx_buf[11] <= mmio_addr_i[31:24];
            5'd12: tx_buf[12] <= mmio_wdata_i[7:0];
            5'd13: tx_buf[13] <= mmio_wdata_i[15:8];
            5'd14: tx_buf[14] <= mmio_wdata_i[23:16];
            5'd15: tx_buf[15] <= mmio_wdata_i[31:24];
            5'd16: tx_buf[16] <= mmio_wdata_i[39:32];
            5'd17: tx_buf[17] <= mmio_wdata_i[47:40];
            5'd18: tx_buf[18] <= mmio_wdata_i[55:48];
            default: tx_buf[19] <= mmio_wdata_i[63:56];
          endcase
          if (build_idx_q == 5'd19) begin
            tx_msg_len <= 9'd20;
            tx_start <= 1'b1;
            br_st_q <= BrSendMmioTx;
          end else begin
            build_idx_q <= build_idx_q + 5'd1;
          end
        end

        BrSendMmioTx: begin
          br_st_q <= BrIdle;
        end

        BrDmaReadAr: begin
          if (dma.arready) br_st_q <= BrDmaReadR;
        end

        BrDmaReadR: begin
          if (dma.rvalid) begin
            automatic logic [ByteBits-1:0] rlane = dma_cur_addr_q[ByteBits-1:0];
            tx_buf[9'd12+dma_idx_q[8:0]] <= 8'(dma.rdata >> (int'(rlane) * 8));
            if (dma.rresp != 2'b00) dma_err_q <= 1'b1;
            if (dma_idx_q + 16'd1 >= dma_total_len_q) begin
              build_idx_q <= '0;
              br_st_q <= BrPrepDmaReadTx;
            end else begin
              dma_idx_q <= dma_idx_q + 16'd1;
              dma_cur_addr_q <= dma_cur_addr_q + 64'd1;
              br_st_q <= BrDmaReadAr;
            end
          end
        end

        BrPrepDmaReadTx: begin
          case (build_idx_q)
            5'd0:  tx_buf[0]  <= Magic0;
            5'd1:  tx_buf[1]  <= Magic1;
            5'd2:  tx_buf[2]  <= ProtoVer;
            5'd3:  tx_buf[3]  <= MsgDmaReadResp;
            5'd4:  tx_buf[4]  <= dma_seq_q[7:0];
            5'd5:  tx_buf[5]  <= dma_seq_q[15:8];
            5'd6:  tx_buf[6]  <= dma_total_len_q[7:0];
            5'd7:  tx_buf[7]  <= dma_total_len_q[15:8];
            5'd8:  tx_buf[8]  <= {7'b0, dma_err_q};
            5'd9:  tx_buf[9]  <= 8'h00;
            5'd10: tx_buf[10] <= 8'h00;
            default: tx_buf[11] <= 8'h00;
          endcase
          if (build_idx_q == 5'd11) begin
            tx_msg_len <= 9'd12 + dma_total_len_q[8:0];
            tx_start <= 1'b1;
            br_st_q <= BrIdle;
          end else begin
            build_idx_q <= build_idx_q + 5'd1;
          end
        end

        BrDmaWriteAw: begin
          if (dma.awready) br_st_q <= BrDmaWriteW;
        end

        BrDmaWriteW: begin
          if (dma.wready) br_st_q <= BrDmaWriteB;
        end

        BrDmaWriteB: begin
          if (dma.bvalid) begin
            if (dma.bresp != 2'b00) dma_err_q <= 1'b1;
            if (dma_idx_q + 16'd1 >= dma_total_len_q) begin
              rx_msg_ack <= 1'b1;
              build_idx_q <= '0;
              br_st_q <= BrPrepDmaWriteTx;
            end else begin
              dma_idx_q <= dma_idx_q + 16'd1;
              dma_cur_addr_q <= dma_cur_addr_q + 64'd1;
              br_st_q <= BrDmaWriteAw;
            end
          end
        end

        BrPrepDmaWriteTx: begin
          case (build_idx_q)
            5'd0:  tx_buf[0]  <= Magic0;
            5'd1:  tx_buf[1]  <= Magic1;
            5'd2:  tx_buf[2]  <= ProtoVer;
            5'd3:  tx_buf[3]  <= MsgDmaWriteResp;
            5'd4:  tx_buf[4]  <= dma_seq_q[7:0];
            5'd5:  tx_buf[5]  <= dma_seq_q[15:8];
            5'd6:  tx_buf[6]  <= dma_total_len_q[7:0];
            5'd7:  tx_buf[7]  <= dma_total_len_q[15:8];
            5'd8:  tx_buf[8]  <= {7'b0, dma_err_q};
            5'd9:  tx_buf[9]  <= 8'h00;
            5'd10: tx_buf[10] <= 8'h00;
            default: tx_buf[11] <= 8'h00;
          endcase
          if (build_idx_q == 5'd11) begin
            tx_msg_len <= 9'd12;
            tx_start <= 1'b1;
            br_st_q <= BrIdle;
          end else begin
            build_idx_q <= build_idx_q + 5'd1;
          end
        end

        default: br_st_q <= BrIdle;
      endcase
    end
  end
endmodule
