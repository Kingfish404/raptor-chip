// Two-master burst-granularity round-robin AXI4 arbiter for non-coherent DMA.
// Read and write channels arbitrate independently so TX/RX Virtqueue DMA and
// remote QEMU bridge DMA never deadlock each other.
module rapt_axi4_dma_arb #(
    parameter int XLEN = `RAPT_XLEN
) (
    input logic clk,
    input logic reset,
    axi4_if.slave m0,
    axi4_if.slave m1,
    axi4_if.master out
);
  logic rd_busy_q, rd_sel_q, rd_rr_q;
  logic wr_busy_q, wr_w_done_q, wr_sel_q, wr_rr_q;
  logic rd_pick, wr_pick;
  logic rd_grant_0, rd_grant_1;
  logic wr_grant_0, wr_grant_1;

  always_comb begin
    if (m0.arvalid && m1.arvalid) rd_pick = rd_rr_q;
    else if (m1.arvalid) rd_pick = 1'b1;
    else rd_pick = 1'b0;

    if (m0.awvalid && m1.awvalid) wr_pick = wr_rr_q;
    else if (m1.awvalid) wr_pick = 1'b1;
    else wr_pick = 1'b0;
  end

  wire rd_owner = rd_busy_q ? rd_sel_q : rd_pick;
  wire wr_owner = wr_busy_q ? wr_sel_q : wr_pick;

  assign rd_grant_0 = !reset && !rd_busy_q && m0.arvalid && (rd_pick == 1'b0);
  assign rd_grant_1 = !reset && !rd_busy_q && m1.arvalid && (rd_pick == 1'b1);
  assign wr_grant_0 = !reset && !wr_busy_q && m0.awvalid && (wr_pick == 1'b0);
  assign wr_grant_1 = !reset && !wr_busy_q && m1.awvalid && (wr_pick == 1'b1);

  // Read address channel
  assign out.arvalid = !reset && !rd_busy_q && (m0.arvalid || m1.arvalid);
  assign out.araddr  = rd_owner ? m1.araddr  : m0.araddr;
  assign out.arid    = rd_owner ? m1.arid    : m0.arid;
  assign out.arlen   = rd_owner ? m1.arlen   : m0.arlen;
  assign out.arsize  = rd_owner ? m1.arsize  : m0.arsize;
  assign out.arburst = rd_owner ? m1.arburst : m0.arburst;
  assign out.arcache = rd_owner ? m1.arcache : m0.arcache;
  assign m0.arready  = rd_grant_0 && out.arready;
  assign m1.arready  = rd_grant_1 && out.arready;

  // Read data channel
  assign m0.rvalid  = rd_busy_q && !rd_sel_q && out.rvalid;
  assign m0.rdata   = out.rdata;
  assign m0.rresp   = out.rresp;
  assign m0.rlast   = out.rlast;
  assign m0.rid     = out.rid;
  assign m1.rvalid  = rd_busy_q && rd_sel_q && out.rvalid;
  assign m1.rdata   = out.rdata;
  assign m1.rresp   = out.rresp;
  assign m1.rlast   = out.rlast;
  assign m1.rid     = out.rid;
  assign out.rready = rd_busy_q && (rd_sel_q ? m1.rready : m0.rready);

  // Write address channel (a burst owns the write channels from AW until B)
  assign out.awvalid = !reset && !wr_busy_q && (m0.awvalid || m1.awvalid);
  assign out.awaddr  = wr_owner ? m1.awaddr  : m0.awaddr;
  assign out.awid    = wr_owner ? m1.awid    : m0.awid;
  assign out.awlen   = wr_owner ? m1.awlen   : m0.awlen;
  assign out.awsize  = wr_owner ? m1.awsize  : m0.awsize;
  assign out.awburst = wr_owner ? m1.awburst : m0.awburst;
  assign out.awcache = wr_owner ? m1.awcache : m0.awcache;
  assign m0.awready  = wr_grant_0 && out.awready;
  assign m1.awready  = wr_grant_1 && out.awready;

  // Write data channel (only active once AW is accepted or concurrently accepted)
  wire wr_data_phase = (wr_busy_q && !wr_w_done_q) || (out.awvalid && out.awready);
  assign out.wvalid = !reset && wr_data_phase && (wr_owner ? m1.wvalid : m0.wvalid);
  assign out.wdata  = wr_owner ? m1.wdata : m0.wdata;
  assign out.wstrb  = wr_owner ? m1.wstrb : m0.wstrb;
  assign out.wlast  = wr_owner ? m1.wlast : m0.wlast;
  assign m0.wready  = !reset && wr_data_phase && !wr_owner && out.wready;
  assign m1.wready  = !reset && wr_data_phase && wr_owner && out.wready;

  // Write response channel
  assign m0.bvalid  = wr_busy_q && !wr_sel_q && out.bvalid;
  assign m0.bresp   = out.bresp;
  assign m0.bid     = out.bid;
  assign m1.bvalid  = wr_busy_q && wr_sel_q && out.bvalid;
  assign m1.bresp   = out.bresp;
  assign m1.bid     = out.bid;
  assign out.bready = wr_busy_q && (wr_sel_q ? m1.bready : m0.bready);

  always_ff @(posedge clk) begin
    if (reset) begin
      rd_busy_q <= 1'b0;
      rd_sel_q <= 1'b0;
      rd_rr_q <= 1'b0;
      wr_busy_q <= 1'b0;
      wr_w_done_q <= 1'b0;
      wr_sel_q <= 1'b0;
      wr_rr_q <= 1'b0;
    end else begin
      if (!rd_busy_q) begin
        if (out.arvalid && out.arready) begin
          rd_busy_q <= 1'b1;
          rd_sel_q <= rd_pick;
          rd_rr_q <= ~rd_pick;
        end
      end else if (out.rvalid && out.rready && out.rlast) begin
        rd_busy_q <= 1'b0;
      end

      if (!wr_busy_q) begin
        if (out.awvalid && out.awready) begin
          wr_busy_q <= 1'b1;
          wr_sel_q <= wr_pick;
          wr_rr_q <= ~wr_pick;
          wr_w_done_q <= out.wvalid && out.wready && out.wlast;
        end
      end else begin
        if (!wr_w_done_q && out.wvalid && out.wready && out.wlast) wr_w_done_q <= 1'b1;
        if (out.bvalid && out.bready) begin
          wr_busy_q <= 1'b0;
          wr_w_done_q <= 1'b0;
        end
      end
    end
  end
endmodule
