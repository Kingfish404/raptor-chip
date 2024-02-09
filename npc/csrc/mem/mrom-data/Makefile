AS        = $(CROSS_COMPILE)gcc
CC        = $(CROSS_COMPILE)gcc
CXX       = $(CROSS_COMPILE)g++
LD        = $(CROSS_COMPILE)ld
AR        = $(CROSS_COMPILE)ar
OBJDUMP   = $(CROSS_COMPILE)objdump
OBJCOPY   = $(CROSS_COMPILE)objcopy
READELF   = $(CROSS_COMPILE)readelf

IMAGE = ./build/mrom-data
SOURCE = $(wildcard *.c)

CFLAGS = -nostartfiles

all: $(IMAGE).elf $(IMAGE).bin

$(IMAGE).elf:
	mkdir -p $(dir $(IMAGE))
	$(CC) -o $(IMAGE).elf $(CFLAGS) $(LINKAGE) $(LDFLAGS) $(SOURCE)

$(IMAGE).bin: $(IMAGE).elf
	$(OBJDUMP) -d $(IMAGE).elf > $(IMAGE).txt
	$(OBJCOPY) -S --set-section-flags .bss=alloc,contents -O binary $(IMAGE).elf $(IMAGE).bin

clean:
	rm -rf ./build/
