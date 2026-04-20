# ============================================================================
# fpga/litex/benchmarks/embench/Makefile: Build Embench-IoT for Raptor LiteX
# ============================================================================
#
# Produces one freestanding ELF + BIN per Embench-IoT benchmark that can be
# loaded into LiteX main_ram (0x80000000) via `--ram-init=<bin>`.
#
# Usage:
#   make build                # Clone embench-iot + build all 14 benchmarks
#   make build BENCH=crc32    # Build just one
#   make clean                # Wipe build artifacts
#
# Output layout:
#   build/<bench>/<bench>.elf
#   build/<bench>/<bench>.bin
#
# Fully freestanding — no newlib/picolibc. Timing uses rdcycle+rdtime
# (RISC-V Zicntr). Output goes to the LiteX UART CSR.

SHELL := /bin/bash

_THIS_DIR   := $(dir $(lastword $(MAKEFILE_LIST)))
LITEX_DIR   := $(abspath $(_THIS_DIR)/../..)
RAPTOR_HOME := $(abspath $(LITEX_DIR)/../..)

# ---- Toolchain ----
# Freestanding build: uses -nostdinc with local stub headers (support/include/)
# plus compiler builtins (stdint.h, stddef.h, stdarg.h, etc.). No system libc
# headers needed — works with any RISC-V cross-compiler.
CROSS_COMPILE ?= $(shell \
  if command -v riscv64-unknown-elf-gcc >/dev/null 2>&1; then echo riscv64-unknown-elf-; \
  elif command -v riscv64-elf-gcc >/dev/null 2>&1; then echo riscv64-elf-; \
  elif command -v riscv64-linux-gnu-gcc >/dev/null 2>&1; then echo riscv64-linux-gnu-; \
  else echo riscv64-unknown-elf-; fi)

CC      := $(CROSS_COMPILE)gcc
OBJCOPY := $(CROSS_COMPILE)objcopy
SIZE    := $(CROSS_COMPILE)size

# ---- Architecture ----
ARCH := rv32imac_zicntr_zicond_zicsr_zifencei_zcb_zba_zbb_zbc_zbs
ABI  := ilp32

# ---- System parameters ----
# LiteX sys_clk used by the default raptor_soc.py invocation (50 MHz).
# Override via `make build SYS_CLK_HZ=...` if you re-generate the SoC with
# a different --sys-clk-freq.
SYS_CLK_HZ ?= 50000000

# ---- Directories ----
EMBENCH_DIR  := $(_THIS_DIR)embench
BUILD_DIR    := $(_THIS_DIR)build
SUPPORT_DIR  := $(_THIS_DIR)support

# ---- Benchmark list (matches app/benchmarks/embench/Makefile) ----
BENCHMARKS := aha-mont64 crc32 depthconv edn huffbench matmult-int \
              md5sum nettle-aes nettle-sha256 nsichneu picojpeg \
              qrduino sglib-combined slre statemate tarfind ud \
              wikisort xgboost

# ---- Flags ----
# Fully freestanding: -nostdinc drops all system headers. We re-add the
# compiler's built-in directory (stdint.h, stddef.h, stdarg.h, stdbool.h,
# limits.h, float.h) via -isystem, then our local stubs (support/include/)
# for stdlib.h, string.h, stdio.h, assert.h, ctype.h, math.h — backed by
# minilib.c implementations. This avoids any dependency on newlib/glibc
# headers and works with both bare-metal and linux-gnu toolchains.
_GCC_BUILTINS := $(shell $(CC) -print-file-name=include)

CFLAGS_COMMON := -march=$(ARCH) -mabi=$(ABI) -mcmodel=medany \
                -O2 -Wall -g -std=gnu99 \
                -ffreestanding -nostdinc \
                -isystem $(_GCC_BUILTINS) \
                -isystem $(SUPPORT_DIR)/include \
                -DHAVE_BOARDSUPPORT_H \
                -DGLOBAL_SCALE_FACTOR=1 -DWARMUP_HEAT=1 \
                -DSYS_CLK_HZ=$(SYS_CLK_HZ) \
                -Wno-unused-variable -Wno-implicit-function-declaration \
                -Wno-incompatible-pointer-types -Wno-builtin-declaration-mismatch \
                -I$(SUPPORT_DIR) -I$(EMBENCH_DIR)/support

LDFLAGS := -march=$(ARCH) -mabi=$(ABI) -mcmodel=medany \
           -nostdlib -static \
           -T$(SUPPORT_DIR)/link.ld

LIBGCC := $(shell $(CC) -march=$(ARCH) -mabi=$(ABI) -print-libgcc-file-name)

# ---- Source fetching ----
$(EMBENCH_DIR)/support/main.c:
	@mkdir -p $(dir $(EMBENCH_DIR))
	git clone --depth 1 https://github.com/embench/embench-iot.git $(EMBENCH_DIR)

