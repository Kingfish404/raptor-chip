// rapt_sram_blackbox.v
//
// Blackbox declarations for the OpenRAM-compiled cache SRAM macros.
// Read by Yosys / Verilator as port-only stubs so the cache RTL (which
// instantiates these from rapt_sram_1rw under `RAPT_USE_SRAM_MACRO`) can
// elaborate without pulling in the heavy OpenRAM functional Verilog. STA
// gets timing from the matching .lib files produced by OpenRAM.
//
// The RTL instantiates the single-port (1RW) variants: one address/data
// port shared by read and write (csb0 low = selected, web0 low = write,
// web0 high = read).
//
// All macros are byte-write-enabled with write_size=8 (one mask bit per
// 8-bit lane of the data word).

/* verilator lint_off DECLFILENAME */
/* verilator lint_off UNUSEDSIGNAL */

(* blackbox *)
module rapt_openram_1rw_2x32 (
    input wire clk0, csb0, web0,
    input wire [3:0] wmask0,
    input wire [0:0] addr0,
    input wire [31:0] din0,
    output wire [31:0] dout0
);
endmodule

(* blackbox *)
module rapt_openram_1rw_8x32 (
    input wire clk0, csb0, web0,
    input wire [3:0] wmask0,
    input wire [2:0] addr0,
    input wire [31:0] din0,
    output wire [31:0] dout0
);
endmodule

(* blackbox *)
module rapt_openram_1rw_32x32 (
    input  wire        clk0,
    input  wire        csb0,
    input  wire        web0,
    input  wire [3:0]  wmask0,
    input  wire [4:0]  addr0,
    input  wire [31:0] din0,
    output wire [31:0] dout0
);
endmodule

(* blackbox *)
module rapt_openram_1rw_16x32 (
    input  wire        clk0,
    input  wire        csb0,
    input  wire        web0,
    input  wire [3:0]  wmask0,
    input  wire [3:0]  addr0,
    input  wire [31:0] din0,
    output wire [31:0] dout0
);
endmodule

(* blackbox *)
module rapt_openram_1rw_16x64 (
    input  wire        clk0,
    input  wire        csb0,
    input  wire        web0,
    input  wire [7:0]  wmask0,
    input  wire [3:0]  addr0,
    input  wire [63:0] din0,
    output wire [63:0] dout0
);
endmodule

(* blackbox *)
module rapt_openram_1rw_512x32 (
    input wire clk0, csb0, web0,
    input wire [3:0] wmask0,
    input wire [8:0] addr0,
    input wire [31:0] din0,
    output wire [31:0] dout0
);
endmodule

(* blackbox *)
module rapt_openram_1rw_2x128 (
    input wire clk0, csb0, web0,
    input wire [15:0] wmask0,
    input wire [0:0] addr0,
    input wire [127:0] din0,
    output wire [127:0] dout0
);
endmodule

(* blackbox *)
module rapt_openram_1rw_8x128 (
    input wire clk0, csb0, web0,
    input wire [15:0] wmask0,
    input wire [2:0] addr0,
    input wire [127:0] din0,
    output wire [127:0] dout0
);
endmodule

(* blackbox *)
module rapt_openram_1rw_16x128 (
    input wire clk0, csb0, web0,
    input wire [15:0] wmask0,
    input wire [3:0] addr0,
    input wire [127:0] din0,
    output wire [127:0] dout0
);
endmodule

(* blackbox *)
module rapt_openram_1rw_64x128 (
    input wire clk0, csb0, web0,
    input wire [15:0] wmask0,
    input wire [5:0] addr0,
    input wire [127:0] din0,
    output wire [127:0] dout0
);
endmodule

(* blackbox *)
module rapt_openram_1rw_2048x32 (
    input wire clk0, csb0, web0,
    input wire [3:0] wmask0,
    input wire [10:0] addr0,
    input wire [31:0] din0,
    output wire [31:0] dout0
);
endmodule

(* blackbox *)
module rapt_openram_1rw_2048x64 (
    input wire clk0, csb0, web0,
    input wire [7:0] wmask0,
    input wire [10:0] addr0,
    input wire [63:0] din0,
    output wire [63:0] dout0
);
endmodule

/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on DECLFILENAME */
