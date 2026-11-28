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

### Run vector code

The `default`, `default-*`, `large` and RV64 `chip64-rva23` presets enable V 1.0.
Compile a bare-metal vector program for `rv32gcv` / `ilp32d` or
`rv64gcv` / `lp64d` and use the matching NPC target. The whole-core smoke
target builds its own program and memory-fault cases.

```sh
make -C verification/subsystem vector-system-smoke CONFIG=default XLEN=32 \
  BUILD_DIR=/tmp/raptor-vector-rv32
make -C verification/subsystem vector-system-smoke CONFIG=default XLEN=64 \
  BUILD_DIR=/tmp/raptor-vector-rv64
make -C verification/subsystem rva23u64-smoke CONFIG=default
```

To select baseline V on RV64, pass `VFLAGS=-DRAPT_NO_RVA23U64` to
`make run-rv64`. Use `VFLAGS=-DRAPT_NO_VPU` for scalar execution on either XLEN.
See [ISA scope](./README.md#isa-scope) for the preset matrix.

### Verify the RV64 supervisor profile

Build the `default` RV64 NPC and the matching NEMU reference before running
the directed profile suite.

```sh
make build-rv64 RAPT_CONFIG=default
make build-nemu64-ref RAPT_CONFIG=default
make -C verification rva23s64-directed RAPT_CONFIG=default
```

The nine directed cases cover guest execution, translation and interrupts,
Svnapot, Sstc, counter overflow and pointer masking. Each case runs with AXI
delay settings 0, 7 and 63 and seeds 1 and 42.

For architectural compliance tests, `make -C verification riscof ISA=rv64`
selects the `raptor-rva23s64` ACT4 suite by default. It uses Sail 0.16 and the
upstream ACT4 dependencies.
[RVA23S64 ACT4 setup](https://github.com/Kingfish404/raptor-chip/blob/master/verification/riscof/raptor-rva23s64/README.md)

## 4. Benchmarks

```shell
# NPC without differential checking
make coremark-rv32 DIFFTEST=0 ARGS="-b -n"
make microbench-rv32 DIFFTEST=0 ARGS="-b -n"

# NPC with NEMU difftest (default)
make coremark-rv32   ARGS="-b -n"
make microbench-rv32 ARGS="-b -n"
make coremark-rv64   ARGS="-b -n"
make microbench-rv64 ARGS="-b -n"

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
make coremark-nemu64       ARGS="-b -n"
make microbench-nemu64     ARGS="-b -n"
```

For reproducible comparisons, record the source revision, HDL preset, XLEN,
benchmark binary, compiler options, and memory-delay settings with each result.
A valid CoreMark score also requires successful CRCs and a timed interval of at
least 10 seconds.

## 5. Apps on riscv-pk

```shell
make app-hello-rv32                        # hello world
make app-coremark-rv32    ARGS="-b -n"     # CoreMark on pk
make app-embench-rv32     ARGS="-b -n"     # Embench-IoT
make app-hello-rv64                        # RV64 hello world
make app-coremark-rv64    ARGS="-b -n"     # RV64 CoreMark on pk
make app-pk-build                           # build riscv-pk
make app-clean
```

## 6. Linux Kernel

```shell
make linux-boot-nemu32              # NEMU
make linux-boot-rv32               # NPC + difftest vs NEMU (default)
make linux-boot-nemu64gc            # RV64GC Buildroot on NEMU
make linux-boot-rv64gc              # RV64GC Buildroot on NPC
```

See [Linux boot](./linux_kernel.md) for simulator payloads and the FPGA
netboot workflow.

## 7. FPGA

The root FPGA targets select **MLK-CU08-KU15P** by default:

```shell
make fpga-synth
make fpga-build
# Select another board
make fpga-build FPGA_BOARD=rk-xcku5p-f
# Board-local targets and variables
make -C fpga/rk-xcku5p-f help
```

For Linux on KU15P or KU5P, use the Ethernet netboot targets.

```shell
make -C fpga/litex fpga-netboot-rv64-check RAPT_CONFIG=default
```

Follow the [FPGA netboot instructions](./linux_kernel.md#fpga-netboot) for
the build, timing gate, TFTP bundle and board boot. Board and toolchain
options are in the [FPGA guide](https://github.com/Kingfish404/raptor-chip/blob/master/fpga/README.md).

## 8. Utilities

```shell
make pack     # pack all SV into one file
make lint     # Verilator lint (RV32)
make sta MEMORY=sram XLEN=32  # full synthesis + STA; can take hours
make sta-check MEMORY=dff XLEN=64 # RTL elaboration only
make format FORMAT_SCOPE=all  # includes tracked HDL and SV testbenches
make format-check FORMAT_SCOPE=all # no file changes
make regression-plan         # inspect dependency and concurrency settings
make regression              # format, then run independent checks in parallel
make clean    # clean NEMU, selected sim profile, generated RTL, verify and app outputs
```

## Build options

| Option | Purpose |
| --- | --- |
| `ARGS`, `IMG` | Runtime flags and custom binary |
| `RAPT_CONFIG` | RTL preset, e.g. `default`, `default-w4`, `default-l2`, `middle-cache` |
| `BUILD_ROOT`, `BUILD_PROFILE` | Isolate simulator outputs and configuration variants |
| `VFLAGS` | Extra RTL defines; RV64 targets add `-DRAPT_RV64` automatically |
| `DIFFTEST=0` / `1` | Disable / enable the NEMU differential reference |
| `BENCH_OPT=baseline` / `optimized` | Benchmark compiler preset |
| `SIM_RANDOM_DELAY`, `SIM_RANDOM_SEED` | Reproducible memory wait states |
| `FPGA_BOARD` | FPGA board selection |
| `MEMORY=sram` / `dff`, `XLEN=32` / `64` | STA memory model and word width |

For direct shell workflows, run `source env.sh`. See the
[simulator guide](https://github.com/Kingfish404/raptor-chip/blob/master/sim/README.md)
for configuration caches and lower-level commands.

RV64 defaults to 32 physical address bits. To exercise the supported 38-bit
capacity, select `RAPT_CONFIG=default-pa38` or explicitly set
`VFLAGS=-DRAPT_PADDR_BITS=38` in an isolated profile. The PMA region map remains
32-bit; a wider cache/PMP address does not add RAM or devices.
