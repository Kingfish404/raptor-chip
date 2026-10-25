# Small RV64 Sv39 demand-paging benchmark; shares the existing bare-metal runtime.
OUT ?= $(CURDIR)/build
CROSS_COMPILE ?= riscv64-elf-
CC := $(CROSS_COMPILE)gcc
OBJCOPY := $(CROSS_COMPILE)objcopy
CFLAGS := -march=rv64imafdc_zicsr_zifencei -mabi=lp64d -mcmodel=medany -O2 \
          -ffreestanding -fno-builtin -fno-stack-protector -fno-common \
          -fno-asynchronous-unwind-tables -msmall-data-limit=0 -Wall -Wextra
LINKER := ../embench/support/link.ld

.PHONY: all
all: $(OUT)/pagefault-riscv64-npc.bin

$(OUT)/pagefault-riscv64-npc.elf: main.S runtime.c $(LINKER) ../../lib/runtime/runtime.c
	mkdir -p $(OUT)
	$(CC) $(CFLAGS) -nostdlib -nostartfiles -static -Wl,--no-relax \
	  -T$(LINKER) main.S runtime.c -lgcc -o $@

$(OUT)/pagefault-riscv64-npc.bin: $(OUT)/pagefault-riscv64-npc.elf
	$(OBJCOPY) -O binary $< $@
