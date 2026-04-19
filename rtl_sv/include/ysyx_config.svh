`ifndef YSYX_CONFIG_SVH
`define YSYX_CONFIG_SVH
/**
 * Architecture (arch) Parameters
 * @param YSYX_XLEN: Width of an integer register in bits
 * @param YSYX_I_EXTENSION: I Extension
 * @param YSYX_M_EXTENSION: M Extension
 */
// To select RV64: define YSYX_RV64 via compiler flag (-DYSYX_RV64)
// Default is RV32 when YSYX_RV64 is not defined
`ifdef YSYX_RV64
`define YSYX_XLEN 64
`define YSYX_MISA 'h8000000000141107
`else
`define YSYX_XLEN 32
`define YSYX_MISA 'h40141107
`endif
`define YSYX_I_EXTENSION 'h1
`define YSYX_M_EXTENSION 'h1

/**
 * Microarchitecture (uarch) Parameters
 * @param YSYX_M_FAST: M Extension Fast Mode (one cycle)
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

`define YSYX_M_FAST 'h1
`define YSYX_L1I_LINE_LEN 2
`define YSYX_L1I_LEN 6
`define YSYX_L1I_N_WAYS 1

`define YSYX_PHT_SIZE 256
`define YSYX_BTB_SIZE 128
`define YSYX_BTB_WAYS 2
`define YSYX_RSB_SIZE 8

// OoO window sizing. Rationale: dual-issue rename/commit were throttled by
// an 8-entry ROB and 4-entry RS; with 2-ALU + pipelined MUL + OoO LSU the
// in-flight window becomes the new bottleneck, so ROB/PRF are grown to
// reduce dispatch stall.
`define YSYX_RIQ_SIZE 8
`define YSYX_IIQ_SIZE 8
`define YSYX_ROB_SIZE 16

`define YSYX_RS_SIZE 8
`define YSYX_IOQ_SIZE 8

`define YSYX_SQ_SIZE 8
`define YSYX_L1D_LINE_LEN 1
`define YSYX_L1D_LEN 5
`define YSYX_L1D_N_WAYS 2

// RVFI: RISC-V Formal Interface for formal verification.
// Adds RVFI output ports to the core; enable only for riscv-formal checks.
// `define YSYX_RVFI

// Dual commit: retire up to 2 consecutive ROB entries per cycle.
// Comment out or undefine to disable for A/B benchmarking.
`define YSYX_DUAL_COMMIT

// Dual issue: dispatch up to 2 instructions per cycle through the pipeline.
// Widens IFU, IDU, RNU, ROU, EXU dispatch paths. Comment out to revert to single-issue.
`define YSYX_DUAL_ISSUE

// Issue width (number of instructions dispatched per cycle)
// Set to 1 for single-issue; increase for multi-issue
`ifdef YSYX_DUAL_ISSUE
`define YSYX_ISSUE_WIDTH 2
`else
`define YSYX_ISSUE_WIDTH 1
`endif

`ifdef YSYX_I_EXTENSION
`define YSYX_REG_SIZE 32 // 32 registers
`else
`define YSYX_REG_SIZE 16 // 16 registers
`endif

`define YSYX_REG_LEN $clog2(`YSYX_REG_SIZE) // Register Length

`define YSYX_PHY_SIZE 64 // physical register number (must be power of 2)
`define YSYX_PHY_LEN $clog2(`YSYX_PHY_SIZE)

`endif
