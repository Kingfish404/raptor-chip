# ============================================================================
# fpga/litex/benchmarks/coremark/Makefile: Build CoreMark for Raptor LiteX SoC
# ============================================================================
#
# Usage:
#   make build          # Clone coremark + build ELF/BIN
#   make clean          # Remove build artifacts
#
# Fully freestanding — no newlib/picolibc required.
# The port uses rdtime (RISC-V Zicntr) for timing at 1 MHz timebase.
# Output via LiteX UART CSR (memory-mapped).

SHELL := /bin/bash

_THIS_DIR   := $(dir $(lastword $(MAKEFILE_LIST)))
LITEX_DIR   := $(abspath $(_THIS_DIR)/../..)
RAPTOR_HOME := $(abspath $(LITEX_DIR)/../..)

# ---- Toolchain ----
CROSS_COMPILE ?= $(shell \
  if command -v riscv64-unknown-elf-gcc >/dev/null 2>&1; then echo riscv64-unknown-elf-; \
  elif command -v riscv64-elf-gcc >/dev/null 2>&1; then echo riscv64-elf-; \
  elif command -v riscv64-linux-gnu-gcc >/dev/null 2>&1; then echo riscv64-linux-gnu-; \
  else echo riscv64-unknown-elf-; fi)
CC      := $(CROSS_COMPILE)gcc
OBJCOPY := $(CROSS_COMPILE)objcopy
SIZE    := $(CROSS_COMPILE)size

# ---- Architecture ----
ARCH   := rv32imac_zicsr_zifencei_zba_zbb_zbc_zbs
ABI    := ilp32

# ---- Directories ----
COREMARK_DIR := $(_THIS_DIR)coremark
BUILD_DIR    := $(_THIS_DIR)build
PORTME_DIR   := $(_THIS_DIR)portme

# ---- CoreMark config ----
ITERATIONS ?= 64
CFLAGS := -march=$(ARCH) -mabi=$(ABI) -mcmodel=medany \
          -O2 -Wall -g \
          -ffreestanding -nostdlib -nostdinc \
          -isystem $(shell $(CC) -print-file-name=include) \
          -I$(PORTME_DIR) -I$(COREMARK_DIR) \
          -DITERATIONS=$(ITERATIONS) -DPERFORMANCE_RUN=1 \
          -DHAS_STDIO=0 -DHAS_PRINTF=0 \
          -DCOMPILER_FLAGS=\""$(ARCH)"\"

LDFLAGS := -march=$(ARCH) -mabi=$(ABI) -mcmodel=medany \
           -nostdlib -static \
           -T$(PORTME_DIR)/link.ld

# libgcc provides soft-float routines (__muldf3 etc.) for printf %f
LIBGCC := $(shell $(CC) -march=$(ARCH) -mabi=$(ABI) -print-libgcc-file-name)

# ---- Source fetching ----
$(COREMARK_DIR)/core_main.c:
	git clone --depth 1 https://github.com/eembc/coremark.git $(COREMARK_DIR)

# ---- Build rules ----
ifneq ($(wildcard $(COREMARK_DIR)/core_main.c),)

CORE_SRCS := core_list_join.c core_main.c core_matrix.c core_state.c core_util.c
PORT_SRCS := core_portme.c minilib.c

OBJS := $(patsubst %.c,$(BUILD_DIR)/%.o,$(CORE_SRCS) $(PORT_SRCS))
# crt0.S is assembled separately
OBJS += $(BUILD_DIR)/crt0.o
ELF  := $(BUILD_DIR)/coremark.elf
BIN  := $(BUILD_DIR)/coremark.bin

$(BUILD_DIR)/crt0.o: $(PORTME_DIR)/crt0.S
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/core_portme.o: $(PORTME_DIR)/core_portme.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/minilib.o: $(PORTME_DIR)/minilib.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/%.o: $(COREMARK_DIR)/%.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@

$(ELF): $(OBJS)
	@mkdir -p $(dir $@)
	$(CC) $(LDFLAGS) $^ $(LIBGCC) -o $@
	@$(SIZE) $@

$(BIN): $(ELF)
	$(OBJCOPY) -O binary $< $@

_build: $(BIN)
	@echo "CoreMark ELF: $(ELF)"
	@echo "CoreMark BIN: $(BIN)"

endif # coremark source exists

# ---- Public targets ----
.PHONY: build _build clean clone

clone: $(COREMARK_DIR)/core_main.c ## Clone CoreMark repository

build: ## Build coremark ELF + BIN
	@$(MAKE) --no-print-directory $(COREMARK_DIR)/core_main.c
	@$(MAKE) --no-print-directory _build

clean: ## Remove build artifacts
	rm -rf $(BUILD_DIR)

.DEFAULT_GOAL := build
