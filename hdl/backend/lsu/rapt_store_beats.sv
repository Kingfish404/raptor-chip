`include "rapt.svh"

// Split-store byte formatting only; the SQ retains beat sequencing and
// accepted-write ownership. The high address is translated by the IOQ.
module rapt_store_beats #(
    parameter int XLEN = `RAPT_XLEN
) (
    input logic [XLEN-1:0] waddr,
    waddr_hi,
    wdata,
    input logic [XLEN-1:0] waddr_third,
    input logic [63:0] wdata64,
    input logic wfp64,
    input logic [4:0] walu,
    output logic ma_store_span,
    ma_store_third,
    output logic [XLEN-1:0] ma_waddr_lo,
    ma_waddr_hi,
    ma_waddr_third,
    output logic [XLEN-1:0] ma_wdata_lo,
    ma_wdata_hi,
    ma_wdata_third,
    output logic [7:0] ma_walu_lo,
    ma_walu_hi,
    ma_walu_third
);
  localparam int OFFW = $clog2(XLEN / 8);
  logic [OFFW:0]   ma_w_off;       // byte offset into the aligned word (extra bit)
  logic [OFFW+1:0] ma_w_size;      // store size in bytes, 1/2/4/(8)
  logic [XLEN/8-1:0] ma_wstrb_lo;
  /* verilator lint_off UNUSEDSIGNAL */
  logic [2*XLEN/8-1:0]   ma_wstrb_wide;
  logic [2*XLEN-1:0]     ma_wdata_wide;
  /* verilator lint_on UNUSEDSIGNAL */
  logic [$clog2(2*XLEN)-1:0] ma_w_shift;

  assign ma_w_off = {1'b0, waddr[OFFW-1:0]};
  // Compute store size from walu byte mask.
  always_comb begin
    unique case (walu)
      `RAPT_SB_WSTRB: ma_w_size = (OFFW+2)'(1);
      `RAPT_SH_WSTRB: ma_w_size = (OFFW+2)'(2);
      `RAPT_SW_WSTRB: ma_w_size = (OFFW+2)'(4);
`ifdef RAPT_RV64
      `RAPT_SD_WSTRB: ma_w_size = (OFFW+2)'(8);
`else
      default:        ma_w_size = wfp64 ? (OFFW+2)'(8) : (OFFW+2)'(0);
`endif
`ifdef RAPT_RV64
      default:        ma_w_size = (OFFW+2)'(0);
`endif
    endcase
  end
  // Misaligned cross-word if off + size > word size.
  assign ma_store_span = (ma_w_size != '0)
                      && ((ma_w_off + ma_w_size) > (OFFW+2)'(XLEN/8));
  assign ma_store_third = (XLEN == 32) && wfp64
                       && (waddr[OFFW-1:0] != '0);

`ifdef RAPT_RV64
  assign ma_wstrb_lo = (walu == `RAPT_SD_WSTRB) ? 8'hff : {3'b0, walu};
`else
  assign ma_wstrb_lo = wfp64 ? 4'hf : walu[XLEN/8-1:0];
`endif

  assign ma_wstrb_wide = {{(XLEN/8){1'b0}}, ma_wstrb_lo} << ma_w_off;
  assign ma_w_shift    = {{($clog2(2*XLEN)-OFFW-3){1'b0}}, waddr[OFFW-1:0], 3'b000};
  assign ma_wdata_wide = (wfp64 ? (2*XLEN)'(wdata64) : (2*XLEN)'(wdata)) << ma_w_shift;
  assign ma_wdata_lo   = ma_wdata_wide[XLEN-1:0];
  assign ma_wdata_hi   = ma_wdata_wide[2*XLEN-1:XLEN];
  // The IOQ pre-translates the next virtual page when the original store
  // crosses a page boundary.  For the common same-page case this is simply
  // the next aligned physical word/dword.
  assign ma_waddr_lo = {waddr[XLEN-1:OFFW], {OFFW{1'b0}}};
  assign ma_waddr_hi = waddr_hi;
`ifdef RAPT_RV64
  assign ma_walu_hi = 8'(ma_wstrb_wide[2*XLEN/8-1:XLEN/8]);
`else
  // An RV32 FSD always contributes four middle bytes to beat 1; an
  // unaligned tail, if any, is emitted separately as beat 2.
  assign ma_walu_hi = wfp64 ? 8'h0f : 8'(ma_wstrb_wide[2*XLEN/8-1:XLEN/8]);
`endif
  always_comb begin
`ifdef RAPT_RV64
    ma_walu_lo = (walu == `RAPT_SD_WSTRB) ? 8'hff : {3'b0, walu};
`else
    ma_walu_lo = wfp64 ? 8'h0f : {4'b0, walu[3:0]};
`endif
    if (ma_store_span) ma_walu_lo = 8'(ma_wstrb_wide[XLEN/8-1:0]);
    ma_walu_third = '0;
    ma_wdata_third = '0;
    if ((XLEN == 32) && wfp64) begin
      unique case (waddr[1:0])
        2'b00: begin
          ma_walu_third = '0;
        end
        2'b01: begin
          ma_walu_third = 8'h01;
          ma_wdata_third = XLEN'(wdata64 >> 56);
        end
        2'b10: begin
          ma_walu_third = 8'h03;
          ma_wdata_third = XLEN'(wdata64 >> 48);
        end
        default: begin
          ma_walu_third = 8'h07;
          ma_wdata_third = XLEN'(wdata64 >> 40);
        end
      endcase
    end
  end
  assign ma_waddr_third = waddr_third;

endmodule