# ==============================================================================
# Build rules (only active after clone)
# ==============================================================================
ifneq ($(wildcard $(EMBENCH_DIR)/support/main.c),)

# ---- Shared support objects ----
SUPPORT_OBJS := \
	$(BUILD_DIR)/_support/crt0.o \
	$(BUILD_DIR)/_support/minilib.o \
	$(BUILD_DIR)/_support/boardsupport.o \
	$(BUILD_DIR)/_support/main.o \
	$(BUILD_DIR)/_support/beebsc.o

$(BUILD_DIR)/_support/crt0.o: $(SUPPORT_DIR)/crt0.S
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS_COMMON) -c $< -o $@

$(BUILD_DIR)/_support/minilib.o: $(SUPPORT_DIR)/minilib.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS_COMMON) -c $< -o $@

# boardsupport.o is rebuilt per-bench (depends on BENCH_NAME macro), so the
# rule below overrides this default via -include. We still have a catch-all
# shared build to provide a symbol if a benchmark doesn't inject one.
$(BUILD_DIR)/_support/boardsupport.o: $(SUPPORT_DIR)/boardsupport.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS_COMMON) -DBENCH_NAME=\"default\" -c $< -o $@

$(BUILD_DIR)/_support/main.o: $(SUPPORT_DIR)/main.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS_COMMON) -c $< -o $@

$(BUILD_DIR)/_support/beebsc.o: $(EMBENCH_DIR)/support/beebsc.c
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS_COMMON) -c $< -o $@

# ---- Per-benchmark template ----
# $(1) = benchmark directory name
define BENCH_template
$(1)_SRC_DIR := $$(EMBENCH_DIR)/src/$(1)
$(1)_SRCS    := $$(wildcard $$($(1)_SRC_DIR)/*.c)
$(1)_OBJS    := $$(patsubst $$($(1)_SRC_DIR)/%.c,$$(BUILD_DIR)/$(1)/%.o,$$($(1)_SRCS))
$(1)_BSO     := $$(BUILD_DIR)/$(1)/boardsupport.o
$(1)_ELF     := $$(BUILD_DIR)/$(1)/$(1).elf
$(1)_BIN     := $$(BUILD_DIR)/$(1)/$(1).bin

# Per-bench boardsupport.o with injected BENCH_NAME
$$($(1)_BSO): $$(SUPPORT_DIR)/boardsupport.c
	@mkdir -p $$(dir $$@)
	$$(CC) $$(CFLAGS_COMMON) -DBENCH_NAME=\"$(1)\" -c $$< -o $$@

$$(BUILD_DIR)/$(1)/%.o: $$($(1)_SRC_DIR)/%.c
	@mkdir -p $$(dir $$@)
	$$(CC) $$(CFLAGS_COMMON) -I$$($(1)_SRC_DIR) -c $$< -o $$@

# Link: swap the per-bench boardsupport.o in for the shared one.
$$($(1)_ELF): $$($(1)_OBJS) \
              $$(BUILD_DIR)/_support/crt0.o \
              $$(BUILD_DIR)/_support/minilib.o \
              $$(BUILD_DIR)/_support/main.o \
              $$(BUILD_DIR)/_support/beebsc.o \
              $$($(1)_BSO)
	@mkdir -p $$(dir $$@)
	$$(CC) $$(LDFLAGS) $$^ $$(LIBGCC) -o $$@
	@$$(SIZE) $$@

$$($(1)_BIN): $$($(1)_ELF)
	$$(OBJCOPY) -O binary $$< $$@

.PHONY: build-$(1)
build-$(1): $$($(1)_BIN)

endef

$(foreach b,$(BENCHMARKS),$(eval $(call BENCH_template,$(b))))

ALL_BINS := $(foreach b,$(BENCHMARKS),$(BUILD_DIR)/$(b)/$(b).bin)

_build: $(ALL_BINS)
	@echo ""
	@echo "Built $(words $(BENCHMARKS)) Embench-IoT benchmarks:"
	@for b in $(BENCHMARKS); do echo "  $(BUILD_DIR)/$$b/$$b.bin"; done

endif # embench source present

# ==============================================================================
# Public targets
# ==============================================================================
.PHONY: build _build clean clone list

clone: $(EMBENCH_DIR)/support/main.c ## Clone embench-iot repository

# BENCH=<name> builds just that one benchmark; otherwise all.
BENCH ?=

build: ## Build all Embench-IoT benchmarks (BENCH=<name> for just one)
	@$(MAKE) --no-print-directory $(EMBENCH_DIR)/support/main.c
ifeq ($(BENCH),)
	@$(MAKE) --no-print-directory _build
else
	@$(MAKE) --no-print-directory build-$(BENCH)
endif

clean: ## Remove build artifacts
	rm -rf $(BUILD_DIR)

list: ## Print the benchmark list
	@for b in $(BENCHMARKS); do echo $$b; done

.DEFAULT_GOAL := build
