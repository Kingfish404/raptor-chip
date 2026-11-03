`ifndef RAPT_CONFIG_SVH
`define RAPT_CONFIG_SVH
`define RAPT_SRAM_CTRL_RESET 16'h0608
// Pin-limited 32-bit chip (rtl/chip): middle core with 16 KiB L1s, because every
// miss crosses the octal link. RV32 only; the missing include below stops an RV64
// build at compile time.
//
// Middle preset: dual-width frontend/backend with TAGE and no L2.
// Capacity and scan parameters must not be smaller than the small preset.
// Changes to this preset require fresh FPGA timing and hardware validation.
//

// ---------- Architecture (arch) ----------
`ifdef RAPT_RV64
`include "chip32-middle-16k is RV32 only: do not define RAPT_RV64"
`endif
`define RAPT_XLEN 32
`define RAPT_MISA 'h4014112f

`define RAPT_M_EXTENSION 'h1

// ---------- Microarchitecture (uarch) ----------
`define RAPT_M_FAST 'h1

// Branch predictor: keep default TAGE accuracy for IPC.
`define RAPT_PHT_SIZE 32
`define RAPT_BTB_SIZE 16
`define RAPT_BTB_WAYS 2
`define RAPT_RSB_SIZE 2
`define RAPT_BPU_DIRP_TAGE

// Half of default's OoO queue capacities, no smaller than small.
`define RAPT_RIQ_SIZE 4
`define RAPT_IIQ_SIZE 4
`ifndef RAPT_ROB_SIZE
`define RAPT_ROB_SIZE 16
`endif
`define RAPT_OPERAND_SPILL_ENTRIES 8
// Eight-entry steering scan window, within the ROB capacity.
`ifndef RAPT_STEER_SCAN_ENTRIES
`define RAPT_STEER_SCAN_ENTRIES 8
`endif

`define RAPT_RS_SIZE 4
`define RAPT_IOQ_SIZE 4

// Unified SQ: one queue from execute to drain, half of default's capacity.
`define RAPT_SQ_SIZE 8

// Authoritative ordered-stage widths and independent cache lookahead.
`ifndef RAPT_INTEGER_ISSUE_PORTS
`define RAPT_INTEGER_ISSUE_PORTS 2
`endif
`ifndef RAPT_INTEGER_SYSTEM_PORT
`define RAPT_INTEGER_SYSTEM_PORT 0
`endif
`ifndef RAPT_DECODE_WIDTH
`define RAPT_DECODE_WIDTH 2
`endif
`ifndef RAPT_RENAME_WIDTH
`define RAPT_RENAME_WIDTH 2
`endif
`ifndef RAPT_DISPATCH_WIDTH
`define RAPT_DISPATCH_WIDTH 2
`endif
`ifndef RAPT_COMMIT_WIDTH
`define RAPT_COMMIT_WIDTH 2
`endif
`define RAPT_FETCH_LOOKAHEAD

`define RAPT_REG_SIZE 32

`define RAPT_REG_LEN $clog2(`RAPT_REG_SIZE)

`define RAPT_PHY_SIZE 64
`define RAPT_PHY_LEN $clog2(`RAPT_PHY_SIZE)

`define RAPT_CACHE_LINE_BYTES 32

// L1I: 32B line * 256 sets * 2-way = 16 KiB.
`define RAPT_L1I_LINE_LEN $clog2(`RAPT_CACHE_LINE_BYTES / 4)
`define RAPT_L1I_LEN 8
`define RAPT_L1I_N_WAYS 2
`define RAPT_L1I_REFILL_WORDS 8

// L1D: 32B line * 128 sets * 4-way = 16 KiB; VIPT-safe. Write-back keeps stores off the
// slow pin link.
`define RAPT_L1D_LINE_LEN $clog2(`RAPT_CACHE_LINE_BYTES / (`RAPT_XLEN / 8))
`define RAPT_L1D_LEN 7
`define RAPT_L1D_N_WAYS 4

`ifndef RAPT_L1D_WRITEBACK
`define RAPT_L1D_WRITEBACK 1
`endif

`define RAPT_ITLB_ENTRIES 8
`define RAPT_DTLB_ENTRIES 8
`define RAPT_DTLB_WAYS 0
// Shared instruction/data second-level translation cache; zero bypasses it.
`define RAPT_L2TLB_ENTRIES 0

// No L2 in this preset.
// `define RAPT_L2_EN
`define RAPT_L2_LINE_LEN $clog2(`RAPT_CACHE_LINE_BYTES / (`RAPT_XLEN / 8))
`define RAPT_L2_LEN 8
`define RAPT_L2_N_WAYS 1

`endif  // RAPT_CONFIG_SVH
