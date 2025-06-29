AM_SRCS := riscv/ysyxsoc/start.c \
           riscv/ysyxsoc/trm.c \
		   riscv/ysyxsoc/ioe.c \
           riscv/ysyxsoc/input.c \
		   riscv/ysyxsoc/gpu.c \
		   riscv/ysyxsoc/cte.c \
		   riscv/ysyxsoc/timer.c \
           riscv/ysyxsoc/trap.S \
           platform/dummy/vme.c \
           platform/dummy/mpe.c

CFLAGS    += -fdata-sections -ffunction-sections
LDFLAGS   = -T $(AM_HOME)/scripts/linker.ysyxsoc.ld \
						 --defsym=_pmem_start=0x80000000 \
						 --defsym=_entry_offset=0x0 \
						 --defsym=_stack_pointer=0x0f002000 \
						 --defsym=_heap_start=0x80200000 \
						#  --defsym=_stack_pointer=0x80200000 \
						#  --defsym=_heap_start=0x80200000 \
						#  --defsym=_stack_pointer=0x0f002000 \
						#  --defsym=_heap_start=0x0f000000 \
						#  --print-map
LDFLAGS   += --gc-sections -e _start
CFLAGS += -DMAINARGS=\"$(mainargs)\"
CFLAGS += -Os -I$(AM_HOME)/am/src/riscv/ysyxsoc/include
.PHONY: $(AM_HOME)/am/src/riscv/ysyxsoc/trm.c

image: $(IMAGE).elf
	@$(OBJDUMP) -d $(IMAGE).elf > $(IMAGE).txt
	@echo + OBJCOPY "->" $(IMAGE_REL).bin
	@$(READELF) -a $(IMAGE).elf > $(IMAGE).elf.txt
	@$(OBJCOPY) -S --set-section-flags .bss=alloc,contents -O binary $(IMAGE).elf $(IMAGE).bin

run: image
	make -C $(NSIM_HOME) ISA=$(ISA) run FLAGS="$(FLAGS)" IMG=$(IMAGE).bin
	# make -C $(NSIM_HOME) ISA=$(ISA) run FLAGS="$(FLAGS)" IMG=$(IMAGE).bin MROM_IMG=$(IMAGE).bin
