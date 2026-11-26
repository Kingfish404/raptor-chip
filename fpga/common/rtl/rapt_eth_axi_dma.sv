// AXI4-Master RX/TX Ring DMA Ethernet Engine (ABI v2).
// Pure-DFF 16-entry RX/TX descriptor rings + 4 KiB store-and-forward packet
// FIFOs (512x64b BRAM each). Streams 64-bit INCR bursts (up to 16 beats = 128B,
// 4 KiB page-boundary safe) directly to/from DDR4, freeing the CPU from word PIO.
module rapt_eth_axi_dma #(
    parameter int AddrW = 64,
    parameter int RingDepth = 16,
    parameter int MaxFrameBytes = 1536,
    parameter int MaxBurstBeats = 16,
    parameter int RxFcsBytes = 0,
    parameter logic [AddrW-1:0] DdrBase = 64'h0000_0000_8000_0000
) (
    input logic clk,
    input logic reset,
    input logic clocks_ready,

    // 32-bit synchronous MMIO slave port (0x1800_0000 window)
    input logic rd,
    input logic wr,
    input logic [15:0] raddr,
    input logic [15:0] waddr,
    input logic [31:0] wdata,
    input logic [3:0] wstrb,
    output logic [31:0] rdata,
    output logic irq,
    output logic enabled,

    // MDIO bit-bang control
    output logic [2:0] mdio_control,
    input logic mdio_input,

    // 8-bit MAC RX stream (in clk domain; e.g. from async FIFO or eth_mac_1g)
    input logic [7:0] mac_rx_data,
    input logic mac_rx_valid,
    input logic mac_rx_last,
    input logic mac_rx_error,
    output logic mac_rx_ready,

    // 8-bit MAC TX stream (in clk domain)
    output logic [7:0] mac_tx_data,
    output logic mac_tx_valid,
    output logic mac_tx_last,
    input logic mac_tx_ready,

    // 64-bit AXI4 Master port to DDR4 (via rapt_axi4_dma_arb)
    output logic [3:0] m_axi_awid,
    output logic [AddrW-1:0] m_axi_awaddr,
    output logic [7:0] m_axi_awlen,
    output logic [2:0] m_axi_awsize,
    output logic [1:0] m_axi_awburst,
    output logic [3:0] m_axi_awcache,
    output logic m_axi_awvalid,
    input logic m_axi_awready,

    output logic [63:0] m_axi_wdata,
    output logic [7:0] m_axi_wstrb,
    output logic m_axi_wlast,
    output logic m_axi_wvalid,
    input logic m_axi_wready,

    /* verilator lint_off UNUSEDSIGNAL */
    input logic [3:0] m_axi_bid,
    /* verilator lint_on UNUSEDSIGNAL */
    input logic [1:0] m_axi_bresp,
    input logic m_axi_bvalid,
    output logic m_axi_bready,

    output logic [3:0] m_axi_arid,
    output logic [AddrW-1:0] m_axi_araddr,
    output logic [7:0] m_axi_arlen,
    output logic [2:0] m_axi_arsize,
    output logic [1:0] m_axi_arburst,
    output logic [3:0] m_axi_arcache,
    output logic m_axi_arvalid,
    input logic m_axi_arready,

    /* verilator lint_off UNUSEDSIGNAL */
    input logic [3:0] m_axi_rid,
    /* verilator lint_on UNUSEDSIGNAL */
    input logic [63:0] m_axi_rdata,
    input logic [1:0] m_axi_rresp,
    input logic m_axi_rlast,
    input logic m_axi_rvalid,
    output logic m_axi_rready,

    // External write notification for CPU LR/SC reservation invalidation
    output logic ext_wr_valid_o,
    output logic [AddrW-1:0] ext_wr_first_o,
    output logic [AddrW-1:0] ext_wr_last_o
);
  localparam int RingBits = $clog2(RingDepth);
  localparam int PtrW = RingBits + 1;
  localparam int FifoWords = 512;  // 4 KiB (512 x 64-bit)
  localparam int FifoBits = $clog2(FifoWords);

  // Control & status registers
  logic dma_enable;
  logic [1:0] irq_mask;
  logic tx_event;
  logic [31:0] rx_good_count, rx_drop_count, tx_good_count, dma_err_count;

  // Staging address registers for 64-bit descriptor push
  logic [31:0] rx_stage_lo, rx_stage_hi;
  logic [31:0] tx_stage_lo, tx_stage_hi;

  // RX/TX descriptor rings (LUTRAM-friendly for RingDepth up to 64)
  (* ram_style = "distributed" *) logic [AddrW-1:0] rx_ring_addr[RingDepth];
  (* ram_style = "distributed" *) logic [15:0] rx_ring_len[RingDepth];
  logic [PtrW-1:0] rx_sw_prod, rx_hw_done, rx_sw_cons;

  (* ram_style = "distributed" *) logic [AddrW-1:0] tx_ring_addr[RingDepth];
  (* ram_style = "distributed" *) logic [15:0] tx_ring_len[RingDepth];
  logic [PtrW-1:0] tx_sw_prod, tx_hw_done, tx_sw_cons;

  wire rx_desc_avail = (rx_hw_done != rx_sw_prod);
  wire rx_comp_avail = (rx_sw_cons != rx_hw_done);
  wire rx_ring_full  = (rx_sw_prod[RingBits] != rx_sw_cons[RingBits])
      && (rx_sw_prod[RingBits-1:0] == rx_sw_cons[RingBits-1:0]);
  wire tx_desc_avail = (tx_hw_done != tx_sw_prod);
  wire tx_ring_full  = (tx_sw_prod[RingBits] != tx_sw_cons[RingBits])
      && (tx_sw_prod[RingBits-1:0] == tx_sw_cons[RingBits-1:0]);
  wire tx_comp_avail = (tx_sw_cons != tx_hw_done);

  wire reg_write = wr && (wstrb == 4'hf);
  wire eng_reset = reset || !enabled || !dma_enable;

  // 4 KiB store-and-forward RX & TX packet FIFOs (inferred as 1x RAMB36 each)
  logic [63:0] rx_fifo_mem[FifoWords];
  logic [63:0] tx_fifo_mem[FifoWords];

  // ---- RX Engine (MAC RX stream -> 4 KiB FIFO -> AXI4 Master Write Bursts) ----
  typedef enum logic [2:0] {
    RxIdle,
    RxRecv,
    RxDrop,
    RxAw,
    RxW,
    RxB
  } rx_state_t;
  rx_state_t rx_state;

  logic [11:0] rx_byte_cnt;
  logic [63:0] rx_pack_word;
  logic [FifoBits-1:0] rx_fifo_rd_idx;
  logic [63:0] rx_fifo_rd_data;
  logic [AddrW-1:0] rx_cur_addr;
  logic [11:0] rx_rem_bytes;
  logic [7:0] rx_burst_len;
  logic [7:0] rx_beat_idx;
  logic [AddrW-1:0] rx_frame_start_addr;

  // Compute safe AXI write burst beats (max 16 beats, never crossing 4 KiB page)
  wire [8:0] rx_beats_left = 9'((rx_rem_bytes + 12'd7) >> 3);
  wire [9:0] rx_page_beats = 10'd512 - {1'b0, rx_cur_addr[11:3]};
  logic [7:0] rx_next_awlen;
  always_comb begin
    automatic logic [9:0] lim;
    lim = ({1'b0, rx_beats_left} < rx_page_beats) ? {1'b0, rx_beats_left} : rx_page_beats;
    if (lim > 10'(MaxBurstBeats)) lim = 10'(MaxBurstBeats);
    rx_next_awlen = (lim > 10'd0) ? 8'(lim - 10'd1) : 8'd0;
  end

  // Last-beat byte strobe for non-8B-aligned frame lengths
  logic [7:0] rx_last_wstrb;
  always_comb begin
    if (rx_rem_bytes >= 12'd8) begin
      rx_last_wstrb = 8'hff;
    end else begin
      rx_last_wstrb = (8'h01 << rx_rem_bytes[2:0]) - 8'h01;
    end
  end

  assign mac_rx_ready = !eng_reset && (rx_state == RxIdle || rx_state == RxRecv
                                       || rx_state == RxDrop);

  // AXI4 Write Channel
  assign m_axi_awid    = 4'd0;
  assign m_axi_awaddr  = rx_cur_addr - DdrBase;
  assign m_axi_awlen   = rx_next_awlen;
  assign m_axi_awsize  = 3'b011;  // 8 bytes/beat
  assign m_axi_awburst = 2'b01;   // INCR
  assign m_axi_awcache = 4'b0011; // Normal Non-cacheable Bufferable
  assign m_axi_awvalid = !eng_reset && (rx_state == RxAw);

  assign m_axi_wdata   = rx_fifo_rd_data;
  assign m_axi_wstrb   = (rx_beat_idx == rx_burst_len && rx_rem_bytes <= 12'd8)
                         ? rx_last_wstrb : 8'hff;
  assign m_axi_wlast   = (rx_beat_idx == rx_burst_len);
  assign m_axi_wvalid  = !eng_reset && (rx_state == RxW);
  assign m_axi_bready  = !eng_reset && (rx_state == RxB);

  // LR/SC invalidation notification on completed RX frame write
  assign ext_wr_valid_o = !eng_reset && (rx_state == RxB) && m_axi_bvalid
      && (rx_rem_bytes == 12'd0);
  assign ext_wr_first_o = rx_frame_start_addr;
  assign ext_wr_last_o  = rx_frame_start_addr + AddrW'(rx_byte_cnt - 12'd1);

  // ---- TX Engine (AXI4 Master Read Bursts -> 4 KiB FIFO -> MAC TX stream) ----
  typedef enum logic [2:0] {
    TxIdle,
    TxAr,
    TxR,
    TxPreload,
    TxSend
  } tx_state_t;
  tx_state_t tx_state;

  logic [AddrW-1:0] tx_cur_addr;
  logic [11:0] tx_frame_len;
  logic [11:0] tx_rem_bytes;
  logic [FifoBits-1:0] tx_fifo_wr_idx;
  logic [11:0] tx_send_idx;
  logic [63:0] tx_fifo_rd_data;

  wire [8:0] tx_beats_left = 9'((tx_rem_bytes + 12'd7) >> 3);
  wire [9:0] tx_page_beats = 10'd512 - {1'b0, tx_cur_addr[11:3]};
  logic [7:0] tx_next_arlen;
  always_comb begin
    automatic logic [9:0] lim;
    lim = ({1'b0, tx_beats_left} < tx_page_beats) ? {1'b0, tx_beats_left} : tx_page_beats;
    if (lim > 10'(MaxBurstBeats)) lim = 10'(MaxBurstBeats);
    tx_next_arlen = (lim > 10'd0) ? 8'(lim - 10'd1) : 8'd0;
  end

  // AXI4 Read Channel
  assign m_axi_arid    = 4'd0;
  assign m_axi_araddr  = tx_cur_addr - DdrBase;
  assign m_axi_arlen   = tx_next_arlen;
  assign m_axi_arsize  = 3'b011;  // 8 bytes/beat
  assign m_axi_arburst = 2'b01;   // INCR
  assign m_axi_arcache = 4'b0011;
  assign m_axi_arvalid = !eng_reset && (tx_state == TxAr);
  assign m_axi_rready  = !eng_reset && (tx_state == TxR);

  // MAC TX byte stream
  assign mac_tx_valid = !eng_reset && (tx_state == TxSend);
  assign mac_tx_data  = tx_fifo_rd_data[tx_send_idx[2:0]*8+:8];
  assign mac_tx_last  = (tx_state == TxSend) && (tx_send_idx + 12'd1 == tx_frame_len);

  // Level-triggered interrupt
  assign irq = enabled && clocks_ready
      && ((irq_mask[0] && rx_comp_avail) || (irq_mask[1] && (tx_event || tx_comp_avail)));

  // Synchronous BRAM read ports for RX and TX FIFOs
  wire [FifoBits-1:0] rx_fifo_next_rd = (rx_state == RxW && m_axi_wready && !m_axi_wlast)
      ? (rx_fifo_rd_idx + FifoBits'(1)) : rx_fifo_rd_idx;
  wire [FifoBits-1:0] tx_fifo_next_rd = (tx_state == TxSend && mac_tx_ready)
      ? FifoBits'((tx_send_idx + 12'd1) >> 3) : tx_send_idx[11:3];

  always_ff @(posedge clk) begin
    rx_fifo_rd_data <= rx_fifo_mem[rx_fifo_next_rd];
    tx_fifo_rd_data <= tx_fifo_mem[tx_fifo_next_rd];
  end

  // ---- MMIO Register Interface & Descriptor Ring Management ----
  always_ff @(posedge clk) begin
    if (rd) begin
      case (raddr)
        16'h0000: rdata <= 32'h524e4554;  // "RNET"
        16'h0004: rdata <= 32'd2;         // ABI v2 (AXI Ring DMA)
        16'h0008: rdata <= {30'b0, dma_enable, enabled};
        16'h000c: rdata <= {27'b0, (tx_state != TxIdle), (rx_state != RxIdle),
                            clocks_ready, !tx_ring_full, rx_comp_avail};
        16'h0010: rdata <= {30'b0, irq_mask};
        16'h0014: rdata <= {30'b0, (tx_event || tx_comp_avail), rx_comp_avail};
        16'h0028: rdata <= rx_good_count;
        16'h0030: rdata <= rx_drop_count;
        16'h0034: rdata <= tx_good_count;
        16'h0038: rdata <= dma_err_count;
        16'h0040: rdata <= {29'b0, mdio_control};
        16'h0044: rdata <= {31'b0, mdio_input};
        16'h0048: rdata <= {16'(RingDepth), 16'(RingDepth)};
        16'h0080: rdata <= rx_stage_lo;
        16'h0084: rdata <= rx_stage_hi;
        16'h008c: rdata <= rx_comp_avail ? {16'b0, rx_ring_len[rx_sw_cons[RingBits-1:0]]} : 32'd0;
        16'h0090: rdata <= {8'b0, 8'(rx_sw_prod), 8'(rx_hw_done), 8'(rx_sw_cons)};
        16'h00a0: rdata <= tx_stage_lo;
        16'h00a4: rdata <= tx_stage_hi;
        16'h00ac: rdata <= {16'b0, 16'(tx_hw_done - tx_sw_cons)};
        16'h00b0: rdata <= {8'b0, 8'(tx_sw_prod), 8'(tx_hw_done), 8'(tx_sw_cons)};
        default:  rdata <= 32'd0;
      endcase
    end

    if (reset) begin
      enabled      <= 1'b0;
      dma_enable   <= 1'b0;
      irq_mask     <= 2'b00;
      mdio_control <= 3'b000;
      rx_stage_lo  <= 32'd0;
      rx_stage_hi  <= 32'd0;
      tx_stage_lo  <= 32'd0;
      tx_stage_hi  <= 32'd0;
    end else if (reg_write) begin
      case (waddr)
        16'h0008: begin
          enabled    <= wdata[0];
          dma_enable <= wdata[1];
        end
        16'h0010: irq_mask     <= wdata[1:0];
        16'h0040: mdio_control <= wdata[2:0];
        16'h0080: rx_stage_lo  <= wdata;
        16'h0084: rx_stage_hi  <= wdata;
        16'h00a0: tx_stage_lo  <= wdata;
        16'h00a4: tx_stage_hi  <= wdata;
        default: ;
      endcase
    end
  end

  // ---- Ring Pointer & Engine FSM Sequential Logic ----
  always_ff @(posedge clk) begin
    if (eng_reset) begin
      rx_sw_prod    <= '0;
      rx_hw_done    <= '0;
      rx_sw_cons    <= '0;
      tx_sw_prod    <= '0;
      tx_hw_done    <= '0;
      tx_sw_cons    <= '0;
      tx_event      <= 1'b0;
      rx_good_count <= 32'd0;
      rx_drop_count <= 32'd0;
      tx_good_count <= 32'd0;
      dma_err_count <= 32'd0;
      rx_state      <= RxIdle;
      rx_byte_cnt   <= 12'd0;
      rx_pack_word  <= 64'd0;
      rx_fifo_rd_idx <= '0;
      rx_cur_addr   <= '0;
      rx_rem_bytes  <= 12'd0;
      rx_burst_len  <= 8'd0;
      rx_beat_idx   <= 8'd0;
      rx_frame_start_addr <= '0;
      tx_state      <= TxIdle;
      tx_cur_addr   <= '0;
      tx_frame_len  <= 12'd0;
      tx_rem_bytes  <= 12'd0;
      tx_fifo_wr_idx <= '0;
      tx_send_idx   <= 12'd0;
    end else begin
      // Software descriptor ring doorbells
      if (reg_write) begin
        case (waddr)
          16'h0014: begin
            if (wdata[1]) tx_event <= 1'b0;
          end
          16'h0088: begin
            if (!rx_ring_full) begin
              rx_ring_addr[rx_sw_prod[RingBits-1:0]] <= AddrW'({rx_stage_hi, rx_stage_lo});
              rx_sw_prod <= rx_sw_prod + PtrW'(1);
            end
          end
          16'h008c: begin
            if (rx_comp_avail) rx_sw_cons <= rx_sw_cons + PtrW'(1);
          end
          16'h00a8: begin
            if (!tx_ring_full && wdata[15:0] >= 16'd14 && wdata[15:0] <= 16'(MaxFrameBytes)) begin
              tx_ring_addr[tx_sw_prod[RingBits-1:0]] <= AddrW'({tx_stage_hi, tx_stage_lo});
              tx_ring_len[tx_sw_prod[RingBits-1:0]]  <= wdata[15:0];
              tx_sw_prod <= tx_sw_prod + PtrW'(1);
            end
          end
          16'h00ac: begin
            tx_sw_cons <= tx_hw_done;
            tx_event   <= 1'b0;
          end
          default: ;
        endcase
      end

      // ---- RX DMA FSM ----
      case (rx_state)
        RxIdle: begin
          if (mac_rx_valid) begin
            if (!rx_desc_avail || mac_rx_error) begin
              rx_drop_count <= rx_drop_count + 32'd1;
              rx_state <= mac_rx_last ? RxIdle : RxDrop;
            end else begin
              automatic logic [63:0] w0;
              w0 = {56'd0, mac_rx_data};
              rx_pack_word <= w0;
              rx_byte_cnt  <= 12'd1;
              if (mac_rx_last) begin
                // 1-byte runt frame -> drop
                rx_drop_count <= rx_drop_count + 32'd1;
                rx_state <= RxIdle;
              end else begin
                rx_state <= RxRecv;
              end
            end
          end
        end
        RxDrop: begin
          if (mac_rx_valid && mac_rx_last) rx_state <= RxIdle;
        end
        RxRecv: begin
          if (mac_rx_valid) begin
            automatic logic [63:0] next_w;
            automatic logic [11:0] next_cnt;
            next_w = rx_pack_word;
            next_w[rx_byte_cnt[2:0]*8+:8] = mac_rx_data;
            next_cnt = rx_byte_cnt + 12'd1;
            if (mac_rx_error || next_cnt > 12'(MaxFrameBytes + RxFcsBytes)) begin
              rx_drop_count <= rx_drop_count + 32'd1;
              rx_state <= mac_rx_last ? RxIdle : RxDrop;
            end else begin
              if (rx_byte_cnt[2:0] == 3'd7 || mac_rx_last) begin
                rx_fifo_mem[rx_byte_cnt[11:3]] <= next_w;
                rx_pack_word <= 64'd0;
              end else begin
                rx_pack_word <= next_w;
              end
              if (mac_rx_last) begin
                if (next_cnt < 12'(14 + RxFcsBytes)) begin
                  rx_drop_count <= rx_drop_count + 32'd1;
                  rx_state <= RxIdle;
                end else begin
                  rx_byte_cnt         <= next_cnt - 12'(RxFcsBytes);
                  rx_cur_addr         <= rx_ring_addr[rx_hw_done[RingBits-1:0]];
                  rx_frame_start_addr <= rx_ring_addr[rx_hw_done[RingBits-1:0]];
                  rx_rem_bytes        <= next_cnt - 12'(RxFcsBytes);
                  rx_fifo_rd_idx      <= '0;
                  rx_state            <= RxAw;
                end
              end else begin
                rx_byte_cnt <= next_cnt;
              end
            end
          end
        end
        RxAw: begin
          if (m_axi_awready) begin
            rx_burst_len <= rx_next_awlen;
            rx_beat_idx  <= 8'd0;
            rx_state     <= RxW;
          end
        end
        RxW: begin
          if (m_axi_wready) begin
            rx_fifo_rd_idx <= rx_fifo_rd_idx + FifoBits'(1);
            rx_cur_addr    <= rx_cur_addr + AddrW'(8);
            rx_rem_bytes   <= (rx_rem_bytes > 12'd8) ? (rx_rem_bytes - 12'd8) : 12'd0;
            if (m_axi_wlast) begin
              rx_state <= RxB;
            end else begin
              rx_beat_idx <= rx_beat_idx + 8'd1;
            end
          end
        end
        RxB: begin
          if (m_axi_bvalid) begin
            if (m_axi_bresp != 2'b00) dma_err_count <= dma_err_count + 32'd1;
            if (rx_rem_bytes == 12'd0) begin
              rx_ring_len[rx_hw_done[RingBits-1:0]] <= {4'b0, rx_byte_cnt};
              rx_hw_done    <= rx_hw_done + PtrW'(1);
              rx_good_count <= rx_good_count + 32'd1;
              rx_state      <= RxIdle;
            end else begin
              rx_state <= RxAw;
            end
          end
        end
        default: rx_state <= RxIdle;
      endcase

      // ---- TX DMA FSM ----
      case (tx_state)
        TxIdle: begin
          if (tx_desc_avail) begin
            tx_cur_addr    <= tx_ring_addr[tx_hw_done[RingBits-1:0]];
            tx_frame_len   <= tx_ring_len[tx_hw_done[RingBits-1:0]][11:0];
            tx_rem_bytes   <= tx_ring_len[tx_hw_done[RingBits-1:0]][11:0];
            tx_fifo_wr_idx <= '0;
            tx_send_idx    <= 12'd0;
            tx_state       <= TxAr;
          end
        end
        TxAr: begin
          if (m_axi_arready) begin
            tx_state <= TxR;
          end
        end
        TxR: begin
          if (m_axi_rvalid) begin
            if (m_axi_rresp != 2'b00) dma_err_count <= dma_err_count + 32'd1;
            tx_fifo_mem[tx_fifo_wr_idx] <= m_axi_rdata;
            tx_fifo_wr_idx <= tx_fifo_wr_idx + FifoBits'(1);
            tx_cur_addr    <= tx_cur_addr + AddrW'(8);
            tx_rem_bytes   <= (tx_rem_bytes > 12'd8) ? (tx_rem_bytes - 12'd8) : 12'd0;
            if (m_axi_rlast) begin
              if (tx_rem_bytes <= 12'd8) begin
                tx_send_idx <= 12'd0;
                tx_state    <= TxPreload;
              end else begin
                tx_state <= TxAr;
              end
            end
          end
        end
        TxPreload: begin
          // 1 cycle for synchronous BRAM read of word 0
          tx_state <= TxSend;
        end
        TxSend: begin
          if (mac_tx_ready) begin
            if (tx_send_idx + 12'd1 == tx_frame_len) begin
              tx_hw_done    <= tx_hw_done + PtrW'(1);
              tx_good_count <= tx_good_count + 32'd1;
              tx_event      <= 1'b1;
              tx_state      <= TxIdle;
            end else begin
              tx_send_idx <= tx_send_idx + 12'd1;
            end
          end
        end
        default: tx_state <= TxIdle;
      endcase
    end
  end
endmodule

// Dual-clock Gray-code asynchronous FIFO with valid/ready output register.
module rapt_eth_async_fifo #(
    parameter int Width = 10,
    parameter int Depth = 2048
) (
    input  logic             wr_clk,
    input  logic             wr_rst,
    input  logic [Width-1:0] wr_data,
    input  logic             wr_valid,
    output logic             wr_ready,
    input  logic             rd_clk,
    input  logic             rd_rst,
    output logic [Width-1:0] rd_data,
    output logic             rd_valid,
    input  logic             rd_ready
);
  localparam int Aw = $clog2(Depth);
  (* ram_style = "block" *) logic [Width-1:0] mem[Depth];
  logic [Aw:0] wr_bin, wr_gray, rd_bin, rd_gray;
  (* ASYNC_REG = "TRUE" *) logic [Aw:0] wr_gray_s1, wr_gray_s2;
  (* ASYNC_REG = "TRUE" *) logic [Aw:0] rd_gray_s1, rd_gray_s2;

  wire [Aw:0] wr_bin_next = wr_bin + {{Aw{1'b0}}, 1'b1};
  wire [Aw:0] wr_gray_next = wr_bin_next ^ (wr_bin_next >> 1);
  wire [Aw:0] rd_bin_next = rd_bin + {{Aw{1'b0}}, 1'b1};
  wire [Aw:0] rd_gray_next = rd_bin_next ^ (rd_bin_next >> 1);

  wire wr_full = (wr_gray == {~rd_gray_s2[Aw:Aw-1], rd_gray_s2[Aw-2:0]});
  wire rd_empty = (rd_gray == wr_gray_s2);
  assign wr_ready = !wr_rst && !wr_full;

  // Reset-free simple dual-port BRAM inference (1x RAMB18E2 per 2048x10 FIFO)
  wire wr_fire = !wr_rst && wr_valid && !wr_full;
  wire rd_fire = !rd_rst && (!rd_valid || rd_ready) && !rd_empty;

  always_ff @(posedge wr_clk) begin
    if (wr_fire) mem[wr_bin[Aw-1:0]] <= wr_data;
  end

  always_ff @(posedge rd_clk) begin
    if (rd_fire) rd_data <= mem[rd_bin[Aw-1:0]];
  end

  always_ff @(posedge wr_clk or posedge wr_rst) begin
    if (wr_rst) begin
      wr_bin     <= '0;
      wr_gray    <= '0;
      rd_gray_s1 <= '0;
      rd_gray_s2 <= '0;
    end else begin
      rd_gray_s1 <= rd_gray;
      rd_gray_s2 <= rd_gray_s1;
      if (wr_valid && !wr_full) begin
        wr_bin  <= wr_bin_next;
        wr_gray <= wr_gray_next;
      end
    end
  end

  always_ff @(posedge rd_clk or posedge rd_rst) begin
    if (rd_rst) begin
      rd_bin     <= '0;
      rd_gray    <= '0;
      wr_gray_s1 <= '0;
      wr_gray_s2 <= '0;
      rd_valid   <= 1'b0;
    end else begin
      wr_gray_s1 <= wr_gray;
      wr_gray_s2 <= wr_gray_s1;
      if ((!rd_valid || rd_ready) && !rd_empty) begin
        rd_valid <= 1'b1;
        rd_bin   <= rd_bin_next;
        rd_gray  <= rd_gray_next;
      end else if (rd_ready) begin
        rd_valid <= 1'b0;
      end
    end
  end
endmodule

// 32-bit LiteEth stream (one-hot last_be) <-> 8-bit MAC byte-stream adapter.
module rapt_eth_stream32_adapter (
    input  logic        clk,
    input  logic        reset,
    // 32-bit RX from CM005 switch -> 8-bit RX to DMA
    input  logic [31:0] rx32_data,
    input  logic [3:0]  rx32_last_be,
    input  logic        rx32_valid,
    input  logic        rx32_last,
    output logic        rx32_ready,
    output logic [7:0]  rx8_data,
    output logic        rx8_valid,
    output logic        rx8_last,
    input  logic        rx8_ready,
    // 8-bit TX from DMA -> 32-bit TX to CM005 switch
    input  logic [7:0]  tx8_data,
    input  logic        tx8_valid,
    input  logic        tx8_last,
    output logic        tx8_ready,
    output logic [31:0] tx32_data,
    output logic [3:0]  tx32_last_be,
    output logic        tx32_valid,
    output logic        tx32_last,
    input  logic        tx32_ready
);
  // RX: 32b -> 8b
  logic [1:0] rx_idx;
  wire [1:0] rx_last_idx = !rx32_last ? 2'd3 :
      rx32_last_be[3] ? 2'd3 :
      rx32_last_be[2] ? 2'd2 :
      rx32_last_be[1] ? 2'd1 : 2'd0;

  assign rx8_valid  = rx32_valid;
  assign rx8_data   = rx32_data[rx_idx*8+:8];
  assign rx8_last   = rx32_last && (rx_idx == rx_last_idx);
  assign rx32_ready = rx8_ready && (rx_idx == rx_last_idx);

  always_ff @(posedge clk) begin
    if (reset) begin
      rx_idx <= 2'd0;
    end else if (rx32_valid && rx8_ready) begin
      rx_idx <= (rx_idx == rx_last_idx) ? 2'd0 : (rx_idx + 2'd1);
    end
  end

  // TX: 8b -> 32b
  logic [1:0]  tx_idx;
  logic [31:0] tx_accum;
  logic tx_hold_valid, tx_hold_last;
  logic [31:0] tx_hold_data;
  logic [3:0]  tx_hold_last_be;

  assign tx32_valid   = tx_hold_valid;
  assign tx32_data    = tx_hold_data;
  assign tx32_last    = tx_hold_last;
  assign tx32_last_be = tx_hold_last_be;
  assign tx8_ready    = !tx_hold_valid || tx32_ready;

  always_ff @(posedge clk) begin
    if (reset) begin
      tx_idx          <= 2'd0;
      tx_accum        <= 32'd0;
      tx_hold_valid   <= 1'b0;
      tx_hold_data    <= 32'd0;
      tx_hold_last    <= 1'b0;
      tx_hold_last_be <= 4'd0;
    end else begin
      if (tx_hold_valid && tx32_ready) tx_hold_valid <= 1'b0;
      if (tx8_valid && tx8_ready) begin
        automatic logic [31:0] next_w;
        next_w = (tx_idx == 2'd0) ? 32'd0 : tx_accum;
        next_w[tx_idx*8+:8] = tx8_data;
        if (tx8_last || tx_idx == 2'd3) begin
          tx_hold_valid   <= 1'b1;
          tx_hold_data    <= next_w;
          tx_hold_last    <= tx8_last;
          tx_hold_last_be <= tx8_last ? (4'b0001 << tx_idx) : 4'b0000;
          tx_idx          <= 2'd0;
          tx_accum        <= 32'd0;
        end else begin
          tx_accum <= next_w;
          tx_idx   <= tx_idx + 2'd1;
        end
      end
    end
  end
endmodule
