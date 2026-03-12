/**
 * ysyx_sram_1r1w - Simple dual-port SRAM behavioral model (1 Read + 1 Write)
 *
 * Standard SRAM wrapper for cache data/tag arrays. Provides a well-defined
 * interface that can be replaced with foundry SRAM macros for tapeout.
 *
 * Behavioral model (default):
 *   - Synchronous read: address latched on posedge clock, data available after
 *     tCQ (modeled as next-cycle output). Matches real foundry SRAM timing
 *     and FPGA Block RAM inference pattern.
 *   - Synchronous write: mem[waddr] updated on posedge clock when wen=1
 *
 * To use real SRAM macros, define YSYX_USE_SRAM_MACRO and replace the
 * behavioral model section with the appropriate macro instantiation.
 *
 * Parameters:
 *   ADDR_WIDTH - Address width (depth = 2^ADDR_WIDTH)
 *   DATA_WIDTH - Data width in bits
 */
/* verilator lint_off WIDTHEXPAND */
module ysyx_sram_1r1w #(
    parameter int ADDR_WIDTH = 7,
    parameter int DATA_WIDTH = 32
) (
    input  logic                  clock,
    // Read port (synchronous: address latched at posedge, data available next cycle)
    input  logic                  ren,
    input  logic [ADDR_WIDTH-1:0] raddr,
    output logic [DATA_WIDTH-1:0] rdata,
    // Write port (synchronous: data written at posedge when wen=1)
    input  logic                  wen,
    input  logic [ADDR_WIDTH-1:0] waddr,
    input  logic [DATA_WIDTH-1:0] wdata
);
  localparam int DEPTH = 2 ** ADDR_WIDTH;

`ifdef YSYX_USE_SRAM_MACRO
  // ============================================================
  // Real SRAM macro instantiation (for tapeout)
  // ============================================================
  // Replace this section with the target foundry SRAM macro.
  // Example for TSMC/SMIC 1R1W SRAM:
  //
  //   S011HD1P_X32Y2D128 u_sram (
  //     .CLK(clock), .A(waddr), .D(wdata), .Q(rdata),
  //     .CEN(~(ren | wen)), .WEN(~wen), ...
  //   );
  //
  // Bypass logic for read-during-write should be added externally
  // in the cache controller if the foundry macro is read-first.
  // ============================================================

`else
  // ============================================================
  // Behavioral model for simulation / Verilator / FPGA BRAM
  // ============================================================
  // Write-first synchronous SRAM model:
  //   - Write: mem[waddr] updated on posedge when wen=1
  //   - Read: address latched on posedge, data available next cycle
  //   - Bypass: when reading and writing same address simultaneously,
  //     the written data is forwarded to rdata (write-first mode).
  //     This matches FPGA Block RAM "write-first" mode and avoids
  //     stale data on simultaneous read-write to the same address.
  //     For ASIC, external bypass logic replaces this behavior.
  // ============================================================
  logic [DATA_WIDTH-1:0] mem[DEPTH];

  // Synchronous write
  always_ff @(posedge clock) begin
    if (wen) begin
      mem[waddr] <= wdata;
    end
  end

  // Synchronous read with write-first bypass
  always_ff @(posedge clock) begin
    if (ren) begin
      if (wen && waddr == raddr) rdata <= wdata;  // write-first bypass
      else rdata <= mem[raddr];
    end
  end
`endif

endmodule
