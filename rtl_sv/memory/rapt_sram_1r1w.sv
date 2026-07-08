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
    parameter int DATA_WIDTH = 32,
    parameter int INST_ID    = 0,  // Unique per-instance ID (for CSE prevention)
    parameter bit SKIP_ADDR_REG = 0,  // Skip internal raddr register (parent pre-registers)
    parameter bit USE_BWE = 0  // Enable byte write enables
) (
    input  logic                  clock,
    // Read port
    input  logic                  ren,
    input  logic [ADDR_WIDTH-1:0] raddr,
    output logic [DATA_WIDTH-1:0] rdata,
    // Write port
    input  logic                  wen,
    input  logic [ADDR_WIDTH-1:0] waddr,
    input  logic [DATA_WIDTH-1:0] wdata,
    // Byte write enables (when USE_BWE=1)
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [DATA_WIDTH/8-1:0] bwe
    /* verilator lint_on UNUSEDSIGNAL */
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

  // Synchronous write with optional byte enables
  generate
    if (USE_BWE) begin : g_write_bwe
      always_ff @(posedge clock) begin
        if (wen) begin
          for (int b = 0; b < DATA_WIDTH/8; b++) begin
            if (bwe[b]) mem[waddr][b*8 +: 8] <= wdata[b*8 +: 8];
          end
        end
      end
    end else begin : g_write_full
      always_ff @(posedge clock) begin
        if (wen) mem[waddr] <= wdata;
      end
    end
  endgenerate

  // Read port: either registered (default) or combinational (SKIP_ADDR_REG=1).
  //
  // SKIP_ADDR_REG=0 (default): raddr registered internally. Used when the
  //   parent drives raddr combinationally.  INST_ID encoding prevents CSE
  //   merging of internal raddr registers across instances under flat synth.
  //
  // SKIP_ADDR_REG=1: parent module pre-registers raddr before fanout.
  //   The SRAM raddr input is already stable; no internal register needed.
  //   This creates hard per-instance registers that flat synthesis cannot merge.
  if (SKIP_ADDR_REG) begin : g_skip_addr_reg
    // Combinational read from pre-registered raddr input
    if (USE_BWE) begin : g_skip_bwe_bypass
      logic [DATA_WIDTH-1:0] rdata_bypassed;

      always_comb begin
        rdata_bypassed = mem[raddr];
        for (int b = 0; b < DATA_WIDTH/8; b++) begin
          if (bwe[b]) rdata_bypassed[b*8 +: 8] = wdata[b*8 +: 8];
        end
      end

      assign rdata = (wen && (waddr == raddr)) ? rdata_bypassed : mem[raddr];
    end else begin : g_skip_full_bypass
      assign rdata = (wen && (waddr == raddr)) ? wdata : mem[raddr];
    end
  end else begin : g_addr_reg
    // Registered read with INST_ID-based encoding for CSE prevention
    localparam logic [ADDR_WIDTH-1:0] KEY = ADDR_WIDTH'(INST_ID);

    (* keep = "true" *)logic [ADDR_WIDTH-1:0] raddr_r;
    (* keep = "true" *)logic                  bypass_en_r;
    (* keep = "true" *)logic [DATA_WIDTH-1:0] wdata_r;
    // Dummy token: holds INST_ID upper bits for per-instance uniqueness
    /* verilator lint_off UNUSEDSIGNAL */
    (* keep = "true" *)logic [3:0]            token_r;
    /* verilator lint_on UNUSEDSIGNAL */

    always_ff @(posedge clock) begin
      if (ren) begin
        raddr_r     <= raddr ^ KEY;
        bypass_en_r <= wen && (waddr == raddr);
        wdata_r     <= wdata;
        token_r     <= 4'(INST_ID >> ADDR_WIDTH);
      end
    end

    assign rdata = bypass_en_r ? wdata_r : mem[raddr_r ^ KEY];
  end
`endif

endmodule
