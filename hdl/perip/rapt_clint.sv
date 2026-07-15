`include "rapt.svh"
`include "rapt_soc.svh"
`include "rapt_soc_if.svh"

// Core Local INTerrupt controller (standard CLINT layout)
//
// Register map (base 0x02000000):
//   0x0000  msip      (32-bit, bit 0 only)  - M-mode software interrupt pending
//   0x4000  mtimecmp  (64-bit)              - timer compare register
//   0xBFF8  mtime     (64-bit, read-only)   - monotonic timer counter
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

    input reset
);
  logic [63:0] mtime;
  logic [63:0] mtimecmp;
  logic        msip_reg;
  localparam int MTIMEdivW = (MTIME_DIV <= 1) ? 1 : $clog2(MTIME_DIV);
  logic [MTIMEdivW-1:0] mtime_div_cnt;

  // --- Interrupt generation (level-triggered) ---
  assign clint_bus.timer_int = (mtime >= mtimecmp);
  assign clint_bus.sw_int    = msip_reg;

  // --- Read mux ---
  always_comb begin
    clint_bus.rdata = '0;
    case (clint_bus.araddr)
      `RAPT_CLINT_MSIP:     clint_bus.rdata = {{(XLEN - 1) {1'b0}}, msip_reg};
      `RAPT_CLINT_MTIMECMP: clint_bus.rdata = mtimecmp[XLEN-1:0];
      `RAPT_CLINT_MTIMECMP_UP: begin
        if (XLEN == 32) clint_bus.rdata = mtimecmp[63:32];
      end
      `RAPT_BUS_RTC_ADDR:   clint_bus.rdata = mtime[XLEN-1:0];
      `RAPT_BUS_RTC_ADDR_UP: begin
        if (XLEN == 32) clint_bus.rdata = mtime[63:32];
      end
      default:              clint_bus.rdata = '0;
    endcase
  end

  // --- Registers ---
  always_ff @(posedge clock) begin
    if (reset) begin
      mtime    <= 64'h0;
      mtimecmp <= 64'hFFFF_FFFF_FFFF_FFFF;
      msip_reg <= 1'b0;
      mtime_div_cnt <= '0;
    end else begin
      if (MTIME_DIV <= 1) begin
        mtime <= mtime + 64'h1;
      end else if (mtime_div_cnt == MTIMEdivW'(MTIME_DIV - 1)) begin
        mtime <= mtime + 64'h1;
        mtime_div_cnt <= '0;
      end else begin
        mtime_div_cnt <= mtime_div_cnt + MTIMEdivW'(1);
      end
      if (clint_bus.wvalid) begin
        case (clint_bus.awaddr)
          `RAPT_CLINT_MSIP: msip_reg <= clint_bus.wdata[0];
          `RAPT_CLINT_MTIMECMP: mtimecmp[XLEN-1:0] <= clint_bus.wdata;
          `RAPT_CLINT_MTIMECMP_UP: begin
            if (XLEN == 32) mtimecmp[63:32] <= clint_bus.wdata;
          end
          default: ;
        endcase
      end
    end
  end
endmodule
