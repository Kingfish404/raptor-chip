`ifndef RAPT_CONFIG_SVH
`define RAPT_CONFIG_SVH
//
// Selected via `make ... RAPT_CONFIG=large`. The sim Makefile prepends
// `configs/<RAPT_CONFIG>` to the include path so this file is picked up
// instead of `hdl/configs/default/rapt_config.svh`.
//
// "Large" preset: scale up every OoO/cache/predictor structure that uses
// power-of-two indexing in the RTL. All depths below are powers of two
// because head/tail pointers are sized via $clog2() and rely on natural
// wrap-around. PHY_SIZE must remain a power of two and >= REG_SIZE.
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

// Branch predictor: large tables for high prediction accuracy.
`define RAPT_PHT_SIZE 1024
`define RAPT_BPU_DIRP_TAGE
`define RAPT_BTB_SIZE 512
`define RAPT_BTB_WAYS 2
`define RAPT_RSB_SIZE 4

// OoO window: grow rename/dispatch/ROB to maximise in-flight ILP.
`define RAPT_RIQ_SIZE 16
`define RAPT_IIQ_SIZE 16
`define RAPT_ROB_SIZE 32

// Scheduler: wider RS / IOQ to feed both ALU pipes plus pipelined MUL.
`define RAPT_RS_SIZE 16
`define RAPT_IOQ_SIZE 16

`define RAPT_SQ_SIZE 16

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

// Physical register file: must be a power of two and >= REG_SIZE.
`define RAPT_PHY_SIZE 128
`define RAPT_PHY_LEN $clog2(`RAPT_PHY_SIZE)

`define RAPT_CACHE_LINE_BYTES 64

// L1I: 64B line * 512 sets * 1 way = 32 KiB
`define RAPT_L1I_LINE_LEN $clog2(`RAPT_CACHE_LINE_BYTES / 4)
`define RAPT_L1I_LEN 9
`define RAPT_L1I_N_WAYS 1
`ifndef RAPT_L1I_REFILL_WORDS
`define RAPT_L1I_REFILL_WORDS 8
`endif

// L1D: 64B line (16*4B RV32, 8*8B RV64) * 64 sets * 2 ways = 8 KiB
// VIPT constraint: L1D_LEN + L1D_LINE_LEN + log2(XLEN/8) must fit in the
// 4 KiB page offset (<=12) so virt_idx == phys_idx. With 64B line OFFSET
// is 6 bits, and the current 2-way fill logic in rapt_l1d.sv caps the
// associativity, so L1D_LEN must be <=6. Larger L1D requires PIPT or a
// generalised N-way fill path.
`define RAPT_L1D_LINE_LEN $clog2(`RAPT_CACHE_LINE_BYTES / (`RAPT_XLEN / 8))
`define RAPT_L1D_LEN 6
`define RAPT_L1D_N_WAYS 2

// L2 unified cache: 64B line * 2048 sets * 1 way = 128 KiB
`define RAPT_L2_EN
`define RAPT_L2_LINE_LEN $clog2(`RAPT_CACHE_LINE_BYTES / (`RAPT_XLEN / 8))
`define RAPT_L2_LEN 11
`define RAPT_L2_N_WAYS 1

`endif
