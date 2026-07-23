# app/tests/irq/Makefile: bare-metal PLIC IRQ tests for sim.
#
# Each .c file becomes one test: `_start` (crt0.S) -> main() -> finisher.
# Output: build/rv32/tests/irq/<name>.bin (raw, loaded at 0x80000000 by sim).
#
# Bare-metal (NOT pk) — runs in M-mode with full PLIC/CSR access.

_THIS_DIR := $(dir $(lastword $(MAKEFILE_LIST)))
APP_HOME  := $(abspath $(_THIS_DIR)/../..)
include $(APP_HOME)/common.mk

BUILD_DIR ?= $(APP_HOME)/build/rv$(XLEN)/tests/irq
EXTRA_CFLAGS ?=

# Bare-metal: bypass picolibc, freestanding, no stdlib, custom linker.
BM_CFLAGS := -march=$(ARCH) -mabi=$(ABI) -mcmodel=medany -O2 -g -Wall $(EXTRA_CFLAGS) \
             -ffreestanding -fno-builtin -fno-stack-protector \
             -nostdlib -nostartfiles \
             -fno-asynchronous-unwind-tables -static
BM_LDFLAGS := -T$(_THIS_DIR)link.ld -Wl,--no-relax -nostdlib -nostartfiles

CRT0 := $(_THIS_DIR)crt0.S
SRCS := $(wildcard $(_THIS_DIR)*.c)
NAMES := $(patsubst $(_THIS_DIR)%.c,%,$(SRCS))
ELFS := $(patsubst %,$(BUILD_DIR)/%.elf,$(NAMES))
BINS := $(patsubst %,$(BUILD_DIR)/%.bin,$(NAMES))

.PRECIOUS: $(ELFS)

OBJCOPY ?= $(CROSS_COMPILE)objcopy

$(BUILD_DIR)/%.elf: $(_THIS_DIR)%.c $(CRT0) $(_THIS_DIR)link.ld
	@mkdir -p $(dir $@)
	$(CC) $(BM_CFLAGS) $(BM_LDFLAGS) $(CRT0) $< -o $@

$(BUILD_DIR)/%.bin: $(BUILD_DIR)/%.elf
	$(OBJCOPY) -O binary $< $@

build: $(BINS)
	@echo "Built $(words $(BINS)) IRQ tests in $(BUILD_DIR)/"

clean:
	rm -rf $(BUILD_DIR)

.PHONY: build clean
