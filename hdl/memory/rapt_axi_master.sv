`include "rapt.svh"
`include "rapt_soc_if.svh"

module rapt_axi_master #(
    parameter int XLEN = `RAPT_XLEN,
    parameter int ID_W = 4,
    parameter int MAX_READ_OUTSTANDING = 8,
    // Accepted writes whose B response is still pending. One keeps the
    // original single-transaction behavior; larger values let a posting
    // requester stream independent writes behind earlier B responses.
    parameter int MAX_WRITE_OUTSTANDING = 1
) (
    input logic clock,
    input logic reset,

    mem_link_if.slave mem,
    axi4_if.master axi
);
  localparam int ReadCountW = $clog2(MAX_READ_OUTSTANDING + 1);
  localparam int AddrLsbW   = $clog2(XLEN / 8);

  logic [ReadCountW-1:0] read_outstanding;
  logic read_capacity;
  logic read_request_fire;
  logic read_response_fire;

  assign read_capacity = read_outstanding < ReadCountW'(MAX_READ_OUTSTANDING);
  assign axi.arvalid = mem.rd_req_valid && read_capacity;
  assign axi.arid = mem.rd_req_id;
  assign axi.araddr = mem.rd_req_addr;
  assign axi.arsize = mem.rd_req_size;
  assign axi.arlen = mem.rd_req_len;
  assign axi.arburst = mem.rd_req_burst;
  assign axi.arcache = rapt_pkg::axi_cache_attr(mem.rd_req_addr, mem.rd_req_pbmt)
      & (mem.rd_req_noallocate ? 4'b0011 : 4'b1111);
  assign mem.rd_req_ready = axi.arready && read_capacity;
  assign read_request_fire = mem.rd_req_valid && mem.rd_req_ready;

  assign mem.rd_rsp_valid = axi.rvalid;
  assign mem.rd_rsp_id = axi.rid;
  assign mem.rd_rsp_data = axi.rdata;
  assign mem.rd_rsp_last = axi.rlast;
  assign mem.rd_rsp_error = axi.rresp != 2'b00;
  assign axi.rready = mem.rd_rsp_ready;
  assign read_response_fire = mem.rd_rsp_valid && mem.rd_rsp_ready && mem.rd_rsp_last;

  always_ff @(posedge clock) begin
    if (reset) begin
      read_outstanding <= '0;
    end else begin
      unique case ({
        read_request_fire, read_response_fire
      })
        2'b10: read_outstanding <= read_outstanding + 1'b1;
        2'b01: read_outstanding <= read_outstanding - 1'b1;
        default: read_outstanding <= read_outstanding;
      endcase
    end
  end

`ifndef SYNTHESIS
  // Response-ownership observer only. The aggregate read_outstanding above
  // remains functional hardware because it controls admission capacity.
  localparam int IdCount = 1 << ID_W;
  logic [ReadCountW-1:0] read_id_outstanding[IdCount];
  always_ff @(posedge clock) begin
    if (reset) begin
      for (int id = 0; id < IdCount; id++) read_id_outstanding[id] <= '0;
    end else begin
      for (int id = 0; id < IdCount; id++) begin
        unique case ({
          read_request_fire && (mem.rd_req_id == ID_W'(id)),
          read_response_fire && (mem.rd_rsp_id == ID_W'(id))
        })
          2'b10: read_id_outstanding[id] <= read_id_outstanding[id] + 1'b1;
          2'b01: read_id_outstanding[id] <= read_id_outstanding[id] - 1'b1;
          default: read_id_outstanding[id] <= read_id_outstanding[id];
        endcase
      end
    end
  end
`endif

  localparam int ZeroBeats   = 64 / (XLEN / 8);
  localparam int WriteCountW = $clog2(MAX_WRITE_OUTSTANDING + 1);
  typedef struct packed {
    logic zero;
    logic [ID_W-1:0] id;
    logic [XLEN-1:0] addr;
    logic [2:0] size;
    logic [3:0] cache;
    logic [XLEN-1:0] data;
    logic [XLEN/8-1:0] strb;
  } write_request_t;
  // `write_*` is the AXI-facing stage; `write_skid` holds one accepted request
  // while the stage is still handshaking, so acceptance never depends on the
  // AXI ready inputs and back-to-back posted writes need no idle cycle.
  write_request_t write_stage /* verilator public_flat_rd */;
  write_request_t write_skid /* verilator public_flat_rd */;
  write_request_t write_accept;
  logic write_skid_valid /* verilator public_flat_rd */;
  logic [$clog2(ZeroBeats)-1:0] write_beat;
  logic write_aw_pending;
  logic write_w_pending /* verilator public_flat_rd */;
  logic [WriteCountW-1:0] write_outstanding;
  logic write_stage_done, write_stage_free;
  logic write_request_fire;
  logic write_response_fire;
  logic [AddrLsbW-1:0] write_addr_offset;
  logic [AddrLsbW-1:0] write_last_byte;
  logic [AddrLsbW:0] write_last_lane;
  logic [2:0] write_cover_size;

  assign mem.wr_req_ready = !write_skid_valid
      && write_outstanding < WriteCountW'(MAX_WRITE_OUTSTANDING);
  assign write_request_fire = mem.wr_req_valid && mem.wr_req_ready;
  assign write_addr_offset = mem.wr_req_addr[AddrLsbW-1:0];

  // WSTRB is right-aligned at mem.wr_req_addr. An unaligned AXI beat ends
  // at the next *size-aligned* boundary, not at AWADDR + (1 << AWSIZE).
  // For example, SW at byte offset 1 has lanes 1..4: AWSIZE=2 only permits
  // lanes 1..3. Widen that beat to cover lane 4, keeping its address and
  // exact strobes. Already aligned/narrow writes (including MMIO) retain
  // their requested size. The upstream store splitter owns bus-word spans.
  always_comb begin
    write_last_byte = '0;
    for (int byte_idx = 0; byte_idx < XLEN / 8; byte_idx++) begin
      if (mem.wr_req_strb[byte_idx]) write_last_byte = AddrLsbW'(byte_idx);
    end
    write_last_lane = {1'b0, write_addr_offset} + {1'b0, write_last_byte};
    write_cover_size = mem.wr_req_size;
    for (int level = 0; level < AddrLsbW; level++) begin
      if ((write_last_lane >> level) != ({1'b0, write_addr_offset} >> level)
          && write_cover_size < 3'(level + 1))
        write_cover_size = 3'(level + 1);
    end
  end

  always_comb begin
    write_accept.zero = mem.wr_req_zero;
    write_accept.id = mem.wr_req_id;
    write_accept.addr = mem.wr_req_zero ? {mem.wr_req_addr[XLEN-1:6], 6'b0} : mem.wr_req_addr;
    write_accept.size = mem.wr_req_zero ? 3'($clog2(XLEN/8)) : write_cover_size;
    // The BOOM-layout L2 owns cacheable store completion and needs the
    // bufferable attribute to perform local write-back/allocate. Other
    // presets retain the final-destination B response for SQ/MBERR.
`ifdef RAPT_L2_STORE_WRITEBACK
    write_accept.cache = rapt_pkg::axi_cache_attr(mem.wr_req_addr, mem.wr_req_pbmt);
`else
    write_accept.cache = rapt_pkg::axi_cache_attr(mem.wr_req_addr, mem.wr_req_pbmt) & 4'b1110;
`endif
    write_accept.data = mem.wr_req_zero ? '0 : mem.wr_req_data << (write_addr_offset * 8);
    write_accept.strb = mem.wr_req_zero ? '1 : mem.wr_req_strb << write_addr_offset;
  end

  assign axi.awvalid = write_aw_pending;
  assign axi.awid = write_stage.id;
  assign axi.awaddr = write_stage.addr;
  assign axi.awsize = write_stage.size;
  assign axi.awcache = write_stage.cache;
  assign axi.awlen = write_stage.zero ? 8'(ZeroBeats - 1) : 8'h00;
  assign axi.awburst = write_stage.zero ? 2'b01 : 2'b00;

  assign axi.wvalid = write_w_pending;
  assign axi.wdata = write_stage.data;
  assign axi.wstrb = write_stage.strb;
  assign axi.wlast = !write_stage.zero || write_beat == $clog2(ZeroBeats)'(ZeroBeats - 1);

  // B can only follow a completed AW/W pair; with a single outstanding write
  // this is the original "stage drained" condition.
  assign mem.wr_rsp_valid = write_outstanding != '0 && axi.bvalid
      && (MAX_WRITE_OUTSTANDING > 1 || (!write_aw_pending && !write_w_pending));
  assign mem.wr_rsp_id = axi.bid;
  assign mem.wr_rsp_error = axi.bresp != 2'b00;
  assign axi.bready = write_outstanding != '0 && mem.wr_rsp_ready
      && (MAX_WRITE_OUTSTANDING > 1 || (!write_aw_pending && !write_w_pending));
  assign write_response_fire = mem.wr_rsp_valid && mem.wr_rsp_ready;

  assign write_stage_done = (!write_aw_pending || axi.awready)
      && (!write_w_pending || (axi.wready && axi.wlast));
  assign write_stage_free = !write_aw_pending && !write_w_pending;

  always_ff @(posedge clock) begin
    if (reset) begin
      write_stage <= '0;
      write_skid <= '0;
      write_skid_valid <= 1'b0;
      write_beat <= '0;
      write_aw_pending <= 1'b0;
      write_w_pending <= 1'b0;
      write_outstanding <= '0;
    end else begin
      unique case ({
        write_request_fire, write_response_fire
      })
        2'b10: write_outstanding <= write_outstanding + 1'b1;
        2'b01: write_outstanding <= write_outstanding - 1'b1;
        default: write_outstanding <= write_outstanding;
      endcase
      if (axi.awvalid && axi.awready) write_aw_pending <= 1'b0;
      if (axi.wvalid && axi.wready) begin
        if (axi.wlast) write_w_pending <= 1'b0;
        else write_beat <= write_beat + 1'b1;
      end
      // Refill the AXI stage once its current request has issued both
      // channels. The skid entry is always older than a same-edge request.
      if (write_stage_free || write_stage_done) begin
        if (write_skid_valid) begin
          write_stage <= write_skid;
          write_aw_pending <= 1'b1;
          write_w_pending <= 1'b1;
          write_beat <= '0;
          write_skid_valid <= 1'b0;
        end else if (write_request_fire) begin
          write_stage <= write_accept;
          write_aw_pending <= 1'b1;
          write_w_pending <= 1'b1;
          write_beat <= '0;
        end
      end
      if (write_request_fire && !((write_stage_free || write_stage_done) && !write_skid_valid)) begin
        write_skid <= write_accept;
        write_skid_valid <= 1'b1;
      end
    end
  end

  `RAPT_SVA_IMPLY(
      clock, reset, AXI_READ_RESPONSE_OWNED, axi.rvalid,
      (read_id_outstanding[axi.rid] != '0) || (read_request_fire && (mem.rd_req_id == axi.rid)))
  `RAPT_SVA_IMPLY(clock, reset, AXI_WRITE_RESPONSE_OWNED, axi.bvalid, write_outstanding != '0)
  `RAPT_SVA_IMPLY(clock, reset, AXI_WRITE_RESPONSE_ID, axi.bvalid && MAX_WRITE_OUTSTANDING == 1,
                  axi.bid == write_stage.id)
  `RAPT_SVA_IMPLY(clock, reset, AXI_WRITE_SKID_BEHIND_STAGE, write_skid_valid,
                  write_aw_pending || write_w_pending)
  `RAPT_SVA_IMPLY(clock, reset, AXI_WRITE_REQUEST_FITS_WORD, write_request_fire && !mem.wr_req_zero,
                  write_last_lane < (AddrLsbW + 1)'(XLEN / 8) && mem.wr_req_size <= 3'(AddrLsbW))
  for (genvar lane = 0; lane < XLEN / 8; lane++) begin : g_write_lane_check
    `RAPT_SVA_IMPLY(clock, reset, AXI_WRITE_STROBE_WITHIN_SIZE,
                    axi.wvalid && write_stage.strb[lane],
                    lane >= int'(write_stage.addr[AddrLsbW-1:0])
                    && (lane >> write_stage.size) == (int'(write_stage.addr[AddrLsbW-1:0]) >> write_stage.size))
  end

endmodule
