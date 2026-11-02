// AMD JTAG-to-AXI master, independent of the replay hart's soft reset.
module rapt_replay_jtag_port (
    input logic clk,
    reset,
    axi4_if.master bus
);
  logic [31:0] awaddr, araddr;
  assign bus.awaddr = {32'b0, awaddr};
  assign bus.araddr = {32'b0, araddr};
  rapt_replay_jtag transport (
      .aclk(clk),
      .aresetn(!reset),
      .m_axi_awid(bus.awid),
      .m_axi_awaddr(awaddr),
      .m_axi_awlen(bus.awlen),
      .m_axi_awsize(bus.awsize),
      .m_axi_awburst(bus.awburst),
      .m_axi_awcache(bus.awcache),
      .m_axi_awlock(),
      .m_axi_awprot(),
      .m_axi_awqos(),
      .m_axi_awvalid(bus.awvalid),
      .m_axi_awready(bus.awready),
      .m_axi_wdata(bus.wdata),
      .m_axi_wstrb(bus.wstrb),
      .m_axi_wlast(bus.wlast),
      .m_axi_wvalid(bus.wvalid),
      .m_axi_wready(bus.wready),
      .m_axi_bid(bus.bid),
      .m_axi_bresp(bus.bresp),
      .m_axi_bvalid(bus.bvalid),
      .m_axi_bready(bus.bready),
      .m_axi_arid(bus.arid),
      .m_axi_araddr(araddr),
      .m_axi_arlen(bus.arlen),
      .m_axi_arsize(bus.arsize),
      .m_axi_arburst(bus.arburst),
      .m_axi_arcache(bus.arcache),
      .m_axi_arlock(),
      .m_axi_arprot(),
      .m_axi_arqos(),
      .m_axi_arvalid(bus.arvalid),
      .m_axi_arready(bus.arready),
      .m_axi_rid(bus.rid),
      .m_axi_rdata(bus.rdata),
      .m_axi_rresp(bus.rresp),
      .m_axi_rlast(bus.rlast),
      .m_axi_rvalid(bus.rvalid),
      .m_axi_rready(bus.rready)
  );
endmodule
