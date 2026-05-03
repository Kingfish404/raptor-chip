`ifndef RAPT_SOC_SVH
`define RAPT_SOC_SVH

`define RAPT_PC_INIT `RAPT_XLEN'h20000000

`define RAPT_ROM_ADDR 'h20000000

`define RAPT_CLINT_BASE 'h02000000
`define RAPT_CLINT_MSIP 'h02000000
`define RAPT_CLINT_MTIMECMP 'h02004000
`define RAPT_CLINT_MTIMECMP_UP 'h02004004
`define RAPT_BUS_RTC_ADDR 'h0200BFF8
`define RAPT_BUS_RTC_ADDR_UP 'h0200BFFC

// --- PLIC (Platform-Level Interrupt Controller) -----------------------------
// 16 MB window starting at 0x0C00_0000, matching the standard RISC-V layout
// and NEMU's reference model (see nemu/src/device/intr.c). Anything that
// satisfies `(addr[31:24] == 8'h0c)` is considered a PLIC access.
`define RAPT_PLIC_BASE 'h0c000000
`define RAPT_PLIC_SIZE 'h01000000
`define RAPT_PLIC_NDEV 31           // sources 1..31; source 0 reserved
`define RAPT_PLIC_NCTX 2            // ctx0 = M-mode hart 0, ctx1 = S-mode hart 0

// --- Timer / clock model -----------------------------------------------------
// Nominal core clock frequency assumed by the simulator's cycle model. The DTS
// `timebase-frequency` (RAPT_MTIME_FREQ_MHZ * 1_000_000) MUST match the rate
// at which CLINT `mtime` and CSR `time` advance. The divider derived below
// paces both so that the kernel-visible time matches what device tree /
// OpenSBI declared.
//
// Override on the verilator/synthesis command line, e.g.:
//   VFLAGS="-DRAPT_MTIME_FREQ_MHZ=50"
//   VFLAGS="-DRAPT_CORE_CLOCK_MHZ=500 -DRAPT_MTIME_FREQ_MHZ=10"
// Remember to also rebuild the DTS / opensbi platform with the matching value.
`ifndef RAPT_CORE_CLOCK_MHZ
`define RAPT_CORE_CLOCK_MHZ 1000
`endif
`ifndef RAPT_MTIME_FREQ_MHZ
`define RAPT_MTIME_FREQ_MHZ 10
`endif
`ifndef RAPT_MTIME_DIV
`define RAPT_MTIME_DIV (`RAPT_CORE_CLOCK_MHZ / `RAPT_MTIME_FREQ_MHZ)
`endif

`define RAPT_BUS_SERIAL_PORT 'h10000000
`define RAPT_BUS_NS16550_ADDR 'h10000000

`define RAPT_BUS_FINISHER_ADDR 'h00100000

// `define RAPT_USE_SLAVE 1

`define RAPT_I_SDRAM_ARBURST 0

// random test setting
`define RAPT_IFSR_ENABLE 0

`endif
