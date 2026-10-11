`ifndef RAPT_CONFIG_SVH
`define RAPT_CONFIG_SVH
//
// Selected via `make ... RAPT_CONFIG=large`. The sim Makefile prepends
// `configs/<RAPT_CONFIG>` to the include path so this file is picked up
// instead of `hdl/configs/default/rapt_config.svh`.
//
// "Large" preset: scale up the OoO, cache and predictor structures. Cache and
// predictor tables are indexed by address/PC bits, and the SQ and IOQ pointers
// rely on natural wrap-around, so those depths must stay powers of two (both are
// checked at elaboration). ROB_SIZE must be a power of two while
// RAPT_FETCH_LOOKAHEAD is defined. PHY_SIZE only has to exceed REG_SIZE.
//

// ---------- Architecture (arch) ----------
`ifdef RAPT_RV64
`define RAPT_XLEN 64
`define RAPT_MISA 'h800000000014112f
`else
`define RAPT_XLEN 32
`define RAPT_MISA 'h4014112f
`endif
`define RAPT_M_EXTENSION 'h1

// ---------- Microarchitecture (uarch) ----------
`define RAPT_M_FAST 'h1

// Branch predictor: large tables for high prediction accuracy.
`define RAPT_PHT_SIZE 1024
`define RAPT_BPU_DIRP_TAGE
`define RAPT_BTB_SIZE 512
`define RAPT_BTB_WAYS 2
`define RAPT_RSB_SIZE 4

// OoO window. Two-wide RNQ/UOQ need no more than the default eight entries:
// RV32 CoreMark changed by 0.03% when 16 was reduced to 8 (2026-10-06).
`define RAPT_RIQ_SIZE 8
`define RAPT_IIQ_SIZE 8
`ifndef RAPT_ROB_SIZE
`define RAPT_ROB_SIZE 32
`endif
`define RAPT_OPERAND_SPILL_ENTRIES 16

// Control-flow speculation depth. The shared default is the area-lean 16;
// this preset keeps a deeper array. CoreMark peaked at 22 live checkpoints
// with 32 available and never filled the pool, so 24 entries suffice.
`ifndef RAPT_BRANCH_CHECKPOINTS
`define RAPT_BRANCH_CHECKPOINTS 24
`endif

// Scheduler: wider RS / IOQ to feed both ALU pipes plus pipelined MUL.
`define RAPT_RS_SIZE 16
`define RAPT_IOQ_SIZE 16

`define RAPT_SQ_SIZE 16

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

`define RAPT_REG_SIZE 32 // 32 registers

`define RAPT_REG_LEN $clog2(`RAPT_REG_SIZE) // Register Length

// Physical register file: must exceed REG_SIZE. 96 covers the 32
// architectural mappings, ROB 32 and renamed work before allocation.
`define RAPT_PHY_SIZE 96
`define RAPT_PHY_LEN $clog2(`RAPT_PHY_SIZE)

`define RAPT_CACHE_LINE_BYTES 64

// L1I: 64B line * 512 sets * 1 way = 32 KiB
`define RAPT_L1I_LINE_LEN $clog2(`RAPT_CACHE_LINE_BYTES / 4)
`define RAPT_L1I_LEN 9
`define RAPT_L1I_N_WAYS 1
`define RAPT_L1I_REFILL_WORDS 8

// L1D: 64B line (16*4B RV32, 8*8B RV64) * 64 sets * 2 ways = 8 KiB
// VIPT constraint: L1D_LEN + L1D_LINE_LEN + log2(XLEN/8) must fit in the
// 4 KiB page offset (<=12) so virt_idx == phys_idx. With 64B line OFFSET
// is 6 bits, so L1D_LEN must be <=6. More ways can increase capacity
// without extending the index beyond the page offset.
`define RAPT_L1D_LINE_LEN $clog2(`RAPT_CACHE_LINE_BYTES / (`RAPT_XLEN / 8))
`define RAPT_L1D_LEN 6
`define RAPT_L1D_N_WAYS 2
`ifndef RAPT_L1D_MSHRS
`define RAPT_L1D_MSHRS 4
`endif

`define RAPT_ITLB_ENTRIES 32
`define RAPT_DTLB_ENTRIES 32
// Shared instruction/data second-level translation cache; zero bypasses it.
`define RAPT_L2TLB_ENTRIES 256

// L2 unified cache: 64B line * 2048 sets * 1 way = 128 KiB
`ifndef RAPT_L2_EN
`define RAPT_L2_EN
`endif
`define RAPT_L2_LINE_LEN $clog2(`RAPT_CACHE_LINE_BYTES / (`RAPT_XLEN / 8))
`define RAPT_L2_LEN 11
`define RAPT_L2_N_WAYS 1

`endif
