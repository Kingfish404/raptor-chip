---
title: Quick Start
---

# Quick Start

Build and simulate Raptor in a few commands. Run everything from the
**project root** - `source env.sh` is not required, the Makefile exports
all variables.

## Prerequisites

- Linux (Ubuntu 22.04+) or macOS. On macOS some targets require a Linux container
  (e.g. [`colima`](https://github.com/abiosoft/colima)).
- `git`, `make`, a C/C++ toolchain, Python 3, a RISC-V GCC toolchain.
- [`verilator`](https://verilator.org/), RTL simulator (installed by `make setup`).

## 1. Install Dependencies

```shell
git clone https://github.com/Kingfish404/raptor-chip
cd raptor-chip

# Install the common development toolchain (FPGA/PDK setup is separate)
make setup-rtl

# Show all available targets
make help
```

## 2. Run NEMU (Software ISS)

```shell
make run-nemu32                 # configure + build + run, RV32
```

## 3. Run NPC (Verilator Simulation)

```shell
# Full pipeline: Chisel -> SystemVerilog -> configure -> build -> run
make run-rv32

# Or step by step
make verilog                    # Chisel -> SystemVerilog
make configure-rv32            # configure only (difftest enabled by default)
make build-rv32
make run-rv32

# Common runtime flags
make run-rv32 ARGS="-b -n"     # -b batch mode (default) | -n no wave trace
make run-rv32 IMG=path/to.bin  # load a custom image
make menuconfig-rv32           # interactive Kconfig
```

### RV64 Mode

The core supports RV64 via the compile-time switch `-DRAPT_RV64`. Switching between
RV32 and RV64 selects separate configuration and model caches - no manual `make clean` needed.

```shell
make build-rv64
make run-rv64   ARGS="-b -n"
make lint-rv64
# or pass VFLAGS explicitly
make run-rv32 VFLAGS="-DRAPT_RV64" ARGS="-b -n"
```

## 4. Benchmarks

```shell
# NPC without differential checking
make coremark-rv32 DIFFTEST=0 ARGS="-b -n"
make microbench-rv32 DIFFTEST=0 ARGS="-b -n"

# NPC with difftest (default; vs NEMU reference model)
make coremark-rv32 DIFFTEST=1     ARGS="-b -n"
make microbench-rv32 DIFFTEST=1   ARGS="-b -n"

# Optional compiler preset (baseline is the default)
make coremark-rv64 BENCH_OPT=optimized

# Reproducible random memory-delay simulation (also supports -rv64)
make coremark-rv32 SIM_RANDOM_DELAY=31 SIM_RANDOM_SEED=1
make microbench-rv32 SIM_RANDOM_DELAY=31 SIM_RANDOM_SEED=42
make cpu-tests-rv64 SIM_RANDOM_DELAY=31 SIM_RANDOM_SEED=1

# ysyxSoC (RV32)
make coremark-ysyxsoc      ARGS="-b -n"
make microbench-ysyxsoc    ARGS="-b -n"

# NEMU
make coremark-nemu32       ARGS="-b -n"
make microbench-nemu32     ARGS="-b -n"
```

For reproducible comparisons, record the source revision, HDL preset, XLEN,
benchmark binary, compiler options, and memory-delay settings with each result.

## 5. Apps on riscv-pk

```shell
make app-hello-rv32                        # hello world
make app-coremark-rv32    ARGS="-b -n"     # CoreMark on pk
make app-embench-rv32     ARGS="-b -n"     # Embench-IoT
make app-pk-build                           # build riscv-pk
make app-clean
```

## 6. Linux Kernel

```shell
make linux-boot-nemu32              # NEMU
make linux-boot-rv32               # NPC + difftest vs NEMU (default)
```

Details: **[Linux Kernel Boot](./linux_kernel.md)**.

## 7. FPGA

The root FPGA targets select native **MLK-CU08-KU15P** by default:

```shell
make fpga-synth
make fpga-build
# Select another native board explicitly
make fpga-build FPGA_BOARD=rk-xcku5p-f
# Board-local targets and variables
make -C fpga/rk-xcku5p-f help
```

For LiteX BIOS/Linux flows:

```shell
make -C fpga/litex help
make -C fpga/litex fpga-detect
```

See [native FPGA support](https://github.com/Kingfish404/raptor-chip/blob/master/fpga/README.md) and
[LiteX board setup](https://github.com/Kingfish404/raptor-chip/blob/master/fpga/litex/README.md) for toolchains and constraints.
Synthesis does not establish routed timing closure or a working board image.

## 8. Utilities

```shell
make pack     # pack all SV into one file
make lint     # Verilator lint (RV32)
make sta MEMORY=sram XLEN=32  # full synthesis + STA; can take hours
make sta-check MEMORY=dff XLEN=64 # RTL elaboration only
make format FORMAT_SCOPE=all  # includes tracked HDL and SV testbenches
make format-check FORMAT_SCOPE=all # no file changes
make regression-plan         # preview CoreMark/STA/FPGA regression commands
make clean    # clean NEMU, selected sim profile, generated RTL, verify and app outputs
```

## Build options

| Option | Purpose |
| --- | --- |
| `ARGS`, `IMG` | Runtime flags and custom binary |
| `DIFFTEST=0` / `1` | Disable / enable the NEMU differential reference |
| `BENCH_OPT=baseline` / `optimized` | Benchmark compiler preset |
| `SIM_RANDOM_DELAY`, `SIM_RANDOM_SEED` | Reproducible memory wait states |
| `FPGA_BOARD` | Native FPGA board selection |
| `MEMORY=sram` / `dff`, `XLEN=32` / `64` | STA memory model and word width |

For direct shell workflows, run `source env.sh`. See the
[simulator guide](https://github.com/Kingfish404/raptor-chip/blob/master/sim/README.md)
for configuration caches and lower-level commands.
