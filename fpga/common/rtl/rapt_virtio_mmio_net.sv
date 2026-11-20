// OASIS VirtIO 1.2 Modern (VERSION=2, DEVICE_ID=1) virtio-mmio NIC with
// hardware Split-Virtqueue AXI4-DMA engine. Advertises VIRTIO_F_VERSION_1 (32),
// VIRTIO_F_ACCESS_PLATFORM (33, enabling unmodified Linux non-coherent Zicbom
// DMA sync), VIRTIO_NET_F_MAC (5), and VIRTIO_NET_F_STATUS (16).
module rapt_virtio_mmio_net #(
    parameter int XLEN = `RAPT_XLEN,
    parameter logic [47:0] LocalMac = 48'h0105_5041_5202  // 02:52:41:50:05:01 LE
) (
    input logic clk,
    input logic reset,
    input logic link_up_i,
    // Synchronous MMIO slave port (0x1000_2000..0x1000_2fff, offset [11:0])
    input logic req_valid_i,
    input logic req_write_i,
    input logic [11:0] req_addr_i,
    input logic [1:0] req_size_i,
    input logic [63:0] req_wdata_i,
    input logic [7:0] req_wstrb_i,
    output logic resp_valid_o,
    output logic [63:0] resp_rdata_o,
    output logic resp_err_o,
    output logic irq_o,
    // AXI4 non-coherent DMA master toward system RAM / DDR
    axi4_if.master dma,
    // Ethernet frame RX/TX byte streams (no FCS, raw L2 frame)
    input logic [7:0] rx_axis_tdata_i,
    input logic rx_axis_tvalid_i,
    input logic rx_axis_tlast_i,
    output logic rx_axis_tready_o,
    output logic [7:0] tx_axis_tdata_o,
    output logic tx_axis_tvalid_o,
    output logic tx_axis_tlast_o,
    input logic tx_axis_tready_i
);
  localparam int Bytes = XLEN / 8;
  localparam int ByteBits = $clog2(Bytes);
  localparam int MaxFrame = 1536;
  localparam int VirtioHdrBytes = 12;
  localparam int QueueNumMax = 256;

  // VirtIO feature bits
  localparam logic [31:0] FeatWord0 = (32'd1 << 5) | (32'd1 << 16);
  localparam logic [31:0] FeatWord1 = (32'd1 << 0) | (32'd1 << 1);

  // VirtIO status & descriptor flags
  localparam logic [7:0] StatusDriverOk = 8'h04;
  localparam logic [15:0] DescFlagNext = 16'h0001;
  localparam logic [15:0] DescFlagWrite = 16'h0002;

  // Per-queue state: queue 0 = RX, queue 1 = TX
  logic [31:0] dev_feat_sel_q, drv_feat_sel_q;
  logic [31:0] drv_feat_q[2];
  logic [31:0] queue_sel_q;
  logic [15:0] q_num_q[2];
  logic q_ready_q[2];
  logic [63:0] q_desc_q[2], q_driver_q[2], q_device_q[2];
  logic [15:0] q_last_avail_q[2], q_used_idx_q[2];
  logic q_kick_q[2];
  logic [7:0] status_q;
  logic [1:0] int_status_q;
  logic resp_valid_q;
  logic [63:0] resp_rdata_q;

  assign resp_valid_o = resp_valid_q;
  assign resp_rdata_o = resp_rdata_q;
  assign resp_err_o   = 1'b0;
  assign irq_o        = |int_status_q;

  // Internal 2 KiB RX & TX frame buffers
  (* ram_style = "distributed" *) logic [7:0] rx_pkt_buf [0:2047];
  (* ram_style = "distributed" *) logic [7:0] tx_pkt_buf [0:2047];

  logic rx_pkt_ready_q;
  logic [11:0] rx_cap_len_q, rx_pkt_len_q;
  logic rx_drop_q;

  assign rx_axis_tready_o = !reset && !rx_pkt_ready_q;

  // Config-space byte lookup (0x100..0x107: MAC[0..5] + uint16 status)
  function automatic logic [7:0] cfg_byte(input logic [2:0] idx, input logic link_up);
    case (idx)
      3'd0: return LocalMac[7:0];
      3'd1: return LocalMac[15:8];
      3'd2: return LocalMac[23:16];
      3'd3: return LocalMac[31:24];
      3'd4: return LocalMac[39:32];
      3'd5: return LocalMac[47:40];
      3'd6: return {7'b0, link_up};
      default: return 8'h00;
    endcase
  endfunction

  // Extract 32-bit aligned MMIO write value from 64-bit bus lane
  wire [11:0] reg_aligned = {req_addr_i[11:2], 2'b00};
  wire [31:0] wdata32 = req_addr_i[2] ? req_wdata_i[63:32] : req_wdata_i[31:0];
  wire qsel_valid = queue_sel_q < 32'd2;
  wire qsel_bit = queue_sel_q[0];

  logic [63:0] mmio_read_val;
  always_comb begin
    mmio_read_val = 64'd0;
    if (req_addr_i >= 12'h100 && req_addr_i < 12'h108) begin
      for (int b = 0; b < 8; b++) begin
        automatic logic [11:0] baddr = {req_addr_i[11:3], 3'b000} + 12'(b);
        if (baddr >= 12'h100 && baddr < 12'h108)
          mmio_read_val[b*8+:8] = cfg_byte(baddr[2:0], link_up_i);
      end
    end else begin
      automatic logic [31:0] r32 = 32'd0;
      case (reg_aligned)
        12'h000: r32 = 32'h74726976;  // "virt"
        12'h004: r32 = 32'd2;         // Modern VirtIO MMIO v2
        12'h008: r32 = 32'd1;         // VirtIO Net
        12'h00c: r32 = 32'h52415054;  // "RAPT"
        12'h010: r32 = (dev_feat_sel_q == 32'd0) ? FeatWord0
                     : (dev_feat_sel_q == 32'd1) ? FeatWord1 : 32'd0;
        12'h034: r32 = qsel_valid ? 32'(QueueNumMax) : 32'd0;
        12'h044: r32 = qsel_valid ? {31'b0, q_ready_q[qsel_bit]} : 32'd0;
        12'h060: r32 = {30'b0, int_status_q};
        12'h070: r32 = {24'b0, status_q};
        12'h0fc: r32 = 32'd0;
        default: r32 = 32'd0;
      endcase
      mmio_read_val = req_addr_i[2] ? {r32, 32'd0} : {32'd0, r32};
    end
  end

  // Split-Virtqueue DMA engine FSM
  typedef enum logic [4:0] {
    DmaIdle,
    // Read avail.flags (2B) + avail.idx (2B)
    DmaReadAvailHdr,
    DmaWaitAvailHdr,
    // Read avail.ring[slot] (2B)
    DmaReadAvailRing,
    DmaWaitAvailRing,
    // Read 16-byte virtq_desc in four 32-bit reads (works identically on RV32 & RV64)
    DmaReadDesc,
    DmaWaitDesc,
    // TX payload copy from guest RAM -> tx_pkt_buf, then stream out tx_axis
    DmaTxReadMem,
    DmaTxWaitMem,
    DmaTxStreamOut,
    // RX header+payload copy from rx_pkt_buf -> guest RAM
    DmaRxWriteAw,
    DmaRxWriteW,
    DmaRxWriteB,
    // Used ring update: write used.ring[slot].{id,len}, then used.idx
    DmaUsedElem,
    DmaWriteUsedElemAw,
    DmaWriteUsedElemW,
    DmaWriteUsedElemB,
    DmaWriteUsedIdxAw,
    DmaWriteUsedIdxW,
    DmaWriteUsedIdxB
  } dma_state_t;

  dma_state_t st_q;
  logic active_tx_q;  // 1 = TX queue (1), 0 = RX queue (0)
  logic [15:0] head_idx_q;
  logic [15:0] avail_flags_q;
  logic [1:0] desc_word_idx_q;
  logic [31:0] desc_words_q[4];
  logic [63:0] cur_buf_addr_q;
  logic [31:0] cur_buf_rem_q;
  logic [15:0] cur_desc_flags_q, cur_desc_next_q;
  logic [15:0] tx_skip_hdr_q;
  logic [11:0] tx_frame_len_q, tx_stream_pos_q;
  logic [12:0] rx_total_len_q, rx_copied_q;
  logic [1:0] used_step_q;
  logic [63:0] dma_addr_q;
  logic [2:0] dma_size_q;
  logic [XLEN-1:0] dma_wdata_q;
  logic [Bytes-1:0] dma_wstrb_q;

  wire driver_ok = (status_q & StatusDriverOk) != 8'd0;
  wire rx_live = driver_ok && q_ready_q[0] && q_num_q[0] != 16'd0;
  wire tx_can_run = driver_ok && q_ready_q[1] && q_num_q[1] != 16'd0 && q_kick_q[1];
  wire rx_can_run = rx_live && rx_pkt_ready_q;

  wire [15:0] active_qnum = q_num_q[active_tx_q];
  wire [63:0] active_desc_base = q_desc_q[active_tx_q];
  wire [63:0] active_drv_base  = q_driver_q[active_tx_q];
  wire [63:0] active_dev_base  = q_device_q[active_tx_q];
  wire [15:0] active_last_avail = q_last_avail_q[active_tx_q];
  wire [15:0] active_used_idx   = q_used_idx_q[active_tx_q];
  // Split virtqueue sizes are powers of two, so ring slots wrap with a mask.
  wire [15:0] avail_slot = active_last_avail & (active_qnum - 16'd1);
  wire [15:0] used_slot  = active_used_idx & (active_qnum - 16'd1);

  // Helper to shift AXI rdata down by byte offset
  function automatic logic [31:0] shift_rdata32(input logic [XLEN-1:0] raw,
                                                input logic [63:0] addr);
    logic [ByteBits-1:0] off;
    off = addr[ByteBits-1:0];
    return 32'(raw >> (int'(off) * 8));
  endfunction

  // RX source byte: first 12 bytes are virtio_net_hdr_v1 (num_buffers = 1 at [11:10]),
  // followed by captured Ethernet frame bytes.
  function automatic logic [7:0] rx_source_byte(input logic [12:0] pos, input logic [7:0] pkt_b);
    if (pos < 13'd10) return 8'h00;
    if (pos == 13'd10) return 8'h01;  // num_buffers = 1 (LE low byte)
    if (pos == 13'd11) return 8'h00;  // num_buffers = 1 (LE high byte)
    return pkt_b;
  endfunction

  wire [11:0] rx_pkt_read_idx = (rx_copied_q >= 13'(VirtioHdrBytes))
      ? 12'(rx_copied_q - 13'(VirtioHdrBytes)) : 12'd0;
  wire [7:0] rx_pkt_byte_cur = rx_pkt_buf[rx_pkt_read_idx[10:0]];

  // Drive AXI4 DMA master signals strictly from registered transaction state
  wire ar_state = (st_q == DmaReadAvailHdr) || (st_q == DmaReadAvailRing)
               || (st_q == DmaReadDesc) || (st_q == DmaTxReadMem);
  wire r_state  = (st_q == DmaWaitAvailHdr) || (st_q == DmaWaitAvailRing)
               || (st_q == DmaWaitDesc) || (st_q == DmaTxWaitMem);
  wire aw_state = (st_q == DmaRxWriteAw) || (st_q == DmaWriteUsedElemAw)
               || (st_q == DmaWriteUsedIdxAw);
  wire w_state  = (st_q == DmaRxWriteW) || (st_q == DmaWriteUsedElemW)
               || (st_q == DmaWriteUsedIdxW);
  wire b_state  = (st_q == DmaRxWriteB) || (st_q == DmaWriteUsedElemB)
               || (st_q == DmaWriteUsedIdxB);

  assign dma.arvalid = !reset && ar_state;
  assign dma.araddr  = XLEN'(dma_addr_q);
  assign dma.arid    = 4'd1;
  assign dma.arlen   = 8'd0;
  assign dma.arsize  = dma_size_q;
  assign dma.arburst = 2'b01;
  assign dma.arcache = 4'b0010;
  assign dma.rready  = !reset && r_state;

  assign dma.awvalid = !reset && aw_state;
  assign dma.awaddr  = XLEN'(dma_addr_q);
  assign dma.awid    = 4'd1;
  assign dma.awlen   = 8'd0;
  assign dma.awsize  = dma_size_q;
  assign dma.awburst = 2'b01;
  assign dma.awcache = 4'b0010;

  assign dma.wvalid  = !reset && w_state;
  assign dma.wdata   = dma_wdata_q;
  assign dma.wstrb   = dma_wstrb_q;
  assign dma.wlast   = 1'b1;
  assign dma.bready  = !reset && b_state;

  // TX stream output
  assign tx_axis_tvalid_o = !reset && (st_q == DmaTxStreamOut);
  assign tx_axis_tdata_o  = tx_pkt_buf[tx_stream_pos_q[10:0]];
  assign tx_axis_tlast_o  = (st_q == DmaTxStreamOut)
                         && (tx_stream_pos_q + 12'd1 >= tx_frame_len_q);

  // RX packet capture into rx_pkt_buf
  always_ff @(posedge clk) begin
    if (reset) begin
      rx_pkt_ready_q <= 1'b0;
      rx_cap_len_q <= '0;
      rx_pkt_len_q <= '0;
      rx_drop_q <= 1'b0;
    end else begin
      if (!rx_pkt_ready_q && rx_axis_tvalid_i && rx_axis_tready_o) begin
        if (!rx_drop_q && rx_cap_len_q < 12'(MaxFrame)) begin
          rx_pkt_buf[rx_cap_len_q[10:0]] <= rx_axis_tdata_i;
          rx_cap_len_q <= rx_cap_len_q + 12'd1;
        end else begin
          rx_drop_q <= 1'b1;
        end
        if (rx_axis_tlast_i) begin
          if (!rx_drop_q && (rx_cap_len_q + 12'd1) >= 12'd14
              && (rx_cap_len_q + 12'd1) <= 12'(MaxFrame)) begin
            rx_pkt_len_q <= rx_cap_len_q + 12'd1;
            rx_pkt_ready_q <= 1'b1;
          end
          rx_cap_len_q <= '0;
          rx_drop_q <= 1'b0;
        end
      end else if (rx_pkt_ready_q && st_q == DmaWriteUsedIdxB && dma.bvalid && dma.bready
                   && !active_tx_q) begin
        rx_pkt_ready_q <= 1'b0;
      end else if (rx_pkt_ready_q && st_q == DmaWaitAvailHdr && dma.rvalid && dma.rready
                   && !active_tx_q) begin
        automatic logic [31:0] hdr32 = shift_rdata32(dma.rdata, dma_addr_q);
        // If guest RX ring has no available buffers yet, drop packet so MAC RX does not wedge
        if (hdr32[31:16] == q_last_avail_q[0]) rx_pkt_ready_q <= 1'b0;
      end else if (rx_pkt_ready_q && !rx_live && st_q == DmaIdle) begin
        // Drop frames while the RX queue is down; the shared MAC RX path (and the
        // QEMU bridge frames behind it) must not wait for the guest driver.
        rx_pkt_ready_q <= 1'b0;
      end
    end
  end

  // Unified MMIO + Virtqueue DMA state machine (single procedural writer per state reg)
  always_ff @(posedge clk) begin
    if (reset) begin
      dev_feat_sel_q <= '0;
      drv_feat_sel_q <= '0;
      drv_feat_q[0] <= '0;
      drv_feat_q[1] <= '0;
      queue_sel_q <= '0;
      for (int q = 0; q < 2; q++) begin
        q_num_q[q] <= '0;
        q_ready_q[q] <= 1'b0;
        q_desc_q[q] <= '0;
        q_driver_q[q] <= '0;
        q_device_q[q] <= '0;
        q_last_avail_q[q] <= '0;
        q_used_idx_q[q] <= '0;
        q_kick_q[q] <= 1'b0;
      end
      status_q <= '0;
      int_status_q <= '0;
      resp_valid_q <= 1'b0;
      resp_rdata_q <= '0;
      st_q <= DmaIdle;
      active_tx_q <= 1'b0;
      head_idx_q <= '0;
      avail_flags_q <= '0;
      desc_word_idx_q <= '0;
      for (int i = 0; i < 4; i++) desc_words_q[i] <= '0;
      cur_buf_addr_q <= '0;
      cur_buf_rem_q <= '0;
      cur_desc_flags_q <= '0;
      cur_desc_next_q <= '0;
      tx_skip_hdr_q <= '0;
      tx_frame_len_q <= '0;
      tx_stream_pos_q <= '0;
      rx_total_len_q <= '0;
      rx_copied_q <= '0;
      used_step_q <= '0;
      dma_addr_q <= '0;
      dma_size_q <= '0;
      dma_wdata_q <= '0;
      dma_wstrb_q <= '0;
    end else begin
      resp_valid_q <= req_valid_i;
      if (req_valid_i && !req_write_i) begin
        resp_rdata_q <= mmio_read_val;
      end

      // MMIO register writes
      if (req_valid_i && req_write_i) begin
        case (reg_aligned)
          12'h014: dev_feat_sel_q <= wdata32;
          12'h020: if (drv_feat_sel_q < 32'd2) drv_feat_q[drv_feat_sel_q[0]] <= wdata32;
          12'h024: drv_feat_sel_q <= wdata32;
          12'h030: queue_sel_q <= wdata32;
          12'h038: if (qsel_valid && wdata32 <= 32'(QueueNumMax)
                       && (wdata32 & (wdata32 - 32'd1)) == 32'd0)
            q_num_q[qsel_bit] <= wdata32[15:0];
          12'h044: if (qsel_valid) begin
            q_ready_q[qsel_bit] <= wdata32[0];
            if (!wdata32[0]) begin
              q_last_avail_q[qsel_bit] <= '0;
              q_used_idx_q[qsel_bit] <= '0;
              q_kick_q[qsel_bit] <= 1'b0;
            end
          end
          12'h050: if (wdata32 < 32'd2) q_kick_q[wdata32[0]] <= 1'b1;
          12'h064: int_status_q <= int_status_q & ~wdata32[1:0];
          12'h070: begin
            if (wdata32[7:0] == 8'd0) begin
              status_q <= 8'd0;
              int_status_q <= 2'b00;
              for (int q = 0; q < 2; q++) begin
                q_ready_q[q] <= 1'b0;
                q_last_avail_q[q] <= '0;
                q_used_idx_q[q] <= '0;
                q_kick_q[q] <= 1'b0;
              end
            end else begin
              status_q <= wdata32[7:0];
            end
          end
          12'h080: if (qsel_valid) q_desc_q[qsel_bit][31:0]    <= wdata32;
          12'h084: if (qsel_valid) q_desc_q[qsel_bit][63:32]   <= wdata32;
          12'h090: if (qsel_valid) q_driver_q[qsel_bit][31:0]  <= wdata32;
          12'h094: if (qsel_valid) q_driver_q[qsel_bit][63:32] <= wdata32;
          12'h0a0: if (qsel_valid) q_device_q[qsel_bit][31:0]  <= wdata32;
          12'h0a4: if (qsel_valid) q_device_q[qsel_bit][63:32] <= wdata32;
          default: ;
        endcase
      end

      // Virtqueue DMA engine transitions
      case (st_q)
        DmaIdle: begin
          if (tx_can_run) begin
            active_tx_q <= 1'b1;
            dma_addr_q <= q_driver_q[1];
            dma_size_q <= 3'd2;
            st_q <= DmaReadAvailHdr;
          end else if (rx_can_run) begin
            active_tx_q <= 1'b0;
            dma_addr_q <= q_driver_q[0];
            dma_size_q <= 3'd2;
            st_q <= DmaReadAvailHdr;
          end
        end

        DmaReadAvailHdr: begin
          if (dma.arready) st_q <= DmaWaitAvailHdr;
        end

        DmaWaitAvailHdr: begin
          if (dma.rvalid) begin
            automatic logic [31:0] hdr32 = shift_rdata32(dma.rdata, dma_addr_q);
            avail_flags_q <= hdr32[15:0];
            if (hdr32[31:16] == active_last_avail) begin
              if (active_tx_q) q_kick_q[1] <= 1'b0;
              st_q <= DmaIdle;
            end else begin
              dma_addr_q <= active_drv_base + 64'd4 + {47'b0, avail_slot, 1'b0};
              dma_size_q <= 3'd1;
              st_q <= DmaReadAvailRing;
            end
          end
        end

        DmaReadAvailRing: begin
          if (dma.arready) st_q <= DmaWaitAvailRing;
        end

        DmaWaitAvailRing: begin
          if (dma.rvalid) begin
            automatic logic [31:0] ring32 = shift_rdata32(dma.rdata, dma_addr_q);
            head_idx_q <= ring32[15:0];
            desc_word_idx_q <= 2'd0;
            tx_skip_hdr_q <= 16'(VirtioHdrBytes);
            tx_frame_len_q <= '0;
            rx_total_len_q <= 13'(VirtioHdrBytes) + {1'b0, rx_pkt_len_q};
            rx_copied_q <= '0;
            dma_addr_q <= active_desc_base + {44'b0, ring32[15:0], 4'b0000};
            dma_size_q <= 3'd2;
            st_q <= DmaReadDesc;
          end
        end

        DmaReadDesc: begin
          if (dma.arready) st_q <= DmaWaitDesc;
        end

        DmaWaitDesc: begin
          if (dma.rvalid) begin
            automatic logic [31:0] w32 = shift_rdata32(dma.rdata, dma_addr_q);
            desc_words_q[desc_word_idx_q] <= w32;
            if (desc_word_idx_q == 2'd3) begin
              automatic logic [63:0] d_addr = {desc_words_q[1], desc_words_q[0]};
              automatic logic [31:0] d_len  = desc_words_q[2];
              automatic logic [15:0] d_flg  = w32[15:0];
              automatic logic [15:0] d_nxt  = w32[31:16];
              cur_buf_addr_q <= d_addr;
              cur_buf_rem_q <= d_len;
              cur_desc_flags_q <= d_flg;
              cur_desc_next_q <= d_nxt;
              if (active_tx_q) begin
                if (d_len <= {16'b0, tx_skip_hdr_q}) begin
                  tx_skip_hdr_q <= tx_skip_hdr_q - d_len[15:0];
                  if ((d_flg & DescFlagNext) != 16'd0) begin
                    desc_word_idx_q <= 2'd0;
                    dma_addr_q <= active_desc_base + {44'b0, d_nxt, 4'b0000};
                    dma_size_q <= 3'd2;
                    st_q <= DmaReadDesc;
                  end else begin
                    st_q <= DmaUsedElem;
                  end
                end else begin
                  automatic logic [63:0] start_addr = d_addr + {48'b0, tx_skip_hdr_q};
                  cur_buf_addr_q <= start_addr;
                  cur_buf_rem_q <= d_len - {16'b0, tx_skip_hdr_q};
                  tx_skip_hdr_q <= 16'd0;
                  dma_addr_q <= start_addr;
                  dma_size_q <= 3'd0;
                  st_q <= DmaTxReadMem;
                end
              end else begin
                // RX descriptor must have VRING_DESC_F_WRITE and non-zero len
                if ((d_flg & DescFlagWrite) == 16'd0 || d_len == 32'd0) begin
                  st_q <= DmaUsedElem;
                end else begin
                  automatic logic [7:0] src_b = rx_source_byte(rx_copied_q, rx_pkt_byte_cur);
                  automatic logic [ByteBits-1:0] lane = d_addr[ByteBits-1:0];
                  dma_addr_q <= d_addr;
                  dma_size_q <= 3'd0;
                  dma_wdata_q <= XLEN'(src_b) << (int'(lane) * 8);
                  dma_wstrb_q <= Bytes'(1) << lane;
                  st_q <= DmaRxWriteAw;
                end
              end
            end else begin
              desc_word_idx_q <= desc_word_idx_q + 2'd1;
              dma_addr_q <= dma_addr_q + 64'd4;
              dma_size_q <= 3'd2;
              st_q <= DmaReadDesc;
            end
          end
        end

        DmaTxReadMem: begin
          if (dma.arready) st_q <= DmaTxWaitMem;
        end

        DmaTxWaitMem: begin
          if (dma.rvalid) begin
            automatic logic [ByteBits-1:0] lane = dma_addr_q[ByteBits-1:0];
            automatic logic [7:0] bval = 8'(dma.rdata >> (int'(lane) * 8));
            if (tx_frame_len_q < 12'(MaxFrame)) begin
              tx_pkt_buf[tx_frame_len_q[10:0]] <= bval;
              tx_frame_len_q <= tx_frame_len_q + 12'd1;
            end
            if (cur_buf_rem_q <= 32'd1) begin
              if ((cur_desc_flags_q & DescFlagNext) != 16'd0) begin
                desc_word_idx_q <= 2'd0;
                dma_addr_q <= active_desc_base + {44'b0, cur_desc_next_q, 4'b0000};
                dma_size_q <= 3'd2;
                st_q <= DmaReadDesc;
              end else begin
                // At least the byte just read is buffered, so the frame is never empty.
                tx_stream_pos_q <= '0;
                st_q <= DmaTxStreamOut;
              end
            end else begin
              cur_buf_addr_q <= cur_buf_addr_q + 64'd1;
              cur_buf_rem_q <= cur_buf_rem_q - 32'd1;
              dma_addr_q <= cur_buf_addr_q + 64'd1;
              dma_size_q <= 3'd0;
              st_q <= DmaTxReadMem;
            end
          end
        end

        DmaTxStreamOut: begin
          if (tx_axis_tready_i) begin
            if (tx_stream_pos_q + 12'd1 >= tx_frame_len_q) begin
              st_q <= DmaUsedElem;
            end else begin
              tx_stream_pos_q <= tx_stream_pos_q + 12'd1;
            end
          end
        end

        DmaRxWriteAw: begin
          if (dma.awready) st_q <= DmaRxWriteW;
        end

        DmaRxWriteW: begin
          if (dma.wready) st_q <= DmaRxWriteB;
        end

        DmaRxWriteB: begin
          if (dma.bvalid) begin
            automatic logic [12:0] next_copied = rx_copied_q + 13'd1;
            rx_copied_q <= next_copied;
            if (next_copied >= rx_total_len_q) begin
              st_q <= DmaUsedElem;
            end else if (cur_buf_rem_q <= 32'd1) begin
              if ((cur_desc_flags_q & DescFlagNext) != 16'd0) begin
                desc_word_idx_q <= 2'd0;
                dma_addr_q <= active_desc_base + {44'b0, cur_desc_next_q, 4'b0000};
                dma_size_q <= 3'd2;
                st_q <= DmaReadDesc;
              end else begin
                st_q <= DmaUsedElem;
              end
            end else begin
              automatic logic [63:0] naddr = cur_buf_addr_q + 64'd1;
              automatic logic [11:0] npkt_idx = (next_copied >= 13'(VirtioHdrBytes))
                  ? 12'(next_copied - 13'(VirtioHdrBytes)) : 12'd0;
              automatic logic [7:0] nb = rx_source_byte(next_copied, rx_pkt_buf[npkt_idx[10:0]]);
              automatic logic [ByteBits-1:0] lane = naddr[ByteBits-1:0];
              cur_buf_addr_q <= naddr;
              cur_buf_rem_q <= cur_buf_rem_q - 32'd1;
              dma_addr_q <= naddr;
              dma_size_q <= 3'd0;
              dma_wdata_q <= XLEN'(nb) << (int'(lane) * 8);
              dma_wstrb_q <= Bytes'(1) << lane;
              st_q <= DmaRxWriteAw;
            end
          end
        end

        DmaUsedElem: begin
          automatic logic [63:0] elem_addr = active_dev_base + 64'd4 + {45'b0, used_slot, 3'b000};
          automatic logic [ByteBits-1:0] lane = elem_addr[ByteBits-1:0];
          used_step_q <= 2'd0;
          dma_addr_q <= elem_addr;
          dma_size_q <= 3'd2;
          dma_wdata_q <= XLEN'({16'b0, head_idx_q}) << (int'(lane) * 8);
          dma_wstrb_q <= Bytes'(4'hf) << lane;
          st_q <= DmaWriteUsedElemAw;
        end

        DmaWriteUsedElemAw: begin
          if (dma.awready) st_q <= DmaWriteUsedElemW;
        end

        DmaWriteUsedElemW: begin
          if (dma.wready) st_q <= DmaWriteUsedElemB;
        end

        DmaWriteUsedElemB: begin
          if (dma.bvalid) begin
            if (used_step_q == 2'd0) begin
              automatic logic [63:0] len_addr = dma_addr_q + 64'd4;
              automatic logic [31:0] ulen = active_tx_q ? 32'd0 : {19'b0, rx_copied_q};
              automatic logic [ByteBits-1:0] lane = len_addr[ByteBits-1:0];
              used_step_q <= 2'd1;
              dma_addr_q <= len_addr;
              dma_size_q <= 3'd2;
              dma_wdata_q <= XLEN'(ulen) << (int'(lane) * 8);
              dma_wstrb_q <= Bytes'(4'hf) << lane;
              st_q <= DmaWriteUsedElemAw;
            end else begin
              automatic logic [63:0] idx_addr = active_dev_base + 64'd2;
              automatic logic [15:0] next_used = active_used_idx + 16'd1;
              automatic logic [ByteBits-1:0] lane = idx_addr[ByteBits-1:0];
              dma_addr_q <= idx_addr;
              dma_size_q <= 3'd1;
              dma_wdata_q <= XLEN'(next_used) << (int'(lane) * 8);
              dma_wstrb_q <= Bytes'(2'b11) << lane;
              st_q <= DmaWriteUsedIdxAw;
            end
          end
        end

        DmaWriteUsedIdxAw: begin
          if (dma.awready) st_q <= DmaWriteUsedIdxW;
        end

        DmaWriteUsedIdxW: begin
          if (dma.wready) st_q <= DmaWriteUsedIdxB;
        end

        DmaWriteUsedIdxB: begin
          if (dma.bvalid) begin
            q_last_avail_q[active_tx_q] <= active_last_avail + 16'd1;
            q_used_idx_q[active_tx_q] <= active_used_idx + 16'd1;
            if (!avail_flags_q[0]) int_status_q[0] <= 1'b1;
            st_q <= DmaIdle;
          end
        end

        default: st_q <= DmaIdle;
      endcase
    end
  end
endmodule
