`ifndef RAPT_CONFIG_SVH
`define RAPT_CONFIG_SVH
//
// Middle preset: KU15P Linux/MIG hardware-passing configuration.
// This keeps the useful default-size frontend/ROB/cache footprint while
// hardening the current FPGA path: single issue, single commit, no L2,
// and a 4-entry store queue.
//

// ---------- Architecture (arch) ----------
`ifdef RAPT_RV64
`define RAPT_XLEN 64
`define RAPT_MISA 'h8000000000141107
`else
`define RAPT_XLEN 32
`define RAPT_MISA 'h40141107
`endif


`define RAPT_I_EXTENSION 'h1
`define RAPT_M_EXTENSION 'h1

// ---------- Microarchitecture (uarch) ----------
`define RAPT_M_FAST 'h1

// Branch predictor: keep default TAGE accuracy for IPC.
`define RAPT_PHT_SIZE 256
`define RAPT_BTB_SIZE 128
`define RAPT_BTB_WAYS 2
`define RAPT_RSB_SIZE 4
`define RAPT_BPU_DIRP_TAGE

// Default-size OoO window, validated on KU15P with single issue/commit.
`define RAPT_RIQ_SIZE 8
`define RAPT_IIQ_SIZE 8
`define RAPT_ROB_SIZE 16

`define RAPT_RS_SIZE 8
`define RAPT_IOQ_SIZE 8

`define RAPT_SQ_SIZE 4

// Middle enables dual commit
`define RAPT_DUAL_COMMIT
`define RAPT_DUAL_ISSUE

`ifdef RAPT_DUAL_ISSUE
`define RAPT_ISSUE_WIDTH 2
`else
`define RAPT_ISSUE_WIDTH 1
`endif

`ifdef RAPT_I_EXTENSION
`define RAPT_REG_SIZE 32
`else
`define RAPT_REG_SIZE 16
`endif

`define RAPT_REG_LEN $clog2(`RAPT_REG_SIZE)

`define RAPT_PHY_SIZE 64
`define RAPT_PHY_LEN $clog2(`RAPT_PHY_SIZE)

// L1I: 64B line * 64 sets * 2-way = 8 KiB.
`define RAPT_L1I_LINE_LEN 4
`define RAPT_L1I_LEN 5
`define RAPT_L1I_N_WAYS 2

// L1D: default-size 2-way cache, with RV64 line sizing preserved.
`ifdef RAPT_RV64
`define RAPT_L1D_LINE_LEN 3
`else
`define RAPT_L1D_LINE_LEN 4
`endif
`define RAPT_L1D_LEN 4
`define RAPT_L1D_N_WAYS 2

// No L2 in the current KU15P passing profile.
// `define RAPT_L2_EN
`ifdef RAPT_RV64
`define RAPT_L2_LINE_LEN 3
`else
`define RAPT_L2_LINE_LEN 4
`endif
`define RAPT_L2_LEN 8
`define RAPT_L2_N_WAYS 1

`endif  // RAPT_CONFIG_SVH
