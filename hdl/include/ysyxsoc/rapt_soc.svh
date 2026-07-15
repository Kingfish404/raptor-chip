`ifndef RAPT_SOC_SVH
`define RAPT_SOC_SVH

`define RAPT_PC_INIT `RAPT_XLEN'h30000000

`define RAPT_ROM_ADDR 'h00001000

`define RAPT_CLINT_BASE 'h02000000
`define RAPT_CLINT_MSIP 'h02000000
`define RAPT_CLINT_MTIMECMP 'h02004000
`define RAPT_CLINT_MTIMECMP_UP 'h02004004
`define RAPT_BUS_RTC_ADDR 'h0200BFF8
`define RAPT_BUS_RTC_ADDR_UP 'h0200BFFC

// --- PLIC (Platform-Level Interrupt Controller) -----------------------------
`define RAPT_PLIC_BASE 'h0c000000
`define RAPT_PLIC_SIZE 'h01000000
`define RAPT_PLIC_NDEV 31
`define RAPT_PLIC_NCTX 2

// --- Timer / clock model (see hdl/include/npc/rapt_soc.svh for details) ---
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

`define RAPT_USE_SLAVE 1

`define RAPT_I_SDRAM_ARBURST 1

// random test setting
`define RAPT_IFSR_ENABLE 0

`endif
