/**
 * rapt_sram_1rw - Single-port SRAM behavioral model (1 shared Read/Write port)
 *
 * Standard single-port SRAM wrapper for cache data/tag arrays. One address
 * port is time-shared between reads and writes; the parent must arbitrate.
 * This matches real foundry single-port SRAM macros and FPGA simple-dual/
 * single-port Block RAM, and replaces the legacy 1R1W wrapper so that the
 * design ports cleanly onto the smallest real macros.
 *
 * Timing contract (matches real macros AND BRAM inference):
 *   - Write: mem[addr] updated on posedge clock when wen=1.
 *   - Read : addr latched on posedge clock when en && !wen; rdata is
 *     combinational from the registered address (tCQ), i.e. valid the
 *     cycle AFTER the address was presented.
 *   - Simultaneous read+write to the same address: write wins on the
 *     storage; the read sees the OLD data (read-first). Parents that need
 *     the new data must implement a bypass register (see rapt_l1d.sv).
 *
 * To use real SRAM macros, define RAPT_USE_SRAM_MACRO and select the
 * pre-characterised OpenRAM single-port macro by (DEPTH, DATA_WIDTH).
 *
 * Parameters:
 *   ADDR_WIDTH - Address width (depth = 2^ADDR_WIDTH)
 *   DATA_WIDTH - Data width in bits
 */
/* verilator lint_off WIDTHEXPAND */
// (* keep_hierarchy *) prevents yosys from flattening every SRAM instance and
// CSE-merging their internal raddr registers into one shared DFF (see the
// legacy 1R1W wrapper header for the full story).
(* keep_hierarchy *)
module rapt_sram_1rw #(
    parameter int ADDR_WIDTH = 7,
    parameter int DATA_WIDTH = 32,
    parameter int INST_ID    = 0,  // Unique per-instance ID (for CSE prevention)
    parameter bit USE_BWE = 0  // Enable byte write enables
) (
    input  logic                  clock,
    input  logic                  en,    // chip-select for the shared port
    input  logic                  wen,   // 1 = write, 0 = read
    input  logic [ADDR_WIDTH-1:0] addr,
    output logic [DATA_WIDTH-1:0] rdata,
    input  logic [DATA_WIDTH-1:0] wdata,
    // Byte write enables (when USE_BWE=1)
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [DATA_WIDTH/8-1:0] bwe
    /* verilator lint_on UNUSEDSIGNAL */
);
  localparam int DEPTH = 2 ** ADDR_WIDTH;

`ifdef RAPT_USE_SRAM_MACRO
  // ============================================================
  // OpenRAM-generated single-port (1RW) SRAM macro instantiation
  // ============================================================
  // Selects a pre-characterised OpenRAM macro by (DEPTH, DATA_WIDTH) so
  // that Yosys reads only a blackbox stub and OpenSTA gets timing from
  // the OpenRAM-produced Liberty file. Macros are generated under
  //   $(RAPTOR_HOME)/sim/sram/build/<PLATFORM>/macro/
  // and registered as blackboxes in
  //   $(RAPTOR_HOME)/sim/sram/wrappers/rapt_sram_blackbox.v
  //
  // OpenRAM single-port macros are read-first: a read concurrent with a
  // write to the same address returns the OLD data.
  // ============================================================
  generate
    if (DEPTH == 32 && DATA_WIDTH == 32) begin : g_32x32
      rapt_openram_1rw_32x32 u_sram (
        .clk0(clock), .csb0(~en), .web0(~wen),
        .wmask0(USE_BWE ? bwe : {(DATA_WIDTH/8){1'b1}}),
        .addr0(addr), .din0(wdata), .dout0(rdata)
      );
    end else if (DEPTH == 16 && DATA_WIDTH == 32) begin : g_16x32
      rapt_openram_1rw_16x32 u_sram (
        .clk0(clock), .csb0(~en), .web0(~wen),
        .wmask0(USE_BWE ? bwe : {(DATA_WIDTH/8){1'b1}}),
        .addr0(addr), .din0(wdata), .dout0(rdata)
      );
    end else if (DEPTH == 16 && DATA_WIDTH == 64) begin : g_16x64
      rapt_openram_1rw_16x64 u_sram (
        .clk0(clock), .csb0(~en), .web0(~wen),
        .wmask0(USE_BWE ? bwe : {(DATA_WIDTH/8){1'b1}}),
        .addr0(addr), .din0(wdata), .dout0(rdata)
      );
    end else begin : g_unsupported
      // No OpenRAM macro generated for this (DEPTH, DATA_WIDTH).
      // Add a config under sim/sram/configs/ and a stub in
      // sim/sram/wrappers/rapt_sram_blackbox.v, then extend this
      // generate cascade. Until then, fail loudly instead of silently
      // mis-mapping.
      initial $fatal(1, "rapt_sram_1rw: no OpenRAM macro for DEPTH=%0d WIDTH=%0d",
                     DEPTH, DATA_WIDTH);
      assign rdata = '0;
    end
  endgenerate

`else
  // ============================================================
  // Behavioral model for simulation / Verilator / FPGA BRAM
  // ============================================================
  logic [DATA_WIDTH-1:0] mem[DEPTH];

  // Synchronous write with optional byte enables
  generate
    if (USE_BWE) begin : g_write_bwe
      always_ff @(posedge clock) begin
        if (en && wen) begin
          for (int b = 0; b < DATA_WIDTH/8; b++) begin
            if (bwe[b]) mem[addr][b*8 +: 8] <= wdata[b*8 +: 8];
          end
        end
      end
    end else begin : g_write_full
      always_ff @(posedge clock) begin
        if (en && wen) mem[addr] <= wdata;
      end
    end
  endgenerate

  // Synchronous read: address registered (gated off during writes), data
  // combinational from the registered address. Read-first on collision:
  // when a write and a read target the same address in one cycle the
  // registered address is the WRITE address, so rdata reflects pre-write
  // storage for that address (real SRAM behavior). INST_ID XOR-keying
  // keeps per-instance address registers CSE-immune under flat synthesis.
  localparam logic [ADDR_WIDTH-1:0] KEY = ADDR_WIDTH'(INST_ID);

  (* keep = "true" *)logic [ADDR_WIDTH-1:0] addr_r;
  // Dummy token: holds INST_ID upper bits for per-instance uniqueness
  /* verilator lint_off UNUSEDSIGNAL */
  (* keep = "true" *)logic [3:0]            token_r;
  /* verilator lint_on UNUSEDSIGNAL */

  always_ff @(posedge clock) begin
    if (en) begin
      addr_r  <= addr ^ KEY;
      token_r <= 4'(INST_ID >> ADDR_WIDTH);
    end
  end

  assign rdata = mem[addr_r ^ KEY];
`endif

endmodule
