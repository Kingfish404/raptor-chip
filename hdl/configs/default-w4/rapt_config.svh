`ifndef RAPT_CONFIG_SVH
`define RAPT_CONFIG_SVH

/**
 * default-w4 preset: four decode, rename, dispatch, commit and integer issue
 * lanes, with the default preset's early load and store-follower paths.
 * Cache geometry/BPU match default; L1D has four MSHRs.
 *
 * ROB 64 provides sixteen full dispatch groups; ALQ/IOQ 16 provide four.
 * RNQ/UOQ retain two full groups because neither queue reclaims space on the
 * admission edge. Operand spill 32 matches half the ROB; PHY 128 covers the
 * architectural mappings, ROB writers and renamed work before allocation.
 *
 * These capacities are an evaluation starting point, not a measured optimum.
 * Earlier CoreMark runs used ROB 32 and ALQ/IOQ 8. Keep capacities and fast
 * paths overrideable for separate performance and physical-cost comparisons.
 */
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
`define RAPT_PHT_SIZE 1024
`ifdef RAPT_RV64
`ifndef RAPT_BPU_AUX_PC_HASH
`define RAPT_BPU_AUX_PC_HASH 1
`endif
`endif
`define RAPT_BTB_SIZE 256
`define RAPT_BTB_WAYS 2
`define RAPT_RSB_SIZE 16

// Direction-predictor (DIRP). The default is TAGE for the best IPC;
// alternatives are kept for ablation / low-area builds.
//   RAPT_BPU_DIRP_TAGE     — bimodal base + 3 tagged tables, history 8/16/64
//   RAPT_BPU_DIRP_GSHARE   — PC XOR GHR indexed 2-bit counters
//   RAPT_BPU_DIRP_BIMODAL  — PC-only 2-bit counters (default if none set)
//   RAPT_BPU_DIRP_STATIC   — always-not-taken (control reference)
`define RAPT_BPU_DIRP_TAGE

// Shared RV32/RV64 OoO window sizing for simulation and FPGA.
// ROB is the primary in-flight window; PHY must cover 32 arch regs plus the
// worst case of ROB_SIZE in-flight register writers (power of 2 required).
`ifndef RAPT_RIQ_SIZE
`define RAPT_RIQ_SIZE 8
`endif
`ifndef RAPT_IIQ_SIZE
`define RAPT_IIQ_SIZE 8
`endif
`ifndef RAPT_ROB_SIZE
`define RAPT_ROB_SIZE 64
`endif
`ifndef RAPT_OPERAND_SPILL_ENTRIES
`define RAPT_OPERAND_SPILL_ENTRIES (`RAPT_ROB_SIZE / 2)
`endif

// ALQ is shared by all four integer issue ports; IOQ feeds the scalar LSU.
`ifndef RAPT_RS_SIZE
`define RAPT_RS_SIZE 16
`endif
`ifndef RAPT_IOQ_SIZE
`define RAPT_IOQ_SIZE 16
`endif

// Unified SQ (Phase A): one queue holds a store from execute to drain
// (committed coloring), replacing the former split STQ(8)+SQ(8).  16 entries
// preserve the former aggregate capacity and move toward the Phase A target.
`ifndef RAPT_SQ_SIZE
`define RAPT_SQ_SIZE 16
`endif

// Hit-under-miss (Phase A2): while a load miss waits on the bus refill, the
// idle L1D SRAM read port serves a second best-effort load (B channel).
// Bare-mode only; B completes only on a clean cacheable hit or SQ forward,
// everything else retries via the trap-owning A channel.
`define RAPT_LSU_HUM

// Match the default preset's load wakeup and store-following retirement paths.
`ifndef RAPT_IOQ_EARLY_LOAD_BCAST
`define RAPT_IOQ_EARLY_LOAD_BCAST 1
`endif
`ifndef RAPT_IOQ_LIVE_EARLY_BCAST
`define RAPT_IOQ_LIVE_EARLY_BCAST 1
`endif
`ifndef RAPT_IOQ_EARLY_LOAD_STORES
`define RAPT_IOQ_EARLY_LOAD_STORES 1
`endif
`ifndef RAPT_IOQ_WAKE_NEXT_B_REQUEST
`define RAPT_IOQ_WAKE_NEXT_B_REQUEST 1
`endif
`ifndef RAPT_ROU_STORE_FOLLOWER
`define RAPT_ROU_STORE_FOLLOWER 1
`endif

