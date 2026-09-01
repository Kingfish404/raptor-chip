module formal_bus #(
    parameter bit [7:0] XLEN = `RAPT_XLEN
) (
    input clock,
    input reset,

    // AXI4 Master
    output [1:0] io_master_arburst,
    output [2:0] io_master_arsize,
    output [7:0] io_master_arlen,
    output [3:0] io_master_arid,
    output [XLEN-1:0] io_master_araddr,
    output io_master_arvalid,
    input io_master_arready,

    input [3:0] io_master_rid,
    input io_master_rlast,
    input [XLEN-1:0] io_master_rdata,
    input [1:0] io_master_rresp,
    input io_master_rvalid,
    output io_master_rready,

    output [1:0] io_master_awburst,
    output [2:0] io_master_awsize,
    output [7:0] io_master_awlen,
    output [3:0] io_master_awid,
    output [XLEN-1:0] io_master_awaddr,
    output io_master_awvalid,
    input io_master_awready,

    output io_master_wlast,
    output [XLEN-1:0] io_master_wdata,
    output [XLEN/8-1:0] io_master_wstrb,
    output io_master_wvalid,
    input io_master_wready,

    input [3:0] io_master_bid,
    input [1:0] io_master_bresp,
    input io_master_bvalid,
    output io_master_bready,

    // L1I cache-side inputs (master outputs, solver-controlled in formal)
    input l1i_arvalid,
    input [XLEN-1:0] l1i_araddr,
    input l1i_arburst,

    // L1D cache-side inputs (master outputs, solver-controlled in formal)
    input l1d_arvalid,
    input [XLEN-1:0] l1d_araddr,
    input [7:0] l1d_rstrb,
    input l1d_awvalid,
    input [XLEN-1:0] l1d_awaddr,
    input l1d_wvalid,
    input [XLEN-1:0] l1d_wdata,
    input [7:0] l1d_wstrb
);
  // Interface instances
  l1i_bus_if #(.XLEN(XLEN)) l1i_bus ();
  l1d_bus_if #(.XLEN(XLEN)) l1d_bus ();
  mem_link_if #(.XLEN(XLEN)) mem ();
  axi4_if #(.XLEN(XLEN)) axi ();
  csr_bcast_if #(.XLEN(XLEN)) csr_bcast ();
  cmu_bcast_if #(.XLEN(XLEN)) cmu_bcast ();

  // Drive L1I master-side signals from module inputs
  assign l1i_bus.arvalid = l1i_arvalid;
  assign l1i_bus.araddr = l1i_araddr;
  assign l1i_bus.arburst = l1i_arburst;
  assign l1i_bus.ar_ptw = 1'b0;
  assign l1i_bus.awvalid = 1'b0;
  assign l1i_bus.awaddr = '0;
  assign l1i_bus.aw_ptw = 1'b0;
  assign l1i_bus.wvalid = 1'b0;
  assign l1i_bus.wdata = '0;
  assign l1i_bus.wstrb = '0;

  // Drive L1D master-side signals from module inputs
  assign l1d_bus.arvalid = l1d_arvalid;
  assign l1d_bus.araddr = l1d_araddr;
  assign l1d_bus.rstrb = l1d_rstrb;
  assign l1d_bus.ar_ptw = 1'b0;
  assign l1d_bus.awvalid = l1d_awvalid;
  assign l1d_bus.awaddr = l1d_awaddr;
  assign l1d_bus.aw_ptw = 1'b0;
  assign l1d_bus.wvalid = l1d_wvalid;
  assign l1d_bus.wdata = l1d_wdata;
  assign l1d_bus.wstrb = l1d_wstrb;

  // Tie off csr_bcast inputs (not used in bus formal check)
  assign csr_bcast.priv = 2'b11;
  assign csr_bcast.satp_ppn = '0;
  assign csr_bcast.satp_asid = '0;
  assign csr_bcast.immu_en = 1'b0;
  assign csr_bcast.dmmu_en = 1'b0;
  assign csr_bcast.mtvec = '0;
  assign csr_bcast.tvec = '0;

  // Tie off cmu_bcast inputs
  assign cmu_bcast.rpc = '0;
  assign cmu_bcast.cpc = '0;
  assign cmu_bcast.rd_a = '0;
  assign cmu_bcast.rd_b = '0;
  assign cmu_bcast.valid_b = 1'b0;
  assign cmu_bcast.ben = 1'b0;
  assign cmu_bcast.jen = 1'b0;
  assign cmu_bcast.jren = 1'b0;
  assign cmu_bcast.btaken = 1'b0;
  assign cmu_bcast.call = 1'b0;
  assign cmu_bcast.ret = 1'b0;
  assign cmu_bcast.rvc = 1'b0;
  assign cmu_bcast.fence_time = 1'b0;
  assign cmu_bcast.fence_i = 1'b0;
  assign cmu_bcast.flush_pipe = 1'b0;
  assign cmu_bcast.time_trap = 1'b0;

  assign io_master_arburst = axi.arburst;
  assign io_master_arsize = axi.arsize;
  assign io_master_arlen = axi.arlen;
  assign io_master_arid = axi.arid;
  assign io_master_araddr = axi.araddr;
  assign io_master_arvalid = axi.arvalid;
  assign axi.arready = io_master_arready;
  assign axi.rid = io_master_rid;
  assign axi.rlast = io_master_rlast;
  assign axi.rdata = io_master_rdata;
  assign axi.rresp = io_master_rresp;
  assign axi.rvalid = io_master_rvalid;
  assign io_master_rready = axi.rready;

  assign io_master_awburst = axi.awburst;
  assign io_master_awsize = axi.awsize;
  assign io_master_awlen = axi.awlen;
  assign io_master_awid = axi.awid;
  assign io_master_awaddr = axi.awaddr;
  assign io_master_awvalid = axi.awvalid;
  assign axi.awready = io_master_awready;
  assign io_master_wlast = axi.wlast;
  assign io_master_wdata = axi.wdata;
  assign io_master_wstrb = axi.wstrb;
  assign io_master_wvalid = axi.wvalid;
  assign axi.wready = io_master_wready;
  assign axi.bid = io_master_bid;
  assign axi.bresp = io_master_bresp;
  assign axi.bvalid = io_master_bvalid;
  assign io_master_bready = axi.bready;

  rapt_bus bus (
      .clock(clock),
      .mem(mem),
      .l1i_bus(l1i_bus),
      .l1d_bus(l1d_bus),

      .csr_bcast(csr_bcast),
      .cmu_bcast(cmu_bcast),

      .reset(reset)
  );

      rapt_axi_master #(.XLEN(XLEN)) axi_master (
        .clock(clock),
        .reset(reset),
        .mem(mem),
        .axi(axi)
      );

`ifdef FORMAL
  // Standard formal past-valid register: skip initial state checks
  reg f_past_valid = 0;
  always @(posedge clock) f_past_valid <= 1;

  // Assume reset held at start, released after first cycle
  always_comb begin
    if (!f_past_valid) assume(reset);
    if (f_past_valid) assume(!reset);
  end

  // Model the cache-side request contract.  Transfer masks are the canonical
  // unshifted masks produced by L1D; AW and W are issued as one local request.
  always_comb begin
    if (l1d_arvalid) begin
      if (XLEN == 32) assume(l1d_rstrb inside {8'h01, 8'h03, 8'h0f});
      else            assume(l1d_rstrb inside {8'h01, 8'h03, 8'h0f, 8'hff});
    end
    if (l1d_awvalid || l1d_wvalid) begin
      assume(l1d_awvalid && l1d_wvalid);
      if (XLEN == 32) assume(l1d_wstrb inside {8'h01, 8'h03, 8'h07, 8'h0f});
      else assume(l1d_wstrb inside {8'h01, 8'h03, 8'h07, 8'h0f, 8'h7f, 8'hff});
    end
  end

  logic ar_stalled_q, aw_stalled_q, w_stalled_q;
  logic [XLEN-1:0] araddr_q, awaddr_q, wdata_q;
  logic [2:0] arsize_q, awsize_q;
  logic [3:0] arid_q, awid_q;
  logic [XLEN/8-1:0] wstrb_q;
  logic [3:0] f_read_outstanding;
  wire f_ar_fire = io_master_arvalid && io_master_arready;
  wire f_r_fire = io_master_rvalid && io_master_rready && io_master_rlast;
  always_ff @(posedge clock) begin
    if (reset) begin
      f_read_outstanding <= '0;
      ar_stalled_q <= 1'b0;
      aw_stalled_q <= 1'b0;
      w_stalled_q <= 1'b0;
      araddr_q <= '0; arsize_q <= '0; arid_q <= '0;
      awaddr_q <= '0; awsize_q <= '0; awid_q <= '0;
      wdata_q <= '0; wstrb_q <= '0;
    end else begin
      unique case ({f_ar_fire, f_r_fire})
        2'b10: f_read_outstanding <= f_read_outstanding + 1'b1;
        2'b01: f_read_outstanding <= f_read_outstanding - 1'b1;
        default: f_read_outstanding <= f_read_outstanding;
      endcase
      ar_stalled_q <= io_master_arvalid && !io_master_arready;
      aw_stalled_q <= io_master_awvalid && !io_master_awready;
      w_stalled_q  <= io_master_wvalid && !io_master_wready;
      araddr_q <= io_master_araddr; arsize_q <= io_master_arsize; arid_q <= io_master_arid;
      awaddr_q <= io_master_awaddr; awsize_q <= io_master_awsize; awid_q <= io_master_awid;
      wdata_q <= io_master_wdata; wstrb_q <= io_master_wstrb;
    end
  end

  // AXI slaves cannot complete a read that the master has not issued.  This
  // prevents an unconstrained spurious R beat from underflowing the DUT's
  // outstanding counter and creating a false AR-stability counterexample.
  always_comb begin
    assume(!io_master_rlast || io_master_rvalid);
    if (f_r_fire) assume((f_read_outstanding != '0) || f_ar_fire);
  end

  // Legal RV32 transfer sizes and AXI payload stability under backpressure.
  always @(posedge clock) begin
    if (f_past_valid && !reset) begin
      if (XLEN == 32 && io_master_arvalid)
        arsize_assert : assert (io_master_arsize <= 3'b010);
      if (XLEN == 32 && io_master_awvalid)
        awsize_assert : assert (io_master_awsize <= 3'b010);
      if (ar_stalled_q) begin
        arhold_valid: assert(io_master_arvalid);
        arhold_data: assert({io_master_araddr, io_master_arsize, io_master_arid}
                            == {araddr_q, arsize_q, arid_q});
      end
      if (aw_stalled_q) begin
        awhold_valid: assert(io_master_awvalid);
        awhold_data: assert({io_master_awaddr, io_master_awsize, io_master_awid}
                            == {awaddr_q, awsize_q, awid_q});
      end
      if (w_stalled_q) begin
        whold_valid: assert(io_master_wvalid);
        whold_data: assert({io_master_wdata, io_master_wstrb} == {wdata_q, wstrb_q});
      end
      if (io_master_wvalid) wlast_assert: assert(io_master_wlast);
    end
  end
`endif  // FORMAL
endmodule
