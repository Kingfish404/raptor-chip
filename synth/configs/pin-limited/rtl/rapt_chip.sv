`include "rapt_soc_if.svh"

// rapt_chip: logical chip top with one clock domain and no pad cells. Memory and
// peripherals are off-chip behind the octal link, so PC_INIT and every external
// address reach the board through rapt_axi_xspi.
//
// JTAG is oversampled by the core clock: TCK must be well below clk_i / 4. The
// TAP advances on a clock enable, so there is no separate TCK clock tree. It
// therefore needs a running core clock, which any debug access needs anyway.
module rapt_chip #(
    parameter int XLEN = `RAPT_XLEN
) (
    input logic clk_i,
    input logic rst_ni,
    input logic irq_i,
    output logic xspi_sclk_o,
    output logic xspi_cs_no,
    input logic [7:0] xspi_dq_i,
    output logic [7:0] xspi_dq_o,
    output logic xspi_dq_oe_o,
    input logic jtag_tck_i,
    input logic jtag_tms_i,
    input logic jtag_tdi_i,
    output logic jtag_tdo_o,
    output logic diag_o
);
  localparam int DiagBits = 10;

  logic [1:0] reset_sync_q, irq_sync_q, tms_sync_q, tdi_sync_q;
  logic [2:0] tck_sync_q;
  logic [DiagBits-1:0] diag_q;
  logic reset, tck_en, tdo, writeback_error_unused;
  rapt_pkg::sram_ctrl_t sram_ctrl;
  axi4_if #(.XLEN(XLEN)) offchip ();

  // Asynchronous assertion, synchronous release.
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) reset_sync_q <= '0;
    else reset_sync_q <= {reset_sync_q[0], 1'b1};
  end
  assign reset = !reset_sync_q[1];

  always_ff @(posedge clk_i) begin
    irq_sync_q <= {irq_sync_q[0], irq_i};
    tck_sync_q <= {tck_sync_q[1:0], jtag_tck_i};
    tms_sync_q <= {tms_sync_q[0], jtag_tms_i};
    tdi_sync_q <= {tdi_sync_q[0], jtag_tdi_i};
    jtag_tdo_o <= tdo;
    diag_q <= reset ? '0 : diag_q + 1'b1;
  end
  assign tck_en = tck_sync_q[1] && !tck_sync_q[2];
  // A slow square wave proves clock, reset release and output pads without the link.
  assign diag_o = diag_q[DiagBits-1];

  rapt #(
      .XLEN(XLEN),
      .MemoryReadCredits(1)
  ) u_cluster (
      .sram_ctrl_i(sram_ctrl),
      .clock(clk_i),
      .reset(reset),
      .writeback_error_o(writeback_error_unused),
      .external_write_valid_i(1'b0),
      .external_write_pending_i(1'b0),
      .external_write_first_i('0),
      .external_write_last_i('0),
      .io_interrupt(irq_sync_q[1]),
      .ext_irq_i('0),
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

  rapt_axi_xspi #(
      .XLEN(XLEN)
  ) u_offchip (
      .sram_ctrl_o(sram_ctrl),
      .clock(clk_i),
      .reset(reset),
      .axi(offchip),
      .sclk_o(xspi_sclk_o),
      .cs_n_o(xspi_cs_no),
      .dq_i(xspi_dq_i),
      .dq_o(xspi_dq_o),
      .dq_oe_o(xspi_dq_oe_o)
  );
endmodule
