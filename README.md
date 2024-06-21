# "一生一芯"工程项目

这是"一生一芯"的工程项目. 通过运行
```bash
bash init.sh subproject-name
```
进行初始化, 具体请参考[实验讲义][lecture note].

[lecture note]: https://ysyx.oscc.cc/docs/

设计的处理器暂称为 **New Processor Core (NPC)** , 采用了`RISC-V`指令集架构, 使用`Verilog`语言进行描述.

## Preparation

```shell
# macOS
brew install verilator sdl2 sdl2_image sdl2_ttf flex

# debian/ubuntu
apt-get install verilator libsdl2-dev flex
apt-get install gcc-riscv64-linux-gnu

# clone mono repository
git clone https://github.com/Kingfish404/ysyxSoC
git clone https://github.com/NJU-ProjectN/nvboard
```

## Architecture

![](./npc/assets/npc-rv32e-ysyxsoc.svg)

## Prepare

```shell
# debian/ubuntu
sudo apt-get install libreadline-dev 
sudo apt-get install libsdl2-dev libsdl2-image-dev libsdl2-ttf-dev
sudo apt-get install llvm

# macOS
brew install readline
brew install sdl2 sdl2_image sdl2_ttf
brew install llvm
```
