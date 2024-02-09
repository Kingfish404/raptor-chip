AS        = $(CROSS_COMPILE)gcc
CC        = $(CROSS_COMPILE)gcc
CXX       = $(CROSS_COMPILE)g++
LD        = $(CROSS_COMPILE)ld
AR        = $(CROSS_COMPILE)ar
OBJDUMP   = $(CROSS_COMPILE)objdump
OBJCOPY   = $(CROSS_COMPILE)objcopy
READELF   = $(CROSS_COMPILE)readelf

COMMON_CFLAGS = -march=rv32e_zicsr -mabi=ilp32e  # overwrite
# LDFLAGS       = -melf32lriscv                    # overwrite

IMAGE = ./build/mrom-data
SOURCE = $(wildcard *.c)

CFLAGS = -nostartfiles $(COMMON_CFLAGS) 

all: $(IMAGE).elf $(IMAGE).bin

$(IMAGE).elf:
	mkdir -p $(dir $(IMAGE))
	$(CC) -o $(IMAGE).elf $(CFLAGS) $(LINKAGE) $(LDFLAGS) $(SOURCE)

$(IMAGE).bin: $(IMAGE).elf
	$(OBJDUMP) -d $(IMAGE).elf > $(IMAGE).txt
	$(OBJCOPY) -S --set-section-flags .bss=alloc,contents -O binary $(IMAGE).elf $(IMAGE).bin

clean:
	rm -rf ./build/
