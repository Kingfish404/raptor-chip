# Core docs

- **[uarch](./uarch.md)** - Microarchitecture details (pipeline stages, module descriptions, interfaces, config parameters, mermaid diagram)
- **[Boot Linux Kernel](./linux_kernel.md)** - OpenSBI + Linux kernel boot on NEMU/NPC
- [PROFILE](./PROFILE.md) - Performance evaluation results (microbench, coremark, PPA)
- [perf-iterations](./perf-iterations.md) - Microarchitecture change performance tracking (IPC, stall breakdown)
- [REFERENCE](./REFERENCE.md) - AXI protocol and PPA benchmark references

## Quick Command Reference

All commands run from the **project root**. No `source env.sh` needed.

| Task | Command |
|------|---------|
| Show all targets | `make help` |
| Setup environment | `make setup` |
| Generate RTL | `make verilog` |
| Build & run NEMU | `make nemu-run` |
| Full NPC simulation | `make npc-sim` |
| NPC simulation (batch, no wave) | `make npc-run ARGS="-b -n"` |
| Run CoreMark on NPC | `make coremark ARGS="-b -n"` |
| Run MicroBench on NPC | `make microbench ARGS="-b -n"` |
| Run nanos-lite on NEMU | `make nanos-nemu` |
| Boot Linux on NEMU | `make linux-boot` |
| FPGA synthesis | `make fpga-syn` |
| Pack SV / Lint / STA | `make pack` / `make lint` / `make sta` |
| Clean all | `make clean` |

## Project Structure

```
raptor-chip/
├── Makefile              # Top-level Makefile (one-line commands)
├── env.sh                # Environment variables (auto-sourced by Makefile)
├── setup.sh              # Dependency installation script
├── rtl_scala/            # Chisel (Scala) → SystemVerilog generation
├── rtl_sv/               # Generated & handwritten SystemVerilog RTL
│   ├── include/          # Config, interfaces, DPI-C macros
│   │   ├── ysyx_config.svh          # Microarch params (ISSUE_WIDTH, ROB_SIZE, cache, BPU, …)
│   │   ├── ysyx_rnu_internal_if.svh # RNU internal interfaces (rnu_fl_if, rnu_mt_if)
│   │   └── ysyx_*_if.svh            # Inter-module interfaces (ifu/idu/rnu/rou/exu)
│   ├── ysyx_pkg.sv       # Types: uop_t, prd_t, rob_entry_t, rob_state_t
│   ├── ysyx.sv            # Top-level core (pure wiring, instantiates all stages + PRF)
│   ├── frontend/         # IFU, IDU (RVC + csr_addr_valid), BPU (PHT/BTB/GHR/RSB), CSR* (M/S-mode)
│   ├── backend/          # RNU (RNQ + freelist + maptable), PRF (2R/2W), ROU (UOQ + ROB), EXU (RS + IOQ + ALU + MUL), CMU
│   ├── memory/           # LSU (STQ + SQ), L1I (TLB, Sv32 PTW), L1D (TLB, STLB, Sv32 PTW), BUS (AXI4), CLINT
│   └── generated/        # Chisel-generated decoders
│   # *CSR lives in frontend/ on disk but architecturally belongs to the backend
├── nemu/                 # NEMU software emulator (RISC-V ISS)
├── nsim/                 # NPC simulator (Verilator testbench)
├── abstract-machine/     # Abstract Machine runtime framework
├── navy-apps/            # Navy applications (for nanos-lite)
├── nanos-lite/           # NanoS-lite simple OS
├── linux/                # Linux kernel build scripts
├── fpga/                 # FPGA targets (Gowin Tang Nano 20K)
├── third_party/          # Third-party dependencies
└── docs/                 # Documentation (this directory)
```

## Code Style and Conventions

SystemVerilog features used in this project:
- `logic` instead of `reg` and `wire`
- `always_comb`, `always_ff`, `always_latch` instead of `always @(*)`, `always @(posedge clk)`, `always @(...)`
- `typedef enum` for finite state machines (e.g., `rob_state_t`)
- `typedef struct packed` for bundled signals (e.g., `uop_t`, `prd_t`, `rob_entry_t`)
- `interface` for inter-module ports (`<src>_<dst>_if`) and internal sub-module ports (`rnu_<component>_if`)
- `package` for global definitions (`ysyx_pkg`)
- All modules/defines use `ysyx_` prefix
- Named port connections only (`.port(signal)`), never positional

The rtl should be synthesizable by Yosys (with slang[^1]).

[^1]: https://github.com/povik/yosys-slang

## (Micro)Architecture

![](./assets/npc-rv32.svg)

## spike device tree

