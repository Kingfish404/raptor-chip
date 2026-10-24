// Native Ethernet packet SRAM ABI v1. No DMA accesses to cached main memory.
// RX descriptors are published only after a complete, valid frame. Gray-coded
// slot ownership crosses clock domains; SRAM data remains stable until RX_POP.
module rapt_native_eth #(
    parameter int RxFcsBytes = 0
) (
    input logic clk,
    reset,
    input logic clocks_ready,
    input logic rd,
    wr,
    input logic [15:0] raddr,
    waddr,
    input logic [31:0] wdata,
    input logic [3:0] wstrb,
    output logic [31:0] rdata,
    output logic irq,
    output logic enabled,
    output logic [2:0] mdio_control,
    input logic mdio_input,
    input logic rx_clk,
    rx_reset,
    input logic [7:0] rx_data,
    input logic rx_valid,
    rx_last,
    rx_error,
    input logic rx_bad_fcs,
    input logic tx_clk,
    tx_reset,
    output logic [7:0] tx_data,
    output logic tx_valid,
    tx_last,
    input logic tx_ready
);
  localparam int Slots = 8;
  localparam int SlotBytes = 2048;
  localparam int MaxFrame = 1536;
  logic [1:0] irq_mask;
  logic tx_event;
  logic [3:0] rx_write_bin, rx_write_gray, rx_read_bin, rx_read_gray;
  (* ASYNC_REG = "TRUE" *) logic [3:0] rx_write_sync1, rx_write_sync2;
  (* ASYNC_REG = "TRUE" *) logic [3:0] rx_read_sync1, rx_read_sync2;
  logic [11:0] rx_length[Slots];
  (* ram_style = "block" *) logic [31:0] rx_mem[Slots*SlotBytes/4];
  (* ram_style = "block" *) logic [31:0] tx_mem[SlotBytes/4];
  logic [31:0] rx_word, read_regs;
  logic [31:0] rx_assembly, rx_packed;
  logic read_rx;
  logic [11:0] rx_count;
  logic rx_drop, rx_bad;
  logic [31:0] rx_good_count, rx_error_count, rx_drop_count, rx_crc_count;
  logic [31:0] rx_good_gray, rx_error_gray, rx_drop_gray, rx_crc_gray;
  (* ASYNC_REG = "TRUE" *) logic [31:0] good_sync1, good_sync2;
  (* ASYNC_REG = "TRUE" *) logic [31:0] error_sync1, error_sync2;
  (* ASYNC_REG = "TRUE" *) logic [31:0] drop_sync1, drop_sync2;
  (* ASYNC_REG = "TRUE" *) logic [31:0] crc_sync1, crc_sync2;
  logic tx_request, tx_done, tx_seen;
  (* ASYNC_REG = "TRUE" *) logic tx_done_sync1, tx_done_sync2;
  (* ASYNC_REG = "TRUE" *) logic tx_request_sync1, tx_request_sync2;
  logic [10:0] tx_length;
  logic [31:0] tx_good_count, tx_rejected_count;
  logic [10:0] tx_index, tx_next_index;
  logic [31:0] tx_word;
  typedef enum logic [1:0] {
    TxIdle,
    TxLoad,
    TxSend
  } tx_state_t;
  tx_state_t tx_state;
  wire rx_empty = rx_read_gray == rx_write_sync2;
  wire rx_full = rx_write_gray == {~rx_read_sync2[3:2], rx_read_sync2[1:0]};
  wire tx_busy = tx_request != tx_done_sync2;
  wire queue_reset = reset || !enabled || !clocks_ready;
  wire reg_write = wr && wstrb == 4'hf;
  wire [3:0] rx_write_next = rx_write_bin + 1'b1;
  wire [3:0] rx_read_next = rx_read_bin + 1'b1;
  wire frame_drop = rx_drop || (rx_count == 0 && rx_full);
  wire frame_bad = rx_bad || rx_error || rx_count >= 12'(MaxFrame + RxFcsBytes);

  function automatic [31:0] gray(input logic [31:0] value);
    return value ^ (value >> 1);
  endfunction
  function automatic [31:0] binary(input logic [31:0] value);
    logic [31:0] result;
    result[31] = value[31];
    for (int i = 30; i >= 0; i--) result[i] = result[i+1] ^ value[i];
    return result;
  endfunction

  assign irq = enabled && clocks_ready && ((irq_mask[0] && !rx_empty) ||
                                            (irq_mask[1] && tx_event));
  assign rdata = read_rx ? rx_word : read_regs;

  // MMIO responses are synchronous, and held until the next read request.
  always_ff @(posedge clk) begin
    if (rd) begin
      read_rx <= raddr >= 16'h4000 && raddr < 16'h8000;
      rx_word <= rx_mem[raddr[13:2]];
      case (raddr)
        16'h0000: read_regs <= 32'h524e4554;  // "RNET"
        16'h0004: read_regs <= 1;
        16'h0008: read_regs <= {31'b0, enabled};
        16'h000c: read_regs <= {29'b0, clocks_ready, !tx_busy, !rx_empty};
        16'h0010: read_regs <= {30'b0, irq_mask};
        16'h0014: read_regs <= {30'b0, tx_event, !rx_empty};
        16'h0018: read_regs <= rx_empty ? 0 : {13'b0, rx_read_bin[2:0],
                                              4'b0, rx_length[rx_read_bin[2:0]]};
        16'h0028: read_regs <= binary(good_sync2);
        16'h002c: read_regs <= binary(error_sync2);
        16'h0030: read_regs <= binary(drop_sync2);
        16'h0034: read_regs <= tx_good_count;
        16'h0038: read_regs <= tx_rejected_count;
        16'h003c: read_regs <= binary(crc_sync2);
        16'h0040: read_regs <= {29'b0, mdio_control};
        16'h0044: read_regs <= {31'b0, mdio_input};
        default: read_regs <= 0;
      endcase
    end
    if (wr && waddr >= 16'h2000 && waddr < 16'h2800 && !tx_busy) begin
      for (int b = 0; b < 4; b++) if (wstrb[b]) tx_mem[waddr[10:2]][b*8+:8] <= wdata[b*8+:8];
    end
    if (reset) begin
      enabled <= 0;
      irq_mask <= 0;
      mdio_control <= 0;
    end else if (reg_write) begin
      case (waddr)
        16'h0008: enabled <= wdata[0];
        16'h0010: irq_mask <= wdata[1:0];
        16'h0040: mdio_control <= wdata[2:0];
        default: ;
      endcase
    end
  end

  // Asynchronous assertion resets ownership even when a PHY clock disappears.
  // Deassertion of the physical rx_reset/tx_reset inputs is locally synchronized.
  always_ff @(posedge clk or posedge queue_reset) begin
    if (queue_reset) begin
      rx_read_bin <= 0;
      rx_read_gray <= 0;
      rx_write_sync1 <= 0;
      rx_write_sync2 <= 0;
      tx_done_sync1 <= 0;
      tx_done_sync2 <= 0;
      tx_seen <= 0;
      tx_request <= 0;
      tx_length <= 0;
      tx_event <= 0;
      tx_good_count <= 0;
      tx_rejected_count <= 0;
      good_sync1 <= 0;
      good_sync2 <= 0;
      error_sync1 <= 0;
      error_sync2 <= 0;
      drop_sync1 <= 0;
      drop_sync2 <= 0;
      crc_sync1 <= 0;
      crc_sync2 <= 0;
    end else begin
      rx_write_sync1 <= rx_write_gray;
      rx_write_sync2 <= rx_write_sync1;
      tx_done_sync1 <= tx_done;
      tx_done_sync2 <= tx_done_sync1;
      good_sync1 <= rx_good_gray;
      good_sync2 <= good_sync1;
      error_sync1 <= rx_error_gray;
      error_sync2 <= error_sync1;
      drop_sync1 <= rx_drop_gray;
      drop_sync2 <= drop_sync1;
      crc_sync1 <= rx_crc_gray;
      crc_sync2 <= crc_sync1;
      if (reg_write && waddr == 16'h001c && wdata[0] && !rx_empty) begin
        rx_read_bin <= rx_read_next;
        rx_read_gray <= rx_read_next ^ (rx_read_next >> 1);
      end
      if (reg_write && waddr == 16'h0014 && wdata[1]) tx_event <= 0;
      if (tx_done_sync2 != tx_seen) begin
        tx_seen <= tx_done_sync2;
        tx_event <= 1;
        tx_good_count <= tx_good_count + 1'b1;
      end
      if (reg_write && waddr == 16'h0020) begin
        if (!tx_busy && wdata >= 14 && wdata <= MaxFrame) begin
          tx_length <= wdata[10:0];
          tx_request <= !tx_request;
        end else tx_rejected_count <= tx_rejected_count + 1'b1;
      end
    end
  end

  // Assemble each word before writing SRAM. A byte-selected write to a deep
  // 32-bit memory otherwise maps to 32 narrow RAMB18s instead of four RAMB36s.
  always_comb begin
    rx_packed = rx_assembly;
    rx_packed[rx_count[1:0]*8+:8] = rx_data;
  end
  always_ff @(posedge rx_clk) begin
    if (!rx_reset && rx_valid && !frame_drop && rx_count < 12'(SlotBytes)) begin
      rx_assembly <= rx_packed;
      if (rx_count[1:0] == 3 || rx_last) rx_mem[{rx_write_bin[2:0], rx_count[10:2]}] <= rx_packed;
    end
  end
  always_ff @(posedge rx_clk or posedge rx_reset) begin
    if (rx_reset) begin
      rx_read_sync1 <= 0;
      rx_read_sync2 <= 0;
      rx_write_bin <= 0;
      rx_write_gray <= 0;
      rx_count <= 0;
      rx_drop <= 0;
      rx_bad <= 0;
      rx_good_count <= 0;
      rx_error_count <= 0;
      rx_drop_count <= 0;
      rx_crc_count <= 0;
      rx_good_gray <= 0;
      rx_error_gray <= 0;
      rx_drop_gray <= 0;
      rx_crc_gray <= 0;
    end else begin
      rx_read_sync1 <= rx_read_gray;
      rx_read_sync2 <= rx_read_sync1;
      if (rx_bad_fcs) begin
        rx_crc_count <= rx_crc_count + 1'b1;
        rx_crc_gray <= gray(rx_crc_count + 1'b1);
      end
      if (rx_valid) begin
        rx_drop <= frame_drop;
        rx_bad <= frame_bad;
        if (rx_count < 12'(SlotBytes)) rx_count <= rx_count + 1'b1;
        if (rx_last) begin
          if (frame_drop) begin
            rx_drop_count <= rx_drop_count + 1'b1;
            rx_drop_gray <= gray(rx_drop_count + 1'b1);
          end else if (frame_bad || rx_count < 12'(59 + RxFcsBytes)) begin
            rx_error_count <= rx_error_count + 1'b1;
            rx_error_gray <= gray(rx_error_count + 1'b1);
          end else begin
            // The vendored CVA6 MAC retains its four CRC bytes for debug.
            // Exclude them from the CPU descriptor after validating the frame.
            rx_length[rx_write_bin[2:0]] <= rx_count + 1'b1 - 12'(RxFcsBytes);
            rx_write_bin <= rx_write_next;
            rx_write_gray <= rx_write_next ^ (rx_write_next >> 1);
            rx_good_count <= rx_good_count + 1'b1;
            rx_good_gray <= gray(rx_good_count + 1'b1);
          end
          rx_count <= 0;
          rx_drop <= 0;
          rx_bad <= 0;
        end
      end
    end
  end

  assign tx_valid = tx_state == TxSend;
  assign tx_last = tx_index == tx_length - 1'b1;
  assign tx_data = tx_word[tx_index[1:0]*8+:8];
  assign tx_next_index = tx_valid && tx_ready ? tx_index + 1'b1 : tx_index;
  always_ff @(posedge tx_clk) tx_word <= tx_mem[tx_next_index[10:2]];
  always_ff @(posedge tx_clk or posedge tx_reset) begin
    if (tx_reset) begin
      tx_request_sync1 <= 0;
      tx_request_sync2 <= 0;
      tx_done <= 0;
      tx_index <= 0;
      tx_state <= TxIdle;
    end else begin
      tx_request_sync1 <= tx_request;
      tx_request_sync2 <= tx_request_sync1;
      case (tx_state)
        TxIdle:
        if (tx_request_sync2 != tx_done) begin
          tx_index <= 0;
          tx_state <= TxLoad;
        end
        TxLoad: tx_state <= TxSend;
        TxSend: if (tx_ready) begin
          tx_index <= tx_next_index;
          if (tx_last) begin
            tx_done <= tx_request_sync2;
            tx_state <= TxIdle;
          end
        end
        default: tx_state <= TxIdle;
      endcase
    end
  end
endmodule
