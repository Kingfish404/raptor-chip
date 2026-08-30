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
 *   - Read : rdata registered on posedge clock when en && !wen, i.e. valid
 *     the cycle AFTER the address was presented. When en is low or a write
 *     is performed, rdata holds its previous value.
 *   - The shared port performs either a read or a write in one cycle. Parents
 *     that need write-to-read forwarding must implement an explicit bypass.
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
  parameter int INST_ID    = 0,  // Compatibility parameter; instance API is stable
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
    if (DEPTH == 2 && DATA_WIDTH == 32) begin : g_2x32
      rapt_openram_1rw_2x32 u_sram (
        .clk0(clock), .csb0(~en), .web0(~wen),
        .wmask0(USE_BWE ? bwe : {(DATA_WIDTH/8){1'b1}}),
        .addr0(addr), .din0(wdata), .dout0(rdata)
      );
    end else if (DEPTH == 8 && DATA_WIDTH == 32) begin : g_8x32
      rapt_openram_1rw_8x32 u_sram (
        .clk0(clock), .csb0(~en), .web0(~wen),
        .wmask0(USE_BWE ? bwe : {(DATA_WIDTH/8){1'b1}}),
        .addr0(addr), .din0(wdata), .dout0(rdata)
      );
    end else if (DEPTH == 32 && DATA_WIDTH == 32) begin : g_32x32
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
    end else if (DEPTH == 512 && DATA_WIDTH == 32) begin : g_512x32
      rapt_openram_1rw_512x32 u_sram (
        .clk0(clock), .csb0(~en), .web0(~wen),
        .wmask0(USE_BWE ? bwe : {(DATA_WIDTH/8){1'b1}}),
        .addr0(addr), .din0(wdata), .dout0(rdata)
      );
    end else if (DEPTH == 2 && DATA_WIDTH == 128) begin : g_2x128
      rapt_openram_1rw_2x128 u_sram (
        .clk0(clock), .csb0(~en), .web0(~wen),
        .wmask0(USE_BWE ? bwe : {(DATA_WIDTH/8){1'b1}}),
        .addr0(addr), .din0(wdata), .dout0(rdata)
      );
    end else if (DEPTH == 8 && DATA_WIDTH == 128) begin : g_8x128
      rapt_openram_1rw_8x128 u_sram (
        .clk0(clock), .csb0(~en), .web0(~wen),
        .wmask0(USE_BWE ? bwe : {(DATA_WIDTH/8){1'b1}}),
        .addr0(addr), .din0(wdata), .dout0(rdata)
      );
    end else if (DEPTH == 16 && DATA_WIDTH == 128) begin : g_16x128
      rapt_openram_1rw_16x128 u_sram (
        .clk0(clock), .csb0(~en), .web0(~wen),
        .wmask0(USE_BWE ? bwe : {(DATA_WIDTH/8){1'b1}}),
        .addr0(addr), .din0(wdata), .dout0(rdata)
      );
    end else if (DEPTH == 64 && DATA_WIDTH == 128) begin : g_64x128
      rapt_openram_1rw_64x128 u_sram (
        .clk0(clock), .csb0(~en), .web0(~wen),
        .wmask0(USE_BWE ? bwe : {(DATA_WIDTH/8){1'b1}}),
        .addr0(addr), .din0(wdata), .dout0(rdata)
      );
    end else if (DEPTH == 2048 && DATA_WIDTH == 32) begin : g_2048x32
      rapt_openram_1rw_2048x32 u_sram (
        .clk0(clock), .csb0(~en), .web0(~wen),
        .wmask0(USE_BWE ? bwe : {(DATA_WIDTH/8){1'b1}}),
        .addr0(addr), .din0(wdata), .dout0(rdata)
      );
    end else if (DEPTH == 2048 && DATA_WIDTH == 64) begin : g_2048x64
      rapt_openram_1rw_2048x64 u_sram (
        .clk0(clock), .csb0(~en), .web0(~wen),
        .wmask0(USE_BWE ? bwe : {(DATA_WIDTH/8){1'b1}}),
        .addr0(addr), .din0(wdata), .dout0(rdata)
      );
    end else begin : g_unsupported
      rapt_unsupported_sram_shape #(
          .DEPTH(DEPTH), .DATA_WIDTH(DATA_WIDTH), .USE_BWE(USE_BWE)
      ) u_unsupported_sram_shape ();
      assign rdata = 'x;
    end
  endgenerate

`else
  // ============================================================
  // Behavioral model for simulation / Verilator / FPGA BRAM
  // ============================================================
  /* verilator lint_off UNUSEDPARAM */
  localparam int InstanceIdUnused = INST_ID;
  /* verilator lint_on UNUSEDPARAM */
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

  // Standard synchronous-read template recognized by FPGA BRAM and ASIC
  // memory inference flows. Keeping the data register inside the memory
  // process avoids an asynchronous array read after a registered address.
  always_ff @(posedge clock) begin
    if (en && !wen) rdata <= mem[addr];
  end
`endif

endmodule
