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

CFLAGS = -g -O2 -MMD -Wall \
	-fno-asynchronous-unwind-tables -fno-builtin -fno-stack-protector \
	-nostartfiles -ffreestanding $(COMMON_CFLAGS) -nostdlib

all: $(IMAGE).elf $(IMAGE).bin

dtb.c: raptor.dts spike-rv32ima.dts
	# brew install dtc
	dtc spike-rv32ima.dts -o raptor.dtb
	xxd -i raptor.dtb > dtb.c

$(IMAGE).elf: $(SOURCE)
	mkdir -p $(dir $(IMAGE))
	$(CC) -o $(IMAGE).elf $(CFLAGS) $(LINKAGE) $(SOURCE) $(LDFLAGS)

$(IMAGE).bin: $(IMAGE).elf
	$(OBJDUMP) -d $(IMAGE).elf > $(IMAGE).txt
	$(OBJCOPY) -S --set-section-flags .bss=alloc,contents -O binary $(IMAGE).elf $(IMAGE).bin

clean:
	rm -rf ./build/
