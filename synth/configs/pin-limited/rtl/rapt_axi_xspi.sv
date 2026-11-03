`include "rapt_soc_if.svh"

// rapt_axi_xspi: AXI4 slave to a pin-limited octal SDR link. Not JEDEC xSPI.
//
// One AXI transaction is one CS_N frame, with bytes sent in this order:
//   request:  command, XLEN/8, id, len, {burst, size}, cache, address (LSB first)
//   write:    for each beat, data (LSB first) then strobe
//   turn:     one dummy byte with DQ released by this end
//   status:   polled until bit 7 is set; bits 1:0 carry the AXI response
//   read:     all beats, LSB first, after the status byte
//
// The target buffers a whole read burst before it reports status, so there is
// no per-beat flow control on the pins. One outstanding transaction at a time.
//
// CtrlAddr and SramCtrlAddr are served locally and never reach the pins.
// CtrlAddr bits 3:0 hold the SCLK half period in core clocks. Software may
// shorten it once the board allows; values below 2 are ignored.
module rapt_axi_xspi #(
    parameter int XLEN = `RAPT_XLEN,
    parameter logic [31:0] CtrlAddr = 32'h0010_0800,
    parameter logic [31:0] SramCtrlAddr = CtrlAddr + 32'd4,
    parameter logic [3:0] ResetHalfPeriod = 4'd4
) (
    input logic clock,
    input logic reset,
    output rapt_pkg::sram_ctrl_t sram_ctrl_o,
    axi4_if.slave axi,
    output logic sclk_o,
    output logic cs_n_o,
    output logic [7:0] dq_o,
    output logic dq_oe_o,
    input logic [7:0] dq_i
);
  localparam int Bytes = XLEN / 8;
  localparam int SramCtrlLane = int'(SramCtrlAddr % Bytes);
  localparam logic [XLEN-1:2] SramCtrlWord = (XLEN - 2)'(SramCtrlAddr >> 2);
  localparam logic [7:0] CmdRead = 8'ha1;
  localparam logic [7:0] CmdWrite = 8'ha2;
  localparam logic [3:0] HeaderLast = 4'(5 + Bytes);
  localparam logic [3:0] DataLast = 4'(Bytes - 1);

  typedef enum logic [3:0] {
    IDLE,
    HEADER,
    WRITE_WAIT,
    WRITE_DATA,
    WRITE_STRB,
    TURN,
    STATUS,
    READ_DATA,
    READ_RESP,
    WRITE_RESP,
    CTRL_WRITE,
    CTRL_READ,
    CTRL_RESP
  } state_t;
  state_t state_q;
  logic write_q, prefer_write_q;
  logic [3:0] id_q, cache_q, half_period_q, gap_q;
  logic [1:0] burst_q, resp_q;
  logic [2:0] size_q;
  logic [7:0] len_q, beat_q;
  logic [XLEN-1:0] addr_q, data_q;
  logic [Bytes-1:0] strb_q;
  logic [3:0] index_q;
  logic byte_valid, byte_write, byte_done, last_beat, idle_ready;
  logic [7:0] byte_tx, byte_rx;
  wire aw_sram_ctrl = axi.awaddr[XLEN-1:2] == SramCtrlWord;
  wire ar_sram_ctrl = axi.araddr[XLEN-1:2] == SramCtrlWord;

  // CS_N stays high long enough for a slower target to see the frame end.
  assign idle_ready = state_q == IDLE && gap_q == '0;
  assign last_beat = beat_q == len_q;
  assign axi.awready = idle_ready && (prefer_write_q || !axi.arvalid);
  assign axi.arready = idle_ready && (!prefer_write_q || !axi.awvalid);
  assign axi.wready = state_q == WRITE_WAIT || state_q == CTRL_WRITE;
  assign axi.rvalid = state_q == READ_RESP || state_q == CTRL_READ;
  assign axi.rid = id_q;
  assign axi.rdata = data_q;
  assign axi.rresp = resp_q;
  assign axi.rlast = last_beat;
  assign axi.bvalid = state_q == WRITE_RESP || state_q == CTRL_RESP;
  assign axi.bid = id_q;
  assign axi.bresp = resp_q;

  always_comb begin
    byte_valid = 1'b0;
    byte_write = 1'b0;
    byte_tx = '0;
    case (state_q)
      HEADER: begin
        byte_valid = 1'b1;
        byte_write = 1'b1;
        case (index_q)
          4'd0: byte_tx = write_q ? CmdWrite : CmdRead;
          4'd1: byte_tx = 8'(Bytes);
          4'd2: byte_tx = {4'b0, id_q};
          4'd3: byte_tx = len_q;
          4'd4: byte_tx = {3'b0, burst_q, size_q};
          4'd5: byte_tx = {4'b0, cache_q};
          default: byte_tx = addr_q[8*(int'(index_q)-6)+:8];
        endcase
      end
      WRITE_DATA: begin
        byte_valid = 1'b1;
        byte_write = 1'b1;
        byte_tx = data_q[8*int'(index_q)+:8];
      end
      WRITE_STRB: begin
        byte_valid = 1'b1;
        byte_write = 1'b1;
        byte_tx = 8'(strb_q);
      end
      TURN, STATUS, READ_DATA: byte_valid = 1'b1;
      default: ;
    endcase
  end

  rapt_xspi_byte u_byte (
      .clock(clock),
      .reset(reset),
      .active_i(state_q != IDLE && state_q != CTRL_WRITE && state_q != CTRL_READ
          && state_q != CTRL_RESP),
      .valid_i(byte_valid),
      .write_i(byte_write),
      .data_i(byte_tx),
      .half_period_i(half_period_q),
      .data_o(byte_rx),
      .done_o(byte_done),
      .sclk_o(sclk_o),
      .cs_n_o(cs_n_o),
      .dq_o(dq_o),
      .dq_oe_o(dq_oe_o),
      .dq_i(dq_i)
  );

  always_ff @(posedge clock) begin
    if (reset) begin
      state_q <= IDLE;
      write_q <= 1'b0;
      prefer_write_q <= 1'b0;
      half_period_q <= ResetHalfPeriod;
      sram_ctrl_o <= rapt_pkg::SramCtrlReset;
      gap_q <= '0;
      id_q <= '0;
      cache_q <= '0;
      burst_q <= '0;
      resp_q <= '0;
      size_q <= '0;
      len_q <= '0;
      beat_q <= '0;
      addr_q <= '0;
      data_q <= '0;
      strb_q <= '0;
      index_q <= '0;
    end else begin
      if (gap_q != '0) gap_q <= gap_q - 4'd1;
      case (state_q)
        IDLE: begin
          index_q <= '0;
          beat_q <= '0;
          resp_q <= '0;
          if (axi.awvalid && axi.awready) begin
            write_q <= 1'b1;
            prefer_write_q <= 1'b0;
            id_q <= axi.awid;
            addr_q <= axi.awaddr;
            len_q <= axi.awlen;
            size_q <= axi.awsize;
            burst_q <= axi.awburst;
            cache_q <= axi.awcache;
            state_q <= (32'(axi.awaddr) == CtrlAddr || aw_sram_ctrl) ? CTRL_WRITE : HEADER;
            if (aw_sram_ctrl && (axi.awaddr[1:0] != 0 || axi.awsize != 3'd2 || axi.awlen != 0))
              resp_q <= 2'b10;
          end else if (axi.arvalid && axi.arready) begin
            write_q <= 1'b0;
            prefer_write_q <= 1'b1;
            id_q <= axi.arid;
            addr_q <= axi.araddr;
            len_q <= axi.arlen;
            size_q <= axi.arsize;
            burst_q <= axi.arburst;
            cache_q <= axi.arcache;
            data_q <= ar_sram_ctrl ? (XLEN'(sram_ctrl_o) << (8 * SramCtrlLane))
                : XLEN'(half_period_q);
            state_q <= (32'(axi.araddr) == CtrlAddr || ar_sram_ctrl) ? CTRL_READ : HEADER;
            if (ar_sram_ctrl && (axi.araddr[1:0] != 0 || axi.arsize != 3'd2 || axi.arlen != 0))
              resp_q <= 2'b10;
          end
        end
        HEADER:
        if (byte_done) begin
          if (index_q == HeaderLast) begin
            index_q <= '0;
            state_q <= write_q ? WRITE_WAIT : TURN;
          end else index_q <= index_q + 4'd1;
        end
        WRITE_WAIT:
        if (axi.wvalid) begin
          data_q <= axi.wdata;
          strb_q <= axi.wstrb;
          index_q <= '0;
          state_q <= WRITE_DATA;
        end
        WRITE_DATA:
        if (byte_done) begin
          if (index_q == DataLast) state_q <= WRITE_STRB;
          else index_q <= index_q + 4'd1;
        end
        WRITE_STRB:
        if (byte_done) begin
          if (last_beat) state_q <= TURN;
          else begin
            beat_q <= beat_q + 8'd1;
            state_q <= WRITE_WAIT;
          end
        end
        TURN: if (byte_done) state_q <= STATUS;
        STATUS:
        if (byte_done && byte_rx[7]) begin
          resp_q <= byte_rx[1:0];
          index_q <= '0;
          state_q <= write_q ? WRITE_RESP : READ_DATA;
        end
        READ_DATA:
        if (byte_done) begin
          data_q[8*int'(index_q)+:8] <= byte_rx;
          if (index_q == DataLast) state_q <= READ_RESP;
          else index_q <= index_q + 4'd1;
        end
        READ_RESP:
        if (axi.rready) begin
          if (last_beat) begin
            state_q <= IDLE;
            gap_q <= half_period_q;
          end else begin
            beat_q <= beat_q + 8'd1;
            index_q <= '0;
            state_q <= READ_DATA;
          end
        end
        WRITE_RESP, CTRL_RESP:
        if (axi.bready) begin
          state_q <= IDLE;
          gap_q <= half_period_q;
        end
        CTRL_WRITE:
        if (axi.wvalid) begin
          if (addr_q[XLEN-1:2] == SramCtrlWord) begin
            if (resp_q == 0) begin
              if (axi.wstrb[SramCtrlLane]) sram_ctrl_o[7:0] <= axi.wdata[8*SramCtrlLane+:8];
              if (axi.wstrb[SramCtrlLane+1])
                sram_ctrl_o[15:8] <= {1'b0, axi.wdata[8*(SramCtrlLane+1)+:7]};
            end
          end else if (axi.wstrb[0] && axi.wdata[3:0] >= 4'd2) half_period_q <= axi.wdata[3:0];
          if (axi.wlast) state_q <= CTRL_RESP;
        end
        CTRL_READ:
        if (axi.rready) begin
          if (last_beat) state_q <= IDLE;
          else beat_q <= beat_q + 8'd1;
        end
        default: state_q <= IDLE;
      endcase
    end
  end

  `RAPT_SVA(clock, reset, SRAM_CTRL_RESERVED_ZERO, !sram_ctrl_o.reserved)
`ifdef RAPT_SVA_ACTIVE
  wire sram_ctrl_write = state_q == CTRL_WRITE && addr_q == XLEN'(SramCtrlAddr)
      && axi.wvalid && resp_q == 0;
`endif
  `RAPT_SVA_NEXT(clock, reset, SRAM_CTRL_HOLD, !sram_ctrl_write, $stable(sram_ctrl_o))
endmodule
