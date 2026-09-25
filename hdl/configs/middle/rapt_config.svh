`ifndef RAPT_CONFIG_SVH
`define RAPT_CONFIG_SVH
//
// Middle preset: dual-width frontend/backend with TAGE and no L2.
// Capacity and scan parameters must not be smaller than the small preset.
// Changes to this preset require fresh FPGA timing and hardware validation.
//

// ---------- Architecture (arch) ----------
`ifdef RAPT_RV64
`define RAPT_XLEN 64
`define RAPT_MISA 'h800000000014112f
`else
`define RAPT_XLEN 32
`define RAPT_MISA 'h4014112f
`endif


`define RAPT_I_EXTENSION 'h1
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
`define RAPT_ROB_SIZE 16
`ifndef RAPT_OPERAND_SPILL_ENTRIES
`define RAPT_OPERAND_SPILL_ENTRIES 8
`endif
// Half of default's steering scan window, within the ROB capacity.
`define RAPT_STEER_SCAN_ENTRIES 8

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
`ifndef RAPT_FETCH_LOOKAHEAD
`define RAPT_FETCH_LOOKAHEAD
`endif

`ifdef RAPT_I_EXTENSION
`define RAPT_REG_SIZE 32
`else
`define RAPT_REG_SIZE 16
`endif

`define RAPT_REG_LEN $clog2(`RAPT_REG_SIZE)

`define RAPT_PHY_SIZE 64
`define RAPT_PHY_LEN $clog2(`RAPT_PHY_SIZE)

`define RAPT_CACHE_LINE_BYTES 16

// L1I: 16B line * 32 sets * 2-way = 1 KiB.
`define RAPT_L1I_LINE_LEN $clog2(`RAPT_CACHE_LINE_BYTES / 4)
`define RAPT_L1I_LEN 5
`define RAPT_L1I_N_WAYS 2
`ifndef RAPT_L1I_REFILL_WORDS
`define RAPT_L1I_REFILL_WORDS 4
`endif

// L1D: 16B line * 8 sets * 2-way = 256 B, matching small.
`define RAPT_L1D_LINE_LEN $clog2(`RAPT_CACHE_LINE_BYTES / (`RAPT_XLEN / 8))
`define RAPT_L1D_LEN 3
`define RAPT_L1D_N_WAYS 2

`define RAPT_ITLB_ENTRIES 8
`define RAPT_DTLB_ENTRIES 8

// No L2 in this preset.
// `define RAPT_L2_EN
`define RAPT_L2_LINE_LEN $clog2(`RAPT_CACHE_LINE_BYTES / (`RAPT_XLEN / 8))
`define RAPT_L2_LEN 8
`define RAPT_L2_N_WAYS 1

`endif  // RAPT_CONFIG_SVH
