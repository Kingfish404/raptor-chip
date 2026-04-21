# Quick Start

Build and simulate Raptor in a few commands. Run everything from the
**project root** — `source env.sh` is not required, the Makefile exports
all variables.

## Prerequisites

- Linux (Ubuntu 22.04+) or macOS. On macOS some targets require a Linux container
  (e.g. [`colima`](https://github.com/abiosoft/colima)).
- `git`, `make`, a C/C++ toolchain, Python 3, a RISC-V GCC toolchain.
- Optional but recommended:
  - [`verilator`](https://verilator.org/) — RTL simulator (installed by `make setup`).
  - [`surfer`](https://surfer-project.org/) — waveform viewer.
  - [`tmux`](https://github.com/tmux/tmux) — nicer terminal multiplexing.

## 1. Install Dependencies

```shell
git clone https://github.com/Kingfish404/raptor-chip
cd raptor-chip

# One-line setup (installs all dependencies)
make setup

# Show all available targets
make help
```

## 2. Run NEMU (Software ISS)

```shell
make run-nemu32                 # configure + build + run, RV32
```

Or step by step:

```shell
make config-nemu32              # riscv32_defconfig
make build-nemu32
make run-nemu32
make menuconfig-nemu32          # interactive Kconfig
```

## 3. Run NPC (Verilator Simulation)

```shell
# Full pipeline: Chisel -> SystemVerilog -> configure -> build -> run
make sim-npc32

# Or step by step
make verilog                    # Chisel -> SystemVerilog
make config-npc32               # o2_defconfig
make build-npc32
make run-npc32

# Common runtime flags
make run-npc32 ARGS="-b -n"     # -b batch mode (default) · -n no wave trace
make run-npc32 IMG=path/to.bin  # load a custom image
make menuconfig-npc32           # interactive Kconfig
```

### RV64 Mode

The core supports RV64 via the compile-time switch `-DRAPT_RV64`. Switching between
RV32 and RV64 automatically invalidates the build cache — no manual `make clean` needed.

```shell
make build-npc64
make run-npc64   ARGS="-b -n"
make lint-npc64
# or pass VFLAGS explicitly
make run-npc32 VFLAGS="-DRAPT_RV64" ARGS="-b -n"
```

## 4. Benchmarks

```shell
# NPC standalone
make coremark-npc32        ARGS="-b -n"
make microbench-npc32      ARGS="-b -n"

# NPC with difftest (vs NEMU reference model)
make coremark-npc32-difftest     ARGS="-b -n"
make microbench-npc32-difftest   ARGS="-b -n"

# raptSoC
make coremark-ysyxsoc      ARGS="-b -n"
make microbench-ysyxsoc    ARGS="-b -n"

# NEMU
make coremark-nemu32       ARGS="-b -n"
make microbench-nemu32     ARGS="-b -n"
```

Detailed results: **[PROFILE](./PROFILE.md)**.

## 5. Apps on riscv-pk

```shell
make app-hello-npc32                        # hello world
make app-coremark-npc32    ARGS="-b -n"     # CoreMark on pk
make app-embench-npc32     ARGS="-b -n"     # Embench-IoT
make app-pk-build                           # build OpenSBI + pk
make app-clean
```

## 6. Linux Kernel

```shell
make linux-boot-nemu32              # NEMU
make linux-boot-npc32               # NPC (Verilator)
make linux-boot-npc32-difftest      # NPC + difftest vs NEMU
```

Details: **[Linux Kernel Boot](./linux_kernel.md)**.

## 7. FPGA

```shell
make fpga-syn                       # synth (Gowin Tang Nano 20K)
make fpga-pnr                       # place & route
# See fpga/gowin-tang-nano-20k/README.md and fpga/litex/README.md
```

## 8. Utilities

```shell
make pack     # pack all SV into one file
make lint     # Verilator lint (RV32)
make sta      # static timing analysis (yosys-opensta)
make clean    # clean all build artifacts
```

## Command Reference

| Task                            | Command                                |
| ------------------------------- | -------------------------------------- |
| Show all targets                | `make help`                            |
| Setup environment               | `make setup`                           |
| Generate RTL                    | `make verilog`                         |
| Build & run NEMU                | `make run-nemu32`                      |
| Full NPC simulation             | `make sim-npc32`                       |
| NPC simulation (batch, no wave) | `make run-npc32 ARGS="-b -n"`          |
| NPC RV64 mode                   | `make run-npc64 ARGS="-b -n"`          |
| CPU tests on NPC                | `make cpu-tests-npc32 ARGS="-b -n"`    |
| Run CoreMark on NPC             | `make coremark-npc32 ARGS="-b -n"`     |
| Run MicroBench on NPC           | `make microbench-npc32 ARGS="-b -n"`   |
| Run nanos-lite on NEMU          | `make nanos-nemu32`                    |
| Boot Linux on NEMU              | `make linux-boot-nemu32`               |
| Boot Linux on NPC w/ difftest   | `make linux-boot-npc32-difftest`       |
| FPGA synthesis                  | `make fpga-syn`                        |
| Pack SV / Lint / STA            | `make pack` / `make lint` / `make sta` |
| Clean all                       | `make clean`                           |

Key overridable variables: `ARGS` (runtime), `VFLAGS` (RTL defines), `IMG` (custom binary),
`MAINARGS` (benchmark mode).

## Manual Workflow

The same actions using the environment directly:

```shell
source ./env.sh

# 1. NEMU
cd $NEMU_HOME && make riscv32_defconfig && make && make run

# 2. NPC
cd $RAPTOR_HOME/rtl_scala && make verilog
cd $NSIM_HOME && make o2_defconfig && make && make run

# 3. nanos-lite on NEMU (with VME)
cd $RAPTOR_HOME/abstract-machine/app/nanos-lite \
  && make ARCH=$ISA-nemu update run ARGS="-b" VME=1
```
