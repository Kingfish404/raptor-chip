# =============================================================================
# fpga/litex/tests/Makefile — Minimal C microbenchmarks for Raptor LiteX SoC
# =============================================================================
#
# Each test compiles to a flat bin loaded into main_ram at 0x80000000 via
# --ram-init. No AM, no libc — just start.S + io.h + one .c file.
#
# All build artifacts land in $(BUILD_DIR) (default: ../build/tests), keeping
# the source tree clean.
#
# Usage (from this directory):
#   make                 # build all test binaries
#   make hello           # build a single test (-> $(BUILD_DIR)/hello.bin)
#   make dump            # also produce disassembly
#   make clean
#
# Higher-level 'make test-hello / tests-run' targets live in
# fpga/litex/Makefile and call this Makefile, passing BUILD_DIR.
# =============================================================================

CROSS   ?= riscv64-unknown-elf-
CC      := $(CROSS)gcc
OBJCOPY := $(CROSS)objcopy
OBJDUMP := $(CROSS)objdump

# Match the CPU variant's ISA (rv32imac_zicsr_zifencei + Zba/Zbb/Zbc/Zbs).
MARCH   := rv32imac_zicsr_zifencei_zba_zbb_zbc_zbs
MABI    := ilp32

SRC_DIR   := $(abspath .)
BUILD_DIR ?= $(abspath ../build/tests)

CFLAGS  := -march=$(MARCH) -mabi=$(MABI) \
           -Os -ffreestanding -fno-builtin -fno-stack-protector \
           -fno-common -ffunction-sections -fdata-sections \
           -Wall -Wextra -Wno-unused-parameter -std=c11 \
           -I$(SRC_DIR) \
           -nostdlib -nostdinc -isystem $(shell $(CC) -print-file-name=include)

LDFLAGS := -nostdlib -nostartfiles -static -T $(SRC_DIR)/link.ld \
           -Wl,--gc-sections -Wl,-melf32lriscv -Wl,--no-relax

# Freestanding needs libgcc for 64-bit __udivdi3/__umoddi3 used by print_udec.
LIBGCC  := $(shell $(CC) -march=$(MARCH) -mabi=$(MABI) -print-libgcc-file-name)

TESTS   := hello text fib prime memcpy mul

BINS    := $(addprefix $(BUILD_DIR)/, $(addsuffix .bin,  $(TESTS)))
ELFS    := $(addprefix $(BUILD_DIR)/, $(addsuffix .elf,  $(TESTS)))
DUMPS   := $(addprefix $(BUILD_DIR)/, $(addsuffix .dump, $(TESTS)))

.PHONY: all clean dump $(TESTS)
all: $(BINS)

# Keep .elf files around (don't let make treat them as intermediate and rm them).
# Without this, `make hello` deletes hello.elf after objcopy, which makes
# later `riscv64-unknown-elf-objdump -d hello.elf` impossible.
.PRECIOUS: $(BUILD_DIR)/%.elf
.SECONDARY: $(ELFS)

# Convenience aliases: `make hello` -> $(BUILD_DIR)/hello.bin.
$(TESTS): %: $(BUILD_DIR)/%.bin

$(BUILD_DIR):
	@mkdir -p $@

$(BUILD_DIR)/%.elf: $(SRC_DIR)/%.c $(SRC_DIR)/start.S $(SRC_DIR)/link.ld $(SRC_DIR)/io.h | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(SRC_DIR)/start.S $< $(LIBGCC)

$(BUILD_DIR)/%.bin: $(BUILD_DIR)/%.elf
	$(OBJCOPY) -O binary $< $@

$(BUILD_DIR)/%.dump: $(BUILD_DIR)/%.elf
	$(OBJDUMP) -d $< > $@

dump: $(DUMPS)

clean:
	rm -rf $(BUILD_DIR)
	@# Legacy in-tree artifacts from older versions of this Makefile:
	rm -f $(SRC_DIR)/*.elf $(SRC_DIR)/*.bin $(SRC_DIR)/*.dump
