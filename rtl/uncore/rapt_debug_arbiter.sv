`include "rapt.svh"
`include "rapt_soc_if.svh"

// Two-master AXI merge. ID 15 belongs exclusively to SBA; all core IDs pass
// unchanged. AR arbitration is round-robin per address, AW/W per complete
// address + data burst. An offered request keeps its owner through stalls.
// Responses route by ID independently, preserving core outstanding capacity.
// core_block_i stops new core offers. Already offered AW/W and AR drain with
// the core still alive; core_idle_o then permits resetting the core and L2.
module rapt_debug_arbiter #(
    parameter int XLEN = `RAPT_XLEN,
    parameter int CoreReadOutstanding = 32,
    parameter int CoreWriteOutstanding = 1
) (
    input logic clock,
    input logic reset,
    input logic core_block_i,
    output logic core_idle_o,
    axi4_if.slave core_axi,
    axi4_if.slave sb_axi,
    axi4_if.master merged_axi
);
  localparam logic [3:0] SbaId = 4'hf;
  localparam int ReadCountBits = $clog2(CoreReadOutstanding + 1);
  localparam int WriteCountBits = $clog2(CoreWriteOutstanding + 1);
  logic [ ReadCountBits-1:0] core_reads_q;
  logic [WriteCountBits-1:0] core_writes_q;
  logic read_lock_q, read_owner_q, read_turn_q, read_owner;
  logic write_lock_q, write_owner_q, write_turn_q, write_owner;
  logic aw_done_q, w_done_q, aw_done, w_done;
  logic read_core_allowed, write_core_allowed;
  logic core_ar_fire, core_r_fire, core_aw_fire, core_b_fire;
  logic response_to_sb, bresponse_to_sb;

  assign read_core_allowed = !core_block_i || (read_lock_q && !read_owner_q);
  assign read_owner = read_lock_q ? read_owner_q
      : sb_axi.arvalid && (!core_axi.arvalid || !read_core_allowed || read_turn_q);
  assign merged_axi.arvalid = read_owner ? sb_axi.arvalid : core_axi.arvalid && read_core_allowed;
  assign merged_axi.araddr = read_owner ? sb_axi.araddr : core_axi.araddr;
  assign merged_axi.arid = read_owner ? SbaId : core_axi.arid;
  assign merged_axi.arlen = read_owner ? sb_axi.arlen : core_axi.arlen;
  assign merged_axi.arsize = read_owner ? sb_axi.arsize : core_axi.arsize;
  assign merged_axi.arburst = read_owner ? sb_axi.arburst : core_axi.arburst;
  assign merged_axi.arcache = read_owner ? sb_axi.arcache : core_axi.arcache;
  assign sb_axi.arready = read_owner && merged_axi.arready;
  assign core_axi.arready = !read_owner && read_core_allowed && merged_axi.arready;

  assign response_to_sb = merged_axi.rid == SbaId;
  assign sb_axi.rvalid = merged_axi.rvalid && response_to_sb;
  assign core_axi.rvalid = merged_axi.rvalid && !response_to_sb;
  assign sb_axi.rid = merged_axi.rid;
  assign core_axi.rid = merged_axi.rid;
  assign sb_axi.rdata = merged_axi.rdata;
  assign core_axi.rdata = merged_axi.rdata;
  assign sb_axi.rresp = merged_axi.rresp;
  assign core_axi.rresp = merged_axi.rresp;
  assign sb_axi.rlast = merged_axi.rlast;
  assign core_axi.rlast = merged_axi.rlast;
  assign merged_axi.rready = response_to_sb ? sb_axi.rready : core_axi.rready;

  // W has no ID in AXI4. Keep one owner until BOTH AW and WLAST handshake,
  // including W-before-AW. B routing does not hold the AW/W arbitration lock.
  assign write_core_allowed = !core_block_i || (write_lock_q && !write_owner_q);
  assign write_owner = write_lock_q ? write_owner_q
      : sb_axi.awvalid && (!core_axi.awvalid || !write_core_allowed || write_turn_q);
  assign merged_axi.awvalid = !aw_done_q && (write_owner ? sb_axi.awvalid
      : core_axi.awvalid && write_core_allowed);
  assign merged_axi.awaddr = write_owner ? sb_axi.awaddr : core_axi.awaddr;
  assign merged_axi.awid = write_owner ? SbaId : core_axi.awid;
  assign merged_axi.awlen = write_owner ? sb_axi.awlen : core_axi.awlen;
  assign merged_axi.awsize = write_owner ? sb_axi.awsize : core_axi.awsize;
  assign merged_axi.awburst = write_owner ? sb_axi.awburst : core_axi.awburst;
  assign merged_axi.awcache = write_owner ? sb_axi.awcache : core_axi.awcache;
  assign sb_axi.awready = write_owner && !aw_done_q && merged_axi.awready;
  assign core_axi.awready = !write_owner && !aw_done_q && write_core_allowed && merged_axi.awready;
  // Before taking a lock, only offer W with that master's valid AW.
  logic write_offer;
  assign write_offer = write_lock_q || merged_axi.awvalid;
  assign merged_axi.wvalid = write_offer && !w_done_q
      && (write_owner ? sb_axi.wvalid : core_axi.wvalid);
  assign merged_axi.wdata = write_owner ? sb_axi.wdata : core_axi.wdata;
  assign merged_axi.wstrb = write_owner ? sb_axi.wstrb : core_axi.wstrb;
  assign merged_axi.wlast = write_owner ? sb_axi.wlast : core_axi.wlast;
  assign sb_axi.wready = write_owner && write_offer && !w_done_q && merged_axi.wready;
  assign core_axi.wready = !write_owner && write_offer && !w_done_q && merged_axi.wready;
  assign aw_done = aw_done_q || (merged_axi.awvalid && merged_axi.awready);
  assign w_done = w_done_q || (merged_axi.wvalid && merged_axi.wready && merged_axi.wlast);

  assign bresponse_to_sb = merged_axi.bid == SbaId;
  assign sb_axi.bvalid = merged_axi.bvalid && bresponse_to_sb;
  assign core_axi.bvalid = merged_axi.bvalid && !bresponse_to_sb;
  assign sb_axi.bid = merged_axi.bid;
  assign core_axi.bid = merged_axi.bid;
  assign sb_axi.bresp = merged_axi.bresp;
  assign core_axi.bresp = merged_axi.bresp;
  assign merged_axi.bready = bresponse_to_sb ? sb_axi.bready : core_axi.bready;

  assign core_ar_fire = core_axi.arvalid && core_axi.arready;
  assign core_r_fire = core_axi.rvalid && core_axi.rready && core_axi.rlast;
  assign core_aw_fire = core_axi.awvalid && core_axi.awready;
  assign core_b_fire = core_axi.bvalid && core_axi.bready;
  assign core_idle_o = core_reads_q == 0 && core_writes_q == 0
      && !(read_lock_q && !read_owner_q) && !(write_lock_q && !write_owner_q);

  always_ff @(posedge clock) begin
    if (reset) begin
      read_lock_q <= 1'b0;
      read_owner_q <= 1'b0;
      read_turn_q <= 1'b1;
      write_lock_q <= 1'b0;
      write_owner_q <= 1'b0;
      write_turn_q <= 1'b1;
      aw_done_q <= 1'b0;
      w_done_q <= 1'b0;
      core_reads_q <= '0;
      core_writes_q <= '0;
    end else begin
      if (merged_axi.arvalid) begin
        read_lock_q  <= !merged_axi.arready;
        read_owner_q <= read_owner;
        if (merged_axi.arready) read_turn_q <= !read_owner;
      end
      if (write_offer) begin
        write_lock_q <= !(aw_done && w_done);
        write_owner_q <= write_owner;
        aw_done_q <= aw_done && !w_done;
        w_done_q <= w_done && !aw_done;
        if (aw_done && w_done) write_turn_q <= !write_owner;
      end
      case ({
        core_ar_fire, core_r_fire
      })
        2'b10:   core_reads_q <= core_reads_q + 1'b1;
        2'b01:   core_reads_q <= core_reads_q - 1'b1;
        default: ;
      endcase
      case ({
        core_aw_fire, core_b_fire
      })
        2'b10:   core_writes_q <= core_writes_q + 1'b1;
        2'b01:   core_writes_q <= core_writes_q - 1'b1;
        default: ;
      endcase
    end
  end

  `RAPT_SVA_IMPLY(clock, reset, DEBUG_CORE_AR_ID, core_ar_fire, core_axi.arid != SbaId)
  `RAPT_SVA_IMPLY(clock, reset, DEBUG_CORE_AW_ID, core_aw_fire, core_axi.awid != SbaId)
  `RAPT_SVA_IMPLY(clock, reset, DEBUG_READ_COUNT, core_r_fire, core_reads_q != 0)
  `RAPT_SVA_IMPLY(clock, reset, DEBUG_WRITE_COUNT, core_b_fire, core_writes_q != 0)
`ifdef RAPT_SVA_ACTIVE
  logic [XLEN+20:0] ar_payload, aw_payload;
  logic [XLEN+XLEN/8:0] w_payload;
  assign ar_payload = {
    merged_axi.araddr,
    merged_axi.arid,
    merged_axi.arlen,
    merged_axi.arsize,
    merged_axi.arburst,
    merged_axi.arcache
  };
  assign aw_payload = {
    merged_axi.awaddr,
    merged_axi.awid,
    merged_axi.awlen,
    merged_axi.awsize,
    merged_axi.awburst,
    merged_axi.awcache
  };
  assign w_payload = {merged_axi.wdata, merged_axi.wstrb, merged_axi.wlast};
  `RAPT_SVA_NEXT(clock, reset, DEBUG_AR_STABLE, merged_axi.arvalid && !merged_axi.arready,
                 merged_axi.arvalid && $stable(ar_payload))
  `RAPT_SVA_NEXT(clock, reset, DEBUG_AW_STABLE, merged_axi.awvalid && !merged_axi.awready,
                 merged_axi.awvalid && $stable(aw_payload))
  `RAPT_SVA_NEXT(clock, reset, DEBUG_W_STABLE, merged_axi.wvalid && !merged_axi.wready,
                 merged_axi.wvalid && $stable(w_payload))
`endif
endmodule
