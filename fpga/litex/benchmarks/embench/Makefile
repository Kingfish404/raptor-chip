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
_THIS_MAKEFILE := $(abspath $(lastword $(MAKEFILE_LIST)))
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
NETTLE_SHA256_LOCAL_SCALE ?= 562

# ---- Directories ----
EMBENCH_DIR      := $(_THIS_DIR)embench
EMBENCH_REPO     := https://github.com/embench/embench-iot.git
EMBENCH_REV      := 09c2ed8c3b7008c95d08b038de4a3f6dc103ed70
EMBENCH_PATCH    := $(_THIS_DIR)patches/0001-nettle-sha256-configurable-local-scale.patch
EMBENCH_PATCH_ID := $(shell git hash-object "$(abspath $(EMBENCH_PATCH))")
EMBENCH_PREPARED := $(EMBENCH_DIR)/.raptor-prepared-$(EMBENCH_REV)-$(EMBENCH_PATCH_ID)
BUILD_DIR        := $(_THIS_DIR)build
SUPPORT_DIR      := $(_THIS_DIR)support
BUILD_CONFIG     := $(BUILD_DIR)/.build-config

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
				-DNETTLE_SHA256_LOCAL_SCALE=$(NETTLE_SHA256_LOCAL_SCALE) \
                -Wno-unused-variable -Wno-implicit-function-declaration \
                -Wno-incompatible-pointer-types -Wno-builtin-declaration-mismatch \
                -I$(SUPPORT_DIR) -I$(EMBENCH_DIR)/support

LDFLAGS := -march=$(ARCH) -mabi=$(ABI) -mcmodel=medany \
           -nostdlib -static \
           -T$(SUPPORT_DIR)/link.ld

LIBGCC := $(shell $(CC) -march=$(ARCH) -mabi=$(ABI) -print-libgcc-file-name)
CC_VERSION := $(shell $(CC) --version 2>/dev/null | head -n 1)
LOCAL_BUILD_INPUTS_ID := $(shell { \
	git hash-object "$(_THIS_MAKEFILE)"; \
	find "$(abspath $(SUPPORT_DIR))" -type f -print | LC_ALL=C sort | xargs git hash-object; \
} | git hash-object --stdin)

# ---- Source fetching ----
.PHONY: FORCE
FORCE:

$(EMBENCH_PREPARED): FORCE $(EMBENCH_PATCH)
	@mkdir -p $(dir $(EMBENCH_DIR))
	@if [ ! -d "$(EMBENCH_DIR)/.git" ]; then \
		git init -q "$(EMBENCH_DIR)"; \
	fi
	@if git -C "$(EMBENCH_DIR)" remote get-url origin >/dev/null 2>&1; then \
		git -C "$(EMBENCH_DIR)" remote set-url origin "$(EMBENCH_REPO)"; \
	else \
		git -C "$(EMBENCH_DIR)" remote add origin "$(EMBENCH_REPO)"; \
	fi
	@if ! git -C "$(EMBENCH_DIR)" cat-file -e "$(EMBENCH_REV)^{commit}" 2>/dev/null; then \
		git -C "$(EMBENCH_DIR)" fetch -q --depth 1 origin "$(EMBENCH_REV)"; \
	fi
	@git -C "$(EMBENCH_DIR)" reset --hard -q "$(EMBENCH_REV)"
	@git -C "$(EMBENCH_DIR)" clean -fdx -q
	@git -C "$(EMBENCH_DIR)" apply --check "$(abspath $(EMBENCH_PATCH))"
	@git -C "$(EMBENCH_DIR)" apply "$(abspath $(EMBENCH_PATCH))"
	@rm -f "$(EMBENCH_DIR)"/.raptor-prepared-*
	@touch $@

$(EMBENCH_DIR)/support/main.c: $(EMBENCH_PREPARED)

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

.PHONY: print-build-config

print-build-config:
	@printf '%s\n' \
		'BUILD_CONFIG_VERSION=2' \
		'EMBENCH_UPSTREAM_REV=$(EMBENCH_REV)' \
		'EMBENCH_PATCH_ID=$(EMBENCH_PATCH_ID)' \
		'SYS_CLK_HZ=$(SYS_CLK_HZ)' \
		'NETTLE_SHA256_LOCAL_SCALE=$(NETTLE_SHA256_LOCAL_SCALE)' \
		'ARCH=$(ARCH)' \
		'ABI=$(ABI)' \
		'CC=$(CC)' \
		'CC_VERSION=$(CC_VERSION)' \
		'OBJCOPY=$(OBJCOPY)' \
		'CFLAGS_COMMON=$(CFLAGS_COMMON)' \
		'LDFLAGS=$(LDFLAGS)' \
		'LIBGCC=$(LIBGCC)' \
		'LOCAL_BUILD_INPUTS_ID=$(LOCAL_BUILD_INPUTS_ID)'

$(BUILD_CONFIG): FORCE
	@mkdir -p $(BUILD_DIR)
	@tmp="$@.tmp"; \
	$(MAKE) --no-print-directory print-build-config > "$$tmp"; \
	if ! cmp -s "$$tmp" "$@"; then \
		echo "[INFO] embench build configuration changed; forcing rebuild."; \
		mv "$$tmp" "$@"; \
	else \
		rm -f "$$tmp"; \
	fi

$(BUILD_DIR)/_support/crt0.o: $(SUPPORT_DIR)/crt0.S $(BUILD_CONFIG)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS_COMMON) -c $< -o $@

$(BUILD_DIR)/_support/minilib.o: $(SUPPORT_DIR)/minilib.c $(BUILD_CONFIG)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS_COMMON) -c $< -o $@

# boardsupport.o is rebuilt per-bench (depends on BENCH_NAME macro), so the
# rule below overrides this default via -include. We still have a catch-all
# shared build to provide a symbol if a benchmark doesn't inject one.
$(BUILD_DIR)/_support/boardsupport.o: $(SUPPORT_DIR)/boardsupport.c $(BUILD_CONFIG)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS_COMMON) -DBENCH_NAME=\"default\" -c $< -o $@

$(BUILD_DIR)/_support/main.o: $(SUPPORT_DIR)/main.c $(BUILD_CONFIG)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS_COMMON) -c $< -o $@

$(BUILD_DIR)/_support/beebsc.o: $(EMBENCH_DIR)/support/beebsc.c $(BUILD_CONFIG)
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
$$($(1)_BSO): $$(SUPPORT_DIR)/boardsupport.c $(BUILD_CONFIG)
	@mkdir -p $$(dir $$@)
	$$(CC) $$(CFLAGS_COMMON) -DBENCH_NAME=\"$(1)\" -c $$< -o $$@

$$(BUILD_DIR)/$(1)/%.o: $$($(1)_SRC_DIR)/%.c $(BUILD_CONFIG)
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

build: clone ## Build all Embench-IoT benchmarks (BENCH=<name> for just one)
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
