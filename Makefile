# ============================================================================
# Environment variables (auto-sourced from env.sh, no manual `source` needed)
# ============================================================================
export RAPTOR_HOME := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
export NEMU_HOME := $(RAPTOR_HOME)/nemu
export NSIM_HOME := $(RAPTOR_HOME)/nsim
export AM_HOME   := $(RAPTOR_HOME)/abstract-machine
export NAVY_HOME := $(RAPTOR_HOME)/abstract-machine/app/navy-apps
export NVBOARD_HOME := $(RAPTOR_HOME)/third_party/NJU-ProjectN/nvboard
export CROSS_COMPILE ?= riscv64-elf-

# Default to batch mode (no interactive prompt). Override with ARGS="" to disable.
ARGS ?= -b -n ## Pass args to runner (-b: batch, -n: no wave)
IMG ?= ## Custom image to load
DISK ?= ## Virtio block disk image to pass to nsim
SDCARD ?= ## QEMU SDHCI SD-card image to pass to nsim/NEMU
MAX_INST ?= ## Max instructions to execute (-m N)
TIMEOUT ?=## Wall-clock timeout in seconds for selected simulator runs
TINYOS_OS ?=## TinyOS payload selector: egos or xv6
QEMU ?=## Override QEMU executable for OS CLI helpers

# Raptor uarch config preset (selects configs/<name>/rapt_config.svh).
# Exported so it propagates through chained sub-makes (nsim, am-kernels, app, ...).
RAPT_CONFIG ?= default ## Raptor uarch config preset (default|small|...)
# `?=` keeps the trailing space before `##` in the value; strip it so paths
# like `$(NSIM_HOME)/build/$(RAPT_CONFIG)/...` don't end up with a stray
# space (which breaks `[ -f ... ]` shell tests in sub-makefiles).
RAPT_CONFIG := $(strip $(RAPT_CONFIG))
export RAPT_CONFIG

# ============================================================================
# Guard: only define project-level targets when invoked from root directory.
# Subprojects (nsim, nemu) include this file for env vars only.
# ============================================================================
ifeq ($(abspath $(dir $(firstword $(MAKEFILE_LIST)))),$(RAPTOR_HOME))

# Use bash for recipes so `set -o pipefail` (used by tee_* wrappers below)
# works on systems where /bin/sh is dash (e.g. Ubuntu / GitHub Actions runners).
SHELL := /bin/bash

