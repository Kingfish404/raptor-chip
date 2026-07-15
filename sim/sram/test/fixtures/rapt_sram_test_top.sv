// Minimal STA smoke wrapper: a single `rapt_sram_1r1w` configured as the
// L1I 32x32 shape, exposed at top level. Used by `make test-sta` to drive
// the yosys+OpenSTA flow through the real blackbox+.lib pair so we can
// confirm:
//   - Yosys preserves the macro (does not flatten the blackbox).
//   - OpenSTA finds at least one path through the macro pins.
//   - Setup checks reference the macro's clk0/clk1 pins.
//
// Keep this top-level small so the timing report is dominated by the
// SRAM macro arcs, not by surrounding glue logic.

`define RAPT_USE_SRAM_MACRO 1

module rapt_sram_test_top #(
    parameter int ADDR_WIDTH = 5,
    parameter int DATA_WIDTH = 32
) (
    input  logic                  clock,
    input  logic                  ren,
    input  logic [ADDR_WIDTH-1:0] raddr,
    output logic [DATA_WIDTH-1:0] rdata,
    input  logic                  wen,
    input  logic [ADDR_WIDTH-1:0] waddr,
    input  logic [DATA_WIDTH-1:0] wdata
);
  rapt_sram_1r1w #(
      .ADDR_WIDTH(ADDR_WIDTH),
      .DATA_WIDTH(DATA_WIDTH)
  ) u_sram (
      .clock(clock),
      .ren  (ren),
      .raddr(raddr),
      .rdata(rdata),
      .wen  (wen),
      .waddr(waddr),
      .wdata(wdata)
  );
endmodule
