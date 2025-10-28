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
./setup.sh

# Optional: install espresso if you need
wget https://github.com/chipsalliance/espresso/releases/download/v2.4/arm64-apple-macos11-espresso
```

## Build and Run

```shell
# 0. environment variables at project root directory
source ./env.sh

# 1. build and run NEMU
cd $NEMU_HOME && make riscv32_linux_defconfig && make && make run

# 2. build and run NPC
cd $NSIM_HOME/ssrc && make verilog
cd $NSIM_HOME && make menuconfig && make ARCH=riscv32e-npc run

# 3. build and run the program you want

## n. running nanos-lite on nemu
cd $NAVY_HOME && make ISA=$ISA fsimg
cd $NAVY_HOME/apps/menu && make ISA=$ISA install
cd $YSYX_HOME/nanos-lite && make ARCH=$ISA-nemu update run
cd $YSYX_HOME/nanos-lite && make ARCH=$ISA-nemu run
## n.vme running nanos-lite on nemu with VME
cd $YSYX_HOME/nanos-lite && make ARCH=$ISA-nemu update run FLAGS="-b" VME=1

## n+1. running busybox on nemu (Linux required)
cd $NAVY_HOME/apps/busybox && colima ssh # login to Linux container
make ARCH=riscv32-nemu install

## 2n. running microbench/coremark on npc
cd $YSYX_HOME/am-kernels/benchmarks/coremark && \
    make ARCH=riscv32e-npc run FLAGS="-b -n"
cd $YSYX_HOME/am-kernels/benchmarks/microbench && \
    make ARCH=riscv32e-npc run FLAGS="-b -n"
# FLAGS="-b -n" is optional, -b is for batch mode, -n is for no wave trace

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