`ifndef RAPT_ALQ_LOAD_WAKE
`define RAPT_ALQ_LOAD_WAKE 1
`endif
`ifndef RAPT_BRQ_CDB_WAKE
`define RAPT_BRQ_CDB_WAKE 1
`endif
`ifndef RAPT_IOQ_FORWARD_REQUEST
`define RAPT_IOQ_FORWARD_REQUEST 1
`endif
`ifndef RAPT_IOQ_STORE_PRECHECK
`define RAPT_IOQ_STORE_PRECHECK 1
`endif
`ifndef RAPT_MDQ_LIVE_WAKE
`define RAPT_MDQ_LIVE_WAKE 1
`endif
`ifndef RAPT_SQ_NARROW_FORWARD
`define RAPT_SQ_NARROW_FORWARD 1
`endif
`ifndef RAPT_FETCH_BRANCH_FOLLOWER
`define RAPT_FETCH_BRANCH_FOLLOWER 1
`endif
`ifndef RAPT_TAGE_BIM_BITS
`define RAPT_TAGE_BIM_BITS 10
`endif
`ifndef RAPT_TAGE_INDEX_BITS
`define RAPT_TAGE_INDEX_BITS 9
`endif

`ifndef RAPT_BPU_AUX_TAGE
`define RAPT_BPU_AUX_TAGE 1
`endif

// RVFI: RISC-V Formal Interface for formal verification.
// Adds RVFI output ports to the core; enable only for riscv-formal checks.
// `define RAPT_RVFI

// Ordered stage widths are authoritative and independently overrideable.
`ifndef RAPT_INTEGER_ISSUE_PORTS
`define RAPT_INTEGER_ISSUE_PORTS 4
`endif
`ifndef RAPT_INTEGER_SYSTEM_PORT
`define RAPT_INTEGER_SYSTEM_PORT 0
`endif
`ifndef RAPT_DECODE_WIDTH
`define RAPT_DECODE_WIDTH 4
`endif
`ifndef RAPT_RENAME_WIDTH
`define RAPT_RENAME_WIDTH 4
`endif
`ifndef RAPT_DISPATCH_WIDTH
`define RAPT_DISPATCH_WIDTH 4
`endif
`ifndef RAPT_COMMIT_WIDTH
`define RAPT_COMMIT_WIDTH 4
`endif
`ifndef RAPT_FETCH_LOOKAHEAD
`define RAPT_FETCH_LOOKAHEAD
`endif
// Read a complete four-instruction window on cache hits, including an
// unaligned 32-bit instruction at the end of the window.
`define RAPT_FETCH_WIDE

`ifdef RAPT_I_EXTENSION
`define RAPT_REG_SIZE 32 // 32 registers
`else
`define RAPT_REG_SIZE 16 // 16 registers
`endif

`define RAPT_REG_LEN $clog2(`RAPT_REG_SIZE) // Register Length

// Shared simulation/FPGA default. Explicit overrides remain available for
// parameterized verification; PHY must still cover the configured ROB.
`ifndef RAPT_PHY_SIZE
`define RAPT_PHY_SIZE 128 // physical register number (must be power of 2)
`endif
`define RAPT_PHY_LEN $clog2(`RAPT_PHY_SIZE)

// Cache line size is a byte-level configuration. Keep it invariant across
// RV32/RV64; individual caches derive XLEN-word counts.
`define RAPT_CACHE_LINE_BYTES 64

// L1I (64 B line * 64 sets * 4-way = 16 KiB).
// Each way spans one 4 KiB page: virtual and physical indices coincide.
`define RAPT_L1I_LINE_LEN $clog2(`RAPT_CACHE_LINE_BYTES / 4)
`define RAPT_L1I_LEN 6
`define RAPT_L1I_N_WAYS 4
// Refill 32 B per L1I miss (8 x RV32 words). This covers most sequential
// fetch sectors while avoiding the request pressure of a full-line refill.
`ifndef RAPT_L1I_REFILL_WORDS
`define RAPT_L1I_REFILL_WORDS 8
`endif

// L1D (64 B line * 64 sets * 4-way = 16 KiB, VIPT-safe for RV32/RV64).
`define RAPT_L1D_LINE_LEN $clog2(`RAPT_CACHE_LINE_BYTES / (`RAPT_XLEN / 8))
`define RAPT_L1D_LEN 6
`define RAPT_L1D_N_WAYS 4
`ifndef RAPT_L1D_MSHRS
`define RAPT_L1D_MSHRS 4
`endif

// Fully-associative translation caches.  The data-side arrays are replicated
// for simultaneous load/store lookup and receive the same fills.
`define RAPT_ITLB_ENTRIES 16
`define RAPT_DTLB_ENTRIES 16

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
