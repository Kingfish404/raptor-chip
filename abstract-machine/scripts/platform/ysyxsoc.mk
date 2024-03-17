AM_SRCS := riscv/ysyxsoc/start.S \
           riscv/ysyxsoc/trm.c \
           riscv/ysyxsoc/trap.S

CFLAGS    += -fdata-sections -ffunction-sections
LDFLAGS   += -T $(AM_HOME)/scripts/linker.ysyxsoc.ld \
						 --defsym=_pmem_start=0x80000000 \
						 --defsym=_entry_offset=0x0 \
						 --defsym=_stack_pointer=0x0f002000 \
						 --defsym=_heap_start=0x80080000 \
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
	make -C $(NPC_HOME) ISA=$(ISA) run NPCFLAGS="$(NPCFLAGS)" IMG=$(IMAGE).bin
	# make -C $(NPC_HOME) ISA=$(ISA) run NPCFLAGS="$(NPCFLAGS)" IMG=$(IMAGE).bin MROM_IMG=$(IMAGE).bin
