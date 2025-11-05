CFLAGS=-march=rv32ima_zicsr_zifencei_zicntr -mabi=ilp32 -nostdlib

init_loop:
	riscv64-linux-gnu-gcc $(CFLAGS) -static -o init init.c $(LDFLAG)

install: init
	cp init ../initramfs
