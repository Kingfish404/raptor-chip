`include "rapt_soc_if.svh"

// rapt_chip: logical chip top with one clock domain and no pad cells. Memory and
// peripherals use one of two serial backends. Chip reset selects ROM-XIP over
// Flash. SBA boot control applies at the next drained core reset; IRQ is always
// an interrupt input. See docs/chip.md for the register and switching contract.
//
// JTAG is oversampled by the core clock: TCK must be well below clk_i / 4. The
// TAP advances on a clock enable, so there is no separate TCK clock tree. It
// therefore needs a running core clock, which any debug access needs anyway.
module rapt_chip #(
    parameter int XLEN = `RAPT_XLEN,
    parameter logic [23:0] FlashStorageOffset = 24'h000000,
    parameter int unsigned FlashWriteStart = 32'h00000000,
    parameter int unsigned FlashWriteEnd = 32'h00800000,
    parameter int unsigned CoreClockHz = 100_000_000,
    parameter int unsigned FlashHalfPeriod = CoreClockHz > 80_000_000
        ? (CoreClockHz + 9_999_999) / 10_000_000 : 8,
    parameter int unsigned FlashPowerupCycles = CoreClockHz + 1,
    parameter int unsigned FlashResetCycles = CoreClockHz / 10000 + 1,
    parameter int unsigned FlashRecoveryCycles = CoreClockHz + 1,
    parameter int unsigned FlashPollCycles = CoreClockHz / 2,
    parameter bit LocalIo = 1'b0
) (
    input logic clk_i,
    input logic rst_ni,
    input logic irq_i,
    output logic xspi_sclk_o,
    output logic xspi_cs_no,
    input logic [7:0] xspi_dq_i,
    input logic xspi_ds_i,
    output logic [7:0] xspi_dq_o,
    output logic [7:0] xspi_dq_oe_o,
    input logic jtag_tck_i,
    input logic jtag_tms_i,
    input logic jtag_tdi_i,
    output logic jtag_tdo_o,
    output logic diag_o,
    output logic diag_oe_o,
    input logic [1:0] uart_rx_i,
    output logic [1:0] uart_tx_o,
    input logic [2:0] gpio_i,
    output logic [2:0] gpio_o,
    output logic [2:0] gpio_oe_o
);
  localparam int DiagBits = 10;

  logic [1:0] reset_sync_q, irq_sync_q, tms_sync_q, tdi_sync_q;
  logic [2:0] tck_sync_q;
  logic [DiagBits-1:0] diag_q;
  logic reset, link_reset, core_reset, boot_flash, boot_mode_valid, cluster_irq;
  logic backend_enable, backend_idle;
  logic tck_en, tdo, writeback_error_unused;
  logic [1:0] uart_irq;
  logic [`RAPT_PLIC_NDEV:1] peripheral_irqs;
  rapt_pkg::sram_ctrl_t sram_ctrl;
  axi4_if #(.XLEN(XLEN)) offchip ();
  axi4_if #(.XLEN(XLEN)) backend_axi ();
  axi4_if #(.XLEN(XLEN)) serial_axi ();

  always_comb begin
    peripheral_irqs = '0;
    peripheral_irqs[2] = uart_irq[0];
    peripheral_irqs[3] = uart_irq[1];
  end

  if (LocalIo) begin : g_local_io
    rapt_chip_local_io #(
        .XLEN(XLEN),
        .CoreClockHz(CoreClockHz)
    ) u_io (
        .clock(clk_i),
        .reset(reset),
        .axi(offchip),
        .backend(backend_axi),
        .uart_rx_i,
        .uart_tx_o,
        .uart_irq_o(uart_irq),
        .gpio_i,
        .gpio_o,
        .gpio_oe_o
    );
  end else begin : g_external_io
    assign backend_axi.araddr = offchip.araddr;
    assign backend_axi.arid = offchip.arid;
    assign backend_axi.arlen = offchip.arlen;
    assign backend_axi.arsize = offchip.arsize;
    assign backend_axi.arburst = offchip.arburst;
    assign backend_axi.arcache = offchip.arcache;
    assign backend_axi.arvalid = offchip.arvalid;
    assign offchip.arready = backend_axi.arready;
    assign offchip.rid = backend_axi.rid;
    assign offchip.rdata = backend_axi.rdata;
    assign offchip.rresp = backend_axi.rresp;
    assign offchip.rlast = backend_axi.rlast;
    assign offchip.rvalid = backend_axi.rvalid;
    assign backend_axi.rready = offchip.rready;
    assign backend_axi.awaddr = offchip.awaddr;
    assign backend_axi.awid = offchip.awid;
    assign backend_axi.awlen = offchip.awlen;
    assign backend_axi.awsize = offchip.awsize;
    assign backend_axi.awburst = offchip.awburst;
    assign backend_axi.awcache = offchip.awcache;
    assign backend_axi.awvalid = offchip.awvalid;
    assign offchip.awready = backend_axi.awready;
    assign backend_axi.wdata = offchip.wdata;
    assign backend_axi.wstrb = offchip.wstrb;
    assign backend_axi.wlast = offchip.wlast;
    assign backend_axi.wvalid = offchip.wvalid;
    assign offchip.wready = backend_axi.wready;
    assign offchip.bid = backend_axi.bid;
    assign offchip.bresp = backend_axi.bresp;
    assign offchip.bvalid = backend_axi.bvalid;
    assign backend_axi.bready = offchip.bready;
    assign uart_tx_o = '1;
    assign uart_irq = '0;
    assign gpio_o = '0;
    assign gpio_oe_o = '0;
  end

  // Asynchronous assertion, synchronous release.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) reset_sync_q <= '0;
    else reset_sync_q <= {reset_sync_q[0], 1'b1};
  end
  assign link_reset = !reset_sync_q[1];
  assign reset = link_reset;
  assign cluster_irq = irq_sync_q[1];

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      irq_sync_q <= '0;
      tck_sync_q <= '0;
      tms_sync_q <= '1;
      tdi_sync_q <= '1;
      jtag_tdo_o <= 1'b0;
      diag_q <= '0;
    end else begin
      irq_sync_q <= {irq_sync_q[0], irq_i};
      tck_sync_q <= {tck_sync_q[1:0], jtag_tck_i};
      tms_sync_q <= {tms_sync_q[0], jtag_tms_i};
      tdi_sync_q <= {tdi_sync_q[0], jtag_tdi_i};
      jtag_tdo_o <= tdo;
      diag_q <= reset ? '0 : diag_q + 1'b1;
    end
  end
  assign tck_en = tck_sync_q[1] && !tck_sync_q[2];
  // A slow square wave proves clock, reset release and output pads without the link.
  assign diag_o = diag_q[DiagBits-1];
  assign diag_oe_o = boot_mode_valid && !boot_flash && !link_reset;

  rapt #(
      .XLEN(XLEN),
      .MemoryReadCredits(1)
  ) u_cluster (
      .sram_ctrl_i(sram_ctrl),
      .clock(clk_i),
      .reset(reset),
      .core_reset_o(core_reset),
      .writeback_error_o(writeback_error_unused),
      .external_write_valid_i(1'b0),
      .external_write_pending_i(1'b0),
      .external_write_first_i('0),
      .external_write_last_i('0),
      .io_interrupt(cluster_irq),
      .ext_irq_i(peripheral_irqs),
      .jtag_tck_en(tck_en),
      .jtag_trst_n(1'b1),
      .jtag_tms(tms_sync_q[1]),
      .jtag_tdi(tdi_sync_q[1]),
      .jtag_tdo(tdo),
      .io_master_arcache(offchip.arcache),
      .io_master_arburst(offchip.arburst),
      .io_master_arsize(offchip.arsize),
      .io_master_arlen(offchip.arlen),
      .io_master_arid(offchip.arid),
      .io_master_araddr(offchip.araddr),
      .io_master_arvalid(offchip.arvalid),
      .io_master_arready(offchip.arready),
      .io_master_rid(offchip.rid),
      .io_master_rlast(offchip.rlast),
      .io_master_rdata(offchip.rdata),
      .io_master_rresp(offchip.rresp),
      .io_master_rvalid(offchip.rvalid),
      .io_master_rready(offchip.rready),
      .io_master_awcache(offchip.awcache),
      .io_master_awburst(offchip.awburst),
      .io_master_awsize(offchip.awsize),
      .io_master_awlen(offchip.awlen),
      .io_master_awid(offchip.awid),
      .io_master_awaddr(offchip.awaddr),
      .io_master_awvalid(offchip.awvalid),
      .io_master_awready(offchip.awready),
      .io_master_wlast(offchip.wlast),
      .io_master_wdata(offchip.wdata),
      .io_master_wstrb(offchip.wstrb),
      .io_master_wvalid(offchip.wvalid),
      .io_master_wready(offchip.wready),
      .io_master_bid(offchip.bid),
      .io_master_bresp(offchip.bresp),
      .io_master_bvalid(offchip.bvalid),
      .io_master_bready(offchip.bready)
  );

  rapt_chip_boot #(
      .XLEN(XLEN)
  ) u_boot (
      .clock(clk_i),
      .reset(link_reset),
      .core_reset_i(core_reset),
      .backend_idle_i(backend_idle),
      .flash_mode_o(boot_flash),
      .enable_o(backend_enable),
      .axi(backend_axi),
      .backend(serial_axi)
  );
  assign boot_mode_valid = backend_enable;

  rapt_chip_backend #(
      .XLEN(XLEN),
      .FlashStorageOffset(FlashStorageOffset),
      .FlashWriteStart(FlashWriteStart),
      .FlashWriteEnd(FlashWriteEnd),
      .CoreClockHz(CoreClockHz),
      .FlashHalfPeriod(FlashHalfPeriod),
      .FlashPowerupCycles(FlashPowerupCycles),
      .FlashResetCycles(FlashResetCycles),
      .FlashRecoveryCycles(FlashRecoveryCycles),
      .FlashPollCycles(FlashPollCycles)
  ) u_backend (
      .clock(clk_i),
      .reset(link_reset),
      .flash_mode_i(boot_flash),
      .enable_i(backend_enable),
      .idle_o(backend_idle),
      .sram_ctrl_o(sram_ctrl),
      .axi(serial_axi),
      .sclk_o(xspi_sclk_o),
      .cs_n_o(xspi_cs_no),
      .dq_i(xspi_dq_i),
      .dq_o(xspi_dq_o),
      .dq_oe_o(xspi_dq_oe_o),
      .ds_i(xspi_ds_i)
  );
endmodule
