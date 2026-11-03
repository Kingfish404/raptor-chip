`include "rapt.svh"
`include "rapt_soc_if.svh"

// Legal AXI sources hold stalled requests. Responses may stall forever and may
// return core IDs out of order. The environment respects the configured credit
// limit and does not return a core response before its address was accepted.
module formal_debug_arbiter #(
    parameter int Capacity = 2,
    parameter int WriteCapacity = Capacity,
    parameter int XLEN = `RAPT_XLEN
) (
    input logic clock,
    input logic reset,
    input logic core_block,
    output logic idle,
    axi4_if.slave core_axi,
    axi4_if.slave sb_axi,
    axi4_if.master merged_axi
);
  rapt_debug_arbiter #(
      .XLEN(XLEN),
      .CoreReadOutstanding(Capacity),
      .CoreWriteOutstanding(WriteCapacity)
  ) dut (
      .clock,
      .reset,
      .core_block_i(core_block),
      .core_idle_o(idle),
      .core_axi,
      .sb_axi,
      .merged_axi
  );
  logic past_valid = 0;
  localparam int CountBits = $clog2(Capacity + 1);
  logic [CountBits-1:0] reads;
  logic [$clog2(WriteCapacity+1)-1:0] writes;
  wire ar_fire = core_axi.arvalid && core_axi.arready;
  wire r_fire = core_axi.rvalid && core_axi.rready && core_axi.rlast;
  wire aw_fire = core_axi.awvalid && core_axi.awready;
  wire b_fire = core_axi.bvalid && core_axi.bready;
  wire bus_ar_fire = merged_axi.arvalid && merged_axi.arready;
  wire bus_aw_fire = merged_axi.awvalid && merged_axi.awready;
  wire bus_w_fire = merged_axi.wvalid && merged_axi.wready && merged_axi.wlast;
  wire current_read_sb = merged_axi.arid == 15;
  wire current_write_sb = merged_axi.awid == 15;
  logic held_read, held_read_sb, held_write, held_write_sb;
  logic aw_seen, w_seen, last_read_sb;
  wire write_active = held_write || merged_axi.awvalid;
  wire write_sb = held_write ? held_write_sb : current_write_sb;
  wire next_aw = aw_seen || bus_aw_fire;
  wire next_w = w_seen || bus_w_fire;

  always_ff @(posedge clock) begin
    past_valid <= 1;
    if (!past_valid) assume (reset);
    if (reset) begin
      reads <= 0;
      writes <= 0;
      held_read <= 0;
      held_read_sb <= 0;
      held_write <= 0;
      held_write_sb <= 0;
      aw_seen <= 0;
      w_seen <= 0;
      last_read_sb <= 0;
    end else begin
      if (core_axi.arvalid) assume (core_axi.arid != 15);
      if (core_axi.awvalid) assume (core_axi.awid != 15);
      if (merged_axi.rvalid && merged_axi.rid != 15) assume (reads != 0);
      if (merged_axi.bvalid && merged_axi.bid != 15) assume (writes != 0);
      if (ar_fire && !r_fire) assume (reads < Capacity);
      if (aw_fire && !b_fire) assume (writes < WriteCapacity);
      case ({
        ar_fire, r_fire
      })
        2'b10: reads <= reads + 1'b1;
        2'b01: reads <= reads - 1'b1;
        default: ;
      endcase
      case ({
        aw_fire, b_fire
      })
        2'b10: writes <= writes + 1'b1;
        2'b01: writes <= writes - 1'b1;
        default: ;
      endcase
      held_read <= merged_axi.arvalid && !merged_axi.arready;
      if (merged_axi.arvalid) held_read_sb <= current_read_sb;
      if (bus_ar_fire) last_read_sb <= current_read_sb;
      if (write_active) begin
        held_write <= !(next_aw && next_w);
        held_write_sb <= write_sb;
        aw_seen <= next_aw && !next_w;
        w_seen <= next_w && !next_aw;
      end
    end
  end

  // These are producer obligations, not assumptions about arbitration outputs.
  for (genvar source = 0; source < 2; source++) begin : g_source
    wire arvalid = source == 0 ? core_axi.arvalid : sb_axi.arvalid;
    wire arready = source == 0 ? core_axi.arready : sb_axi.arready;
    wire awvalid = source == 0 ? core_axi.awvalid : sb_axi.awvalid;
    wire awready = source == 0 ? core_axi.awready : sb_axi.awready;
    wire wvalid = source == 0 ? core_axi.wvalid : sb_axi.wvalid;
    wire wready = source == 0 ? core_axi.wready : sb_axi.wready;
    wire [XLEN+20:0] ar_payload = source == 0 ?
        {core_axi.araddr, core_axi.arid, core_axi.arlen, core_axi.arsize,
         core_axi.arburst, core_axi.arcache} :
        {sb_axi.araddr, sb_axi.arid, sb_axi.arlen, sb_axi.arsize,
         sb_axi.arburst, sb_axi.arcache};
    wire [XLEN+20:0] aw_payload = source == 0 ?
        {core_axi.awaddr, core_axi.awid, core_axi.awlen, core_axi.awsize,
         core_axi.awburst, core_axi.awcache} :
        {sb_axi.awaddr, sb_axi.awid, sb_axi.awlen, sb_axi.awsize,
         sb_axi.awburst, sb_axi.awcache};
    wire [XLEN+XLEN/8:0] w_payload = source == 0 ?
        {core_axi.wdata, core_axi.wstrb, core_axi.wlast} :
        {sb_axi.wdata, sb_axi.wstrb, sb_axi.wlast};
    always_ff @(posedge clock) begin
      if (past_valid && !reset && !$past(reset)) begin
        if ($past(arvalid && !arready)) assume (arvalid && $stable(ar_payload));
        if ($past(awvalid && !awready)) assume (awvalid && $stable(aw_payload));
        if ($past(wvalid && !wready)) assume (wvalid && $stable(w_payload));
      end
    end
  end

  wire expected_idle = reads == 0 && writes == 0
      && !(held_read && !held_read_sb) && !(held_write && !held_write_sb);
  wire read_competing = !held_read && !core_block && core_axi.arvalid && sb_axi.arvalid;
  wire blocked_read = core_block && !(held_read && !held_read_sb);
  wire blocked_write = core_block && !(held_write && !held_write_sb);
  wire [XLEN+16:0] read_payload = {merged_axi.araddr, merged_axi.arlen,
    merged_axi.arsize, merged_axi.arburst, merged_axi.arcache};
  wire [XLEN+16:0] write_payload = {merged_axi.awaddr, merged_axi.awlen,
    merged_axi.awsize, merged_axi.awburst, merged_axi.awcache};
  wire [XLEN+16:0] expected_read = current_read_sb ?
      {sb_axi.araddr, sb_axi.arlen, sb_axi.arsize, sb_axi.arburst, sb_axi.arcache} :
      {core_axi.araddr, core_axi.arlen, core_axi.arsize, core_axi.arburst, core_axi.arcache};
  wire [XLEN+16:0] expected_write = write_sb ?
      {sb_axi.awaddr, sb_axi.awlen, sb_axi.awsize, sb_axi.awburst, sb_axi.awcache} :
      {core_axi.awaddr, core_axi.awlen, core_axi.awsize, core_axi.awburst, core_axi.awcache};
  // Proved strengthening relates the independent interface scoreboard to the
  // implementation. These are assertions, so unreachable induction offsets are
  // excluded only after the same base and step checks establish the relation.
  `RAPT_SVA(clock, reset, ARBITER_READ_ACCOUNTING, reads == dut.core_reads_q)
  `RAPT_SVA(clock, reset, ARBITER_WRITE_ACCOUNTING, writes == dut.core_writes_q)
  `RAPT_SVA(clock, reset, ARBITER_READ_LOCK, held_read == dut.read_lock_q)
  `RAPT_SVA(clock, reset, ARBITER_READ_TURN, dut.read_turn_q == !last_read_sb)
  `RAPT_SVA(clock, reset, ARBITER_WRITE_LOCK, held_write == dut.write_lock_q)
  `RAPT_SVA(clock, reset, ARBITER_WRITE_PHASE, aw_seen == dut.aw_done_q && w_seen == dut.w_done_q)
  `RAPT_SVA_IMPLY(clock, reset, ARBITER_READ_LOCK_OWNER, held_read,
                  held_read_sb == dut.read_owner_q)
  `RAPT_SVA_IMPLY(clock, reset, ARBITER_WRITE_LOCK_OWNER, held_write,
                  held_write_sb == dut.write_owner_q)
  `RAPT_SVA(clock, reset, ARBITER_IDLE, idle == expected_idle)
  `RAPT_SVA_IMPLY(clock, reset, ARBITER_ROUND_ROBIN, read_competing,
                  current_read_sb != last_read_sb)
  `RAPT_SVA_IMPLY(clock, reset, ARBITER_BLOCK_READ, blocked_read, !core_axi.arready)
  `RAPT_SVA_IMPLY(clock, reset, ARBITER_BLOCK_WRITE, blocked_write, !core_axi.awready)
  `RAPT_SVA_IMPLY(clock, reset, ARBITER_WRITE_OWNER, merged_axi.wvalid,
                  write_active && merged_axi.wdata == (write_sb ? sb_axi.wdata : core_axi.wdata))
  `RAPT_SVA_IMPLY(clock, reset, ARBITER_WRITE_MASK, merged_axi.wvalid,
                  merged_axi.wstrb == (write_sb ? sb_axi.wstrb : core_axi.wstrb))
  `RAPT_SVA_IMPLY(clock, reset, ARBITER_WRITE_ADDRESS, held_write && merged_axi.awvalid,
                  current_write_sb == held_write_sb)
  `RAPT_SVA_IMPLY(clock, reset, ARBITER_AR_PAYLOAD, merged_axi.arvalid,
                  read_payload == expected_read)
  `RAPT_SVA_IMPLY(clock, reset, ARBITER_AW_PAYLOAD, merged_axi.awvalid,
                  write_payload == expected_write)
  `RAPT_SVA_IMPLY(clock, reset, ARBITER_W_LAST, merged_axi.wvalid,
                  merged_axi.wlast == (write_sb ? sb_axi.wlast : core_axi.wlast))
  for (genvar response = 0; response < 2; response++) begin : g_response
    wire [XLEN+6:0] r_payload = response == 0 ?
        {core_axi.rid, core_axi.rdata, core_axi.rresp, core_axi.rlast} :
        {sb_axi.rid, sb_axi.rdata, sb_axi.rresp, sb_axi.rlast};
    wire [5:0] b_payload = response == 0 ? {core_axi.bid, core_axi.bresp} :
        {sb_axi.bid, sb_axi.bresp};
    `RAPT_SVA(clock, reset, ARBITER_R_PAYLOAD,
              r_payload == {merged_axi.rid, merged_axi.rdata, merged_axi.rresp, merged_axi.rlast})
    `RAPT_SVA(clock, reset, ARBITER_B_PAYLOAD, b_payload == {merged_axi.bid, merged_axi.bresp})
  end
  `RAPT_SVA(clock, reset, ARBITER_R_ROUTE,
            core_axi.rvalid == (merged_axi.rvalid && merged_axi.rid != 15))
  `RAPT_SVA(clock, reset, ARBITER_SB_R_ROUTE,
            sb_axi.rvalid == (merged_axi.rvalid && merged_axi.rid == 15))
  `RAPT_SVA(clock, reset, ARBITER_B_ROUTE,
            core_axi.bvalid == (merged_axi.bvalid && merged_axi.bid != 15))
  `RAPT_SVA(clock, reset, ARBITER_SB_B_ROUTE,
            sb_axi.bvalid == (merged_axi.bvalid && merged_axi.bid == 15))
  `RAPT_SVA(clock, reset, ARBITER_R_BACKPRESSURE,
            merged_axi.rready == (merged_axi.rid == 15 ? sb_axi.rready : core_axi.rready))
  `RAPT_SVA(clock, reset, ARBITER_B_BACKPRESSURE,
            merged_axi.bready == (merged_axi.bid == 15 ? sb_axi.bready : core_axi.bready))
  `RAPT_COVER(clock, reset, ARBITER_DRAIN_READ, core_block && reads != 0 && r_fire)
  `RAPT_COVER(clock, reset, ARBITER_DRAIN_WRITE, core_block && writes != 0 && b_fire)
  `RAPT_COVER(clock, reset, ARBITER_W_BEFORE_AW, held_write && w_seen && !aw_seen)
  `RAPT_COVER(clock, reset, ARBITER_AW_BEFORE_W, held_write && aw_seen && !w_seen)
  `RAPT_COVER(clock, reset, ARBITER_BLOCKED_CORE_OFFER, core_block && held_read && !held_read_sb)
  `RAPT_COVER(clock, reset, ARBITER_SBA_DURING_BLOCK, core_block && bus_ar_fire && current_read_sb)
  `RAPT_COVER(clock, reset, ARBITER_SIMULTANEOUS_READ, ar_fire && r_fire)
  if (Capacity > 1) begin : g_multiple
    `RAPT_COVER(clock, reset, ARBITER_MULTIPLE_CORE, reads > 1)
  end
endmodule
