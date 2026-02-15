# Raptor Project

[![build & eval](https://github.com/Kingfish404/raptor-chip/actions/workflows/build.yaml/badge.svg)](https://github.com/Kingfish404/raptor-chip/actions/workflows/build.yaml)
[![Ubuntu](https://img.shields.io/badge/Ubuntu-E95420?style=flat&logo=ubuntu&logoColor=white)](https://en.wikipedia.org/wiki/Ubuntu)
[![macOS](https://img.shields.io/badge/macOS-000000?style=flat&logo=apple&logoColor=white)](https://en.wikipedia.org/wiki/MacOS)
[![Github](https://img.shields.io/badge/GitHub-181717?style=flat&logo=github&logoColor=white)](https://github.dev/Kingfish404/raptor-chip)

**New Processor Core (NPC)** with [`RISC-V`][RISC-V] ISA. Hardware generation is done using `SystemVerilog` and `Chisel` (`Scala`).

Candidate ip core name: `raptor-0.1.0-falcon` (`rt-f`).

[RISC-V]: https://riscv.org/

## Microarchitecture

![](./docs/assets/npc-rv32.svg)

**[Core Documentation](./docs/README.md)**

## Build Setup

Suggest install `tmux` for better terminal management. [`surfer`][^surfer] for wave viewer. [`colima`][^colima] for Linux container.

[^surfer]: https://surfer-project.org/
[^colima]: https://github.com/abiosoft/colima

```shell
# One-line setup (installs all dependencies)
make setup

# Optional: install espresso if you need
wget https://github.com/chipsalliance/espresso/releases/download/v2.4/arm64-apple-macos11-espresso
```

## Quick Start

All commands run from the project root. (No need to `source env.sh` — the Makefile exports all environment variables automatically.)

```shell
# Show all available targets
make help
```

### 1. NEMU (Software Emulator)

```shell
# Configure, build and run NEMU (riscv32)
make nemu-run

# Or step by step
make nemu-config          # configure (riscv32_defconfig)
make nemu-build           # build
make nemu-run             # run

# Interactive menuconfig
make nemu-menuconfig
```

### 2. NPC Simulation (Verilator)

```shell
# Full pipeline: generate RTL → configure → build → run
make npc-sim

# Or step by step
make verilog              # Chisel → SystemVerilog
make npc-config           # configure (o2_defconfig)
make npc-build            # build Verilator simulator
make npc-run              # run simulation


# Run with args
make npc-run ARGS="-b -n"    # -b: batch mode [default], -n: no wave trace
make npc-run IMG=path/to.bin  # load custom image

# Interactive menuconfig
make npc-menuconfig
```

### 3. Benchmarks

```shell
# Run on NPC (riscv32e-npc)
make coremark ARGS="-b -n"
make microbench ARGS="-b -n"

# Run on NEMU (riscv32-nemu)
make coremark-nemu ARGS="-b -n"
make microbench-nemu ARGS="-b -n"
```

### 4. Nanos-lite OS

```shell
# Run nanos-lite on NEMU
make nanos-nemu

# Run nanos-lite on NPC
make nanos-npc
```

### 5. Linux Kernel

```shell
# Boot Linux on NEMU (requires OpenSBI payload built first)
make linux-boot

# See detailed instructions
# docs/linux_kernel.md, linux/README.md
```

### 6. FPGA

```shell
# Synthesize for Gowin Tang Nano 20K
make fpga-syn

# Place and route
make fpga-pnr

# See fpga/gowin-tang-nano-20k/README.md for details
```

### 7. Utilities

```shell
# Pack all SV into one file
make pack

# Lint RTL
make lint

# Static timing analysis
make sta

# Clean all build artifacts
make clean
```

## Build and Run (Manual)

> The following commands are equivalent to the `make` targets above,
> useful if you need finer-grained control.

```shell

# 0. environment variables at project root directory
source ./env.sh

# 1. build and run NEMU
cd $NEMU_HOME && make riscv32_defconfig && make && make run
cd $NEMU_HOME && make riscv32_linux_defconfig && make && make run

# 2. build and run NPC
cd $YSYX_HOME/rtl_scala && make verilog
cd $NSIM_HOME && make o2_defconfig && make && make run
cd $NSIM_HOME && make o2linux_defconfig && make && make run
cd $NSIM_HOME && make menuconfig && make ARCH=riscv32e-npc run

# 3. build and run the program you want

## n. running nanos-lite on nemu
cd $NAVY_HOME && make ISA=$ISA fsimg
cd $NAVY_HOME/apps/menu && make ISA=$ISA install
cd $YSYX_HOME/nanos-lite && make ARCH=$ISA-nemu update run
cd $YSYX_HOME/nanos-lite && make ARCH=$ISA-nemu run
## n.vme running nanos-lite on nemu with VME
cd $YSYX_HOME/nanos-lite && make ARCH=$ISA-nemu update run ARGS="-b" VME=1

## n+1. running busybox on nemu (Linux required)
cd $NAVY_HOME/apps/busybox && colima ssh # login to Linux container
make ARCH=riscv32-nemu install

## 2n. running microbench/coremark on npc
cd $YSYX_HOME/am-kernels/benchmarks/coremark_eembc && \
    make ARCH=riscv32e-npc run ARGS="-b -n"
cd $YSYX_HOME/am-kernels/benchmarks/microbench && \
    make ARCH=riscv32e-npc run ARGS="-b -n"
# ARGS="-b -n" is optional, -b is for batch mode [default], -n is for no wave trace

## fpga. running on gowin-tang-nano-20k
### follow `fpga/gowin-tang-nano-20k/README.md`

## package all sv files into one
cd nsim && make pack
```

## Run OpenSBI & Linux Kernel

See [Linux Kernel](./docs/linux_kernel.md)

## Reference

- [Specifications – RISC-V International](https://riscv.org/technical/specifications/)
- [riscv/riscv-isa-manual: RISC-V Instruction Set Manual](https://github.com/riscv/riscv-isa-manual)
- [riscv-software-src/riscv-unified-db: Machine-readable database of the RISC-V specification, and tools to generate various views](https://github.com/riscv-software-src/riscv-unified-db)
- ["一生一芯"](https://ysyx.oscc.cc/)
