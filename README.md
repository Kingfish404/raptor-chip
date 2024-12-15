# "一生一芯"工程项目

这是"一生一芯"的工程项目. 通过运行
```bash
bash init.sh subproject-name
```
进行初始化, 具体请参考[实验讲义][lecture note].

[lecture note]: https://ysyx.oscc.cc/docs/

设计的处理器暂称为 **New Processor Core (NPC)** , 采用[`RISC-V`][RISC-V]指令集架构, 使用`SystemVerilog`和`Chisel`进行描述.

[RISC-V]: https://riscv.org/

## Preparation

```shell
# macOS or Linux(debian/ubuntu/fedora)
# install brew https://brew.sh/
brew install verilator sdl2 sdl2_image sdl2_ttf flex
brew tap riscv-software-src/riscv
brew install riscv-tools
brew install readline ncurses llvm yosys
# devlopment tools
brew install surfer # Waveform viewer, supporting VCD, FST, or GHW format

# debian/ubuntu
apt-get install verilator libsdl2-dev libsdl2-image-dev libsdl2-ttf-dev flex
apt-get install gcc-riscv64-linux-gnu
sudo apt-get install libreadline-dev flock
sudo apt-get install llvm

# clone mono repository
git clone https://github.com/kingfish404/am-kernels
git clone https://github.com/NJU-ProjectN/nvboard
git clone https://github.com/Kingfish404/ysyxSoC
cd ysyxSoC && make dev-init

# install mill and espresso
cd ./npc/ssrc
wget https://github.com/com-lihaoyi/mill/releases/download/0.11.13/0.11.13 -O mill
chmod +x mill
# install espresso
wget https://github.com/chipsalliance/espresso/releases/download/v2.4/arm64-apple-macos11-espresso
# generated from chisel (scala) at `npc/ssrc`
make verilog
```

## Environment Variables

```shell 
export YSYX_HOME=[path to ysyx-workbench]

export NEMU_HOME=$YSYX_HOME/nemu

export AM_HOME=$YSYX_HOME/abstract-machine
export NPC_HOME=$YSYX_HOME/npc
export NVBOARD_HOME=$YSYX_HOME/nvboard
export NAVY_HOME=$YSYX_HOME/navy-apps

export ISA=riscv32e
export CROSS_COMPILE=riscv64-unknown-elf-
```

## Build and Run

```shell
# 1. build and run NEMU
cd $NEMU_HOME && make menuconfig && make && make run

# 2. build and run NPC
cd $NPC_HOME/ssrc && make verilog
cd $NPC_HOME && make menuconfig && make ARCH=riscv32e-npc run

# 3. build and run the program you want

## n. running nanos-lite on nemu
cd $NAVY_HOME && make ISA=$ISA fsimg
cd $NAVY_HOME/apps/nterm && make ISA=$ISA install
cd $NAVY_HOME/apps/pal && make ISA=$ISA install
cd $YSYX_HOME/nanos-lite && make ARCH=$ISA-nemu update run
cd $YSYX_HOME/nanos-lite && make ARCH=$ISA-nemu run

## fpga. running on gowin-tang-nano-20k
./npc/ana-fpga-cat.sh
# then follow `fpga/gowin-tang-nano-20k/README.md`
```

## Architecture

![](./docs/assets/npc-rv32e-pipeline.svg)

## Reference

- [Specifications – RISC-V International](https://riscv.org/technical/specifications/)
- [riscv/riscv-isa-manual: RISC-V Instruction Set Manual](https://github.com/riscv/riscv-isa-manual)
- [riscv-software-src/riscv-unified-db: Machine-readable database of the RISC-V specification, and tools to generate various views](https://github.com/riscv-software-src/riscv-unified-db)
