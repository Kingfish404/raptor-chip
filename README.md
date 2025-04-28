# "一生一芯"工程项目

设计的处理器暂称为 **New Processor Core (NPC)** , 采用[`RISC-V`][RISC-V]指令集架构, 使用`SystemVerilog`和`Chisel`进行描述.

Candidate ip core name: `bird-0.1.0-sparrow`.

**[Core Documentation](./docs/README.md)**

> "一生一芯"参考[实验讲义][^lecture note].

[^lecture note]: https://ysyx.oscc.cc/docs/
[RISC-V]: https://riscv.org/

## Microarchitecture

![](./docs/assets/npc-rv32im-o3-pipeline.svg)

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
source ./environment.env

# 1. build and run NEMU
cd $NEMU_HOME && make riscv32_linux_defconfig && make && make run

# 2. build and run NPC
cd $NPC_HOME/ssrc && make verilog
cd $NPC_HOME && make menuconfig && make ARCH=riscv32e-npc run

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
./npc/ana-fpga-cat.sh
# then follow `fpga/gowin-tang-nano-20k/README.md`

## package all sv files into one
cd npc && make build_packed
```

## Run opensbi & Kernel

See [Linux Kernel](./docs/linux_kernel.md)

## Reference

- [Specifications – RISC-V International](https://riscv.org/technical/specifications/)
- [riscv/riscv-isa-manual: RISC-V Instruction Set Manual](https://github.com/riscv/riscv-isa-manual)
- [riscv-software-src/riscv-unified-db: Machine-readable database of the RISC-V specification, and tools to generate various views](https://github.com/riscv-software-src/riscv-unified-db)
