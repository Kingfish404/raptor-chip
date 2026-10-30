// RVFI formal verification wrapper for Raptor Chip
//
// Exposes RVFI and an explicit external environment. The default raw responses
// overapproximate the bus, including unsolicited/error responses. ISA checks
// can select the transaction-driven, error-free environment with the macro
// RAPT_RVFI_PROTOCOL_ENV; fault/interrupt semantics require separate contracts.

`ifdef RAPT_RVFI_PROTOCOL_ENV
// Formal-only, transaction-driven AXI slave. Data is unconstrained per beat;
// responses have matching IDs/lengths and remain stable under backpressure.
// Reads may interleave across IDs; responses with one ID follow address order.
// Writes consume W beats in AW order and permit B reordering across IDs.
// Registered responses have at least one cycle of latency. PMA, memory-value
// coherence and fault/interrupt semantics require separate architectural models.
module rvfi_axi_environment #(
    parameter integer XLEN = 32,
    parameter AllowErrors = 0,
    parameter CheckMaster = 1
) (
    input clock,
    reset,
    input [3:0] arid,
    awid,
    input [XLEN-1:0] araddr,
    awaddr,
    wdata,
    input [7:0] arlen,
    awlen,
    input [2:0] arsize,
    awsize,
    input [1:0] arburst,
    awburst,
    input [XLEN/8-1:0] wstrb,
    input arvalid,
    awvalid,
    wvalid,
    wlast,
    rready,
    bready,
    output arready,
    awready,
    wready,
    output reg rvalid,
    rlast,
    bvalid,
    output reg [3:0] rid,
    bid,
    output reg [XLEN-1:0] rdata,
    output reg [1:0] rresp,
    bresp
);
  localparam integer Slots = 16;
  `rvformal_rand_reg allow_ar, allow_r, allow_aw, allow_w, allow_b;
  `rvformal_rand_reg [3:0] choose_rid, choose_bslot;
  `rvformal_rand_reg [XLEN-1:0] choose_rdata;
  `rvformal_rand_reg [1:0] choose_rresp, choose_bresp;

  reg [4:0] read_count[0:15];
  reg [3:0] read_head[0:15], read_tail[0:15];
  reg [8:0] read_left [0:255];
  wire ar_fire = arvalid && arready;
  wire r_fire = rvalid && rready;
  assign arready = !reset && allow_ar && read_count[arid] < Slots;

  reg [Slots-1:0] write_live, write_done;
  reg [Slots-1:0] older_writes [0:Slots-1];
  reg [3:0] write_id [0:Slots-1];
  reg [8:0] write_left [0:Slots-1];
  reg [3:0] write_order [0:Slots-1];
  reg [3:0] write_head, write_tail;
  reg [4:0] write_count;
  reg [3:0] bslot;
  reg free_found;
  reg [3:0] free_slot;
  reg [Slots-1:0] same_id_older;
  reg [Slots-1:0] queued_writes;
  integer index;
  always @* begin
    free_found = 0;
    free_slot = 0;
    same_id_older = 0;
    queued_writes = 0;
    for (integer i = 0; i < Slots; i = i + 1) begin
      if (!free_found && !write_live[i]) begin
        free_found = 1;
        free_slot = 4'(i);
      end
      same_id_older[i] = older_writes[choose_bslot][i] && write_live[i]
          && write_id[i] == write_id[choose_bslot];
      if (i < write_count) queued_writes[write_order[4'(write_head+i)]] = 1'b1;
    end
  end
  wire [3:0] wslot = write_order[write_head];
  wire aw_fire = awvalid && awready;
  wire w_fire = wvalid && wready;
  wire b_fire = bvalid && bready;
  assign awready = !reset && allow_aw && free_found && write_count < Slots;
  assign wready = !reset && allow_w && write_count != 0;

  always @(posedge clock) begin
    if (reset) begin
      rvalid <= 0;
      bvalid <= 0;
      write_live <= 0;
      write_done <= 0;
      write_head <= 0;
      write_tail <= 0;
      write_count <= 0;
      for (index = 0; index < 16; index = index + 1) begin
        read_count[index] <= 0;
        read_head[index] <= 0;
        read_tail[index] <= 0;
        older_writes[index] <= 0;
      end
    end else begin
      for (index = 0; index < 16; index = index + 1) begin
        case ({
          ar_fire && arid == index, r_fire && rlast && rid == index
        })
          2'b10: read_count[index] <= read_count[index] + 1;
          2'b01: read_count[index] <= read_count[index] - 1;
          default: begin
          end
        endcase
      end
      if (ar_fire) begin
        read_left[{arid, read_tail[arid]}] <= {1'b0, arlen} + 1;
        read_tail[arid] <= read_tail[arid] + 1;
      end
      if (!rvalid && allow_r && read_count[choose_rid] != 0) begin
        rvalid <= 1;
        rid <= choose_rid;
        rlast <= read_left[{choose_rid, read_head[choose_rid]}] == 1;
        rdata <= choose_rdata;
        rresp <= AllowErrors && choose_rresp[1] ? choose_rresp : 2'b00;
      end
      if (r_fire) begin
        rvalid <= 0;
        if (rlast) read_head[rid] <= read_head[rid] + 1;
        else read_left[{rid, read_head[rid]}] <= read_left[{rid, read_head[rid]}] - 1;
      end

      case ({
        aw_fire, w_fire && write_left[wslot] == 1
      })
        2'b10: write_count <= write_count + 1;
        2'b01: write_count <= write_count - 1;
        default: begin
        end
      endcase
      if (b_fire) begin
        bvalid <= 0;
        write_live[bslot] <= 0;
        write_done[bslot] <= 0;
        for (index = 0; index < Slots; index = index + 1) older_writes[index][bslot] <= 0;
      end
      if (aw_fire) begin
        write_live[free_slot] <= 1;
        write_done[free_slot] <= 0;
        write_id[free_slot] <= awid;
        write_left[free_slot] <= {1'b0, awlen} + 1;
        older_writes[free_slot] <= write_live & ~(b_fire ? (16'b1 << bslot) : 16'b0);
        write_order[write_tail] <= free_slot;
        write_tail <= write_tail + 1;
      end
      if (w_fire) begin
        write_left[wslot] <= write_left[wslot] - 1;
        if (write_left[wslot] == 1) begin
          write_done[wslot] <= 1;
          write_head <= write_head + 1;
        end
      end
      if (!bvalid && allow_b && write_live[choose_bslot]
          && write_done[choose_bslot] && same_id_older == 0) begin
        bvalid <= 1;
        bid <= write_id[choose_bslot];
        bslot <= choose_bslot;
        bresp <= AllowErrors && choose_bresp[1] ? choose_bresp : 2'b00;
      end
    end
  end

  reg past_valid = 0;
  always @(posedge clock) begin
    past_valid <= 1;
    if (!reset) begin
      if (rvalid) begin
        assert (read_count[rid] != 0);
        assert (rlast == (read_left[{rid, read_head[rid]}] == 1));
      end
      if (bvalid) assert (write_live[bslot] && write_done[bslot] && bid == write_id[bslot]);
      assert (write_count <= Slots);
      assert (write_tail == 4'(write_head + write_count));
      assert (queued_writes == (write_live & ~write_done));
      assert (write_count == $countones(queued_writes));
      for (integer i = 0; i < 16; i = i + 1) begin
        if (write_live[i] && !write_done[i]) assert (write_left[i] >= 1 && write_left[i] <= 256);
        assert (read_count[i] <= Slots);
        assert (read_tail[i] == 4'(read_head[i] + read_count[i]));
        for (integer j = 0; j < Slots; j = j + 1) begin
          if (4'(j - read_head[i]) < read_count[i])
            assert (read_left[{4'(i), 4'(j)}] >= 1 && read_left[{4'(i), 4'(j)}] <= 256);
        end
      end
      if (CheckMaster) begin
        if (w_fire) assert (wlast == (write_left[wslot] == 1));
        if (arvalid) assert (arsize <= $clog2(XLEN / 8) && arburst != 2'b11);
        if (awvalid) assert (awsize <= $clog2(XLEN / 8) && awburst != 2'b11);
      end
    end
    if (past_valid && !reset && !$past(reset)) begin
      if ($past(rvalid && !rready)) assert (rvalid && $stable({rid, rlast, rdata, rresp}));
      if ($past(bvalid && !bready)) assert (bvalid && $stable({bid, bresp}));
      if (CheckMaster) begin
        if ($past(arvalid && !arready))
          assert (arvalid && $stable({arid, araddr, arlen, arsize, arburst}));
        if ($past(awvalid && !awready))
          assert (awvalid && $stable({awid, awaddr, awlen, awsize, awburst}));
        if ($past(wvalid && !wready)) assert (wvalid && $stable({wlast, wdata, wstrb}));
      end
    end
  end
endmodule
`endif

