# Ecosystem

Simulators, FPGA boards, ASIC flow, software stack, and memory maps.

## Supported Targets

| Target      | Purpose                           | Entry                                                         |
| ----------- | --------------------------------- | ------------------------------------------------------------- |
| NEMU        | Software ISS (difftest reference) | `nemu/README.md`                                              |
| NPC         | Verilator simulator               | `sim/`                                                        |
| FPGA        | Gowin boards and LiteX KU15P      | `fpga/gowin-tang-nano-20k/README.md`, `fpga/litex/README.md`  |
| ASIC (open) | Yosys + OpenSTA flow              | [yosys-opensta](https://github.com/Kingfish404/yosys-opensta) |

## Simulators

| Simulator   | Role                                     | Entry                      |
| ----------- | ---------------------------------------- | -------------------------- |
| **NEMU**    | Software ISS, reference model            | `make run-nemu32`, `nemu/` |
| **NPC**     | Verilator, cycle-accurate, waveform      | `make sim-rv32`, `sim/`    |
| **raptSoC** | SystemVerilog NPC top + AXI memory model | `sim/rtl/rapt_npc_soc.sv`  |

NPC is the primary development simulator. NEMU acts as the difftest reference for every commit.

## FPGA Targets

| Board / Flow                   | Status                                          | Entry                                        |
| ------------------------------ | ----------------------------------------------- | -------------------------------------------- |
| **Gowin Tang Nano 20K**        | Supported (synth + P&R)                         | `fpga/gowin-tang-nano-20k/`, `make fpga-syn` |
| **Tang Mega 138K Pro / LiteX** | Supported Gowin LiteX FPGA flow                 | `fpga/litex/`                                |
| **MLK-CU07-KU15P / LiteX**     | Vivado, BIOS, MIG DDR4, SDCard, RV32 Linux boot | `fpga/litex/`                                |

See [`fpga/litex/README.md`](../fpga/litex/README.md) for the LiteX BIOS + Linux flow.

## ASIC Flow

- **Synthesis**: [Yosys](https://github.com/YosysHQ/yosys) with
  [yosys-slang](https://github.com/povik/yosys-slang) front-end for SystemVerilog.
- **STA**: [yosys-opensta](https://github.com/Kingfish404/yosys-opensta) — open-source
  static timing analysis (`make sta`).
- **PDK**: open-source cell libraries; PPA results published under
  [openppa](https://github.com/Kingfish404/openppa).

See **[PROFILE.md](./PROFILE.md)** for archived Freq / Power / Area results,
[Performance Iterations](./perf-iterations.md) for recorded configuration-specific
measurements, and
**[REFERENCE.md](./REFERENCE.md)** for the PPA benchmark framework.

## Software Stack

| Layer      | Component                                                    | Notes                                              |
| ---------- | ------------------------------------------------------------ | -------------------------------------------------- |
| App        | CoreMark, MicroBench, Embench-IoT, busybox, demos            | `app/`, `abstract-machine/app/`                    |
| User OS    | nanos-lite (simple OS), Linux v6.18 userspace                | `abstract-machine/app/nanos-lite`                  |
| ABI / libc | riscv-pk (proxy kernel), AM runtime, newlib, glibc           | `app/pk/`, `abstract-machine/`                     |
| Kernel     | Linux v6.18.22 prebuilt by default; v6.12/v6.18 paths tested | `linux/`, see [linux_kernel.md](./linux_kernel.md) |
| Firmware   | OpenSBI (v1.8.1)                                             | `linux/opensbi/`                                   |
| Bootrom    | NPC / raptSoC reset vector                                   | `nemu/src/memory/rom/`                             |

## NPC Memory Map

`npc_soc` peripherals and address ranges:

| Device             | Range                       |
| ------------------ | --------------------------- |
| Finisher           | `0x0010_0000 – 0x0010_0fff` |
| CLINT              | `0x0200_0000 – 0x020b_ffff` |
| PLIC               | `0x0c00_0000 – 0x0cff_ffff` |
| UART / peripherals | `0x1000_0000 – 0x1001_1fff` |
| MROM               | `0x2000_0000 – 0x2000_ffff` |
| Flash              | `0x3000_0000 – 0x3fff_ffff` |
| PMEM / PSRAM       | `0x8000_0000 – 0x8fff_ffff` |

Reset vector `PC_INIT` = `0x2000_0000` (MROM).

## Random Memory-Delay Simulation

Use `make microbench-random-rv32` or `make coremark-random-rv64` with
`SIM_RANDOM_DELAY=31 SIM_RANDOM_SEED=42` to exercise reproducible AXI memory
wait states. `cpu-tests-random-rv32` / `cpu-tests-random-rv64` run AM CPU tests
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

- [NJU-ProjectN/NEMU](https://github.com/NJU-ProjectN/nemu) — reference ISS.
- [NJU-ProjectN/abstract-machine](https://github.com/NJU-ProjectN/abstract-machine) — AM runtime.
- [riscv-software-src/opensbi](https://github.com/riscv-software-src/opensbi) — SBI firmware.
- [enjoy-digital/litex](https://github.com/enjoy-digital/litex) — FPGA SoC framework.
- [OpenXiangShan/XiangShan](https://github.com/OpenXiangShan/XiangShan) — inspirational reference.
