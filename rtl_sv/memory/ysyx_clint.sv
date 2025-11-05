`include "ysyx.svh"
`include "ysyx_soc.svh"
`include "ysyx_dpi_c.svh"

// Core Local INTerrupt controller
module ysyx_clint #(
    parameter bit [7:0] XLEN = `YSYX_XLEN
) (
    input clock,

    input [XLEN-1:0] araddr,
    input arvalid,

    output [XLEN-1:0] out_rdata,

    output io_trap_o,
    input  io_trap_received_i,

    input reset
);
  logic [63:0] mtime;
  logic trap;
  assign out_rdata = (
    ({XLEN{araddr == `YSYX_BUS_RTC_ADDR}} & mtime[31:0]) |
    ({XLEN{araddr == `YSYX_BUS_RTC_ADDR_UP}} & mtime[63:32])
  );
  assign io_trap_o = trap;
  always @(posedge clock) begin
    if (reset) begin
      mtime <= 0;
      trap  <= 0;
    end else begin
      mtime <= mtime + 1;
      if (~|(mtime[18:0] ^ 'h40000)) begin
        trap <= 1;
      end else if (io_trap_received_i) begin
        trap <= 0;
      end
      if (arvalid) begin
        `YSYX_DPI_C_NPC_DIFFTEST_SKIP_REF
      end
    end
  end
endmodule
