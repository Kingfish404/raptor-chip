`include "rapt.svh"
`include "rapt_soc.svh"
`include "rapt_soc_if.svh"

// Core Local INTerrupt controller (standard CLINT layout)
//
// Register map (base 0x02000000):
//   0x0000  msip      (32-bit, bit 0 only)  - M-mode software interrupt pending
//   0x4000  mtimecmp  (64-bit)              - timer compare register
//   0xBFF8  mtime     (64-bit, read/write)  - real-time counter
//
// Interrupt outputs are active-high level signals:
//   timer_int = (mtime >= mtimecmp)
//   sw_int    = msip[0]
module rapt_clint #(
    parameter int XLEN = `RAPT_XLEN,
    // Pace mtime so it ticks at RAPT_MTIME_FREQ_MHZ (DTS timebase-frequency).
    // Override via VFLAGS="-DRAPT_MTIME_FREQ_MHZ=..." or by passing MTIME_DIV at
    // instantiation. See hdl/include/npc/rapt_soc.svh.
    parameter int MTIME_DIV = `RAPT_MTIME_DIV
) (
    input clock,

    clint_bus_if.slave clint_bus,

`ifdef FORMAL
    input reset,
    output logic [63:0] formal_mtime,
    output logic [63:0] formal_mtimecmp,
    output logic formal_msip,
    output logic [((MTIME_DIV <= 1) ? 1 : $clog2(MTIME_DIV))-1:0]
        formal_mtime_div_cnt
`else
    input reset
`endif
);
  logic [63:0] mtime;
  logic [63:0] mtimecmp;
  logic        msip_reg;
  localparam int MTIMEdivW = (MTIME_DIV <= 1) ? 1 : $clog2(MTIME_DIV);
  logic [MTIMEdivW-1:0] mtime_div_cnt;

`ifdef FORMAL
  assign formal_mtime = mtime;
  assign formal_mtimecmp = mtimecmp;
  assign formal_msip = msip_reg;
  assign formal_mtime_div_cnt = mtime_div_cnt;
`endif

  // --- Interrupt generation (level-triggered) ---
  assign clint_bus.timer_int = (mtime >= mtimecmp);
  assign clint_bus.sw_int    = msip_reg;
  assign clint_bus.mtime_value = mtime;
  // The router normalizes AXI data/strobes to byte zero of the addressed
  // transfer. Reposition them within the 64-bit register, independently of
  // XLEN, so byte/halfword offsets do not alias or disappear.
  logic [63:0] register_wdata;
  logic [7:0] register_wstrb;
  logic mtime_write, mtimecmp_write;
  assign register_wdata = 64'(clint_bus.wdata) << {clint_bus.awaddr[2:0],3'b000};
  assign register_wstrb = 8'(clint_bus.wstrb) << clint_bus.awaddr[2:0];
  assign mtime_write = clint_bus.wvalid && |register_wstrb
      && ((clint_bus.awaddr & ~XLEN'(7)) == `RAPT_BUS_RTC_ADDR);
  assign mtimecmp_write = clint_bus.wvalid
      && ((clint_bus.awaddr & ~XLEN'(7)) == `RAPT_CLINT_MTIMECMP);

  // Select one register before byte alignment, sharing the read shifter.
  logic [63:0] read_register;
  always_comb begin
    read_register = '0;
    if ((clint_bus.araddr & ~XLEN'(7)) == `RAPT_CLINT_MTIMECMP) read_register = mtimecmp;
    else if ((clint_bus.araddr & ~XLEN'(7)) == `RAPT_BUS_RTC_ADDR) read_register = mtime;
    else if ((clint_bus.araddr & ~XLEN'(3)) == `RAPT_CLINT_MSIP) read_register = {63'b0, msip_reg};
  end
  assign clint_bus.rdata = XLEN'(read_register >> {clint_bus.araddr[2:0], 3'b000});

  // --- Registers ---
  always_ff @(posedge clock) begin
    if (reset) begin
      mtime    <= 64'h0;
      mtimecmp <= 64'hFFFF_FFFF_FFFF_FFFF;
      msip_reg <= 1'b0;
      mtime_div_cnt <= '0;
    end else begin
      if (MTIME_DIV <= 1) begin
        if (!mtime_write) mtime <= mtime + 64'h1;
      end else if (mtime_div_cnt == MTIMEdivW'(MTIME_DIV - 1)) begin
        if (!mtime_write) mtime <= mtime + 64'h1;
        mtime_div_cnt <= '0;
      end else begin
        mtime_div_cnt <= mtime_div_cnt + MTIMEdivW'(1);
      end
      // A nonempty time write wins a coincident tick; untouched bytes
      // retain their pre-edge value and the divider phase keeps advancing.
      for (int b = 0; b < 8; b++) begin
        if (mtime_write && register_wstrb[b]) mtime[8*b+:8] <= register_wdata[8*b+:8];
        if (mtimecmp_write && register_wstrb[b]) mtimecmp[8*b+:8] <= register_wdata[8*b+:8];
      end
      if (clint_bus.wvalid && clint_bus.awaddr == (`RAPT_CLINT_MSIP) && clint_bus.wstrb[0])
        msip_reg <= clint_bus.wdata[0];
    end
  end
endmodule
