#!/bin/sh
#
# installing toolchain:
#   RISC-V GNU Compiler Toolchain
#   https://github.com/riscv-collab/riscv-gnu-toolchain
#   ./configure --prefix=~/riscv/install --with-arch=rv32i --with-abi=ilp32
#
#   Compiling Freestanding RISC-V Programs
#   https://www.youtube.com/watch?v=ODn7vnWOptM
#
#   RISC-V Assembly Language Programming: A.1 The GNU Toolchain
#   https://github.com/johnwinans/rvalp/releases/download/v0.14/rvalp.pdf
#
# for macOS:
#   homebrew (macOS) packages for RISC-V toolchain
#   https://github.com/riscv-software-src/homebrew-riscv
# 	brew tap riscv-software-src/riscv
#   brew install riscv-tools
set -e

BIN=os

riscv64-unknown-elf-gcc \
	-O0 \
	-g \
	-nostartfiles \
	-ffreestanding \
	-nostdlib \
	-fno-toplevel-reorder \
	-fno-pic \
	-march=rv32e_zicsr_zifencei \
	-mabi=ilp32e \
	-mstrict-align \
	-Wfatal-errors \
	-Wall -Wextra -pedantic \
	-Wconversion \
	-Wshadow \
	-Wl,-Ttext=0x0 \
	-Wl,--no-relax \
	start.s os.c -o $BIN

riscv64-unknown-elf-objcopy $BIN -O binary $BIN.bin

chmod -x $BIN.bin

#riscv64-unknown-elf-objdump -Mnumeric,no-aliases --source-comment -Sr $BIN > $BIN.s
riscv64-unknown-elf-objdump -D --source-comment -Sr $BIN > $BIN.s

# print 4 bytes at a time as hex in little endian mode
xxd -c 4 -e $BIN.bin | awk '{print $2}' > $BIN.mem

rm $BIN

ls -l $BIN.bin $BIN.s $BIN.mem
