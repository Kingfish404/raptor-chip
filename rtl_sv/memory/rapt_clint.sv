`include "rapt.svh"
`include "rapt_soc.svh"

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
    parameter bit [7:0] XLEN = `RAPT_XLEN
) (
    input clock,

    // Read port (active when bus detects CLINT address on load)
    input [XLEN-1:0] araddr,
    output logic [XLEN-1:0] out_rdata,

    // Write port (active when bus detects CLINT address on store)
    input [XLEN-1:0] awaddr,
    input [XLEN-1:0] wdata,
    input wvalid,

    // Level-triggered interrupt outputs
    output timer_int,
    output sw_int,

    input reset
);
  logic [63:0] mtime;
  logic [63:0] mtimecmp;
  logic        msip_reg;

  // --- Interrupt generation (level-triggered) ---
  assign timer_int = (mtime >= mtimecmp);
  assign sw_int    = msip_reg;

  // --- Read mux ---
  always_comb begin
    out_rdata = '0;
    case (araddr)
      `RAPT_CLINT_MSIP:     out_rdata = {{(XLEN - 1) {1'b0}}, msip_reg};
      `RAPT_CLINT_MTIMECMP: out_rdata = mtimecmp[XLEN-1:0];
      `RAPT_CLINT_MTIMECMP_UP: begin
        if (XLEN == 32) out_rdata = mtimecmp[63:32];
      end
      `RAPT_BUS_RTC_ADDR:   out_rdata = mtime[XLEN-1:0];
      `RAPT_BUS_RTC_ADDR_UP: begin
        if (XLEN == 32) out_rdata = mtime[63:32];
      end
      default:              out_rdata = '0;
    endcase
  end

  // --- Registers ---
  always_ff @(posedge clock) begin
    if (reset) begin
      mtime    <= 64'h0;
      mtimecmp <= 64'hFFFF_FFFF_FFFF_FFFF;
      msip_reg <= 1'b0;
    end else begin
      mtime <= mtime + 64'h1;
      if (wvalid) begin
        case (awaddr)
          `RAPT_CLINT_MSIP: msip_reg <= wdata[0];
          `RAPT_CLINT_MTIMECMP: mtimecmp[XLEN-1:0] <= wdata;
          `RAPT_CLINT_MTIMECMP_UP: begin
            if (XLEN == 32) mtimecmp[63:32] <= wdata;
          end
          default: ;
        endcase
      end
    end
  end
endmodule
