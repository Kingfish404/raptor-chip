`include "ysyx.svh"
`include "ysyx_soc.svh"
`include "ysyx_dpi_c.svh"

// Core Local INTerrupt controller
module ysyx_clint #(
    parameter bit [7:0] XLEN = `YSYX_XLEN
) (
    input clock,
    input reset,

    input [XLEN-1:0] araddr,
    input arvalid,
    output out_arready,

    output [XLEN-1:0] out_rdata,
    output [1:0] out_rresp,
    output logic out_rvalid
);
  logic [63:0] mtime = 0;
  assign out_rdata = (
    ({32{araddr == `YSYX_BUS_RTC_ADDR}} & mtime[31:0]) |
    ({32{araddr == `YSYX_BUS_RTC_ADDR_UP}} & mtime[63:32])
  );
  assign out_arready = 0;
  assign out_rresp = 0;
  always @(posedge clock) begin
    if (reset) begin
      mtime <= 0;
    end else begin
      mtime <= mtime + 1;
      if (arvalid) begin
        `YSYX_DPI_C_NPC_DIFFTEST_SKIP_REF
        out_rvalid <= 1;
      end else begin
        out_rvalid <= 0;
      end
    end
  end
endmodule