NPROC := $(shell nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

# ============================================================================
# Parallel multi-binary test runner
# ----------------------------------------------------------------------------
# Multi-binary test suites (cpu-tests, irq-tests, ...) historically ran their
# member tests one-by-one. We parallelize the run phase across $(JOBS) sim
# instances. Build phase stays sequential (cheap; shares AM lib state).
#
# Override `JOBS=N` to cap parallelism (default = NPROC).
# Override `JOBS=1` to recover deterministic interleaved output.
# ============================================================================
JOBS ?= $(NPROC)## Parallel simulator instances for multi-binary test suites

# ============================================================================
# Test/benchmark output logging (tee to nsim/build/<config>/logs/)
#
# All benchmark/test recipes pipe their output through `tee` to a per-target
# log file under nsim/build/<RAPT_CONFIG>/logs/ (NPC) or nemu/build/logs/
# (NEMU). This persists results so they can be inspected later without
# re-running the simulator.
#
# Wrappers:
#   $(call tee_npc,name)  -> ` 2>&1 | tee nsim/build/<config>/logs/<name>.log`
#   $(call tee_nemu,name) -> ` 2>&1 | tee nemu/build/logs/<name>.log`
#
# Generic escape hatch for any target not pre-wrapped:
#   make log TARGET=<existing-target> [LOG_NAME=<filename-stem>]
# ============================================================================
NPC_LOG_DIR  := $(NSIM_HOME)/build/$(RAPT_CONFIG)/logs
NEMU_LOG_DIR := $(NEMU_HOME)/build/logs
APP_LOG_DIR  := $(NSIM_HOME)/build/$(RAPT_CONFIG)/logs/app
VERIFY_LOG_DIR := $(NSIM_HOME)/build/$(RAPT_CONFIG)/logs/verify
export NPC_LOG_DIR NEMU_LOG_DIR APP_LOG_DIR VERIFY_LOG_DIR

tee_npc    = 2>&1 | tee $(NPC_LOG_DIR)/$(1).log
tee_nemu   = 2>&1 | tee $(NEMU_LOG_DIR)/$(1).log
tee_app    = 2>&1 | tee $(APP_LOG_DIR)/$(1).log
tee_verify = 2>&1 | tee $(VERIFY_LOG_DIR)/$(1).log

log: ## Run TARGET=<target> with stdout/stderr tee'd to nsim/build/<config>/logs/$(LOG_NAME).log
	@test -n "$(TARGET)" || { echo "Usage: make log TARGET=<target> [LOG_NAME=<stem>]"; exit 1; }
	@mkdir -p $(NPC_LOG_DIR)
	@stem="$(if $(LOG_NAME),$(LOG_NAME),$(TARGET))"; \
	  echo "[log] $(NPC_LOG_DIR)/$$stem.log"; \
	  set -o pipefail; $(MAKE) --no-print-directory $(TARGET) 2>&1 | tee "$(NPC_LOG_DIR)/$$stem.log"

logs-show: ## List all persisted test/benchmark logs under nsim/build/ and nemu/build/logs/
	@find $(NSIM_HOME)/build $(NEMU_LOG_DIR) -type f -name '*.log' 2>/dev/null | sort

logs-clean: ## Remove all persisted test/benchmark logs
	@rm -rf $(NPC_LOG_DIR) $(NEMU_LOG_DIR) $(APP_LOG_DIR) $(VERIFY_LOG_DIR)
	@echo "[logs] cleared"

# ============================================================================
# Default target
# ============================================================================
.DEFAULT_GOAL := help

help: ## Show this help message
	@echo "Usage: make <target> [VAR=value ...]"
	@awk '\
		BEGIN { state=0; pending=""; first_target=1 } \
		/^# =+$$/ { \
			if (state==0) state=1; \
			else if (state==2) { pending=section; state=0 } \
			else state=0; next } \
		state==1 && /^# .+/ { section=substr($$0,3); state=2; next } \
		{ if (state==1) state=0 } \
		/^[a-zA-Z0-9_-]+:.*## / { \
			if (pending!="") { printf "\n%s:\n", pending; pending="" } \
			else if (first_target) printf "\nTargets:\n"; \
			first_target=0; \
			target=$$0; sub(/:.*/, "", target); \
			desc=$$0; sub(/.*## /, "", desc); \
			printf "  %-20s %s\n", target, desc }' $(MAKEFILE_LIST)
	@echo ""
	@echo "Variables (override with VAR=value):"
	@grep -hE '^[A-Z_]+\s*\?=' $(MAKEFILE_LIST) | \
		awk '{ \
			if (match($$0, /## /)) { \
				name=$$0; sub(/\s*\?=.*/, "", name); \
				desc=substr($$0, RSTART+3); \
				printf "  %-20s %s\n", name, desc } \
			else { \
				split($$0, a, "\\?="); \
				gsub(/^[ \t]+|[ \t]+$$/, "", a[1]); gsub(/^[ \t]+|[ \t]+$$/, "", a[2]); \
				printf "  %-20s %s\n", a[1], a[2] } }'
	@echo ""

# ============================================================================
# Setup
# ============================================================================
setup: ## Install dependencies and initialize workspace
	bash ./setup.sh

setup-rtl: ## Install dependencies and initialize RTL workspace
	bash ./setup-rtl.sh

# ============================================================================
# RTL Generation (Chisel -> SystemVerilog)
# ============================================================================
verilog: ## Generate SystemVerilog from Chisel (Scala)
	$(MAKE) -C $(RAPTOR_HOME)/rtl_scala verilog

# ============================================================================
# NEMU Targets
# ============================================================================
NEMU_DEFCONFIG ?= riscv32_defconfig ## NEMU defconfig profile
NEMU64_DEFCONFIG ?= riscv64_defconfig ## NEMU RV64 defconfig profile
NEMU_DISK_ARG = $(if $(DISK),--disk=$(DISK),)
NEMU_SDCARD_ARG = $(if $(SDCARD),--sdcard=$(SDCARD),)

config-nemu32: ## Configure NEMU (riscv32 default)
	$(MAKE) -C $(NEMU_HOME) $(NEMU_DEFCONFIG)
	$(MAKE) -C $(NEMU_HOME) -j$(NPROC)

config-nemu32-linux:
	$(MAKE) -C $(NEMU_HOME) riscv32_linux_defconfig
	$(MAKE) -C $(NEMU_HOME) -j$(NPROC)

config-nemu32-ref:
	$(MAKE) -C $(NEMU_HOME) riscv32_ref_defconfig
	$(MAKE) -C $(NEMU_HOME) -j$(NPROC)

menuconfig-nemu32: ## Open NEMU menuconfig
	$(MAKE) -C $(NEMU_HOME) menuconfig

build-nemu32: config-nemu32 ## Build NEMU (riscv32)
	$(MAKE) -C $(NEMU_HOME) -j$(NPROC)

run-nemu32: build-nemu32 ## Build and run NEMU (riscv32)
	$(MAKE) -C $(NEMU_HOME) run $(if $(IMG),IMG=$(IMG)) ARGS="$(ARGS) $(NEMU_DISK_ARG) $(NEMU_SDCARD_ARG)"
	$(MAKE) -C $(NEMU_HOME) -j$(NPROC)

run-nemu32-linux:
	$(MAKE) -C $(NEMU_HOME) riscv32_linux_defconfig
	$(MAKE) -C $(NEMU_HOME) -j$(NPROC)
	$(MAKE) -C $(NEMU_HOME) run $(if $(IMG),IMG=$(IMG)) ARGS="$(ARGS)"

config-nemu32-linux-device:
	$(MAKE) -C $(NEMU_HOME) riscv32_linux_device_defconfig
	$(MAKE) -C $(NEMU_HOME) -j$(NPROC)

DEVICE_ARGS ?= -b ## Args for -device targets (interactive by default)

run-nemu32-linux-device: ## Run NEMU RV32 with VGA screen + keyboard
	$(MAKE) -C $(NEMU_HOME) riscv32_linux_device_defconfig
	$(MAKE) -C $(NEMU_HOME) -j$(NPROC)
	$(MAKE) -C $(NEMU_HOME) run $(if $(IMG),IMG=$(IMG)) ARGS="$(DEVICE_ARGS)"

# --- RV64 NEMU targets ---
config-nemu64: ## Configure NEMU (riscv64)
	$(MAKE) -C $(NEMU_HOME) $(NEMU64_DEFCONFIG)
	$(MAKE) -C $(NEMU_HOME) -j$(NPROC)

config-nemu64-ref:
	$(MAKE) -C $(NEMU_HOME) riscv64_ref_defconfig
	$(MAKE) -C $(NEMU_HOME) -j$(NPROC)

build-nemu64: config-nemu64 ## Build NEMU (riscv64)
	$(MAKE) -C $(NEMU_HOME) -j$(NPROC)

run-nemu64: build-nemu64 ## Build and run NEMU (riscv64)
	$(MAKE) -C $(NEMU_HOME) run $(if $(IMG),IMG=$(IMG)) ARGS="$(ARGS) $(NEMU_DISK_ARG) $(NEMU_SDCARD_ARG)"

config-nemu64-linux:
	$(MAKE) -C $(NEMU_HOME) riscv64_linux_defconfig
	$(MAKE) -C $(NEMU_HOME) -j$(NPROC)

config-nemu64-linux-device:
	$(MAKE) -C $(NEMU_HOME) riscv64_linux_device_defconfig
	$(MAKE) -C $(NEMU_HOME) -j$(NPROC)

run-nemu64-linux-device: ## Run NEMU RV64 with VGA screen + keyboard
	$(MAKE) -C $(NEMU_HOME) riscv64_linux_device_defconfig
	$(MAKE) -C $(NEMU_HOME) -j$(NPROC)
	$(MAKE) -C $(NEMU_HOME) run $(if $(IMG),IMG=$(IMG)) ARGS="$(DEVICE_ARGS)"

# --- Spike-diff reference (for NEMU --diff= self-difftest) ---
# Builds tools/spike-diff/build/riscv{32,64}-spike-so. First-time build is slow
# (clones riscv-isa-sim, compiles spike); subsequent invocations are cached.
SPIKE_DIFF_SO32 := $(NEMU_HOME)/tools/spike-diff/build/riscv32-spike-so
SPIKE_DIFF_SO64 := $(NEMU_HOME)/tools/spike-diff/build/riscv64-spike-so

build-spike-diff32: ## Build spike-diff reference SO for RV32 (used by NEMU --diff)
	@test -f $(SPIKE_DIFF_SO32) || \
		$(MAKE) -C $(NEMU_HOME)/tools/spike-diff CONFIG_RV64= GUEST_ISA=riscv

build-spike-diff64: ## Build spike-diff reference SO for RV64 (used by NEMU --diff)
	@test -f $(SPIKE_DIFF_SO64) || \
		$(MAKE) -C $(NEMU_HOME)/tools/spike-diff CONFIG_RV64=y GUEST_ISA=riscv

# --- NEMU + spike-diff combined configs ---
# Build NEMU as a standalone binary with CONFIG_DIFFTEST=y + CONFIG_DIFFTEST_REF_SPIKE=y
# so that `--diff=…/riscv{32,64}-spike-so` is actually honored at runtime.
# These targets also build the spike-diff SO so the wildcard auto-detect in
# app/pk/Makefile finds it. Use these for `*-nemu{32,64}` runs that need
# instruction-level cross-check against spike.
config-nemu32-difftest: build-spike-diff32 ## Configure NEMU RV32 binary with spike-diff enabled
	$(MAKE) -C $(NEMU_HOME) riscv32_difftest_defconfig
	$(MAKE) -C $(NEMU_HOME) -j$(NPROC)

config-nemu64-difftest: build-spike-diff64 ## Configure NEMU RV64 binary with spike-diff enabled
	$(MAKE) -C $(NEMU_HOME) riscv64_difftest_defconfig
	$(MAKE) -C $(NEMU_HOME) -j$(NPROC)

.PHONY: build-spike-diff32 build-spike-diff64 config-nemu32-difftest config-nemu64-difftest

# ============================================================================
# NPC Simulation Targets
# ============================================================================
NPC_DEFCONFIG ?= o2_defconfig ## NPC simulator defconfig profile
NPC_ARCH ?= riscv32-npc ## Override ARCH for AM targets
YSYXSOC_ARCH ?= riscv32-ysyxsoc ## Override ARCH for ysyxSoC targets

# RV64 mode: set via `make run-npc64` or explicitly `make run-npc32 VFLAGS="-DRAPT_RV64"`.
# NSIM Verilator simulation enables RTL assertions by default via RAPT_SIM_ASSERT;
# pack/STA/FPGA synthesis paths do not receive the default assertion define.
VFLAGS ?= ## Extra RTL defines for NPC (-DRAPT_RV64, etc.)
RAPT_SIM_ASSERT ?= 1## Enable RTL SVA assertions by default in NPC Verilator simulation (1=on, 0=off)
RAPT_SIM_ASSERT := $(strip $(RAPT_SIM_ASSERT))
export RAPT_SIM_ASSERT

config-npc32: ## Configure NPC simulator (o2 default)
	@$(MAKE) --no-print-directory -C $(NSIM_HOME) $(NPC_DEFCONFIG)

config-npc32-difftest:
	$(MAKE) -C $(NSIM_HOME) o2_difftest_defconfig
	$(MAKE) -C $(NSIM_HOME) -j$(NPROC)

config-npc32-linux:
	$(MAKE) -C $(NSIM_HOME) o2linux_defconfig
	$(MAKE) -C $(NSIM_HOME) -j$(NPROC)

config-npc32-linux-difftest:
	$(MAKE) -C $(NSIM_HOME) o2linux_difftest_defconfig
	$(MAKE) -C $(NSIM_HOME) -j$(NPROC)

config-npc32-ysyxsoc:
	$(MAKE) -C $(NSIM_HOME) o2soc_defconfig
	$(MAKE) -C $(NSIM_HOME) -j$(NPROC)

menuconfig-npc32: ## Open NPC menuconfig
	$(MAKE) -C $(NSIM_HOME) menuconfig
	$(MAKE) -C $(NSIM_HOME) -j$(NPROC)

# Auto-generate RTL from Chisel if generated/ doesn't exist
GENERATED_DIR := $(RAPTOR_HOME)/rtl_sv/generated

$(GENERATED_DIR):
	$(MAKE) verilog

build-npc32: config-npc32 | $(GENERATED_DIR) ## Build NPC simulator
	@$(MAKE) --no-print-directory -q -C $(NSIM_HOME) VFLAGS="$(VFLAGS)" 2>/dev/null \
		|| $(MAKE) --no-print-directory -C $(NSIM_HOME) -j$(NPROC) VFLAGS="$(VFLAGS)"

run-npc32: build-npc32 ## Build and run NPC simulator
	$(MAKE) -C $(NSIM_HOME) run ARGS="$(ARGS)" VFLAGS="$(VFLAGS)" $(if $(IMG),IMG=$(IMG)) $(if $(DISK),DISK=$(DISK)) $(if $(SDCARD),SDCARD=$(SDCARD))

sim-npc32: verilog config-npc32 build-npc32 ## Full pipeline: verilog + config + build + run
	$(MAKE) -C $(NSIM_HOME) run ARGS="$(ARGS)" VFLAGS="$(VFLAGS)" $(if $(IMG),IMG=$(IMG)) $(if $(DISK),DISK=$(DISK)) $(if $(SDCARD),SDCARD=$(SDCARD))

# --- RV64 convenience targets (equivalent to VFLAGS="-DRAPT_RV64") ---
build-npc64: VFLAGS := -DRAPT_RV64
build-npc64: build-npc32 ## Build NPC in RV64 mode

run-npc64: VFLAGS := -DRAPT_RV64
run-npc64: run-npc32 ## Build and run NPC in RV64 mode

lint-npc64: VFLAGS := -DRAPT_RV64
lint-npc64: lint ## Lint RTL in RV64 mode

# ============================================================================
# AM Kernels / Benchmarks
# ============================================================================
AM_KERNELS = $(RAPTOR_HOME)/abstract-machine/app/am-kernels

$(AM_KERNELS):
	mkdir -p $(abspath $(AM_KERNELS))
	git clone --depth 1 https://github.com/kingfish404/am-kernels $(AM_KERNELS)

MAINARGS ?= test ## Benchmark arguments (test/train/ref)

coremark-nemu32: $(AM_KERNELS) config-nemu32 ## Run CoreMark on NEMU (riscv32)
	@mkdir -p $(NEMU_LOG_DIR)
	@set -o pipefail; $(MAKE) -C $(AM_KERNELS)/benchmarks/coremark_eembc ARCH=riscv32-nemu run ARGS="$(ARGS)" $(call tee_nemu,coremark-nemu32)

microbench-nemu32: $(AM_KERNELS) config-nemu32 ## Run MicroBench on NEMU (riscv32)
	@mkdir -p $(NEMU_LOG_DIR)
	@set -o pipefail; $(MAKE) -C $(AM_KERNELS)/benchmarks/microbench ARCH=riscv32-nemu run ARGS="$(ARGS)" mainargs=$(MAINARGS) $(call tee_nemu,microbench-nemu32-$(MAINARGS))

coremark-nemu64: $(AM_KERNELS) config-nemu64 ## Run CoreMark on NEMU (riscv64)
	@mkdir -p $(NEMU_LOG_DIR)
	@set -o pipefail; $(MAKE) -C $(AM_KERNELS)/benchmarks/coremark_eembc ARCH=riscv64-nemu run ARGS="$(ARGS)" $(call tee_nemu,coremark-nemu64)

microbench-nemu64: $(AM_KERNELS) config-nemu64 ## Run MicroBench on NEMU (riscv64)
	@mkdir -p $(NEMU_LOG_DIR)
	@set -o pipefail; $(MAKE) -C $(AM_KERNELS)/benchmarks/microbench ARCH=riscv64-nemu run ARGS="$(ARGS)" mainargs=$(MAINARGS) $(call tee_nemu,microbench-nemu64-$(MAINARGS))

am-tests-nemu32: build-nemu32
	@mkdir -p $(NEMU_LOG_DIR)
	@set -o pipefail; $(MAKE) -C $(AM_KERNELS)/tests/am-tests ARCH=riscv32-nemu run ARGS="$(ARGS)" mainargs="i" VME=1 $(call tee_nemu,am-tests-nemu32)

am-tests-npc32: build-npc32
	@mkdir -p $(NPC_LOG_DIR)
	@set -o pipefail; $(MAKE) -C $(AM_KERNELS)/tests/am-tests ARCH=$(NPC_ARCH) run ARGS="$(ARGS)" mainargs="i" VME=1 $(call tee_npc,am-tests-npc32)

CPU_TESTS_DIR := $(AM_KERNELS)/tests/cpu-tests
CPU_TESTS     := $(basename $(notdir $(wildcard $(CPU_TESTS_DIR)/tests/*.c)))

# Parallel cpu-tests runner.
# 1. Build all per-test .bin files sequentially (shares AM lib state).
# 2. Run resulting .bin files concurrently via xargs -P $(JOBS).
# Args (positional, all shell-quoted internally):
#   $(1) suite label (e.g. npc32 / nemu32) - used in log header
#   $(2) shell expression producing the simulator command (binary + base args)
#   $(3) AM ARCH for the test build (riscv32-npc / riscv32-nemu / ...)
#   $(4) absolute log file path for tee'ing aggregate output
define run_cpu_tests_parallel
	{ \
	  arch="$(strip $(3))"; \
	  echo "=== cpu-tests-$(1): building $(words $(CPU_TESTS)) tests (sequential) ==="; \
	  cd $(CPU_TESTS_DIR); \
	  for t in $(CPU_TESTS); do \
	    printf 'NAME = %s\nSRCS = tests/%s.c\ninclude $${AM_HOME}/Makefile\n' "$$t" "$$t" > Makefile.$$t; \
	    $(MAKE) -s -f Makefile.$$t ARCH=$$arch CROSS_COMPILE=$(CROSS_COMPILE) image >/dev/null 2>&1 \
	      || echo "[cpu-tests-$(1)] BUILD FAIL: $$t"; \
	  done; \
	  rm -f Makefile.*; \
	  SIM_CMD=$(2); \
	  echo "=== cpu-tests-$(1): running in parallel (JOBS=$(JOBS)) ==="; \
	  ( for t in $(CPU_TESTS); do \
	      bin="$(CPU_TESTS_DIR)/build/$$t-$$arch.bin"; \
	      [ -f "$$bin" ] && printf '%s|%s\n' "$$t" "$$bin"; \
	    done ) \
	  | SIM_CMD="$$SIM_CMD" SIM_ARGS="$(ARGS)" NSIM_HOME="$(NSIM_HOME)" \
	    xargs -P $(JOBS) -n1 sh -c ' \
	      line="$$1"; name="$${line%%|*}"; bin="$${line#*|}"; \
	      out=$$(cd "$$NSIM_HOME" && $$SIM_CMD $$SIM_ARGS "$$bin" 2>&1); \
	      rc=$$?; \
	      if [ $$rc -eq 0 ] && echo "$$out" | grep -q "HIT GOOD TRAP"; then \
	        printf "[%18s] \033[1;32mPASS\033[0m\n" "$$name"; \
	      else \
	        printf "[%18s] \033[1;31mFAIL\033[0m (rc=%d)\n" "$$name" $$rc; \
	      fi' _; \
	  echo "=== cpu-tests-$(1): done ==="; \
	} 2>&1 | tee $(4)
endef

cpu-tests-nemu32: build-nemu32 ## Run AM cpu-tests on NEMU (sequential; NEMU is not concurrency-safe here)
	@mkdir -p $(NEMU_LOG_DIR)
	@set -o pipefail; $(MAKE) -C $(AM_KERNELS)/tests/cpu-tests ARCH=riscv32-nemu run ARGS="$(ARGS)" mainargs="i" VME=1 $(call tee_nemu,cpu-tests-nemu32)

cpu-tests-npc32: build-npc32 ## Run AM cpu-tests on NPC (parallel)
	@mkdir -p $(NPC_LOG_DIR)
	@set -o pipefail; \
	  NPC_CMD=$$($(MAKE) --no-print-directory -C $(NSIM_HOME) VFLAGS="$(VFLAGS)" print-npc-exec) \
	    || { echo "[cpu-tests-npc32] ERROR: print-npc-exec failed"; exit 1; }; \
	  $(call run_cpu_tests_parallel,npc32,"$$NPC_CMD",$(NPC_ARCH),$(NPC_LOG_DIR)/cpu-tests-npc32.log)

# --- Bare-metal IRQ tests (PLIC, etc) -------------------------------------
# Each test is a standalone M-mode .bin loaded directly at 0x80000000 via
# the nsim positional IMG argument. No pk/AM dependency.
IRQ_TESTS_DIR  := $(RAPTOR_HOME)/app/build/rv32/tests/irq
IRQ_TESTS_SRC_DIR := $(RAPTOR_HOME)/app/tests/irq
IRQ_TESTS      := $(notdir $(basename $(wildcard $(IRQ_TESTS_SRC_DIR)/*.c)))

irq-tests-build: ## Build bare-metal PLIC IRQ tests
	$(MAKE) -C $(RAPTOR_HOME)/app/tests/irq build

irq-tests-npc32: build-npc32 irq-tests-build ## Build & run bare-metal PLIC IRQ tests on NPC (parallel)
	@mkdir -p $(NPC_LOG_DIR)
	@set -o pipefail; \
	  NPC_CMD=$$($(MAKE) --no-print-directory -C $(NSIM_HOME) VFLAGS="$(VFLAGS)" print-npc-exec) \
	    || { echo "[irq-tests-npc32] ERROR: print-npc-exec failed"; exit 1; }; \
	  { \
	    echo "=== IRQ tests (bare-metal, parallel JOBS=$(JOBS)) ==="; \
	    ( for t in $(IRQ_TESTS); do printf '%s|%s\n' "$$t" "$(IRQ_TESTS_DIR)/$$t.bin"; done ) \
	    | NPC_CMD="$$NPC_CMD" SIM_ARGS="$(ARGS)" NSIM_HOME="$(NSIM_HOME)" \
	      xargs -P $(JOBS) -n1 sh -c ' \
	        line="$$1"; name="$${line%%|*}"; bin="$${line#*|}"; \
	        out=$$(cd "$$NSIM_HOME" && $$NPC_CMD $$SIM_ARGS "$$bin" 2>&1); \
	        rc=$$?; \
	        if [ $$rc -eq 0 ] && echo "$$out" | grep -q "HIT GOOD TRAP"; then \
	          printf "[%30s] \033[1;32mPASS\033[0m\n" "$$name"; \
	        else \
	          printf "[%30s] \033[1;31mFAIL\033[0m (rc=%d)\n" "$$name" $$rc; \
	          echo "$$out" | tail -10 | sed "s/^/    /"; \
	          exit 1; \
	        fi' _; \
	    rc=$$?; \
	    if [ $$rc -eq 0 ]; then echo "=== IRQ tests: ALL PASSED ==="; \
	    else echo "=== IRQ tests: FAILURES ==="; exit $$rc; fi; \
	  } $(call tee_npc,irq-tests-npc32)

irq-tests-npc32-difftest: config-npc32-difftest config-nemu32-ref irq-tests-build ## Build & run bare-metal PLIC IRQ tests on NPC with difftest (parallel)
	@mkdir -p $(NPC_LOG_DIR)
	@set -o pipefail; \
	  NPC_CMD=$$($(MAKE) --no-print-directory -C $(NSIM_HOME) VFLAGS="$(VFLAGS)" print-npc-exec) \
	    || { echo "[irq-tests-npc32-difftest] ERROR: print-npc-exec failed"; exit 1; }; \
	  { \
	    echo "=== IRQ tests (bare-metal, difftest, parallel JOBS=$(JOBS)) ==="; \
	    ( for t in $(IRQ_TESTS); do printf '%s|%s\n' "$$t" "$(IRQ_TESTS_DIR)/$$t.bin"; done ) \
	    | NPC_CMD="$$NPC_CMD" SIM_ARGS="$(ARGS)" NSIM_HOME="$(NSIM_HOME)" \
	      xargs -P $(JOBS) -n1 sh -c ' \
	        line="$$1"; name="$${line%%|*}"; bin="$${line#*|}"; \
	        out=$$(cd "$$NSIM_HOME" && $$NPC_CMD $$SIM_ARGS "$$bin" 2>&1); \
	        rc=$$?; \
	        if [ $$rc -eq 0 ] && echo "$$out" | grep -q "HIT GOOD TRAP"; then \
	          printf "[%30s] \033[1;32mPASS\033[0m\n" "$$name"; \
	        else \
	          printf "[%30s] \033[1;31mFAIL\033[0m (rc=%d)\n" "$$name" $$rc; \
	          echo "$$out" | tail -10 | sed "s/^/    /"; \
	          exit 1; \
	        fi' _; \
	    rc=$$?; \
	    if [ $$rc -eq 0 ]; then echo "=== IRQ tests (difftest): ALL PASSED ==="; \
	    else echo "=== IRQ tests (difftest): FAILURES ==="; exit $$rc; fi; \
	  } $(call tee_npc,irq-tests-npc32-difftest)

# --- Minimal Linux-pattern repros -----------------------------------------
REPRO_TESTS_DIR := $(RAPTOR_HOME)/app/build/rv32/tests/repro

repro-tests-build: ## Build bare-metal minimal repro tests
	$(MAKE) -C $(RAPTOR_HOME)/app/tests/repro build

linux-ticket-spinlock-repro-npc32: build-npc32 repro-tests-build ## Run Linux ticket-spinlock AMO/SH/LW repro on NPC
	$(MAKE) --no-print-directory -C $(NSIM_HOME) run \
		ARGS="$(ARGS)" VFLAGS="$(VFLAGS)" \
		IMG=$(REPRO_TESTS_DIR)/linux_ticket_spinlock.bin

coremark-npc32: $(AM_KERNELS) config-npc32 ## Run CoreMark on NPC
	@mkdir -p $(NPC_LOG_DIR)
	@set -o pipefail; $(MAKE) -C $(AM_KERNELS)/benchmarks/coremark_eembc ARCH=$(NPC_ARCH) run ARGS="$(ARGS)" $(call tee_npc,coremark-npc32)

coremark-npc32-difftest: $(AM_KERNELS) config-npc32-difftest config-nemu32-ref ## Run CoreMark on NPC with difftest
	@mkdir -p $(NPC_LOG_DIR)
	@set -o pipefail; $(MAKE) -C $(AM_KERNELS)/benchmarks/coremark_eembc ARCH=$(NPC_ARCH) run ARGS="$(ARGS)" mainargs=test $(call tee_npc,coremark-npc32-difftest)

coremark-ysyxsoc: $(AM_KERNELS) config-npc32-ysyxsoc config-nemu32-ref ## Run CoreMark on ysyxSoC
	@mkdir -p $(NPC_LOG_DIR)
	@set -o pipefail; $(MAKE) -C $(AM_KERNELS)/benchmarks/coremark_eembc ARCH=$(YSYXSOC_ARCH) run ARGS="$(ARGS)" mainargs=test $(call tee_npc,coremark-ysyxsoc)

microbench-npc32: $(AM_KERNELS) config-npc32 ## Run MicroBench on NPC
	@mkdir -p $(NPC_LOG_DIR)
	@set -o pipefail; $(MAKE) -C $(AM_KERNELS)/benchmarks/microbench ARCH=$(NPC_ARCH) run ARGS="$(ARGS)" mainargs=$(MAINARGS) $(call tee_npc,microbench-npc32-$(MAINARGS))

micorbench-npc32-difftest: $(AM_KERNELS) config-npc32-difftest config-nemu32-ref ## Run MicroBench on NPC with difftest (typo compat)
	@mkdir -p $(NPC_LOG_DIR)
	@set -o pipefail; $(MAKE) -C $(AM_KERNELS)/benchmarks/microbench ARCH=$(NPC_ARCH) run ARGS="$(ARGS)" mainargs=$(MAINARGS) $(call tee_npc,microbench-npc32-difftest-$(MAINARGS))

# --- RV64 benchmark targets ---
coremark-npc64: VFLAGS := -DRAPT_RV64
coremark-npc64: $(AM_KERNELS) config-npc32 ## Run CoreMark on NPC (riscv64)
	@mkdir -p $(NPC_LOG_DIR)
	@set -o pipefail; $(MAKE) -C $(AM_KERNELS)/benchmarks/coremark_eembc ARCH=riscv64-npc run ARGS="$(ARGS)" VFLAGS="$(VFLAGS)" $(call tee_npc,coremark-npc64)

coremark-npc64-difftest: VFLAGS := -DRAPT_RV64
coremark-npc64-difftest: $(AM_KERNELS) config-npc32-difftest config-nemu64-ref ## Run CoreMark on NPC (riscv64) with difftest
	@mkdir -p $(NPC_LOG_DIR)
	@set -o pipefail; $(MAKE) -C $(AM_KERNELS)/benchmarks/coremark_eembc ARCH=riscv64-npc run ARGS="$(ARGS)" VFLAGS="$(VFLAGS)" $(call tee_npc,coremark-npc64-difftest)

microbench-npc64: VFLAGS := -DRAPT_RV64
microbench-npc64: $(AM_KERNELS) config-npc32 ## Run MicroBench on NPC (riscv64)
	@mkdir -p $(NPC_LOG_DIR)
	@set -o pipefail; $(MAKE) -C $(AM_KERNELS)/benchmarks/microbench ARCH=riscv64-npc run ARGS="$(ARGS)" VFLAGS="$(VFLAGS)" mainargs=$(MAINARGS) $(call tee_npc,microbench-npc64-$(MAINARGS))

microbench-npc64-difftest: VFLAGS := -DRAPT_RV64
microbench-npc64-difftest: $(AM_KERNELS) config-npc32-difftest config-nemu64-ref ## Run MicroBench on NPC (riscv64) with difftest
	@mkdir -p $(NPC_LOG_DIR)
	@set -o pipefail; $(MAKE) -C $(AM_KERNELS)/benchmarks/microbench ARCH=riscv64-npc run ARGS="$(ARGS)" VFLAGS="$(VFLAGS)" mainargs=$(MAINARGS) $(call tee_npc,microbench-npc64-difftest-$(MAINARGS))

microbench-npc32-difftest: $(AM_KERNELS) config-npc32-difftest config-nemu32-ref ## Run MicroBench on NPC with difftest
	@mkdir -p $(NPC_LOG_DIR)
	@set -o pipefail; $(MAKE) -C $(AM_KERNELS)/benchmarks/microbench ARCH=$(NPC_ARCH) run ARGS="$(ARGS)" mainargs=$(MAINARGS) $(call tee_npc,microbench-npc32-difftest-$(MAINARGS))

microbench-ysyxsoc: $(AM_KERNELS) config-npc32-ysyxsoc config-nemu32-ref ## Run MicroBench on ysyxSoC
	@mkdir -p $(NPC_LOG_DIR)
	@set -o pipefail; $(MAKE) -C $(AM_KERNELS)/benchmarks/microbench ARCH=$(YSYXSOC_ARCH) run ARGS="$(ARGS)" mainargs=test $(call tee_npc,microbench-ysyxsoc)

# --- RISC-V Architecture Tests ---
RISCV_ARCH_TEST ?= $(RAPTOR_HOME)/third_party/kingfish404/riscv-arch-test-am

$(RISCV_ARCH_TEST):
	git clone --depth 1 https://github.com/Kingfish404/riscv-arch-test-am $@

archtest-npc32: build-npc32 $(RISCV_ARCH_TEST) ## Run RISC-V Architecture Test on NPC (riscv32)
	@mkdir -p $(NPC_LOG_DIR)
	@set -o pipefail; $(MAKE) -C $(RISCV_ARCH_TEST) ARCH=$(NPC_ARCH) run ARGS="$(ARGS)" $(call tee_npc,archtest-npc32)

archtest-npc32e: build-npc32 $(RISCV_ARCH_TEST) ## Run RISC-V Architecture Test on NPC (riscv32e)
	@mkdir -p $(NPC_LOG_DIR)
	@set -o pipefail; $(MAKE) -C $(RISCV_ARCH_TEST) ARCH=riscv32e-npc run ARGS="$(ARGS)" $(call tee_npc,archtest-npc32e)

# ============================================================================
# Nanos-lite OS
# ============================================================================
ISA ?= riscv32 ## ISA for nanos-lite targets

nanos-nemu32: ## Build and run nanos-lite on NEMU
	$(MAKE) -C $(NAVY_HOME) ISA=$(ISA) fsimg
	$(MAKE) -C $(NAVY_HOME)/apps/menu ISA=$(ISA) install
	$(MAKE) -C $(RAPTOR_HOME)/abstract-machine/app/nanos-lite ARCH=$(ISA)-nemu update run

nanos-npc32: ## Build and run nanos-lite on NPC
	$(MAKE) -C $(NAVY_HOME) ISA=$(ISA) fsimg
	$(MAKE) -C $(NAVY_HOME)/apps/menu ISA=$(ISA) install
	$(MAKE) -C $(RAPTOR_HOME)/abstract-machine/app/nanos-lite ARCH=$(ISA)-npc update run

# ============================================================================
# Linux Kernel Boot (via OpenSBI on NEMU)
# ============================================================================

# Delegate download/version management to linux/Makefile (single source of truth).
LINUX_HOME          := $(RAPTOR_HOME)/linux
include $(LINUX_HOME)/vars.mk

linux-download-rv32: ## Download pre-built Linux (RV32 only)
	$(MAKE) -C $(LINUX_HOME) download-rv32

linux-download-rv64: ## Download pre-built Linux (RV64 only)
	$(MAKE) -C $(LINUX_HOME) download-rv64

linux-download: ## Download pre-built Linux (RV32 + RV64)
	$(MAKE) -C $(LINUX_HOME) download

linux-boot-nemu32: config-nemu32-linux ## Boot Linux on NEMU (riscv32)
	$(MAKE) -C $(LINUX_HOME) download-rv32
	$(MAKE) -C $(NEMU_HOME) -j$(NPROC)
	@mkdir -p $(NEMU_LOG_DIR)
	@set -o pipefail; $(MAKE) -C $(NEMU_HOME) run IMG=$(LINUX_RV32_PAYLOAD) ARGS="$(ARGS) $(if $(MAX_INST),-m $(MAX_INST))" $(call tee_nemu,linux-boot-nemu32)

linux-boot-nemu64: config-nemu64-linux ## Boot Linux on NEMU (riscv64)
	$(MAKE) -C $(LINUX_HOME) download-rv64
	$(MAKE) -C $(NEMU_HOME) -j$(NPROC)
	@mkdir -p $(NEMU_LOG_DIR)
	@set -o pipefail; $(MAKE) -C $(NEMU_HOME) run IMG=$(LINUX_RV64_PAYLOAD) ARGS="$(ARGS) $(if $(MAX_INST),-m $(MAX_INST))" $(call tee_nemu,linux-boot-nemu64)

linux-boot-npc32: config-npc32-linux ## Boot Linux on NPC (riscv32)
	$(MAKE) -C $(LINUX_HOME) download-rv32
	$(MAKE) -C $(NSIM_HOME) -j$(NPROC)
	@mkdir -p $(NPC_LOG_DIR)
	@set -o pipefail; $(MAKE) -C $(NSIM_HOME) run IMG=$(LINUX_RV32_PAYLOAD) ARGS="$(ARGS) $(if $(MAX_INST),-m $(MAX_INST))" $(call tee_npc,linux-boot-npc32)

linux-boot-npc32-difftest: config-npc32-linux-difftest config-nemu32-ref ## Boot Linux on NPC with difftest
	$(MAKE) -C $(LINUX_HOME) download-rv32
	$(MAKE) -C $(NSIM_HOME) -j$(NPROC)
	@mkdir -p $(NPC_LOG_DIR)
	@set -o pipefail; $(MAKE) -C $(NSIM_HOME) run IMG=$(LINUX_RV32_PAYLOAD) ARGS="$(ARGS) $(if $(MAX_INST),-m $(MAX_INST))" $(call tee_npc,linux-boot-npc32-difftest)

linux-boot-npc64: VFLAGS := -DRAPT_RV64
linux-boot-npc64: config-npc32-linux ## Boot Linux on NPC (riscv64)
	$(MAKE) -C $(LINUX_HOME) download-rv64
	$(MAKE) -C $(NSIM_HOME) -j$(NPROC) VFLAGS="$(VFLAGS)"
	@mkdir -p $(NPC_LOG_DIR)
	@set -o pipefail; $(MAKE) -C $(NSIM_HOME) run IMG=$(LINUX_RV64_PAYLOAD) ARGS="$(ARGS) $(if $(MAX_INST),-m $(MAX_INST))" VFLAGS="$(VFLAGS)" $(call tee_npc,linux-boot-npc64)

linux-boot-npc64-difftest: VFLAGS := -DRAPT_RV64
linux-boot-npc64-difftest: config-npc32-linux-difftest config-nemu64-ref ## Boot Linux on NPC RV64 with difftest
	$(MAKE) -C $(LINUX_HOME) download-rv64
	$(MAKE) -C $(NSIM_HOME) -j$(NPROC) VFLAGS="$(VFLAGS)"
	@mkdir -p $(NPC_LOG_DIR)
	@set -o pipefail; $(MAKE) -C $(NSIM_HOME) run IMG=$(LINUX_RV64_PAYLOAD) ARGS="$(ARGS) $(if $(MAX_INST),-m $(MAX_INST))" VFLAGS="$(VFLAGS)" $(call tee_npc,linux-boot-npc64-difftest)

linux-boot-nemu32-device: config-nemu32-linux-device ## Boot Linux on NEMU RV32 (auto-download)
	$(MAKE) -C $(LINUX_HOME) download-rv32
	$(MAKE) -C $(NEMU_HOME) run IMG=$(LINUX_RV32_PAYLOAD) ARGS="$(DEVICE_ARGS)"

linux-boot-nemu32-device-difftest: config-nemu32-linux-device ## Boot Linux on NEMU RV32 (auto-download)
	$(MAKE) -C $(LINUX_HOME) download-rv32
	$(MAKE) -C $(NEMU_HOME) run IMG=$(LINUX_RV32_PAYLOAD) ARGS="$(DEVICE_ARGS)"

linux-boot-nemu64-device: config-nemu64-linux-device ## Boot Linux on NEMU RV64 (auto-download)
	$(MAKE) -C $(LINUX_HOME) download-rv64
	$(MAKE) -C $(NEMU_HOME) run IMG=$(LINUX_RV64_PAYLOAD) ARGS="$(DEVICE_ARGS)"

# ----------------------------------------------------------------------------
# Linux boot checkpoint save/restore (architectural snapshot of nsim).
# Saves arch state + memory at a chosen cycle, restores via an MROM trampoline
# that re-runs through real lw/csrw/mret instructions. Pure architectural
# checkpoint — survives RTL/microarch changes.
# ----------------------------------------------------------------------------
CKPT_DIR   ?= $(RAPTOR_HOME)/nsim/data/ckpt-linux-rv32 ## Checkpoint directory (save target / load source)
CKPT_CYCLE ?= 1000000 ## Cycle at which to take the checkpoint

linux-boot-npc32-ckpt-save: config-npc32-linux ## Boot Linux on NPC, save checkpoint at CKPT_CYCLE -> CKPT_DIR
	$(MAKE) -C $(LINUX_HOME) download-rv32
	$(MAKE) -C $(NSIM_HOME) -j$(NPROC)
	rm -rf $(CKPT_DIR)
	$(MAKE) -C $(NSIM_HOME) run IMG=$(LINUX_RV32_PAYLOAD) \
		ARGS="$(ARGS) --ckpt-cycle=$(CKPT_CYCLE) --ckpt-save=$(CKPT_DIR) --ckpt-save-exit"

linux-boot-npc32-ckpt-load: config-npc32-linux ## Resume Linux boot on NPC from CKPT_DIR
	$(MAKE) -C $(NSIM_HOME) -j$(NPROC)
	$(MAKE) -C $(NSIM_HOME) run IMG=$(LINUX_RV32_PAYLOAD) \
		ARGS="$(ARGS) --ckpt-load=$(CKPT_DIR) $(if $(MAX_INST),-m $(MAX_INST))"

# ============================================================================
# FPGA Targets
# ============================================================================
fpga-syn: ## Synthesize for Gowin Tang Nano 20K
	$(MAKE) -C $(RAPTOR_HOME)/fpga/gowin-tang-nano-20k syn

fpga-pnr: ## Place and route for FPGA
	$(MAKE) -C $(RAPTOR_HOME)/fpga/gowin-tang-nano-20k pnr

# ============================================================================
# Utilities
# ============================================================================
pack: ## Pack all SV files into one
	$(MAKE) -C $(NSIM_HOME) pack VFLAGS="$(VFLAGS)"

lint: ## Lint RTL with Verilator
	$(MAKE) -C $(NSIM_HOME) lint VFLAGS="$(VFLAGS)"

lint-verible: ## Lint RTL with Verible
	$(MAKE) -C $(NSIM_HOME) lint-verible

ide-setup: compile-commands ## Generate compile_commands.json for IDE/LSP setup
	@echo "[ide-setup] compile_commands.json refreshed at $(RAPTOR_HOME)/compile_commands.json"
	@echo "[ide-setup] clangd-based editors will pick it up via .clangd"
	@echo "[ide-setup] VS Code can open raptor-chip.code-workspace"

compile-commands: ## Generate root compile_commands.json from real NEMU+NSIM build commands
	bash $(RAPTOR_HOME)/.github/scripts/gen_compile_commands.sh

STA_PLATFORM ?= nangate45 ## STA platform: nangate45, asap7, sky130hd
CLK_FREQ_MHZ ?= 50 ## Target clock frequency for STA (MHz)

sta: ## Static timing analysis (VFLAGS="-DRAPT_RV64" for RV64)
	$(MAKE) -C $(NSIM_HOME) sta STA_PLATFORM=$(STA_PLATFORM) CLK_FREQ_MHZ=$(CLK_FREQ_MHZ) VFLAGS="$(VFLAGS)"

sta-detail: ## Detailed static timing analysis (VFLAGS="-DRAPT_RV64" for RV64)
	$(MAKE) -C $(NSIM_HOME) sta-detail STA_PLATFORM=$(STA_PLATFORM) CLK_FREQ_MHZ=$(CLK_FREQ_MHZ) VFLAGS="$(VFLAGS)"

# RV64 convenience targets for STA (half clock target — RV64 datapath is wider/slower)
sta-rv64: VFLAGS := -DRAPT_RV64
sta-rv64: CLK_FREQ_MHZ := 25
sta-rv64: sta ## Static timing analysis in RV64 mode

sta-detail-rv64: VFLAGS := -DRAPT_RV64
sta-detail-rv64: CLK_FREQ_MHZ := 25
sta-detail-rv64: sta-detail ## Detailed static timing analysis in RV64 mode

SRAM_PLATFORM ?= sky130 ## OpenRAM technology for SRAM macros (sky130, freepdk45)

sram-macros: ## Compile OpenRAM SRAM macros for cache data arrays (see nsim/sram/README.md)
	$(MAKE) -C $(NSIM_HOME) sram-macros SRAM_PLATFORM=$(SRAM_PLATFORM)

sram-stubs: ## Generate behavioural SRAM .lib/.v stubs (placeholder timing, no PDK needed)
	$(MAKE) -C $(NSIM_HOME) sram-stubs SRAM_PLATFORM=$(SRAM_PLATFORM)

sram-doctor: ## Diagnose OpenRAM / PDK / docker prerequisites
	$(MAKE) -C $(NSIM_HOME) sram-doctor SRAM_PLATFORM=$(SRAM_PLATFORM)

sram-test: ## Validate SRAM macro integration (configs/blackbox/RTL/.lib consistency)
	$(MAKE) -C $(NSIM_HOME)/sram test

sram-test-sta: ## Opt-in SRAM STA smoke (needs yosys+slang+OpenSTA)
	$(MAKE) -C $(NSIM_HOME)/sram test-sta

sta-sram: ## STA with OpenRAM SRAM macros (vs flop-array default)
	$(MAKE) -C $(NSIM_HOME) sta-sram \
	    STA_PLATFORM=$(STA_PLATFORM) CLK_FREQ_MHZ=$(CLK_FREQ_MHZ) \
	    SRAM_PLATFORM=$(SRAM_PLATFORM) VFLAGS="$(VFLAGS)"

sta-sram-detail: ## Detailed STA with OpenRAM SRAM macros
	$(MAKE) -C $(NSIM_HOME) sta-sram-detail \
	    STA_PLATFORM=$(STA_PLATFORM) CLK_FREQ_MHZ=$(CLK_FREQ_MHZ) \
	    SRAM_PLATFORM=$(SRAM_PLATFORM) VFLAGS="$(VFLAGS)"

clean-npc: ## Clean NPC build only
	$(MAKE) -C $(NSIM_HOME) clean

clean: ## Clean all build artifacts
	-$(MAKE) -C $(NEMU_HOME) clean 2>/dev/null || true
	-$(MAKE) -C $(NSIM_HOME) clean 2>/dev/null || true
	-$(MAKE) -C $(RAPTOR_HOME)/rtl_scala clean 2>/dev/null || true
	-$(MAKE) -C $(RAPTOR_HOME)/verify clean 2>/dev/null || true
	-$(MAKE) -C $(RAPTOR_HOME)/app clean 2>/dev/null || true

# ============================================================================
# Verification Suite (verify/)
# ============================================================================
VERIFY_HOME := $(RAPTOR_HOME)/verify

verify-fuzz: ## Random instruction fuzz with difftest
	@mkdir -p $(VERIFY_LOG_DIR)
	@set -o pipefail; $(MAKE) -C $(VERIFY_HOME) fuzz $(call tee_verify,fuzz)

verify-fuzz-inf: ## Continuous fuzz until Ctrl-C or failure
	@mkdir -p $(VERIFY_LOG_DIR)
	@set -o pipefail; $(MAKE) -C $(VERIFY_HOME) fuzz-inf $(call tee_verify,fuzz-inf)

verify-fuzz-replay: ## Replay the last failing fuzz-inf batch
	@mkdir -p $(VERIFY_LOG_DIR)
	@set -o pipefail; $(MAKE) -C $(VERIFY_HOME) fuzz-replay $(call tee_verify,fuzz-replay)

verify-sigtest: ## Signature-based ISA corner-case tests
	@mkdir -p $(VERIFY_LOG_DIR)
	@set -o pipefail; $(MAKE) -C $(VERIFY_HOME) sigtest $(call tee_verify,sigtest)

verify-riscof-classic: ## RISCOF classic compliance tests (legacy, no difftest)
	@mkdir -p $(VERIFY_LOG_DIR)
	@set -o pipefail; $(MAKE) -C $(VERIFY_HOME) riscof-classic $(call tee_verify,riscof-classic)

verify-riscof-classic-nemu: ## RISCOF classic compliance tests on NEMU reference
	@mkdir -p $(VERIFY_LOG_DIR)
	@set -o pipefail; $(MAKE) -C $(VERIFY_HOME) riscof-classic-nemu $(call tee_verify,riscof-classic-nemu)

verify-riscof: ## RISCOF official compliance tests
	@mkdir -p $(VERIFY_LOG_DIR)
	@set -o pipefail; $(MAKE) -C $(VERIFY_HOME) riscof $(call tee_verify,riscof)

verify-coverage: ## Verilator line/toggle coverage
	@mkdir -p $(VERIFY_LOG_DIR)
	@set -o pipefail; $(MAKE) -C $(VERIFY_HOME) coverage $(call tee_verify,coverage)

verify-all: ## Run all verification targets
	@mkdir -p $(VERIFY_LOG_DIR)
	@set -o pipefail; $(MAKE) -C $(VERIFY_HOME) all $(call tee_verify,all)

verify-clean: ## Clean verification artifacts
	$(MAKE) -C $(VERIFY_HOME) clean

# ============================================================================
# Standard Toolchain (app/, riscv-pk)
# ============================================================================
APP_HOME := $(RAPTOR_HOME)/app

app-run: build-npc32 ## [app] Run USER_ELF via pk on NPC
	@$(MAKE) --no-print-directory -C $(APP_HOME) pk-run USER_ELF=$(USER_ELF) ARGS="$(ARGS)"

app-run-nemu: build-nemu32 ## [app] Run USER_ELF via pk on NEMU
	@$(MAKE) --no-print-directory -C $(APP_HOME) nemu-run USER_ELF=$(USER_ELF) ARGS="$(ARGS)"

app-bbl-linux: build-npc32 ## [app] Boot Linux via BBL on NPC
	@$(MAKE) --no-print-directory -C $(APP_HOME) bbl-linux ARGS="$(ARGS)"

app-hello-npc32: build-npc32 ## [app] Hello world test via pk (rv32)
	@mkdir -p $(APP_LOG_DIR)
	@set -o pipefail; $(MAKE) --no-print-directory -C $(APP_HOME) hello-npc ARGS="$(ARGS)" $(call tee_app,hello-npc32)

app-coremark-npc32: build-npc32 ## [app] CoreMark via pk (rv32)
	@mkdir -p $(APP_LOG_DIR)
	@set -o pipefail; $(MAKE) --no-print-directory -C $(APP_HOME) coremark-npc ARGS="$(ARGS)" $(call tee_app,coremark-npc32)

app-coremark-nemu32: config-nemu32 ## [app] CoreMark via pk on NEMU (rv32)
	@mkdir -p $(APP_LOG_DIR)
	@set -o pipefail; $(MAKE) --no-print-directory -C $(APP_HOME) coremark-nemu ARGS="$(ARGS)" $(call tee_app,coremark-nemu32)

app-embench-npc32: build-npc32 ## [app] Embench-IoT via pk (rv32)
	@mkdir -p $(APP_LOG_DIR)
	@set -o pipefail; $(MAKE) --no-print-directory -C $(APP_HOME) embench-npc ARGS="$(ARGS)" $(call tee_app,embench-npc32)

app-embench-nemu32: config-nemu32 ## [app] Embench-IoT via pk on NEMU (rv32)
	@mkdir -p $(APP_LOG_DIR)
	@set -o pipefail; $(MAKE) --no-print-directory -C $(APP_HOME) embench-nemu ARGS="$(ARGS)" $(call tee_app,embench-nemu32)

app-llm-npc32: build-npc32 ## [app] LLM operator/infer/train benchmarks via pk (rv32)
	@mkdir -p $(APP_LOG_DIR)
	@set -o pipefail; $(MAKE) --no-print-directory -C $(APP_HOME) llm-bench-report-npc ARGS="$(ARGS)" $(call tee_app,llm-npc32)

app-llm-nemu32: config-nemu32 ## [app] LLM operator/infer/train benchmarks via pk on NEMU (rv32)
	@mkdir -p $(APP_LOG_DIR)
	@set -o pipefail; $(MAKE) --no-print-directory -C $(APP_HOME) llm-bench-report-nemu ARGS="$(ARGS)" $(call tee_app,llm-nemu32)

# --- app tests/demos on NPC ---
app-tests-npc32: build-npc32 ## [app] All tests via pk on NPC (rv32)
	@mkdir -p $(APP_LOG_DIR)
	@set -o pipefail; $(MAKE) --no-print-directory -C $(APP_HOME) tests-npc ARGS="$(ARGS)" $(call tee_app,tests-npc32)

app-tests-npc32-difftest: config-npc32-difftest config-nemu32-ref ## [app] All tests via pk on NPC with difftest
	@mkdir -p $(APP_LOG_DIR)
	@set -o pipefail; $(MAKE) --no-print-directory -C $(APP_HOME) tests-npc ARGS="$(ARGS)" $(call tee_app,tests-npc32-difftest)

app-demos-npc32: build-npc32 ## [app] All demos via pk on NPC (rv32)
	@mkdir -p $(APP_LOG_DIR)
	@set -o pipefail; $(MAKE) --no-print-directory -C $(APP_HOME) demos-npc ARGS="$(ARGS)" $(call tee_app,demos-npc32)

# --- app tests/demos on NEMU (default: with difftest) ---
app-tests-nemu32: config-nemu32 ## [app] All tests via pk on NEMU (rv32)
	@mkdir -p $(APP_LOG_DIR)
	@set -o pipefail; $(MAKE) --no-print-directory -C $(APP_HOME) tests-nemu ARGS="$(ARGS)" $(call tee_app,tests-nemu32)

app-demos-nemu32: config-nemu32 ## [app] All demos via pk on NEMU (rv32)
	@mkdir -p $(APP_LOG_DIR)
	@set -o pipefail; $(MAKE) --no-print-directory -C $(APP_HOME) demos-nemu ARGS="$(ARGS)" $(call tee_app,demos-nemu32)

# --- TinyOS / OS CLI helpers ---
tinyos-sync: ## [app] Clone or update egos-2000 and xv6-riscv under app/tinyos
	@$(MAKE) --no-print-directory -C $(APP_HOME) tinyos-sync

os-cli-qemu: ## [app] Enter upstream OS CLI on QEMU (OS=egos|xv6 or TINYOS_OS=egos|xv6)
	@$(MAKE) --no-print-directory -C $(APP_HOME) os-cli-qemu OS="$(OS)" TINYOS_OS="$(TINYOS_OS)" $(if $(QEMU),QEMU="$(QEMU)",)

egos-cli-qemu: ## [app] Enter egos CLI on QEMU
	@$(MAKE) --no-print-directory -C $(APP_HOME) egos-cli-qemu $(if $(QEMU),QEMU="$(QEMU)",)

xv6-cli-qemu: ## [app] Enter xv6 CLI on QEMU
	@$(MAKE) --no-print-directory -C $(APP_HOME) xv6-cli-qemu $(if $(QEMU),QEMU="$(QEMU)",)

os-cli-nsim: ## [app] Boot upstream OS image on NPC/nsim (OS=egos|xv6 or TINYOS_OS=egos|xv6)
	@$(MAKE) --no-print-directory -C $(APP_HOME) os-cli-nsim OS="$(OS)" TINYOS_OS="$(TINYOS_OS)" ARGS="$(ARGS)" MAX_INST="$(MAX_INST)" TIMEOUT="$(TIMEOUT)"

os-cli-nemu: ## [app] Boot upstream OS image on NEMU (OS=egos|xv6 or TINYOS_OS=egos|xv6)
	@$(MAKE) --no-print-directory -C $(APP_HOME) os-cli-nemu OS="$(OS)" TINYOS_OS="$(TINYOS_OS)" ARGS="$(ARGS)" MAX_INST="$(MAX_INST)"

egos-cli-nsim: ## [app] Boot upstream egos image on NPC/nsim
	@$(MAKE) --no-print-directory -C $(APP_HOME) egos-cli-nsim ARGS="$(ARGS)" MAX_INST="$(MAX_INST)" TIMEOUT="$(TIMEOUT)"

egos-cli-nemu: ## [app] Boot upstream egos image on NEMU
	@$(MAKE) --no-print-directory -C $(APP_HOME) egos-cli-nemu ARGS="$(ARGS)" MAX_INST="$(MAX_INST)"

xv6-cli-nsim: ## [app] Boot upstream xv6-riscv on NPC/nsim
	@$(MAKE) --no-print-directory -C $(APP_HOME) xv6-cli-nsim ARGS="$(ARGS)" MAX_INST="$(MAX_INST)" TIMEOUT="$(TIMEOUT)"

xv6-cli-nemu: ## [app] Boot upstream xv6-riscv on NEMU
	@$(MAKE) --no-print-directory -C $(APP_HOME) xv6-cli-nemu ARGS="$(ARGS)" MAX_INST="$(MAX_INST)"

app-pk-build: ## [app] Build riscv-pk
	@$(MAKE) --no-print-directory -C $(APP_HOME) pk-build

app-clean: ## [app] Clean app build artifacts
	@$(MAKE) --no-print-directory -C $(APP_HOME) clean

.PHONY: help setup verilog log logs-show logs-clean \
	config-nemu32 config-nemu32-linux config-nemu32-ref config-nemu32-linux-device menuconfig-nemu32 build-nemu32 run-nemu32 run-nemu32-linux run-nemu32-linux-device \
	config-nemu64 config-nemu64-ref config-nemu64-linux-device build-nemu64 run-nemu64 run-nemu64-linux-device \
	config-npc32 config-npc32-difftest config-npc32-linux config-npc32-ysyxsoc menuconfig-npc32 build-npc32 run-npc32 sim-npc32 \
	build-npc64 run-npc64 lint-npc64 \
	coremark-npc32 coremark-npc64 coremark-npc32-difftest coremark-ysyxsoc microbench-npc32 microbench-npc64 microbench-npc32-difftest microbench-ysyxsoc \
	coremark-nemu32 microbench-nemu32 coremark-nemu64 microbench-nemu64 \
	archtest-npc32 archtest-npc32e \
	nanos-nemu32 nanos-npc32 \
	linux-download linux-download-rv32 linux-download-rv64 \
	linux-boot-nemu32 linux-boot-npc32 linux-boot-npc32-difftest linux-boot-npc64 linux-boot-npc64-difftest linux-boot-nemu32-device linux-boot-nemu64-device \
	fpga-syn fpga-pnr pack lint ide-setup compile-commands sta clean-npc clean \
	verify-fuzz verify-fuzz-inf verify-fuzz-replay verify-sigtest verify-riscof verify-coverage verify-all verify-clean \
	tinyos-sync os-cli-qemu egos-cli-qemu xv6-cli-qemu os-cli-nsim os-cli-nemu egos-cli-nsim egos-cli-nemu xv6-cli-nsim xv6-cli-nemu \
	app-hello-npc32 app-coremark-npc32 app-coremark-nemu32 app-embench-npc32 app-embench-nemu32 app-llm-npc32 app-llm-nemu32 \
	app-tests-npc32 app-tests-npc32-difftest app-demos-npc32 \
	app-tests-nemu32 app-demos-nemu32 \
	app-run app-run-nemu app-pk-build app-clean \
	run-pk bbl-linux

# ============================================================================
# Local overrides (private synthesis targets, not tracked by Git)
# ============================================================================
# Copy Makefile.local.example -> Makefile.local and fill in site-specific values.
-include Makefile.local

endif # Guard: root-only targets
