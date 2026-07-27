# Raptor Project

[![Benchmark](https://github.com/Kingfish404/raptor-chip/actions/workflows/benchmark.yaml/badge.svg)](https://github.com/Kingfish404/raptor-chip/actions/workflows/benchmark.yaml)
[![App](https://github.com/Kingfish404/raptor-chip/actions/workflows/app.yaml/badge.svg)](https://github.com/Kingfish404/raptor-chip/actions/workflows/app.yaml)
[![STA](https://github.com/Kingfish404/raptor-chip/actions/workflows/sta.yaml/badge.svg)](https://github.com/Kingfish404/raptor-chip/actions/workflows/sta.yaml)

[![ISA](https://img.shields.io/badge/ISA-RV32%2F64IMAC__Zb*-192f60?longCache=true&style=flat&logo=riscv&logoColor=white&colorA=192f60&colorB=660874)](./docs/uarch.md)
[![marchID](https://img.shields.io/badge/marchID-0x32-660874?longCache=true&style=flat&colorA=192f60&colorB=660874)](https://github.com/riscv/riscv-isa-manual)
[![Privilege](https://img.shields.io/badge/Priv-M%2FS%2FU%20%2B%20Sv32%2FSv39%20%2B%20PMP-660874?longCache=true&style=flat&colorA=192f60&colorB=660874)](./docs/uarch.md)
[![FPGA](https://img.shields.io/badge/FPGA-LiteX-192f60?longCache=true&style=flat&colorA=192f60&colorB=660874)](./fpga/)
[![License](https://img.shields.io/github/license/Kingfish404/raptor-chip?label=License&longCache=true&style=flat&logo=apache&logoColor=white&colorA=192f60&colorB=660874)](./LICENSE)

> It is possible to invent a single machine which can be used to compute any computable sequence. — Alan Turing, 1936

Welcome to the Raptor Project! Here is an all-in-one repository for exploring, developing, optimizing, and verifying a RISC-V core. Aiming at high quality, full Linux support, FPGA implementation, and ASIC readiness.

Core description: **Super-scalar, out-of-order RISC-V core** with register renaming, a 64-entry ROB, 5 execution pipelines fed by per-class issue queues over a unified writeback CDB, TAGE branch prediction, and a unified speculative/committed store queue. The RTL is described by `SystemVerilog` with `Chisel` (`Scala`) used only for decoder generation. Features Sv32 (RV32) / Sv39 (RV64) virtual memory (MMU/TLB/PTW), 16-entry PMP (TOR/NA4/NAPOT), LR/SC + AMO atomics, compressed instructions (RVC), CLINT/PLIC interrupts, a RISC-V Debug Module / JTAG DTM bring-up path, and boots Linux v6.18.x via OpenSBI. Supports configurable **RV32** and **RV64** modes via compile-time switch.

```
Core name:  raptor-falcon (M/S/U + Sv32/Sv39 + PMP, Linux-capable)
ISA:        rv32/rv64 imac_zicbom_zicbop_zicntr_zicond_zicsr_zifencei_zihintntl_zihintpause_zimop_zcb_zcmop_zba_zbb_zbc_zbs
Modes:      Machine, Supervisor, User
MMU:        riscv,sv32 (RV32) / riscv,sv39 (RV64) / riscv,none (Bare)
PMP:        16 entries, TOR / NA4 / NAPOT, L-bit lockable
Interrupts: CLINT (mtime, mtimecmp, msip) + PLIC (31 sources, M/S contexts)
Profile:    n/a (closest peer: RVM23U32 / RVA20S64)

Bus Interface:  AXI4, XLEN-bit data/addr, 4-bit ID, burst
Default uarch: dual issue / dual commit, ROB=64, ALQ=8 (2 issue ports), BRQ=4, MDQ=4, IOQ=8, SQ=16, PRF=128, L1I=4 KiB, L1D=2 KiB, 64 B cache lines, optional L2 passthrough/cache stage

Verifying:  RISCOF (riscv-arch-test), RVFI, SVA
```

See [documentation](./docs/README.md) for more details.

## Microarchitecture

```mermaid
flowchart TD
  subgraph BPU["BPU structure"]
    direction TD
    BTB["BTB (2-way SA, 128 entries)"]
    PHT["PHT (2-bit, 256 entries)"]
    RSB["RSB (4 entries)"]
    TAGE["TAGE (default DIRP)"]
  end
  subgraph FE["Frontend (dual-fetch) · IF0-IF1-ID-RN"]
    BPU["BPU (TAGE/BTB/RSB)"]
    IFU["IFU (dual fetch, 2x16B)"]
    IDU["IDU (dual decode)"]
    RNU["RNU (rename, PHY 128)"]
    FL["Freelist (PHY 128)"]
    MAP["Maptable (ARCH 32/64)"]
  end
  subgraph BE["Backend (dual-issue / dual-commit) · DI-IS/EX-WB-CM"]
    ROU["ROU (UOQ + ROB 64)"]
    RT{{"EXU dispatch router"}}
    PAB["ALQ 8: ALU-CSR | ALU (2 issue ports)"]
    PBR["BRQ 4: Branch"]
    PM["MDQ 4: MUL/DIV"]
    PQ["IOQ 8: mem"]
    CDB(("CDB ×5"))
    PRF["PRF (4R/4W)"]
    CMU["CMU (commit)"]
    CSR
  end
  subgraph MEM["Memory Subsystem"]
    direction TD
    subgraph IMEM["I-side · IF0 (0-bubble seq fetch)"]
      L1I["L1I 4 KiB 2-way (banked SRAM)"]
      ITLB["ITLB (4e, FA)"]
      IPTW["IPTW (Sv32 2-lvl / Sv39 3-lvl)"]
    end
    subgraph DMEM["D-side · IS/EX-WB (2-cyc hit, 3-cyc load-use)"]
      LSU["LSU (unified SQ 16, STL fwd)"]
      L1D["L1D 2 KiB 2-way (banked SRAM, VIPT, write-through)"]
      DTLB["DTLB/DSTLB"]
      DPTW["DPTW (Sv32/Sv39, hw A/D)"]
    end
    PMPC["PMP ×16 (TOR/NA4/NAPOT): fetch + ld/st + PTW checks"]
    BUS["BUS (mem_link arbiter, request IDs, L1D > L1I)"]
    AXIM["AXI4 master (up to 8 reads, independent AW/W)"]
    L2["L2 (optional, 16 KiB DM / passthrough)"]
    RTR["cluster AXI router (1 master / 3 targets)"]
    CLINT["CLINT (mtime / mtimecmp / msip)"]
    PLIC["PLIC (31 sources, M/S contexts)"]
    EXT["off-chip AXI (memory / LiteX SoC)"]
  end
  BPU --- IFU
  IFU --> IDU --> RNU --> FL & MAP
  IDU -."Early Resteer".-> IFU
  IDU --> RNU --> FL & MAP --> ROU --> RT
  RT --> PAB & PBR & PM & PQ
  PAB & PBR & PM & PQ --> CDB
  CDB -->|"writeback + wakeup"| ROU & PRF
  ROU --> CMU
  ROU -."store commit".-> LSU
  CMU -."flush / BPU train".-> FE
  CSR --- PAB
  IFU --- L1I
  L1I --- ITLB
  ITLB -."miss".-> IPTW
  PQ --> LSU --> L1D
  L1D --- DTLB
  DTLB -."miss".-> DPTW
  PMPC -.-> L1I & L1D & IPTW & DPTW
  L1I & L1D & IPTW & DPTW --> BUS
  BUS -->|mem_link| AXIM --> L2 --> RTR
  RTR --> CLINT & PLIC & EXT
```

## Setup & Quick Start

Suggest install `tmux` for better terminal management. [`surfer`][^surfer] for wave viewer. [`colima`][^colima] for Linux container.

[^surfer]: https://surfer-project.org/
[^colima]: https://github.com/abiosoft/colima

```shell
# One-line setup (installs all dependencies)
make setup
# or if just want to setup RTL workspace
make setup-rtl

# Show all available targets
make help
# or pack all SV files into one
make verilog pack

# Setup for IDE/LSP support
make ide-setup
```

### 1. NEMU (Software Emulator)

```shell
# Configure, build and run NEMU (riscv32)
make run-nemu32

# Or step by step
make config-nemu32          # configure (riscv32_defconfig)
make build-nemu32           # build
make run-nemu32             # run

# Interactive menuconfig
make menuconfig-nemu32
```

### 2. Simulation (Verilator)

```shell
# Full pipeline: generate RTL -> configure -> build -> run
make sim-rv32

# Or step by step
make verilog              # Chisel -> SystemVerilog
make config-rv32         # configure (o2_defconfig)
make build-rv32          # build Verilator simulator
make run-rv32            # run simulation

# Run with args
make run-rv32 ARGS="-b -n"    # -b: batch mode [default], -n: no wave trace
make run-rv32 IMG=path/to.bin  # load custom image
# Add reproducible 0..8-cycle delays to each AXI memory beat/response
make run-rv32 ARGS="-b -n --mem-random-delay=8 --mem-random-seed=1"
# Interactive menuconfig
make menuconfig-rv32
```

#### RV64 Mode

The processor supports RV64 via a compile-time switch (`-DRAPT_RV64`). Switching between RV32 and RV64 automatically invalidates the build cache, no manual `make clean` needed.

```shell
# Build and run in RV64 mode (convenience targets)
make build-rv64
make run-rv64 ARGS="-b -n"
# Or explicitly pass VFLAGS
make run-rv32 VFLAGS="-DRAPT_RV64" ARGS="-b -n"
```

### 3. Benchmarks

```shell
# Run riscv32
make coremark-rv32 ARGS="-b -n"
make microbench-rv32 ARGS="-b -n"
# Run with difftest (vs NEMU reference)
make coremark-rv32-difftest ARGS="-b -n"
make microbench-rv32-difftest ARGS="-b -n"
# Run on ysyxSoC
make coremark-ysyxsoc ARGS="-b -n"
make microbench-ysyxsoc ARGS="-b -n"
# Run on NEMU (riscv32-nemu)
make coremark-nemu32 ARGS="-b -n"
make microbench-nemu32 ARGS="-b -n"
```

### 4. Applications running on riscv-pk

```shell
# Build and run hello world on NPC
make app-hello-rv32
# Build and run CoreMark on NPC
make app-coremark-rv32 ARGS="-b -n"
# Build and run Embench-IoT on NPC
make app-embench-rv32 ARGS="-b -n"
# Build riscv-pk (opensbi + pk)
make app-pk-build
# Clean app build artifacts
make app-clean
```

### 5. Linux Kernel Boot

```shell
# Boot Linux on NEMU (requires OpenSBI payload built first)
make linux-boot-nemu32
# Boot Linux on NPC
make linux-boot-rv32
# Boot Linux on NPC with difftest (vs NEMU reference)
make linux-boot-rv32-difftest
# See detailed instructions
# docs/linux_kernel.md, linux/README.md
```

### 6. Verification

```shell
# Random instruction fuzzing with difftest (NPC vs NEMU)
make verify-fuzz
make verify-fuzz-inf      # continuous until Ctrl-C / failure
# Signature-based ISA corner-case tests
make verify-sigtest
# RISCOF classic compliance tests (legacy, no difftest)
make verify-riscof-classic
make verify-riscof-classic-nemu
# Official RISCOF compliance (riscv-arch-test, sail reference)
make verify-riscof
# Verilator line/toggle coverage
make verify-coverage
# Run everything
make verify-all
# See verify/README.md for SVA, formal (RVFI), and ACT4 details
```

### 7. FPGA

```shell
# --- LiteX SoC ---
cd fpga/litex
make setup                          # one-time: install LiteX + register Raptor CPU
make pack                           # pack RTL into single .sv
make sim                            # Verilator sim with LiteX BIOS
make coremark                       # build + run CoreMark in sim
make embench                        # build + run all Embench-IoT benches
make linux                          # build + run Linux payload in sim

# Tang Mega 138K Pro hardware flow
make fpga-build                     # synth + P&R bitstream
make fpga-load                      # load to SRAM (volatile)
make fpga-flash                     # write to external SPI flash
make fpga-console                   # open UART console

# MLK-CU07-KU15P OpenSBI/Linux over MIG DDR and BIOS serialboot
make opensbi-fpga-e2e UART_PORT=/dev/ttyUSB0  # build/load, then standalone OpenSBI
make linux-fpga-e2e UART_PORT=/dev/ttyUSB0    # build/load, then OpenSBI + Linux
make linux-fpga-run UART_PORT=/dev/ttyUSB0    # reuse an existing bitstream
# See fpga/litex/README.md for full target/variant matrix
```

## Build and Run (Manual)

> The following commands are equivalent to the `make` targets above,
> useful if you need finer-grained control.

```shell

# 0. environment variables for direct subdirectory workflows
source ./env.sh

# 1. build and run NEMU
cd $NEMU_HOME && make riscv32_defconfig && make && make run
cd $NEMU_HOME && make riscv32_linux_defconfig && make && make run

# 2. build and run NPC
cd $RAPTOR_HOME/hdl/chisel && make verilog
cd $NSIM_HOME && make o2_defconfig && make && make run
cd $NSIM_HOME && make o2linux_defconfig && make && make run
cd $NSIM_HOME && make menuconfig && make ARCH=riscv32-npc run

# 3. build and run the program you want

## n. running nanos-lite on nemu
cd $NAVY_HOME && make ISA=$ISA fsimg
cd $NAVY_HOME/apps/menu && make ISA=$ISA install
cd $RAPTOR_HOME/abstract-machine/app/nanos-lite && make ARCH=$ISA-nemu update run
cd $RAPTOR_HOME/abstract-machine/app/nanos-lite && make ARCH=$ISA-nemu run
## n.vme running nanos-lite on nemu with VME
cd $RAPTOR_HOME/abstract-machine/app/nanos-lite && make ARCH=$ISA-nemu update run ARGS="-b" VME=1

## n+1. running busybox on nemu (Linux required)
cd $NAVY_HOME/apps/busybox && colima ssh # login to Linux container
make ARCH=riscv32-nemu install

## 2n. running microbench/coremark on npc
cd $RAPTOR_HOME/abstract-machine/app/am-kernels/benchmarks/coremark_eembc && \
    make ARCH=riscv32-npc run ARGS="-b -n"
cd $RAPTOR_HOME/abstract-machine/app/am-kernels/benchmarks/microbench && \
    make ARCH=riscv32-npc run ARGS="-b -n"
# ARGS="-b -n" is optional, -b is for batch mode [default], -n is for no wave trace

## package all sv files into one
cd sim && make pack
```

## Run OpenSBI & Linux Kernel

See [Linux Kernel](./docs/linux_kernel.md)

## Reference

- [Specifications – RISC-V International](https://riscv.org/technical/specifications/)
- [riscv/riscv-isa-manual: RISC-V Instruction Set Manual](https://github.com/riscv/riscv-isa-manual)
- [riscv-software-src/riscv-unified-db: Machine-readable database of the RISC-V specification, and tools to generate various views](https://github.com/riscv-software-src/riscv-unified-db)
- ["一生一芯"](https://rapt.oscc.cc/)