module rvfi_wrapper (
    input clock,
    input reset,
    `RVFI_OUTPUTS
);
  // ----------------------------------------------------------------
  // Unconstrained AXI4 master responses (memory model abstracted away)
  // ----------------------------------------------------------------
`ifdef RAPT_RVFI_PROTOCOL_ENV
  wire axi_arready, axi_rlast, axi_rvalid, axi_awready, axi_wready, axi_bvalid;
  wire [3:0] axi_rid, axi_bid;
  wire [`RISCV_FORMAL_XLEN-1:0] axi_rdata;
  wire [1:0] axi_rresp, axi_bresp;
  wire axi_interrupt = 1'b0;
`else
  (* keep *)`rvformal_rand_reg        axi_arready;
  (* keep *)`rvformal_rand_reg [ 3:0] axi_rid;
  (* keep *)`rvformal_rand_reg        axi_rlast;
  (* keep *)`rvformal_rand_reg [`RISCV_FORMAL_XLEN-1:0] axi_rdata;
  (* keep *)`rvformal_rand_reg [ 1:0] axi_rresp;
  (* keep *)`rvformal_rand_reg        axi_rvalid;
  (* keep *)`rvformal_rand_reg        axi_awready;
  (* keep *)`rvformal_rand_reg        axi_wready;
  (* keep *)`rvformal_rand_reg [ 3:0] axi_bid;
  (* keep *)`rvformal_rand_reg [ 1:0] axi_bresp;
  (* keep *)`rvformal_rand_reg        axi_bvalid;
  (* keep *)`rvformal_rand_reg        axi_interrupt;
`endif

  // AXI4 master output wires (from core, left unconnected for formal)
  (* keep *)wire               [ 1:0] m_arburst;
  (* keep *)wire               [ 2:0] m_arsize;
  (* keep *)wire               [ 7:0] m_arlen;
  (* keep *)wire               [ 3:0] m_arid;
  (* keep *)wire [`RISCV_FORMAL_XLEN-1:0] m_araddr;
  (* keep *)wire                      m_arvalid;
  (* keep *)wire                      m_rready;

  (* keep *)wire               [ 1:0] m_awburst;
  (* keep *)wire               [ 2:0] m_awsize;
  (* keep *)wire               [ 7:0] m_awlen;
  (* keep *)wire               [ 3:0] m_awid;
  (* keep *)wire [`RISCV_FORMAL_XLEN-1:0] m_awaddr;
  (* keep *)wire                      m_awvalid;

  (* keep *)wire                      m_wlast;
  (* keep *)wire [`RISCV_FORMAL_XLEN-1:0] m_wdata;
  (* keep *)wire [`RISCV_FORMAL_XLEN/8-1:0] m_wstrb;
  (* keep *)wire                      m_wvalid;
  (* keep *)wire                      m_bready;

`ifdef RAPT_RVFI_PROTOCOL_ENV
  rvfi_axi_environment #(
      .XLEN(`RISCV_FORMAL_XLEN)
  ) memory (
      .clock(clock),
      .reset(reset),
      .arid(m_arid),
      .araddr(m_araddr),
      .arlen(m_arlen),
      .arsize(m_arsize),
      .arburst(m_arburst),
      .arvalid(m_arvalid),
      .arready(axi_arready),
      .rid(axi_rid),
      .rdata(axi_rdata),
      .rresp(axi_rresp),
      .rlast(axi_rlast),
      .rvalid(axi_rvalid),
      .rready(m_rready),
      .awid(m_awid),
      .awaddr(m_awaddr),
      .awlen(m_awlen),
      .awsize(m_awsize),
      .awburst(m_awburst),
      .awvalid(m_awvalid),
      .awready(axi_awready),
      .wdata(m_wdata),
      .wstrb(m_wstrb),
      .wlast(m_wlast),
      .wvalid(m_wvalid),
      .wready(axi_wready),
      .bid(axi_bid),
      .bresp(axi_bresp),
      .bvalid(axi_bvalid),
      .bready(m_bready)
  );
`endif

  rapt uut (
      .clock(clock),
      .reset(reset),
      .external_write_valid_i(1'b0),
      .external_write_pending_i(1'b0),
      .external_write_first_i('0),
      .external_write_last_i('0),

      // AXI4 master — AR channel
      .io_master_arburst(m_arburst),
      .io_master_arcache(),
      .io_master_arsize (m_arsize),
      .io_master_arlen  (m_arlen),
      .io_master_arid   (m_arid),
      .io_master_araddr (m_araddr),
      .io_master_arvalid(m_arvalid),
      .io_master_arready(axi_arready),

      // AXI4 master — R channel
      .io_master_rid   (axi_rid),
      .io_master_rlast (axi_rlast),
      .io_master_rdata (axi_rdata),
      .io_master_rresp (axi_rresp),
      .io_master_rvalid(axi_rvalid),
      .io_master_rready(m_rready),

      // AXI4 master — AW channel
      .io_master_awburst(m_awburst),
      .io_master_awcache(),
      .io_master_awsize (m_awsize),
      .io_master_awlen  (m_awlen),
      .io_master_awid   (m_awid),
      .io_master_awaddr (m_awaddr),
      .io_master_awvalid(m_awvalid),
      .io_master_awready(axi_awready),

      // AXI4 master — W channel
      .io_master_wlast (m_wlast),
      .io_master_wdata (m_wdata),
      .io_master_wstrb (m_wstrb),
      .io_master_wvalid(m_wvalid),
      .io_master_wready(axi_wready),

      // AXI4 master — B channel
      .io_master_bid   (axi_bid),
      .io_master_bresp (axi_bresp),
      .io_master_bvalid(axi_bvalid),
      .io_master_bready(m_bready),

      // Interrupt
      .io_interrupt(axi_interrupt),
      .ext_irq_i   ('0),

      // RVFI
      .rvfi_valid    (rvfi_valid),
      .rvfi_order    (rvfi_order),
      .rvfi_insn     (rvfi_insn),
      .rvfi_trap     (rvfi_trap),
      .rvfi_halt     (rvfi_halt),
      .rvfi_intr     (rvfi_intr),
      .rvfi_mode     (rvfi_mode),
      .rvfi_ixl      (rvfi_ixl),
      .rvfi_rs1_addr (rvfi_rs1_addr),
      .rvfi_rs2_addr (rvfi_rs2_addr),
      .rvfi_rs1_rdata(rvfi_rs1_rdata),
      .rvfi_rs2_rdata(rvfi_rs2_rdata),
      .rvfi_rd_addr  (rvfi_rd_addr),
      .rvfi_rd_wdata (rvfi_rd_wdata),
      .rvfi_pc_rdata (rvfi_pc_rdata),
      .rvfi_pc_wdata (rvfi_pc_wdata),
      .rvfi_mem_addr (rvfi_mem_addr),
      .rvfi_mem_rmask(rvfi_mem_rmask),
      .rvfi_mem_wmask(rvfi_mem_wmask),
      .rvfi_mem_rdata(rvfi_mem_rdata),
      .rvfi_mem_wdata(rvfi_mem_wdata),

      // JTAG (always-on at the cluster boundary). Tie to TLR-park values
      // so the formal wrapper does not see DTM transitions.
      .jtag_trst_n(1'b0),
      .jtag_tms   (1'b1),
      .jtag_tdi   (1'b0),
      .jtag_tdo   (  /* unused */)
  );

endmodule
