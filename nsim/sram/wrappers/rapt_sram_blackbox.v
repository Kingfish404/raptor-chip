// rapt_sram_blackbox.v
//
// Blackbox declarations for the OpenRAM-compiled 1R1W cache SRAM macros.
// Read by Yosys / Verilator as port-only stubs so the cache RTL (which
// instantiates these from rapt_sram_1r1w under `RAPT_USE_SRAM_MACRO`) can
// elaborate without pulling in the heavy OpenRAM functional Verilog. STA
// gets timing from the matching .lib files produced by OpenRAM.
//
// Port shape mirrors OpenRAM's standard 1R1W output. Port 0 = read/write,
// port 1 = read-only. The raptor cache controller drives:
//   port 0  ← refill / store write path
//   port 1  ← load / fetch path
//
// All macros are byte-write-enabled with write_size=8 (one mask bit per
// 8-bit lane of the data word).

/* verilator lint_off DECLFILENAME */
/* verilator lint_off UNUSEDSIGNAL */

(* blackbox *)
module rapt_openram_1r1w_32x32 (
    // Port 0 (read/write)
    input  wire        clk0,
    input  wire        csb0,        // active-low chip-select
    input  wire        web0,        // active-low write-enable
    input  wire [3:0]  wmask0,      // per-byte write mask (4 bytes × 32 b)
    input  wire [4:0]  addr0,       // log2(32) = 5
    input  wire [31:0] din0,
    // Port 1 (read only)
    input  wire        clk1,
    input  wire        csb1,
    input  wire [4:0]  addr1,
    output wire [31:0] dout1
);
endmodule

(* blackbox *)
module rapt_openram_1r1w_16x32 (
    input  wire        clk0,
    input  wire        csb0,
    input  wire        web0,
    input  wire [3:0]  wmask0,
    input  wire [3:0]  addr0,       // log2(16) = 4
    input  wire [31:0] din0,
    input  wire        clk1,
    input  wire        csb1,
    input  wire [3:0]  addr1,
    output wire [31:0] dout1
);
endmodule

(* blackbox *)
module rapt_openram_1r1w_16x64 (
    input  wire        clk0,
    input  wire        csb0,
    input  wire        web0,
    input  wire [7:0]  wmask0,      // 8 byte enables × 64 b
    input  wire [3:0]  addr0,
    input  wire [63:0] din0,
    input  wire        clk1,
    input  wire        csb1,
    input  wire [3:0]  addr1,
    output wire [63:0] dout1
);
endmodule

/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on DECLFILENAME */
