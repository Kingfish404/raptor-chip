AS        = $(CROSS_COMPILE)gcc
CC        = $(CROSS_COMPILE)gcc
CXX       = $(CROSS_COMPILE)g++
LD        = $(CROSS_COMPILE)ld
AR        = $(CROSS_COMPILE)ar
OBJDUMP   = $(CROSS_COMPILE)objdump
OBJCOPY   = $(CROSS_COMPILE)objcopy
READELF   = $(CROSS_COMPILE)readelf

# ISA64=1 to build for RV64, default RV32
ifeq ($(ISA64),1)
COMMON_CFLAGS = -march=rv64im_zicsr_zifencei -mabi=lp64
else
COMMON_CFLAGS = -march=rv32im_zicsr_zifencei -mabi=ilp32
endif
LDFLAGS       =

IMAGE = ./build/mrom-data
SOURCE = rom.c dtb.c

# Auto-invalidate build when ISA64 flag changes (e.g., switching RV32<->RV64)
ISA64 ?= 0
ISA_STAMP := ./build/.isa_stamp
ISA_PREV  := $(shell cat $(ISA_STAMP) 2>/dev/null)
ifneq ($(ISA64),$(ISA_PREV))
$(shell rm -rf ./build)
$(shell mkdir -p ./build && printf '%s' '$(ISA64)' > $(ISA_STAMP))
endif

CFLAGS = -g -O2 -MMD -Wall -fno-pie \
	-fno-asynchronous-unwind-tables -fno-builtin -fno-stack-protector \
	-nostartfiles -ffreestanding $(COMMON_CFLAGS) -nostdlib
LDFLAGS = -no-pie -Wl,-Ttext=0 -Wl,-e,_start

all: $(IMAGE).elf $(IMAGE).bin ## Build MROM data (elf + bin)

dtb.c: raptor.dts spike-rv32ima.dts ## Generate DTB C source
	# brew install dtc
	dtc spike-rv32ima.dts -o raptor.dtb
	xxd -i raptor.dtb > dtb.c

$(IMAGE).elf: $(SOURCE)
	mkdir -p $(dir $(IMAGE))
	$(CC) -o $(IMAGE).elf $(CFLAGS) $(LINKAGE) $(SOURCE) $(LDFLAGS)

$(IMAGE).bin: $(IMAGE).elf
	$(OBJDUMP) -d $(IMAGE).elf > $(IMAGE).txt
	$(OBJCOPY) -S --set-section-flags .bss=alloc,contents -O binary $(IMAGE).elf $(IMAGE).bin

clean: ## Clean build artifacts
	rm -rf ./build/
