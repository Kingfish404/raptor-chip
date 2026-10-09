---
title: Ecosystem
---

# Ecosystem

Simulators, FPGA boards, ASIC flow, software stack, and memory maps.

## Supported Targets

| Target      | Purpose                           | Entry                                                         |
| ----------- | --------------------------------- | ------------------------------------------------------------- |
| NEMU        | Software ISS (difftest reference) | `nemu/README.md`                                              |
| NPC         | Verilator simulator               | `sim/`                                                        |
| FPGA        | LiteX boards + Gowin Tang Nano    | `fpga/litex/README.md`, `fpga/gowin-tang-nano-20k/README.md`  |
| ASIC (open) | Yosys + OpenSTA flow              | [yosys-opensta](https://github.com/Kingfish404/yosys-opensta) |

## Simulators

| Simulator   | Role                                     | Entry                      |
| ----------- | ---------------------------------------- | -------------------------- |
| **NEMU**    | Software ISS, reference model            | `make run-nemu32`, `nemu/` |
| **NPC**     | Verilator, cycle-accurate, waveform      | `make run-rv32`, `sim/`    |
| **raptSoC** | SystemVerilog NPC top + AXI memory model | `sim/rtl/rapt_npc_soc.sv`  |

NPC is the primary development simulator. With `DIFFTEST=1` (the default), NEMU checks retired architectural state; intentional MMIO/interrupt skip paths are handled by the differential-test protocol.

## FPGA Targets

| Board / Flow                   | Status                                                                  | Entry                                        |
| ------------------------------ | ----------------------------------------------------------------------- | -------------------------------------------- |
| **MLK-CU08-KU15P / LiteX**     | Primary: Vivado, MIG DDR4, SD, CM005 Ethernet, RV32/RV64 Linux/netboot  | `fpga/litex/`                                |
| **MLK-CU07-KU15P / LiteX**     | Vivado, BIOS, MIG DDR4, SDCard, RV32 Linux boot                         | `fpga/litex/`                                |
| **Alinx AXAU15 / LiteX**       | Vivado AU15P, auto-detected when that part is on the cable              | `fpga/litex/`                                |
| **Xilinx VCU118 / LiteX**      | Vivado VU9P, auto-detected when that part is on the cable               | `fpga/litex/`                                |
| **Tang Mega 138K Pro / LiteX** | Gowin LiteX FPGA flow                                                   | `fpga/litex/`                                |
| **Gowin Tang Nano 20K**        | Open-toolchain synth + P&R                                              | `fpga/gowin-tang-nano-20k/`, `make fpga-syn` |
| **OOC partitions**             | Frontend/backend/cache checkpoints, not a board flow                    | `fpga/ooc/README.md`                         |

See [`fpga/litex/README.md`](../fpga/litex/README.md) for the LiteX BIOS + Linux flow.

## ASIC Flow

- **Synthesis**: [Yosys](https://github.com/YosysHQ/yosys) with
  [yosys-slang](https://github.com/povik/yosys-slang) front-end for SystemVerilog.
- **STA**: [yosys-opensta](https://github.com/Kingfish404/yosys-opensta) - open-source
  static timing analysis (`make sta`).
- **PDK**: open-source cell libraries; PPA results published under
  [openppa](https://github.com/Kingfish404/openppa).

See **[REFERENCE.md](./REFERENCE.md)** for the PPA benchmark framework.
Record the source revision, configuration, XLEN, memory model, and constraints
with each timing or area measurement.

## Software Stack

| Layer      | Component                                                    | Notes                                              |
| ---------- | ------------------------------------------------------------ | -------------------------------------------------- |
| App        | CoreMark, MicroBench, Embench-IoT, busybox, demos            | `app/`, `abstract-machine/app/`                    |
| User OS    | nanos-lite (simple OS), Linux v6.18 userspace                | `abstract-machine/app/nanos-lite`                  |
| ABI / libc | riscv-pk (proxy kernel), AM runtime, newlib, glibc           | `app/pk/`, `abstract-machine/`                     |
| Kernel     | Linux v6.18.51 prebuilt by default (`linux/vars.mk`)         | `linux/`, see [linux_kernel.md](./linux_kernel.md) |
| Firmware   | OpenSBI v1.8 (in-tree `third_party/.../opensbi`)             | `linux/opensbi/`                                   |
| Bootrom    | NPC / raptSoC reset vector                                   | `nemu/src/memory/rom/`                             |

## Physical Address Contract

[`hdl/configs/memory_map.json`](../hdl/configs/memory_map.json) records the shared 32-bit physical addresses and the main RAM
capacity of each board or simulator profile. The window starts at `0x80000000`.
KU15P CU07/CU08 with MIG map 2 GiB through `0xffffffff`; RV32 and RV64 use
the same hardware map. RV32 Linux advertises only the lower 1 GiB in its device
tree until high-memory support is validated. KU15P LiteDRAM and AXAU15 MIG
remain at 1 GiB. Other board capacities are listed in the JSON file.

`make memory-map-check` cross-checks the contract against RTL, LiteX, firmware,
NPC and NEMU constants, and that the generated [`app/lib/raptor_platform.h`](../app/lib/raptor_platform.h) is current.
Guest test programs include that header (`RAPTOR_<REGION>_BASE`/`_SIZE`,
`RAPTOR_PTE()`) instead of copying addresses; the verify Makefile adds
`-I app/lib` to every guest compile. The generator and checker live in `verify/scripts/`. After editing the JSON, run
`make memory-map-header`. The FPGA build also validates the selected hardware
and Linux RAM sizes. When changing a region or capacity, update the JSON and
the affected implementation together, then rerun the checker and focused
regressions.

The optional `SIM_MEM_PROFILE=large` NPC profile and matching NEMU
`riscv32_ref_2g_defconfig` / `riscv64_ref_2g_defconfig` map 2 GiB of sparse
RAM. Their default profiles retain the smaller legacy RAM capacity. In the
large profile, `0xa0000000` is RAM, not the separate legacy SDRAM or software
MMIO region. LiteX UART is at `0x11001800`; old high MMIO aliases are absent.

The boundary program in `app/tests/baremetal/pmem_2g_boundaries.S` checks
`0xa0000000`, `0xc0000000`, `0xf0001800`, and the final word and byte of RAM.
Its RV64 path also rejects an address with arbitrary noncanonical upper bits.
Build it for both XLENs with the repository RISC-V toolchain (add `-I app/lib`) and run each image
with `make -C sim run SIM_MEM_PROFILE=large IMG=/absolute/path/to/image.bin`
(add `VFLAGS=-DRAPT_RV64` for RV64). The `run` target selects the matching
NEMU 2 GiB reference for differential checking. The program exits through the
SiFive finisher with `0x5555` on success or `0x3333` on failure; the old UART
address must produce no serial output.

The source contract, SoC generation and simulator regressions cannot prove
that a physical KU15P DDR build meets timing or that every DDR cell works. Board
bring-up must read and write `0xa0000000`, `0xc0000000` and near `0xffffffff`,
check that `0xf0001800` does not activate UART, and exercise the selected
SD/Ethernet hardware. Throughput, CoreMark/MHz, timing and resource results
from matching builds are needed before making a 64-bit Wishbone performance
claim.

## NPC Memory Map

`npc_soc` peripherals and address ranges for the default memory profile:

| Device             | Range                       |
| ------------------ | --------------------------- |
| Finisher           | `0x0010_0000 - 0x0010_0fff` |
| CLINT              | `0x0200_0000 - 0x020b_ffff` |
| PLIC               | `0x0c00_0000 - 0x0cff_ffff` |
| SRAM               | `0x0f00_0000 - 0x0f00_1fff` |
| UART / peripherals | `0x1000_0000 - 0x1001_1fff` |
| MROM               | `0x2000_0000 - 0x2000_ffff` |
| Flash              | `0x3000_0000 - 0x3fff_ffff` |
| PMEM (main memory) | `0x8000_0000 - 0x8fff_ffff` |
| SDRAM              | `0xa000_0000 - 0xa1ff_ffff` |

Reset vector `PC_INIT` = `0x2000_0000` (MROM).

## Random Memory-Delay Simulation

Use `make microbench-rv32 SIM_RANDOM_DELAY=31` or `make coremark-rv64 SIM_RANDOM_DELAY=31` with
`SIM_RANDOM_DELAY=31 SIM_RANDOM_SEED=42` to exercise reproducible AXI memory
wait states. `cpu-tests-rv32` / `cpu-tests-rv64` run AM CPU tests
under the same delay model. These targets use the NPC memory map above.

## Reference Device Trees

### Spike

Source: [`riscv-isa-sim/riscv/platform.h`](https://github.com/riscv-software-src/riscv-isa-sim/blob/master/riscv/platform.h)

```c
#define DEFAULT_RSTVEC     0x00001000
#define DEFAULT_ISA        "rv64imafdc_zicntr_zihpm"
#define DEFAULT_PRIV       "MSU"
#define CLINT_BASE         0x02000000
#define CLINT_SIZE         0x000c0000
#define PLIC_BASE          0x0c000000
#define PLIC_SIZE          0x01000000
#define NS16550_BASE       0x10000000
#define NS16550_SIZE       0x100
#define DRAM_BASE          0x80000000
```

### QEMU (`virt`)

Source: [`hw/riscv/virt.c`](https://github.com/qemu/qemu/blob/master/hw/riscv/virt.c)

```c
[VIRT_CLINT]  = { 0x02000000, 0x00010000 },
[VIRT_PLIC]   = { 0x0c000000, VIRT_PLIC_SIZE(...) },
[VIRT_UART0]  = { 0x10000000, 0x00000100 },
[VIRT_FLASH]  = { 0x20000000, 0x04000000 },
[VIRT_DRAM]   = { 0x80000000, 0x00000000 },
```

## Upstream & Related Projects

- [NJU-ProjectN/NEMU](https://github.com/NJU-ProjectN/nemu) - reference ISS.
- [NJU-ProjectN/abstract-machine](https://github.com/NJU-ProjectN/abstract-machine) - AM runtime.
- [riscv-software-src/opensbi](https://github.com/riscv-software-src/opensbi) - SBI firmware.
- [enjoy-digital/litex](https://github.com/enjoy-digital/litex) - FPGA SoC framework.
- [OpenXiangShan/XiangShan](https://github.com/OpenXiangShan/XiangShan) - inspirational reference.
