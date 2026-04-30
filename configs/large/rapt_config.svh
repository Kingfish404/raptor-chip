`ifndef RAPT_CONFIG_SVH
`define RAPT_CONFIG_SVH
//
// Selected via `make ... RAPT_CONFIG=large`. The nsim Makefile prepends
// `configs/<RAPT_CONFIG>` to the include path so this file is picked up
// instead of `configs/default/rapt_config.svh`.
//
// "Large" preset: scale up every OoO/cache/predictor structure that uses
// power-of-two indexing in the RTL. All depths below are powers of two
// because head/tail pointers are sized via $clog2() and rely on natural
// wrap-around. PHY_SIZE must remain a power of two and >= REG_SIZE.
//

// ---------- Architecture (arch) ----------
`ifdef RAPT_RV64
`define RAPT_XLEN 64
`define RAPT_MISA 'h8000000000141105
`else
`define RAPT_XLEN 32
`define RAPT_MISA 'h40141105
`endif
`define RAPT_I_EXTENSION 'h1
`define RAPT_M_EXTENSION 'h1

// ---------- Microarchitecture (uarch) ----------
`define RAPT_M_FAST 'h1

// L1I: 16B line * 256 sets * 2 ways = 8 KiB
`define RAPT_L1I_LINE_LEN 2
`define RAPT_L1I_LEN 8
`define RAPT_L1I_N_WAYS 2

// Branch predictor — large tables for high prediction accuracy.
`define RAPT_PHT_SIZE 1024
`define RAPT_BTB_SIZE 512
`define RAPT_BTB_WAYS 2
`define RAPT_RSB_SIZE 16

// OoO window — grow rename/dispatch/ROB to maximise in-flight ILP.
`define RAPT_RIQ_SIZE 16
`define RAPT_IIQ_SIZE 16
`define RAPT_ROB_SIZE 32

// Scheduler — wider RS / IOQ to feed both ALU pipes plus pipelined MUL.
`define RAPT_RS_SIZE 16
`define RAPT_IOQ_SIZE 16

// LSU / L1D: 8B line * 128 sets * 4 ways = 4 KiB
`define RAPT_SQ_SIZE 16
`define RAPT_L1D_LINE_LEN 1
`define RAPT_L1D_LEN 7
`define RAPT_L1D_N_WAYS 4

// Dual commit: retire up to 2 consecutive ROB entries per cycle.
`define RAPT_DUAL_COMMIT

// Dual issue: dispatch up to 2 instructions per cycle through the pipeline.
`define RAPT_DUAL_ISSUE

`ifdef RAPT_DUAL_ISSUE
`define RAPT_ISSUE_WIDTH 2
`else
`define RAPT_ISSUE_WIDTH 1
`endif

`ifdef RAPT_I_EXTENSION
`define RAPT_REG_SIZE 32 // 32 registers
`else
`define RAPT_REG_SIZE 16 // 16 registers
`endif

`define RAPT_REG_LEN $clog2(`RAPT_REG_SIZE) // Register Length

// Physical register file — must be a power of two and >= REG_SIZE.
`define RAPT_PHY_SIZE 128
`define RAPT_PHY_LEN $clog2(`RAPT_PHY_SIZE)

`endif
