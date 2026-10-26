`include "rapt.svh"
// A formatter property only: an aligned half store needs no second beat.
// This does not establish SQ ordering or external-observer atomicity.
module formal_half_store_beats (
    input logic [`RAPT_XLEN-1:0] address,
    data,
    high_address,
    output logic correct
);
  logic span, third;
  logic [7:0] low_mask, high_mask, third_mask;
  rapt_store_beats dut (
      .waddr(address),
      .waddr_hi(high_address),
      .waddr_third(high_address),
      .wdata(data),
      .wdata64(64'b0),
      .wfp64(1'b0),
      .walu(`RAPT_SH_WSTRB),
      .ma_store_span(span),
      .ma_store_third(third),
      .ma_waddr_lo(),
      .ma_waddr_hi(),
      .ma_waddr_third(),
      .ma_wdata_lo(),
      .ma_wdata_hi(),
      .ma_wdata_third(),
      .ma_walu_lo(low_mask),
      .ma_walu_hi(high_mask),
      .ma_walu_third(third_mask)
  );
  assign correct = address[0] || (!span && !third && low_mask == 8'h03
      && high_mask == 0 && third_mask == 0);
endmodule
