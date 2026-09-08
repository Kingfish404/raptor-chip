NSIM_HOME = $(abspath $(RAPTOR_HOME)/sim)
AM_SRCS := riscv/ysyxsoc/start.S \
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
              --defsym=_pmem_start=0xa0000000 --defsym=_entry_offset=0
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
	$(MAKE) -C $(NSIM_HOME) SIM_PLATFORM=ysyxsoc ISA=$(ISA) run ARGS="$(ARGS)" IMG=$(IMAGE).bin
