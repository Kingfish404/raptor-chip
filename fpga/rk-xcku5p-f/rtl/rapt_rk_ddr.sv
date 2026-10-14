// axi4_if is supplied by the shared Raptor RTL compilation unit.

// Vendor width converter owns the AXI CDC and SI ID bookkeeping. Its MI has
// no IDs; MIG sees ID zero. No hand-written multi-bit synchronizers are used.
module rapt_rk_ddr (
    input logic clk,
    input logic reset,
    output logic ready,
    axi4_if.slave bus,
    input logic sys_clk,
    output wire [16:0] ddram_adr,
    output wire [1:0] ddram_ba,
    output wire ddram_bg,
    output wire ddram_act_n,
    output wire ddram_cke,
    output wire ddram_odt,
    output wire ddram_cs_n,
    output wire ddram_clk_p,
    output wire ddram_clk_n,
    output wire ddram_reset_n,
    inout wire [3:0] ddram_dm,
    inout wire [31:0] ddram_dq,
    inout wire [3:0] ddram_dqs_p,
    inout wire [3:0] ddram_dqs_n
);
  // DCI I/Os must finish impedance calibration before MIG leaves reset (UG571).
  logic dci_locked;
  (* ASYNC_REG = "TRUE" *) logic [1:0] dci_ready;
  DCIRESET dci_reset (
      .RST(reset),
      .LOCKED(dci_locked)
  );
  always_ff @(posedge clk or posedge reset) begin
    if (reset) dci_ready <= 0;
    else dci_ready <= {dci_ready[0], dci_locked};
  end
  logic ui_clk, ui_reset, calibrated, ready_ui;
  (* ASYNC_REG = "TRUE" *) logic [1:0] ready_sync;
  (* ASYNC_REG = "TRUE" *) logic [1:0] ui_release;
  // Register status in its source domain before crossing to the CPU clock.
  always_ff @(posedge ui_clk or posedge ui_reset) begin
    if (ui_reset) ready_ui <= 0;
    else ready_ui <= calibrated;
  end
  always_ff @(posedge clk or posedge reset) begin
    if (reset) ready_sync <= 0;
    else ready_sync <= {ready_sync[0], ready_ui};
  end
  assign ready = ready_sync[1];
  always_ff @(posedge ui_clk or posedge ui_reset) begin
    if (ui_reset) ui_release <= 0;
    else ui_release <= {ui_release[0], 1'b1};
  end
  logic [31:0] m_awaddr;
  logic [7:0] m_awlen;
  logic [2:0] m_awsize;
  logic [1:0] m_awburst;
  logic m_awlock;
  logic [3:0] m_awcache;
  logic [2:0] m_awprot;
  logic [3:0] m_awqos;
  logic [3:0] m_awregion;
  logic m_awvalid;
  logic m_awready;
  logic [255:0] m_wdata;
  logic [31:0] m_wstrb;
  logic m_wlast;
  logic m_wvalid;
  logic m_wready;
  logic [1:0] m_bresp;
  logic m_bvalid;
  logic m_bready;
  logic [31:0] m_araddr;
  logic [7:0] m_arlen;
  logic [2:0] m_arsize;
  logic [1:0] m_arburst;
  logic m_arlock;
  logic [3:0] m_arcache;
  logic [2:0] m_arprot;
  logic [3:0] m_arqos;
  logic [3:0] m_arregion;
  logic m_arvalid;
  logic m_arready;
  logic [255:0] m_rdata;
  logic [1:0] m_rresp;
  logic m_rlast;
  logic m_rvalid;
  logic m_rready;
  rapt_rk_axi_bridge bridge (
      .s_axi_aclk(clk),
      .s_axi_aresetn(!reset && ready),
      .m_axi_aclk(ui_clk),
      .m_axi_aresetn(ui_release[1] && calibrated),
      .s_axi_arcache(bus.arcache),
      .s_axi_arburst(bus.arburst),
      .s_axi_arsize(bus.arsize),
      .s_axi_arlen(bus.arlen),
      .s_axi_arid(bus.arid),
      .s_axi_araddr(bus.araddr[31:0]),
      .s_axi_arvalid(bus.arvalid),
      .s_axi_arready(bus.arready),
      .s_axi_rid(bus.rid),
      .s_axi_rlast(bus.rlast),
      .s_axi_rdata(bus.rdata),
      .s_axi_rresp(bus.rresp),
      .s_axi_rvalid(bus.rvalid),
      .s_axi_rready(bus.rready),
      .s_axi_awcache(bus.awcache),
      .s_axi_awburst(bus.awburst),
      .s_axi_awsize(bus.awsize),
      .s_axi_awlen(bus.awlen),
      .s_axi_awid(bus.awid),
      .s_axi_awaddr(bus.awaddr[31:0]),
      .s_axi_awvalid(bus.awvalid),
      .s_axi_awready(bus.awready),
      .s_axi_wlast(bus.wlast),
      .s_axi_wdata(bus.wdata),
      .s_axi_wstrb(bus.wstrb),
      .s_axi_wvalid(bus.wvalid),
      .s_axi_wready(bus.wready),
      .s_axi_bid(bus.bid),
      .s_axi_bresp(bus.bresp),
      .s_axi_bvalid(bus.bvalid),
      .s_axi_bready(bus.bready),
      .s_axi_awlock(1'b0),
      .s_axi_awprot(3'b0),
      .s_axi_awqos(4'b0),
      .s_axi_awregion(4'b0),
      .s_axi_arlock(1'b0),
      .s_axi_arprot(3'b0),
      .s_axi_arqos(4'b0),
      .s_axi_arregion(4'b0),
      .m_axi_awaddr(m_awaddr),
      .m_axi_awlen(m_awlen),
      .m_axi_awsize(m_awsize),
      .m_axi_awburst(m_awburst),
      .m_axi_awlock(m_awlock),
      .m_axi_awcache(m_awcache),
      .m_axi_awprot(m_awprot),
      .m_axi_awqos(m_awqos),
      .m_axi_awregion(m_awregion),
      .m_axi_awvalid(m_awvalid),
      .m_axi_awready(m_awready),
      .m_axi_wdata(m_wdata),
      .m_axi_wstrb(m_wstrb),
      .m_axi_wlast(m_wlast),
      .m_axi_wvalid(m_wvalid),
      .m_axi_wready(m_wready),
      .m_axi_bresp(m_bresp),
      .m_axi_bvalid(m_bvalid),
      .m_axi_bready(m_bready),
      .m_axi_araddr(m_araddr),
      .m_axi_arlen(m_arlen),
      .m_axi_arsize(m_arsize),
      .m_axi_arburst(m_arburst),
      .m_axi_arlock(m_arlock),
      .m_axi_arcache(m_arcache),
      .m_axi_arprot(m_arprot),
      .m_axi_arqos(m_arqos),
      .m_axi_arregion(m_arregion),
      .m_axi_arvalid(m_arvalid),
      .m_axi_arready(m_arready),
      .m_axi_rdata(m_rdata),
      .m_axi_rresp(m_rresp),
      .m_axi_rlast(m_rlast),
      .m_axi_rvalid(m_rvalid),
      .m_axi_rready(m_rready)
  );
  raptor_ddr4_0 mig (
      .sys_rst(reset || !dci_ready[1]),
      .c0_sys_clk_i(sys_clk),
      .c0_init_calib_complete(calibrated),
      .c0_ddr4_ui_clk(ui_clk),
      .c0_ddr4_ui_clk_sync_rst(ui_reset),
      .c0_ddr4_aresetn(ui_release[1]),
      .dbg_clk(),
      .dbg_bus(),
      .c0_ddr4_s_axi_awaddr(m_awaddr[30:0]),
      .c0_ddr4_s_axi_awlen(m_awlen),
      .c0_ddr4_s_axi_awsize(m_awsize),
      .c0_ddr4_s_axi_awburst(m_awburst),
      .c0_ddr4_s_axi_awlock(m_awlock),
      .c0_ddr4_s_axi_awcache(m_awcache),
      .c0_ddr4_s_axi_awprot(m_awprot),
      .c0_ddr4_s_axi_awqos(m_awqos),
      .c0_ddr4_s_axi_awvalid(m_awvalid),
      .c0_ddr4_s_axi_awready(m_awready),
      .c0_ddr4_s_axi_wdata(m_wdata),
      .c0_ddr4_s_axi_wstrb(m_wstrb),
      .c0_ddr4_s_axi_wlast(m_wlast),
      .c0_ddr4_s_axi_wvalid(m_wvalid),
      .c0_ddr4_s_axi_wready(m_wready),
      .c0_ddr4_s_axi_bresp(m_bresp),
      .c0_ddr4_s_axi_bvalid(m_bvalid),
      .c0_ddr4_s_axi_bready(m_bready),
      .c0_ddr4_s_axi_araddr(m_araddr[30:0]),
      .c0_ddr4_s_axi_arlen(m_arlen),
      .c0_ddr4_s_axi_arsize(m_arsize),
      .c0_ddr4_s_axi_arburst(m_arburst),
      .c0_ddr4_s_axi_arlock(m_arlock),
      .c0_ddr4_s_axi_arcache(m_arcache),
      .c0_ddr4_s_axi_arprot(m_arprot),
      .c0_ddr4_s_axi_arqos(m_arqos),
      .c0_ddr4_s_axi_arvalid(m_arvalid),
      .c0_ddr4_s_axi_arready(m_arready),
      .c0_ddr4_s_axi_rdata(m_rdata),
      .c0_ddr4_s_axi_rresp(m_rresp),
      .c0_ddr4_s_axi_rlast(m_rlast),
      .c0_ddr4_s_axi_rvalid(m_rvalid),
      .c0_ddr4_s_axi_rready(m_rready),
      .c0_ddr4_s_axi_awid(4'b0),
      .c0_ddr4_s_axi_arid(4'b0),
      .c0_ddr4_s_axi_rid(),
      .c0_ddr4_s_axi_bid(),
      .c0_ddr4_adr(ddram_adr),
      .c0_ddr4_ba(ddram_ba),
      .c0_ddr4_bg(ddram_bg),
      .c0_ddr4_act_n(ddram_act_n),
      .c0_ddr4_cke(ddram_cke),
      .c0_ddr4_odt(ddram_odt),
      .c0_ddr4_cs_n(ddram_cs_n),
      .c0_ddr4_ck_t(ddram_clk_p),
      .c0_ddr4_ck_c(ddram_clk_n),
      .c0_ddr4_reset_n(ddram_reset_n),
      .c0_ddr4_dm_dbi_n(ddram_dm),
      .c0_ddr4_dq(ddram_dq),
      .c0_ddr4_dqs_t(ddram_dqs_p),
      .c0_ddr4_dqs_c(ddram_dqs_n)
  );
endmodule
