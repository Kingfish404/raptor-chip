`ifndef RAPT_CONFIG_SVH
`define RAPT_CONFIG_SVH

/**
 * default-w8 evaluation preset: eight decode, rename, dispatch, commit and
 * integer issue lanes. Cache geometry matches default-w4; branch-predictor
 * tables keep the default sizes. L1D retains its four MSHRs. ROB 64 provides
 * eight full dispatch groups, ALQ/IOQ 16 provide two, and SQ 16 matches the
 * scalar store commit/drain endpoint, which does not widen with the core.
 * Operand spill 32 provides four groups. PHY 128 covers the 32 architectural
 * mappings plus the ROB and nearly all renamed work before allocation; at most
 * 136 destinations can be live, and a short stall is safe.
 *
 * RNQ and UOQ grow from 8 to 16 entries because neither queue has empty
 * fall-through or same-cycle reclaim. An 8-entry queue with an 8-wide input
 * would otherwise accept a full group only every other cycle.
 *
 * The default preset's early load wakeup and store-follower paths avoid
 * memory dependency and commit bubbles exposed by the wider backend.
 * RAPT_FETCH_WIDE supplies at most four full 32-bit instructions per fetch
 * response, so sustained eight-instruction frontend throughput is unavailable.
 * Capacities are an evaluation starting point, not a measured optimum. RV32
 * CoreMark ROI cycles were unchanged when PHY 256 and SQ 32 were reduced to
 * PHY 128 and SQ 16 (2026-10-06).
 */
/**
 * Architecture (arch) Parameters
 * @param RAPT_XLEN: Width of an integer register in bits
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
`define RAPT_M_EXTENSION 'h1

/**
 * Microarchitecture (uarch) Parameters
 * @param RAPT_M_FAST: Pipelined multiply (2-cycle latency, 1/cycle throughput); iterative divide
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
//   RAPT_BPU_DIRP_BIMODAL  — PC-only 2-bit counters
//   RAPT_BPU_DIRP_STATIC   — always-not-taken (control reference)
`define RAPT_BPU_DIRP_TAGE

// Shared RV32/RV64 OoO window sizing for simulation and FPGA.
// ROB is the primary in-flight window. With RAPT_FETCH_LOOKAHEAD, ROB_SIZE must
// be a power of two (the BPU tracks 2 * ROB_SIZE predictions). PHY only has to
// exceed the 32 arch regs; 32 + ROB_SIZE avoids rename stalls on free registers.
`define RAPT_RIQ_SIZE 16
`define RAPT_IIQ_SIZE 16
`ifndef RAPT_ROB_SIZE
`define RAPT_ROB_SIZE 64
`endif
`define RAPT_OPERAND_SPILL_ENTRIES 32

// ALQ is shared by all eight integer issue ports; IOQ feeds the scalar LSU.
`define RAPT_RS_SIZE 16
`define RAPT_IOQ_SIZE 16

// One queue holds each store from execution through committed drain. Commit
// and drain remain one store per cycle, so the default-w4 depth suffices.
`define RAPT_SQ_SIZE 16

// Hit-under-miss (Phase A2): while a load miss waits on the bus refill, the
// idle L1D SRAM read port serves a second best-effort load (B channel).
// Bare-mode only; B completes only on a clean cacheable hit or SQ forward,
// everything else retries via the trap-owning A channel.
`define RAPT_LSU_HUM

// RVFI: RISC-V Formal Interface for formal verification.
// Adds RVFI output ports to the core; enable only for riscv-formal checks.
// `define RAPT_RVFI

// Ordered stage widths are authoritative and independently overrideable.
`ifndef RAPT_INTEGER_ISSUE_PORTS
`define RAPT_INTEGER_ISSUE_PORTS 8
`endif
`ifndef RAPT_INTEGER_SYSTEM_PORT
`define RAPT_INTEGER_SYSTEM_PORT 0
`endif
`ifndef RAPT_DECODE_WIDTH
`define RAPT_DECODE_WIDTH 8
`endif
`ifndef RAPT_RENAME_WIDTH
`define RAPT_RENAME_WIDTH 8
`endif
`ifndef RAPT_DISPATCH_WIDTH
`define RAPT_DISPATCH_WIDTH 8
`endif
`ifndef RAPT_COMMIT_WIDTH
`define RAPT_COMMIT_WIDTH 8
`endif
`define RAPT_FETCH_LOOKAHEAD
// Reuse the available wide fetch window; its 8 halfwords cannot supply
// eight 32-bit instructions in a single response.
`define RAPT_FETCH_WIDE

`define RAPT_REG_SIZE 32 // 32 registers

`define RAPT_REG_LEN $clog2(`RAPT_REG_SIZE) // Register Length

// Shared simulation/FPGA default. Explicit overrides remain available for
// parameterized verification; PHY must still cover the configured ROB.
`define RAPT_PHY_SIZE 128 // total physical registers, including architectural mappings
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
`define RAPT_L1I_REFILL_WORDS 8

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
// 16 KiB direct-mapped (256 sets x 64B).
`define RAPT_L2_LEN 8            // 256 sets
// 64-byte line (16 x 4B @ RV32, 8 x 8B @ RV64).
`define RAPT_L2_LINE_LEN $clog2(`RAPT_CACHE_LINE_BYTES / (`RAPT_XLEN / 8))
`define RAPT_L2_N_WAYS 1         // direct-mapped

// Cache SRAM subarray width in bits (matches CVW CACHE_SRAMLEN=128).
// Reduces SRAM instance count and address fanout vs per-word (32-bit) banks.
`define RAPT_CACHE_SRAMLEN 128

`endif
