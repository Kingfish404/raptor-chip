`ifndef RAPT_CONFIG_SVH
`define RAPT_CONFIG_SVH
/**
 * Architecture (arch) Parameters
 * @param RAPT_XLEN: Width of an integer register in bits
 * @param RAPT_I_EXTENSION: I Extension
 * @param RAPT_M_EXTENSION: M Extension
 */
// To select RV64: define RAPT_RV64 via compiler flag (-DRAPT_RV64)
// Default is RV32 when RAPT_RV64 is not defined
`ifdef RAPT_RV64
`define RAPT_XLEN 64
`define RAPT_MISA 'h8000000000141107
`else
`define RAPT_XLEN 32
`define RAPT_MISA 'h40141107
`endif
`define RAPT_I_EXTENSION 'h1
`define RAPT_M_EXTENSION 'h1

/**
 * Microarchitecture (uarch) Parameters
 * @param RAPT_M_FAST: M Extension Fast Mode (one cycle)
 *
 * @param L1I_LINE_LEN: L1I Line Length
 * @param L1I_LEN: L1I Length (Size)
 *
 * @param IQ_SIZE: Issue Queue Size
 * @param ROB_SIZE: ReOrder Buffer Size
 *
 * @param RS_SIZE: Revervation Station Size
 * @param IOQ_SIZE: In-Order Queue Size
 *
 * @param SQ_SIZE: Store Queue Size
 * @param L1D_LEN: L1D Length (Size)
 */

`define RAPT_M_FAST 'h1

// Branch predictor
`define RAPT_PHT_SIZE 256
`define RAPT_BTB_SIZE 128
`define RAPT_BTB_WAYS 2
`define RAPT_RSB_SIZE 4

// Direction-predictor (DIRP). The default is TAGE for the best IPC;
// alternatives are kept for ablation / low-area builds.
//   RAPT_BPU_DIRP_TAGE     — bimodal base + 3 tagged tables, history 8/16/64
//   RAPT_BPU_DIRP_GSHARE   — PC XOR GHR indexed 2-bit counters
//   RAPT_BPU_DIRP_BIMODAL  — PC-only 2-bit counters (default if none set)
//   RAPT_BPU_DIRP_STATIC   — always-not-taken (control reference)
`define RAPT_BPU_DIRP_TAGE

// OoO window sizing. Rationale: dual-issue rename/commit were throttled by
// an 8-entry ROB and 4-entry RS; with 2-ALU + pipelined MUL + OoO LSU the
// in-flight window becomes the new bottleneck, so ROB/PRF are grown to
// reduce dispatch stall.
`define RAPT_RIQ_SIZE 8
`define RAPT_IIQ_SIZE 8
`define RAPT_ROB_SIZE 16

// Scheduler: RS / IOQ to feed both ALU pipes plus pipelined MUL.
`define RAPT_RS_SIZE 8
`define RAPT_IOQ_SIZE 8

`define RAPT_SQ_SIZE 8

// RVFI: RISC-V Formal Interface for formal verification.
// Adds RVFI output ports to the core; enable only for riscv-formal checks.
// `define RAPT_RVFI

// Dual commit: retire up to 2 consecutive ROB entries per cycle.
// Comment out or undefine to disable for A/B benchmarking.
`define RAPT_DUAL_COMMIT

// Dual issue: dispatch up to 2 instructions per cycle through the pipeline.
// Widens IFU, IDU, RNU, ROU, EXU dispatch paths. Comment out to revert to single-issue.
`define RAPT_DUAL_ISSUE

// Issue width (number of instructions dispatched per cycle)
// Set to 1 for single-issue; increase for multi-issue
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

// L1I (Phase A baseline: 64 B line × 64 sets × 2-way = 8 KiB)
`define RAPT_L1I_LINE_LEN 4
`define RAPT_L1I_LEN 5
`define RAPT_L1I_N_WAYS 2

// L1D (Phase A baseline: 64 B line × 32 sets × 2-way = 4 KiB, VIPT-safe)
`ifdef RAPT_RV64
`define RAPT_L1D_LINE_LEN 3
`else
`define RAPT_L1D_LINE_LEN 4
`endif
`define RAPT_L1D_LEN 4
`define RAPT_L1D_N_WAYS 2

// L2 unified cache (between rapt_bus and io_master).
// Disabled by default -- pass-through. Define `RAPT_L2_EN` to opt in.
`define RAPT_L2_EN
// Target is 2x(L1I+L1D). With direct-mapped + power-of-two sets,
// default rounds up to 16 KiB (256 sets x 64B).
`define RAPT_L2_LEN 8            // 256 sets
// 64-byte line (16 × 4B @ RV32, 8 × 8B @ RV64).
`ifdef RAPT_RV64
`define RAPT_L2_LINE_LEN 3
`else
`define RAPT_L2_LINE_LEN 4
`endif
`define RAPT_L2_N_WAYS 1         // direct-mapped (only mode supported today)

`endif
