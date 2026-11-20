// Native FPGA SoC integrating Raptor cluster + AXI4-DMA interconnect +
// standard OASIS VirtIO 1.2 virtio-mmio NIC + FPGA-to-QEMU Direct I/O & DMA
// Bridge (exposing upstream VirtIO-Blk, VirtIO-Net, SDHCI, and PCIe + NVMe).
module rapt_native_io_soc #(
    parameter int XLEN = `RAPT_XLEN,
    parameter bit WithDdr = 0,
    parameter bit WithPeripheral = 0,
    parameter bit WithLocalVirtioNet = 1,
    parameter bit WithQemuBridge = 1,
    parameter int RamBytes = 131072,
    parameter int ClockHz = 50_000_000,
    parameter string RomFile = "boot.hex"
) (
    input logic clk,
    input logic reset,
    input logic uart_rx,
    output logic uart_tx,
    output logic writeback_error,
    // Legacy board peripheral window (0x1800_0000)
    output logic peripheral_rd,
    output logic peripheral_wr,
    output logic [15:0] peripheral_raddr,
    output logic [15:0] peripheral_waddr,
    output logic [31:0] peripheral_wdata,
    output logic [3:0] peripheral_wstrb,
    input logic [31:0] peripheral_rdata,
    input logic peripheral_irq,
    // Ethernet packet stream (shared via EtherType 0x88B5 mux between
    // guest virtio-mmio NIC and host QEMU RQIO I/O + DMA tunnel)
    input logic eth_link_up_i,
    input logic [7:0] eth_rx_data_i,
    input logic eth_rx_valid_i,
    input logic eth_rx_last_i,
    output logic eth_rx_ready_o,
    output logic [7:0] eth_tx_data_o,
    output logic eth_tx_valid_o,
    output logic eth_tx_last_o,
    input logic eth_tx_ready_i,
    // Optional SLIP + CRC16 fallback byte-stream tunnel (UART / JTAG)
    input logic bridge_use_slip_i,
    input logic [7:0] slip_rx_data_i,
    input logic slip_rx_valid_i,
    output logic slip_rx_ready_o,
    output logic [7:0] slip_tx_data_o,
    output logic slip_tx_valid_o,
    input logic slip_tx_ready_i,
    axi4_if.master ddr
);
  axi4_if #(.XLEN(XLEN)) cpu ();
  axi4_if #(.XLEN(XLEN)) dma_vnet ();
  axi4_if #(.XLEN(XLEN)) dma_bridge ();
  axi4_if #(.XLEN(XLEN)) dma_bus ();

  logic uart_irq, vnet_irq;
  logic [31:0] bridge_irq_mask;
  logic [31:1] core_irq;
  logic ext_wr_valid, ext_wr_pending;
  logic [XLEN-1:0] ext_wr_first, ext_wr_last;

  logic vnet_req_valid, vnet_req_write, vnet_resp_valid, vnet_resp_err;
  logic [11:0] vnet_req_addr;
  logic [1:0] vnet_req_size;
  logic [63:0] vnet_req_wdata, vnet_resp_rdata;
  logic [7:0] vnet_req_wstrb;

  logic bridge_req_valid, bridge_req_write, bridge_resp_valid, bridge_resp_err;
  logic [31:0] bridge_req_addr;
  logic [1:0] bridge_req_size;
  logic [63:0] bridge_req_wdata, bridge_resp_rdata;
  logic [7:0] bridge_req_wstrb;

  logic [7:0] rqio_rx_data, rqio_tx_data, vnet_rx_data, vnet_tx_data;
  logic rqio_rx_valid, rqio_rx_last, rqio_rx_ready;
  logic rqio_tx_valid, rqio_tx_last, rqio_tx_ready;
  logic vnet_rx_valid, vnet_rx_last, vnet_rx_ready;
  logic vnet_tx_valid, vnet_tx_last, vnet_tx_ready;

  // PLIC interrupt assignment:
  //   IRQ 1: UART
  //   IRQ 2: VirtIO-Net (local RTL DMA NIC or remote QEMU NIC) / board peripheral
  //   IRQ 3..31: Remote QEMU devices (VirtIO-Blk=3, SDHCI=4, PCIe/NVMe INTx=11..14)
  assign core_irq[1] = uart_irq | (WithQemuBridge ? bridge_irq_mask[1] : 1'b0);
  assign core_irq[2] = (WithLocalVirtioNet ? vnet_irq : 1'b0)
                     | (WithQemuBridge ? bridge_irq_mask[2] : 1'b0)
                     | (WithPeripheral ? peripheral_irq : 1'b0);
  assign core_irq[31:3] = WithQemuBridge ? bridge_irq_mask[31:3] : 29'b0;

  rapt #(
      .XLEN(XLEN)
  ) core (
      .sram_ctrl_i(rapt_pkg::SramCtrlReset),
      .clock(clk),
      .reset(reset),
      .core_reset_o(),
      .writeback_error_o(writeback_error),
      .external_write_valid_i(ext_wr_valid),
      .external_write_pending_i(ext_wr_pending),
      .external_write_first_i(ext_wr_first),
      .external_write_last_i(ext_wr_last),
      .io_interrupt(1'b0),
      .ext_irq_i(core_irq),
      .jtag_trst_n(1'b0),
      .jtag_tms(1'b1),
      .jtag_tdi(1'b0),
      .jtag_tdo(),
      .jtag_tck_en(1'b1),
      .io_master_arcache(cpu.arcache),
      .io_master_arburst(cpu.arburst),
      .io_master_arsize(cpu.arsize),
      .io_master_arlen(cpu.arlen),
      .io_master_arid(cpu.arid),
      .io_master_araddr(cpu.araddr),
      .io_master_arvalid(cpu.arvalid),
      .io_master_arready(cpu.arready),
      .io_master_rid(cpu.rid),
      .io_master_rlast(cpu.rlast),
      .io_master_rdata(cpu.rdata),
      .io_master_rresp(cpu.rresp),
      .io_master_rvalid(cpu.rvalid),
      .io_master_rready(cpu.rready),
      .io_master_awcache(cpu.awcache),
      .io_master_awburst(cpu.awburst),
      .io_master_awsize(cpu.awsize),
      .io_master_awlen(cpu.awlen),
      .io_master_awid(cpu.awid),
      .io_master_awaddr(cpu.awaddr),
      .io_master_awvalid(cpu.awvalid),
      .io_master_awready(cpu.awready),
      .io_master_wlast(cpu.wlast),
      .io_master_wdata(cpu.wdata),
      .io_master_wstrb(cpu.wstrb),
      .io_master_wvalid(cpu.wvalid),
      .io_master_wready(cpu.wready),
      .io_master_bid(cpu.bid),
      .io_master_bresp(cpu.bresp),
      .io_master_bvalid(cpu.bvalid),
      .io_master_bready(cpu.bready)
  );

  rapt_eth_rqio_mux u_eth_mux (
      .clk(clk),
      .reset(reset),
      .mac_rx_data_i(eth_rx_data_i),
      .mac_rx_valid_i(eth_rx_valid_i),
      .mac_rx_last_i(eth_rx_last_i),
      .mac_rx_ready_o(eth_rx_ready_o),
      .mac_tx_data_o(eth_tx_data_o),
      .mac_tx_valid_o(eth_tx_valid_o),
      .mac_tx_last_o(eth_tx_last_o),
      .mac_tx_ready_i(eth_tx_ready_i),
      .rqio_rx_data_o(rqio_rx_data),
      .rqio_rx_valid_o(rqio_rx_valid),
      .rqio_rx_last_o(rqio_rx_last),
      .rqio_rx_ready_i(rqio_rx_ready),
      .rqio_tx_data_i(rqio_tx_data),
      .rqio_tx_valid_i(rqio_tx_valid),
      .rqio_tx_last_i(rqio_tx_last),
      .rqio_tx_ready_o(rqio_tx_ready),
      .vnet_rx_data_o(vnet_rx_data),
      .vnet_rx_valid_o(vnet_rx_valid),
      .vnet_rx_last_o(vnet_rx_last),
      .vnet_rx_ready_i(vnet_rx_ready),
      .vnet_tx_data_i(vnet_tx_data),
      .vnet_tx_valid_i(vnet_tx_valid),
      .vnet_tx_last_i(vnet_tx_last),
      .vnet_tx_ready_o(vnet_tx_ready)
  );

  if (WithLocalVirtioNet) begin : g_virtio_net
    rapt_virtio_mmio_net #(
        .XLEN(XLEN)
    ) u_vnet (
        .clk(clk),
        .reset(reset),
        .link_up_i(eth_link_up_i),
        .req_valid_i(vnet_req_valid),
        .req_write_i(vnet_req_write),
        .req_addr_i(vnet_req_addr),
        .req_size_i(vnet_req_size),
        .req_wdata_i(vnet_req_wdata),
        .req_wstrb_i(vnet_req_wstrb),
        .resp_valid_o(vnet_resp_valid),
        .resp_rdata_o(vnet_resp_rdata),
        .resp_err_o(vnet_resp_err),
        .irq_o(vnet_irq),
        .dma(dma_vnet),
        .rx_axis_tdata_i(vnet_rx_data),
        .rx_axis_tvalid_i(vnet_rx_valid),
        .rx_axis_tlast_i(vnet_rx_last),
        .rx_axis_tready_o(vnet_rx_ready),
        .tx_axis_tdata_o(vnet_tx_data),
        .tx_axis_tvalid_o(vnet_tx_valid),
        .tx_axis_tlast_o(vnet_tx_last),
        .tx_axis_tready_i(vnet_tx_ready)
    );
  end else begin : g_no_virtio_net
    assign vnet_resp_valid = 1'b1;
    assign vnet_resp_rdata = 64'd0;
    assign vnet_resp_err   = 1'b1;
    assign vnet_irq        = 1'b0;
    assign vnet_rx_ready   = 1'b1;
    assign vnet_tx_data    = 8'h00;
    assign vnet_tx_valid   = 1'b0;
    assign vnet_tx_last    = 1'b0;
    assign dma_vnet.arvalid = 1'b0;
    assign dma_vnet.araddr  = '0;
    assign dma_vnet.arid    = '0;
    assign dma_vnet.arlen   = '0;
    assign dma_vnet.arsize  = '0;
    assign dma_vnet.arburst = '0;
    assign dma_vnet.arcache = '0;
    assign dma_vnet.rready  = 1'b0;
    assign dma_vnet.awvalid = 1'b0;
    assign dma_vnet.awaddr  = '0;
    assign dma_vnet.awid    = '0;
    assign dma_vnet.awlen   = '0;
    assign dma_vnet.awsize  = '0;
    assign dma_vnet.awburst = '0;
    assign dma_vnet.awcache = '0;
    assign dma_vnet.wvalid  = 1'b0;
    assign dma_vnet.wdata   = '0;
    assign dma_vnet.wstrb   = '0;
    assign dma_vnet.wlast   = 1'b0;
    assign dma_vnet.bready  = 1'b0;
  end

  if (WithQemuBridge) begin : g_qemu_bridge
    rapt_qemu_io_bridge #(
        .XLEN(XLEN)
    ) u_bridge (
        .clk(clk),
        .reset(reset),
        .use_slip_i(bridge_use_slip_i),
        .mmio_valid_i(bridge_req_valid),
        .mmio_write_i(bridge_req_write),
        .mmio_addr_i(bridge_req_addr),
        .mmio_size_i(bridge_req_size),
        .mmio_wdata_i(bridge_req_wdata),
        .mmio_wstrb_i(bridge_req_wstrb),
        .mmio_ready_o(bridge_resp_valid),
        .mmio_rdata_o(bridge_resp_rdata),
        .mmio_err_o(bridge_resp_err),
        .irq_mask_o(bridge_irq_mask),
        .dma(dma_bridge),
        .eth_rx_data_i(rqio_rx_data),
        .eth_rx_valid_i(rqio_rx_valid),
        .eth_rx_last_i(rqio_rx_last),
        .eth_rx_ready_o(rqio_rx_ready),
        .eth_tx_data_o(rqio_tx_data),
        .eth_tx_valid_o(rqio_tx_valid),
        .eth_tx_last_o(rqio_tx_last),
        .eth_tx_ready_i(rqio_tx_ready),
        .slip_rx_data_i(slip_rx_data_i),
        .slip_rx_valid_i(slip_rx_valid_i),
        .slip_rx_ready_o(slip_rx_ready_o),
        .slip_tx_data_o(slip_tx_data_o),
        .slip_tx_valid_o(slip_tx_valid_o),
        .slip_tx_ready_i(slip_tx_ready_i)
    );
  end else begin : g_no_qemu_bridge
    assign bridge_resp_valid = 1'b1;
    assign bridge_resp_rdata = 64'd0;
    assign bridge_resp_err   = 1'b1;
    assign bridge_irq_mask   = 32'd0;
    assign rqio_rx_ready     = 1'b1;
    assign rqio_tx_data      = 8'h00;
    assign rqio_tx_valid     = 1'b0;
    assign rqio_tx_last      = 1'b0;
    assign slip_rx_ready_o   = 1'b1;
    assign slip_tx_data_o    = 8'h00;
    assign slip_tx_valid_o   = 1'b0;
    assign dma_bridge.arvalid = 1'b0;
    assign dma_bridge.araddr  = '0;
    assign dma_bridge.arid    = '0;
    assign dma_bridge.arlen   = '0;
    assign dma_bridge.arsize  = '0;
    assign dma_bridge.arburst = '0;
    assign dma_bridge.arcache = '0;
    assign dma_bridge.rready  = 1'b0;
    assign dma_bridge.awvalid = 1'b0;
    assign dma_bridge.awaddr  = '0;
    assign dma_bridge.awid    = '0;
    assign dma_bridge.awlen   = '0;
    assign dma_bridge.awsize  = '0;
    assign dma_bridge.awburst = '0;
    assign dma_bridge.awcache = '0;
    assign dma_bridge.wvalid  = 1'b0;
    assign dma_bridge.wdata   = '0;
    assign dma_bridge.wstrb   = '0;
    assign dma_bridge.wlast   = 1'b0;
    assign dma_bridge.bready  = 1'b0;
  end

  rapt_axi4_dma_arb #(
      .XLEN(XLEN)
  ) u_dma_arb (
      .clk(clk),
      .reset(reset),
      .m0(dma_vnet),
      .m1(dma_bridge),
      .out(dma_bus)
  );

  rapt_native_io_bus #(
      .XLEN(XLEN),
      .WithDdr(WithDdr),
      .WithPeripheral(WithPeripheral),
      .WithLocalVirtioNet(WithLocalVirtioNet),
      .WithQemuBridge(WithQemuBridge),
      .RamBytes(RamBytes),
      .ClockHz(ClockHz),
      .RomFile(RomFile)
  ) bus (
      .clk(clk),
      .reset(reset),
      .uart_rx(uart_rx),
      .uart_tx(uart_tx),
      .uart_irq(uart_irq),
      .peripheral_rd(peripheral_rd),
      .peripheral_wr(peripheral_wr),
      .peripheral_raddr(peripheral_raddr),
      .peripheral_waddr(peripheral_waddr),
      .peripheral_wdata(peripheral_wdata),
      .peripheral_wstrb(peripheral_wstrb),
      .peripheral_rdata(peripheral_rdata),
      .vnet_req_valid_o(vnet_req_valid),
      .vnet_req_write_o(vnet_req_write),
      .vnet_req_addr_o(vnet_req_addr),
      .vnet_req_size_o(vnet_req_size),
      .vnet_req_wdata_o(vnet_req_wdata),
      .vnet_req_wstrb_o(vnet_req_wstrb),
      .vnet_resp_valid_i(vnet_resp_valid),
      .vnet_resp_rdata_i(vnet_resp_rdata),
      .vnet_resp_err_i(vnet_resp_err),
      .bridge_req_valid_o(bridge_req_valid),
      .bridge_req_write_o(bridge_req_write),
      .bridge_req_addr_o(bridge_req_addr),
      .bridge_req_size_o(bridge_req_size),
      .bridge_req_wdata_o(bridge_req_wdata),
      .bridge_req_wstrb_o(bridge_req_wstrb),
      .bridge_resp_valid_i(bridge_resp_valid),
      .bridge_resp_rdata_i(bridge_resp_rdata),
      .bridge_resp_err_i(bridge_resp_err),
      .external_write_valid_o(ext_wr_valid),
      .external_write_pending_o(ext_wr_pending),
      .external_write_first_o(ext_wr_first),
      .external_write_last_o(ext_wr_last),
      .idle_o(),
      .cpu(cpu),
      .dma(dma_bus),
      .ddr(ddr)
  );
endmodule
