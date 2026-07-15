# app/tests/repro/Makefile: bare-metal minimal repro tests for sim.

_THIS_DIR := $(dir $(lastword $(MAKEFILE_LIST)))
APP_HOME  := $(abspath $(_THIS_DIR)/../..)
IRQ_DIR   := $(abspath $(_THIS_DIR)/../irq)
include $(APP_HOME)/common.mk

BUILD_DIR := $(APP_HOME)/build/rv$(XLEN)/tests/repro

BM_CFLAGS := -march=$(ARCH) -mabi=$(ABI) -mcmodel=medany -O2 -g -Wall \
             -ffreestanding -fno-builtin -fno-stack-protector \
             -nostdlib -nostartfiles \
             -fno-asynchronous-unwind-tables -static -I$(IRQ_DIR)
BM_LDFLAGS := -T$(IRQ_DIR)/link.ld -Wl,--no-relax -nostdlib -nostartfiles

CRT0 := $(IRQ_DIR)/crt0.S
SRCS := $(wildcard $(_THIS_DIR)*.c)
NAMES := $(patsubst $(_THIS_DIR)%.c,%,$(SRCS))
ELFS := $(patsubst %,$(BUILD_DIR)/%.elf,$(NAMES))
BINS := $(patsubst %,$(BUILD_DIR)/%.bin,$(NAMES))

OBJCOPY ?= $(CROSS_COMPILE)objcopy

$(BUILD_DIR)/%.elf: $(_THIS_DIR)%.c $(CRT0) $(IRQ_DIR)/link.ld $(IRQ_DIR)/test_common.h
	@mkdir -p $(dir $@)
	$(CC) $(BM_CFLAGS) $(BM_LDFLAGS) $(CRT0) $< -o $@

$(BUILD_DIR)/%.bin: $(BUILD_DIR)/%.elf
	$(OBJCOPY) -O binary $< $@

build: $(BINS)
	@echo "Built $(words $(BINS)) repro tests in $(BUILD_DIR)/"

clean:
	rm -rf $(BUILD_DIR)

.PRECIOUS: $(ELFS)
.PHONY: build clean