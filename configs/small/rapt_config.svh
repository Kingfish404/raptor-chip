`ifndef RAPT_CONFIG_SVH
`define RAPT_CONFIG_SVH
//
// Selected via `make ... RAPT_CONFIG=small`. The nsim Makefile prepends
// `configs/<RAPT_CONFIG>` to the include path so this file is picked up
// instead of `configs/default/rapt_config.svh`.
//
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

// L1I
`define RAPT_L1I_LINE_LEN 2
`define RAPT_L1I_LEN 5
`define RAPT_L1I_N_WAYS 1

// Branch predictor
`define RAPT_PHT_SIZE 16
`define RAPT_BTB_SIZE 16
`define RAPT_BTB_WAYS 2
`define RAPT_RSB_SIZE 2

// OoO window — halve all queue depths to relieve CLS / clock-routing pressure.
`define RAPT_RIQ_SIZE 2
`define RAPT_IIQ_SIZE 2
`define RAPT_ROB_SIZE 4

`define RAPT_RS_SIZE 4
`define RAPT_IOQ_SIZE 4

// LSU / L1D.
`define RAPT_SQ_SIZE 4
`define RAPT_L1D_LINE_LEN 1
`define RAPT_L1D_LEN 3
`define RAPT_L1D_N_WAYS 2

// Issue width
// `define RAPT_DUAL_COMMIT

// Commit width
// `define RAPT_DUAL_ISSUE

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

`define RAPT_PHY_SIZE 64 // physical register number (must be power of 2)
`define RAPT_PHY_LEN $clog2(`RAPT_PHY_SIZE)

`endif
