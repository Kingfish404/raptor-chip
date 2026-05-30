/**
 * rapt_sram_1r1w - Simple dual-port SRAM behavioral model (1 Read + 1 Write)
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
 * To use real SRAM macros, define RAPT_USE_SRAM_MACRO and replace the
 * behavioral model section with the appropriate macro instantiation.
 *
 * Parameters:
 *   ADDR_WIDTH - Address width (depth = 2^ADDR_WIDTH)
 *   DATA_WIDTH - Data width in bits
 */
/* verilator lint_off WIDTHEXPAND */
// (* keep_hierarchy *) prevents yosys from flattening every SRAM instance and
// CSE-merging their internal retimed raddr registers into one shared DFF.
// When multiple banks share the same combinational raddr net (e.g. L1D data
// SRAMs across ways/banks), the merged DFF ends up driving every bank's read
// mux cone, producing a multi-ns BUF-only fanout delay. keep_hierarchy keeps
// each instance's raddr register local, so each raddr bit only fans out to
// its own bank's DEPTH x DATA_WIDTH mux.
(* keep_hierarchy *)
module rapt_sram_1r1w #(
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

`ifdef RAPT_USE_SRAM_MACRO
  // ============================================================
  // OpenRAM-generated 1R1W SRAM macro instantiation
  // ============================================================
  // Selects a pre-characterised OpenRAM macro by (DEPTH, DATA_WIDTH) so
  // that Yosys reads only a blackbox stub and OpenSTA gets timing from
  // the OpenRAM-produced Liberty file. Macros are generated under
  //   $(RAPTOR_HOME)/nsim/sram/build/<PLATFORM>/macro/
  // and registered as blackboxes in
  //   $(RAPTOR_HOME)/nsim/sram/wrappers/rapt_sram_blackbox.v
  //
  // Naming follows OpenRAM convention for 1R1W ports:
  //   <tech>_sram_<size>_1r1w_<word_size>x<num_words>_<write_size>
  // and is aliased to the generic per-shape symbol used here:
  //   rapt_openram_1r1w_<num_words>x<word_size>
  //
  // OpenRAM SRAMs are read-first; the bypass mux around the macro
  // implements write-first semantics for the cache controller.
  // ============================================================
  logic [DATA_WIDTH-1:0] macro_rdata;
  (* keep = "true" *)logic                  bypass_en_r;
  (* keep = "true" *)logic [DATA_WIDTH-1:0] wdata_r;

  always_ff @(posedge clock) begin
    if (ren) begin
      bypass_en_r <= wen && (waddr == raddr);
      wdata_r     <= wdata;
    end
  end

  generate
    if (DEPTH == 32 && DATA_WIDTH == 32) begin : g_32x32
      rapt_openram_1r1w_32x32 u_sram (
        .clk0(clock), .csb0(~wen), .web0(~wen),
        .wmask0({(DATA_WIDTH/8){1'b1}}), .addr0(waddr), .din0(wdata),
        .clk1(clock), .csb1(~ren), .addr1(raddr), .dout1(macro_rdata)
      );
    end else if (DEPTH == 16 && DATA_WIDTH == 32) begin : g_16x32
      rapt_openram_1r1w_16x32 u_sram (
        .clk0(clock), .csb0(~wen), .web0(~wen),
        .wmask0({(DATA_WIDTH/8){1'b1}}), .addr0(waddr), .din0(wdata),
        .clk1(clock), .csb1(~ren), .addr1(raddr), .dout1(macro_rdata)
      );
    end else if (DEPTH == 16 && DATA_WIDTH == 64) begin : g_16x64
      rapt_openram_1r1w_16x64 u_sram (
        .clk0(clock), .csb0(~wen), .web0(~wen),
        .wmask0({(DATA_WIDTH/8){1'b1}}), .addr0(waddr), .din0(wdata),
        .clk1(clock), .csb1(~ren), .addr1(raddr), .dout1(macro_rdata)
      );
    end else begin : g_unsupported
      // No OpenRAM macro generated for this (DEPTH, DATA_WIDTH).
      // Add a config under nsim/sram/configs/ and a stub in
      // nsim/sram/wrappers/rapt_sram_blackbox.v, then extend this
      // generate cascade. Until then, leave macro_rdata undriven so
      // synthesis fails loudly instead of silently mis-mapping.
      initial $fatal(1, "rapt_sram_1r1w: no OpenRAM macro for DEPTH=%0d WIDTH=%0d",
                     DEPTH, DATA_WIDTH);
      assign macro_rdata = '0;
    end
  endgenerate

  assign rdata = bypass_en_r ? wdata_r : macro_rdata;

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

  // Explicit per-instance registered read port.
  //
  // Original RTL used `rdata <= mem[raddr]` which yosys retimes by moving
  // the rdata DFF backward, creating an implicit raddr register. The
  // retimed register is then CSE-merged across bank/way SRAM instances
  // that share the same combinational raddr driver (e.g. L1D data array:
  // 2 ways x L1D_LINE_SIZE banks sharing one `sram_raddr`). The merged DFF
  // drives every bank's DEPTH x DATA_WIDTH read mux, producing an ~11 ns
  // BUF-only fanout on r_raddr[0]/Q (observed chip critical path).
  //
  // Making raddr_r / bypass_en_r / wdata_r explicit and (* keep = "true" *)
  // prevents CSE merging: each SRAM instance owns its own read-address DFF
  // and its fanout is capped at one bank's mux cone.
  (* keep = "true" *)logic [ADDR_WIDTH-1:0] raddr_r;
  (* keep = "true" *)logic                  bypass_en_r;
  (* keep = "true" *)logic [DATA_WIDTH-1:0] wdata_r;

  always_ff @(posedge clock) begin
    if (ren) begin
      raddr_r     <= raddr;
      bypass_en_r <= wen && (waddr == raddr);
      wdata_r     <= wdata;
    end
  end

  // Combinational read: bypass_en_r selects registered write data for
  // write-first semantics, otherwise read from memory using the
  // per-instance registered address.
  assign rdata = bypass_en_r ? wdata_r : mem[raddr_r];
`endif

endmodule