[Spike. riscv-isa-sim/riscv/platform.h](https://github.com/riscv-software-src/riscv-isa-sim/blob/master/riscv/platform.h)

```c
#define DEFAULT_KERNEL_BOOTARGS "console=ttyS0 earlycon"
#define DEFAULT_RSTVEC     0x00001000
#define DEFAULT_ISA        "rv64imafdc_zicntr_zihpm"
#define DEFAULT_PRIV       "MSU"
#define CLINT_BASE         0x02000000
#define CLINT_SIZE         0x000c0000
#define PLIC_BASE          0x0c000000
#define PLIC_SIZE          0x01000000
#define PLIC_NDEV          31
#define PLIC_PRIO_BITS     4
#define NS16550_BASE       0x10000000
#define NS16550_SIZE       0x100
#define NS16550_REG_SHIFT  0
#define NS16550_REG_IO_WIDTH 1
#define NS16550_INTERRUPT_ID 1
#define EXT_IO_BASE        0x40000000
#define DRAM_BASE          0x80000000
```

## qemu device tree

[QEMU, hw/riscv/virt.c](https://github.com/qemu/qemu/blob/master/hw/riscv/virt.c)

```c
static const MemMapEntry virt_memmap[] = {
    [VIRT_DEBUG] =        {        0x0,         0x100 },
    [VIRT_MROM] =         {     0x1000,        0xf000 },
    [VIRT_TEST] =         {   0x100000,        0x1000 },
    [VIRT_RTC] =          {   0x101000,        0x1000 },
    [VIRT_CLINT] =        {  0x2000000,       0x10000 },
    [VIRT_ACLINT_SSWI] =  {  0x2F00000,        0x4000 },
    [VIRT_PCIE_PIO] =     {  0x3000000,       0x10000 },
    [VIRT_IOMMU_SYS] =    {  0x3010000,        0x1000 },
    [VIRT_PLATFORM_BUS] = {  0x4000000,     0x2000000 },
    [VIRT_PLIC] =         {  0xc000000, VIRT_PLIC_SIZE(VIRT_CPUS_MAX * 2) },
    [VIRT_APLIC_M] =      {  0xc000000, APLIC_SIZE(VIRT_CPUS_MAX) },
    [VIRT_APLIC_S] =      {  0xd000000, APLIC_SIZE(VIRT_CPUS_MAX) },
    [VIRT_UART0] =        { 0x10000000,         0x100 },
    [VIRT_VIRTIO] =       { 0x10001000,        0x1000 },
    [VIRT_FW_CFG] =       { 0x10100000,          0x18 },
    [VIRT_FLASH] =        { 0x20000000,     0x4000000 },
    [VIRT_IMSIC_M] =      { 0x24000000, VIRT_IMSIC_MAX_SIZE },
    [VIRT_IMSIC_S] =      { 0x28000000, VIRT_IMSIC_MAX_SIZE },
    [VIRT_PCIE_ECAM] =    { 0x30000000,    0x10000000 },
    [VIRT_PCIE_MMIO] =    { 0x40000000,    0x40000000 },
    [VIRT_DRAM] =         { 0x80000000,           0x0 },
};
```

## npc

npc (npc_soc) 包含的外围设备和相应的地址空间如下：

| 设备      | 地址空间                  |
| --------- | ------------------------- |
| CLINT     | `0x0200_0000~0x0200_ffff` |
| UART16550 | `0x1000_0000~0x1000_0fff` |
| PSRAM     | `0x8000_0000~0x9fff_ffff` |

PC_INIT 为 `0x8000_0000`，即 PSRAM 的起始地址。

## ysyxSoC

ysyxSoC 包含的外围设备和相应的地址空间如下：

| 设备          | 地址空间                  |
| ------------- | ------------------------- |
| CLINT         | `0x0200_0000~0x0200_ffff` |
| SRAM          | `0x0f00_0000~0x0fff_ffff` |
| UART16550     | `0x1000_0000~0x1000_0fff` |
| SPI master    | `0x1000_1000~0x1000_1fff` |
| GPIO          | `0x1000_2000~0x1000_200f` |
| PS2           | `0x1001_1000~0x1001_1007` |
| MROM          | `0x2000_0000~0x2000_0fff` |
| VGA           | `0x2100_0000~0x211f_ffff` |
| Flash         | `0x3000_0000~0x3fff_ffff` |
| ChipLink MMIO | `0x4000_0000~0x7fff_ffff` |
| PSRAM         | `0x8000_0000~0x9fff_ffff` |
| SDRAM         | `0xa000_0000~0xbfff_ffff` |
| ChipLink MEM  | `0xc000_0000~0xffff_ffff` |
| Reverse       | 其他                      |

PC_INIT 为 `0x3000_0000`，即 Flash 的起始地址。需要通过FSBL（First Stage Boot Loader）和SSBL（Second Stage Boot Loader）将程序加载到 SRAM 中运行，详情见`trm.c`。
