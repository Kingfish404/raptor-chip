`include "rapt_soc_if.svh"

// Exclusive serial ownership, selected only by rapt_chip_boot at a drained
// reset boundary. Keep an initialized Flash controller parked across switches:
// the external target also retains its octal protocol until shared chip reset.
module rapt_chip_backend #(
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
    parameter int unsigned FlashPollCycles = CoreClockHz / 2
) (
    input logic clock,
    input logic reset,
    input logic flash_mode_i,
    input logic enable_i,
    output logic idle_o,
    output rapt_pkg::sram_ctrl_t sram_ctrl_o,
    axi4_if.slave axi,
    output logic sclk_o,
    output logic cs_n_o,
    output logic [7:0] dq_o,
    output logic [7:0] dq_oe_o,
    input logic [7:0] dq_i,
    input logic ds_i
);
  logic bridge_on, flash_on, flash_started_q, flash_idle;
  logic bridge_reset, flash_reset, bridge_oe;
  logic bridge_sclk, bridge_cs_n, flash_sclk, flash_cs_n;
  logic [7:0] bridge_dq, flash_dq, flash_oe;
  rapt_pkg::sram_ctrl_t bridge_sram_ctrl, flash_sram_ctrl;
  axi4_if #(.XLEN(XLEN)) bridge_axi ();
  axi4_if #(.XLEN(XLEN)) flash_axi ();

  always_ff @(posedge clock or posedge reset) begin
    if (reset) flash_started_q <= 1'b0;
    else if (flash_on) flash_started_q <= 1'b1;
  end
  assign bridge_on = enable_i && !reset && !flash_mode_i;
  assign flash_on = enable_i && !reset && flash_mode_i;
  assign bridge_reset = !bridge_on;
  assign flash_reset = reset || !flash_started_q;
  assign idle_o = !flash_started_q || flash_idle;

  assign sram_ctrl_o = bridge_on ? bridge_sram_ctrl
      : flash_on ? flash_sram_ctrl : rapt_pkg::SramCtrlReset;
  assign sclk_o = bridge_on ? bridge_sclk : flash_on ? flash_sclk : 1'b0;
  assign cs_n_o = bridge_on ? bridge_cs_n : flash_on ? flash_cs_n : 1'b1;
  assign dq_o = bridge_on ? bridge_dq : flash_on ? flash_dq : '0;
  assign dq_oe_o = bridge_on ? {8{bridge_oe}} : flash_on ? flash_oe : '0;

  // Gate all handshake directions. The inactive backend cannot accept a
  // transaction or acknowledge a response, even while its reset is asserting.
  assign bridge_axi.araddr = axi.araddr;
  assign bridge_axi.arid = axi.arid;
  assign bridge_axi.arlen = axi.arlen;
  assign bridge_axi.arsize = axi.arsize;
  assign bridge_axi.arburst = axi.arburst;
  assign bridge_axi.arcache = axi.arcache;
  assign bridge_axi.arvalid = axi.arvalid && bridge_on;
  assign bridge_axi.rready = axi.rready && bridge_on;
  assign bridge_axi.awaddr = axi.awaddr;
  assign bridge_axi.awid = axi.awid;
  assign bridge_axi.awlen = axi.awlen;
  assign bridge_axi.awsize = axi.awsize;
  assign bridge_axi.awburst = axi.awburst;
  assign bridge_axi.awcache = axi.awcache;
  assign bridge_axi.awvalid = axi.awvalid && bridge_on;
  assign bridge_axi.wdata = axi.wdata;
  assign bridge_axi.wstrb = axi.wstrb;
  assign bridge_axi.wlast = axi.wlast;
  assign bridge_axi.wvalid = axi.wvalid && bridge_on;
  assign bridge_axi.bready = axi.bready && bridge_on;

  assign flash_axi.araddr = axi.araddr;
  assign flash_axi.arid = axi.arid;
  assign flash_axi.arlen = axi.arlen;
  assign flash_axi.arsize = axi.arsize;
  assign flash_axi.arburst = axi.arburst;
  assign flash_axi.arcache = axi.arcache;
  assign flash_axi.arvalid = axi.arvalid && flash_on;
  assign flash_axi.rready = axi.rready && flash_on;
  assign flash_axi.awaddr = axi.awaddr;
  assign flash_axi.awid = axi.awid;
  assign flash_axi.awlen = axi.awlen;
  assign flash_axi.awsize = axi.awsize;
  assign flash_axi.awburst = axi.awburst;
  assign flash_axi.awcache = axi.awcache;
  assign flash_axi.awvalid = axi.awvalid && flash_on;
  assign flash_axi.wdata = axi.wdata;
  assign flash_axi.wstrb = axi.wstrb;
  assign flash_axi.wlast = axi.wlast;
  assign flash_axi.wvalid = axi.wvalid && flash_on;
  assign flash_axi.bready = axi.bready && flash_on;

  assign axi.arready = bridge_on ? bridge_axi.arready : flash_on && flash_axi.arready;
  assign axi.awready = bridge_on ? bridge_axi.awready : flash_on && flash_axi.awready;
  assign axi.wready = bridge_on ? bridge_axi.wready : flash_on && flash_axi.wready;
  assign axi.rvalid = bridge_on ? bridge_axi.rvalid : flash_on && flash_axi.rvalid;
  assign axi.rid = bridge_on ? bridge_axi.rid : flash_on ? flash_axi.rid : '0;
  assign axi.rdata = bridge_on ? bridge_axi.rdata : flash_on ? flash_axi.rdata : '0;
  assign axi.rresp = bridge_on ? bridge_axi.rresp : flash_on ? flash_axi.rresp : '0;
  assign axi.rlast = bridge_on ? bridge_axi.rlast : flash_on && flash_axi.rlast;
  assign axi.bvalid = bridge_on ? bridge_axi.bvalid : flash_on && flash_axi.bvalid;
  assign axi.bid = bridge_on ? bridge_axi.bid : flash_on ? flash_axi.bid : '0;
  assign axi.bresp = bridge_on ? bridge_axi.bresp : flash_on ? flash_axi.bresp : '0;

  rapt_axi_xspi #(
      .XLEN(XLEN)
  ) u_bridge (
      .clock,
      .reset(bridge_reset),
      .sram_ctrl_o(bridge_sram_ctrl),
      .axi(bridge_axi),
      .sclk_o(bridge_sclk),
      .cs_n_o(bridge_cs_n),
      .dq_o(bridge_dq),
      .dq_oe_o(bridge_oe),
      .dq_i(bridge_on ? dq_i : 8'b0)
  );

  rapt_axi_flash #(
      .XLEN(XLEN),
      .FlashStorageOffset(FlashStorageOffset),
      .FlashWriteStart(FlashWriteStart),
      .FlashWriteEnd(FlashWriteEnd),
      .CoreClockHz(CoreClockHz),
      .HalfPeriod(FlashHalfPeriod),
      .PowerupCycles(FlashPowerupCycles),
      .ResetCycles(FlashResetCycles),
      .RecoveryCycles(FlashRecoveryCycles),
      .PollCycles(FlashPollCycles)
  ) u_flash (
      .clock,
      .reset(flash_reset),
      .idle_o(flash_idle),
      .sram_ctrl_o(flash_sram_ctrl),
      .axi(flash_axi),
      .sclk_o(flash_sclk),
      .cs_n_o(flash_cs_n),
      .dq_o(flash_dq),
      .dq_oe_o(flash_oe),
      .dq_i(flash_on ? dq_i : 8'b0),
      .ds_i(flash_on && ds_i)
  );

  `RAPT_SVA(clock, reset, BACKEND_EXCLUSIVE, !(bridge_on && flash_on))
endmodule
