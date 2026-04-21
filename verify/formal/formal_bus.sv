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
  csr_bcast_if #(.XLEN(XLEN)) csr_bcast ();
  cmu_bcast_if #(.XLEN(XLEN)) cmu_bcast ();

  // Drive L1I master-side signals from module inputs
  assign l1i_bus.arvalid = l1i_arvalid;
  assign l1i_bus.araddr = l1i_araddr;
  assign l1i_bus.arburst = l1i_arburst;

  // Drive L1D master-side signals from module inputs
  assign l1d_bus.arvalid = l1d_arvalid;
  assign l1d_bus.araddr = l1d_araddr;
  assign l1d_bus.rstrb = l1d_rstrb;
  assign l1d_bus.awvalid = l1d_awvalid;
  assign l1d_bus.awaddr = l1d_awaddr;
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
  assign csr_bcast.interrupt_en = 1'b0;

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

  wire io_trap_o;

  rapt_bus bus (
      .clock(clock),

      .axi_arburst(io_master_arburst),
      .axi_arsize(io_master_arsize),
      .axi_arlen(io_master_arlen),
      .axi_arid(io_master_arid),
      .axi_araddr(io_master_araddr),
      .axi_arvalid(io_master_arvalid),
      .axi_arready(io_master_arready),

      .axi_rid(io_master_rid),
      .axi_rlast(io_master_rlast),
      .axi_rdata(io_master_rdata),
      .axi_rresp(io_master_rresp),
      .axi_rvalid(io_master_rvalid),
      .axi_rready(io_master_rready),

      .axi_awburst(io_master_awburst),
      .axi_awsize(io_master_awsize),
      .axi_awlen(io_master_awlen),
      .axi_awid(io_master_awid),
      .axi_awaddr(io_master_awaddr),
      .axi_awvalid(io_master_awvalid),
      .axi_awready(io_master_awready),

      .axi_wlast (io_master_wlast),
      .axi_wdata (io_master_wdata),
      .axi_wstrb (io_master_wstrb),
      .axi_wvalid(io_master_wvalid),
      .axi_wready(io_master_wready),

      .axi_bid(io_master_bid),
      .axi_bresp(io_master_bresp),
      .axi_bvalid(io_master_bvalid),
      .axi_bready(io_master_bready),

      .l1i_bus(l1i_bus),
      .l1d_bus(l1d_bus),

      .csr_bcast(csr_bcast),
      .cmu_bcast(cmu_bcast),
      .io_trap_o(io_trap_o),

      .reset(reset)
  );

`ifdef FORMAL
  // Standard formal past-valid register: skip initial state checks
  reg f_past_valid = 0;
  always @(posedge clock) f_past_valid <= 1;

  // Assume reset held at start, released after first cycle
  always @(*) if (!f_past_valid) assume(reset);
  always @(*) if (f_past_valid) assume(!reset);

  // Assume legal cache-side input values: in RV32, no 8-byte transfers
  always_comb begin
    if (XLEN == 32) begin
      assume (l1d_rstrb != 8'hff);
      assume (l1d_wstrb != 8'hff);
    end
  end

  // Assert only after reset has been applied (after first clock edge)
  always @(posedge clock) begin
    if (f_past_valid && XLEN == 32) begin
      arsize_assert : assert (io_master_arsize != 3'b011);
      awsize_assert : assert (io_master_awsize != 3'b011);
    end
  end
`endif  // FORMAL
endmodule
