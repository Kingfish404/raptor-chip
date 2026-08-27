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
`define RAPT_MISA 'h800000000014112f
`else
`define RAPT_XLEN 32
`define RAPT_MISA 'h4014112f
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

// OoO window sizing (Phase B: grow toward a classic large-window OoO).
// ROB is the primary in-flight window; PHY must cover 32 arch regs plus the
// worst case of ROB_SIZE in-flight register writers (power of 2 required).
`define RAPT_RIQ_SIZE 8
`define RAPT_IIQ_SIZE 8
`define RAPT_ROB_SIZE 64

// Scheduler: RS / IOQ to feed both ALU pipes plus pipelined MUL.
`define RAPT_RS_SIZE 8
`ifndef RAPT_IOQ_SIZE
`define RAPT_IOQ_SIZE 8
`endif

// Unified SQ (Phase A): one queue holds a store from execute to drain
// (committed coloring), replacing the former split STQ(8)+SQ(8).  16 entries
// preserve the former aggregate capacity and move toward the Phase A target.
`define RAPT_SQ_SIZE 16

// Hit-under-miss (Phase A2): while a load miss waits on the bus refill, the
// idle L1D SRAM read port serves a second best-effort load (B channel).
// Bare-mode only; B completes only on a clean cacheable hit or SQ forward,
// everything else retries via the trap-owning A channel.
`define RAPT_LSU_HUM

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

`define RAPT_PHY_SIZE 128 // physical register number (must be power of 2)
`define RAPT_PHY_LEN $clog2(`RAPT_PHY_SIZE)

// Cache line size is a byte-level configuration. Keep it invariant across
// RV32/RV64; individual caches derive XLEN-word counts.
`define RAPT_CACHE_LINE_BYTES 64

// L1I (64 B line * 32 sets * 2-way = 4 KiB)
`define RAPT_L1I_LINE_LEN $clog2(`RAPT_CACHE_LINE_BYTES / 4)
`define RAPT_L1I_LEN 5
`define RAPT_L1I_N_WAYS 2
// Refill 32 B per L1I miss (8 x RV32 words). This covers most sequential
// fetch sectors while avoiding the request pressure of a full-line refill.
`ifndef RAPT_L1I_REFILL_WORDS
`define RAPT_L1I_REFILL_WORDS 8
`endif

// L1D (64 B line * 16 sets * 2-way = 2 KiB, VIPT-safe)
`define RAPT_L1D_LINE_LEN $clog2(`RAPT_CACHE_LINE_BYTES / (`RAPT_XLEN / 8))
`define RAPT_L1D_LEN 4
`define RAPT_L1D_N_WAYS 2

// L2 unified cache (between rapt_bus and io_master).
// `define RAPT_L2_EN  // disabled to isolate STA bottleneck
// 16 KiB direct-mapped (256 sets x 64B).  Multi-way support reserved.
`define RAPT_L2_LEN 8            // 256 sets
// 64-byte line (16 x 4B @ RV32, 8 x 8B @ RV64).
`define RAPT_L2_LINE_LEN $clog2(`RAPT_CACHE_LINE_BYTES / (`RAPT_XLEN / 8))
`define RAPT_L2_N_WAYS 1         // direct-mapped (multi-way support reserved)

// Cache SRAM subarray width in bits (matches CVW CACHE_SRAMLEN=128).
// Reduces SRAM instance count and address fanout vs per-word (32-bit) banks.
`define RAPT_CACHE_SRAMLEN 128

`endif
