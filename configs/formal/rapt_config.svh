`ifndef RAPT_CONFIG_SVH
`define RAPT_CONFIG_SVH
/**
 * Formal-verification uarch preset (riscv-formal / RVFI).
 *
 * Functionally a full RV32IMC core (32 architectural registers, I/M/C
 * extensions, dual-issue / dual-commit so RVFI channel 1 stays exercised),
 * but every memory array is shrunk to the minimum legal size so the
 * flattened netlist that riscv-formal feeds to yosys `prep`/`check` and the
 * BMC engine stays tractable.
 *
 * Rationale: the riscv-formal wrapper instantiates the whole `rapt` cluster,
 * so the L1I/L1D/L2/TLB/BPU/ROB/PRF memories all land in the proof cone.
 * With the `default` preset that flattens to ~57k cells / 177 memories and
 * yosys `check` alone runs for tens of minutes. The reductions below keep
 * the architecture identical (so the riscv-formal rv32imc instruction model
 * still applies) while cutting array depth by 1-2 orders of magnitude.
 *
 * Do NOT use this preset for performance/simulation runs.
 */

// Architecture: RV32 (RV64 still selectable via -DRAPT_RV64 for rv64 checks)
`ifdef RAPT_RV64
`define RAPT_XLEN 64
`define RAPT_MISA 'h8000000000141107
`else
`define RAPT_XLEN 32
`define RAPT_MISA 'h40141107
`endif
`define RAPT_I_EXTENSION 'h1
`define RAPT_M_EXTENSION 'h1

// One-cycle multiplier keeps the proof shallow.
`define RAPT_M_FAST 'h1

// Branch predictor: smallest tables, bimodal direction predictor (no TAGE /
// gshare history memories).
`define RAPT_PHT_SIZE 16
`define RAPT_BTB_SIZE 16
`define RAPT_BTB_WAYS 2
`define RAPT_RSB_SIZE 2
`define RAPT_BPU_DIRP_BIMODAL

// OoO window: keep dual issue/commit but the smallest window that still
// retires two consecutive entries.
`define RAPT_RIQ_SIZE 2
`define RAPT_IIQ_SIZE 2
`define RAPT_ROB_SIZE 4

`define RAPT_RS_SIZE 4
`define RAPT_IOQ_SIZE 4

`define RAPT_SQ_SIZE 4

// RVFI is enabled through the formal Makefile (-DRAPT_RVFI); leave the source
// default off so the preset is also usable for non-RVFI submodule proofs.

// Dual commit / dual issue retained so RVFI channel 1 is exercised.
`define RAPT_DUAL_COMMIT
`define RAPT_DUAL_ISSUE

`ifdef RAPT_DUAL_ISSUE
`define RAPT_ISSUE_WIDTH 2
`else
`define RAPT_ISSUE_WIDTH 1
`endif

// Full 32-entry architectural register file (rv32i, not rv32e).
`define RAPT_REG_SIZE 32
`define RAPT_REG_LEN $clog2(`RAPT_REG_SIZE)

// Physical register file: must be a power of two and cover 32 arch regs plus
// the in-flight window. 64 is the smallest legal value.
`define RAPT_PHY_SIZE 64
`define RAPT_PHY_LEN $clog2(`RAPT_PHY_SIZE)

// L1I: 2 words/line x 2 sets x 1 way (minimum legal geometry).
`define RAPT_L1I_LINE_LEN 1
`define RAPT_L1I_LEN 1
`define RAPT_L1I_N_WAYS 1

// L1D: 2 words/line x 2 sets x 1 way.
`define RAPT_L1D_LINE_LEN 1
`define RAPT_L1D_LEN 1
`define RAPT_L1D_N_WAYS 1

// L2: disabled (pass-through) so its tag/data arrays drop out of the cone.
// (RAPT_L2_EN intentionally not defined.)

`endif
