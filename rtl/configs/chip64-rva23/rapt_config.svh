`ifndef RAPT_CONFIG_SVH
`define RAPT_CONFIG_SVH
`define RAPT_SRAM_CTRL_RESET 16'h0608

// Pin-limited 64-bit RVA23 chip (synth/configs/pin-limited/) with V 1.0, H,
// 64-byte cache lines, 16 KiB L1I/L1D, and 512 KiB inclusive L2.
// RV64 only; the missing include below stops an RV32 build at compile time.

// Application presets include V 1.0 (VLEN=128, ELEN=64).
// Define RAPT_NO_VPU to build the scalar configuration explicitly.
`ifndef RAPT_NO_VPU
`ifndef RAPT_V_EXTENSION
`define RAPT_V_EXTENSION
`endif
`endif

// ---------- Architecture (arch) ----------
`ifndef RAPT_RV64
`include "chip64-rva23 is RV64 only: define RAPT_RV64"
`endif
`define RAPT_XLEN 64
`ifdef RAPT_V_EXTENSION
`define RAPT_MISA 'h800000000034112f
`else
`define RAPT_MISA 'h800000000014112f
`endif
`define RAPT_M_EXTENSION 'h1

// RV64 physical-address capacity: 32..38 bits.
// The platform PMA map stays 32-bit, including its all-ones Bare alias.
`ifndef RAPT_PADDR_BITS
`define RAPT_PADDR_BITS 32
`endif

// ---------- Microarchitecture (uarch) ----------
`define RAPT_M_FAST 'h1

// Branch predictor
`define RAPT_PHT_SIZE 256
`define RAPT_BTB_SIZE 512
`define RAPT_BTB_WAYS 4
`define RAPT_RSB_SIZE 16
`define RAPT_BPU_DIRP_TAGE
`define RAPT_TAGE_BIM_BITS 10
`define RAPT_TAGE_INDEX_BITS 10

// OoO window sizing matching default.
`define RAPT_RIQ_SIZE 8
`define RAPT_IIQ_SIZE 8
`ifndef RAPT_ROB_SIZE
`define RAPT_ROB_SIZE 32
`endif
`define RAPT_OPERAND_SPILL_ENTRIES 16

// Scheduler: RS / IOQ to feed both ALU pipes plus pipelined MUL.
`define RAPT_RS_SIZE 8
`define RAPT_IOQ_SIZE 8

// Unified store queue.
`define RAPT_SQ_SIZE 16

// Hit-under-miss (Phase A2).
`define RAPT_LSU_HUM

// Ordered stage widths are authoritative and independently overrideable.
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

`define RAPT_REG_SIZE 32
`define RAPT_REG_LEN $clog2(`RAPT_REG_SIZE)

`define RAPT_PHY_SIZE 64
`define RAPT_PHY_LEN $clog2(`RAPT_PHY_SIZE)

// 64-byte cache lines (Zic64b / RVA23).
`define RAPT_CACHE_LINE_BYTES 64

// L1I (64 B line * 64 sets * 4-way = 16 KiB, VIPT-safe).
`define RAPT_L1I_LINE_LEN $clog2(`RAPT_CACHE_LINE_BYTES / 4)
`define RAPT_L1I_LEN 6
`define RAPT_L1I_N_WAYS 4
`define RAPT_L1I_REFILL_WORDS 8

// L1D (64 B line * 64 sets * 4-way = 16 KiB, VIPT-safe, write-back).
`define RAPT_L1D_LINE_LEN $clog2(`RAPT_CACHE_LINE_BYTES / (`RAPT_XLEN / 8))
`define RAPT_L1D_LEN 6
`ifndef RAPT_L1D_N_WAYS
`define RAPT_L1D_N_WAYS 4
`endif
`ifndef RAPT_L1D_WRITEBACK
`define RAPT_L1D_WRITEBACK 1
`endif
`ifndef RAPT_L1D_MSHRS
`define RAPT_L1D_MSHRS 4
`endif

// TLBs
`define RAPT_ITLB_ENTRIES 16
`define RAPT_DTLB_ENTRIES 64
`define RAPT_DTLB_WAYS 2
`define RAPT_L2TLB_ENTRIES 512
`define RAPT_L2TLB_WAYS 4

// L2 unified cache: 512 KiB = 1024 sets x 8 ways x 64 bytes, write-back.
`ifndef RAPT_L2_EN
`define RAPT_L2_EN
`endif
`define RAPT_L2_STORE_WRITEBACK
`define RAPT_L2_LEN 10
`define RAPT_L2_LINE_LEN $clog2(`RAPT_CACHE_LINE_BYTES / (`RAPT_XLEN / 8))
`define RAPT_L2_N_WAYS 8

// Cache SRAM subarray width in bits.
`define RAPT_CACHE_SRAMLEN 128

`endif  // RAPT_CONFIG_SVH
