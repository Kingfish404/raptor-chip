# ============================================================================
# Environment variables (auto-sourced from env.sh, no manual `source` needed)
# ============================================================================
export RAPTOR_HOME := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
export NEMU_HOME := $(RAPTOR_HOME)/nemu
export NSIM_HOME := $(RAPTOR_HOME)/sim
export AM_HOME   := $(RAPTOR_HOME)/abstract-machine
export NAVY_HOME := $(RAPTOR_HOME)/abstract-machine/app/navy-apps
export NVBOARD_HOME := $(RAPTOR_HOME)/third_party/NJU-ProjectN/nvboard
export CROSS_COMPILE ?= riscv64-elf-
VERIBLE_FORMAT ?= verible-verilog-format

# Default to batch mode (no interactive prompt). Override with ARGS="" to disable.
ARGS ?= -b -n ## Pass args to runner (-b: batch, -n: no wave)
IMG ?= ## Custom image to load
DISK ?= ## Virtio block disk image to pass to sim
SDCARD ?= ## QEMU SDHCI SD-card image to pass to sim/NEMU
MAX_INST ?= ## Max instructions to execute (-m N)
TIMEOUT ?=## Wall-clock timeout in seconds for selected simulator runs
TINYOS_OS ?=## TinyOS payload selector: egos or xv6
QEMU ?=## Override QEMU executable for OS CLI helpers

# Raptor uarch config preset (selects hdl/configs/<name>/rapt_config.svh).
# Exported so it propagates through chained sub-makes (sim, am-kernels, app, ...).
RAPT_CONFIG ?= default ## Raptor uarch config preset (default|small|...)
# `?=` keeps the trailing space before `##` in the value; strip it so paths
# like `$(NSIM_HOME)/build/$(RAPT_CONFIG)/...` don't end up with a stray
# space (which breaks `[ -f ... ]` shell tests in sub-makefiles).
RAPT_CONFIG := $(strip $(RAPT_CONFIG))
export RAPT_CONFIG

# ============================================================================
# Guard: only define project-level targets when invoked from root directory.
# Subprojects (sim, nemu) include this file for env vars only.
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
# Test/benchmark output logging (tee to sim/build/<config>/logs/)
#
# All benchmark/test recipes pipe their output through `tee` to a per-target
# log file under sim/build/<RAPT_CONFIG>/logs/ (NPC) or nemu/build/logs/
# (NEMU). This persists results so they can be inspected later without
# re-running the simulator.
#
# Wrappers:
#   $(call tee_npc,name)  -> ` 2>&1 | tee sim/build/<config>/logs/<name>.log`
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

# tee wrappers auto-create their log directory, so recipes never need a
# standalone `mkdir -p <log dir>` line.
tee_npc    = 2>&1 | { mkdir -p $(NPC_LOG_DIR); tee $(NPC_LOG_DIR)/$(1).log; }
tee_nemu   = 2>&1 | { mkdir -p $(NEMU_LOG_DIR); tee $(NEMU_LOG_DIR)/$(1).log; }
tee_app    = 2>&1 | { mkdir -p $(APP_LOG_DIR); tee $(APP_LOG_DIR)/$(1).log; }
tee_verify = 2>&1 | { mkdir -p $(VERIFY_LOG_DIR); tee $(VERIFY_LOG_DIR)/$(1).log; }

log: ## Run TARGET=<target> with stdout/stderr tee'd to sim/build/<config>/logs/$(LOG_NAME).log
	@test -n "$(TARGET)" || { echo "Usage: make log TARGET=<target> [LOG_NAME=<stem>]"; exit 1; }
	@mkdir -p $(NPC_LOG_DIR)
	@stem="$(if $(LOG_NAME),$(LOG_NAME),$(TARGET))"; \
	  echo "[log] $(NPC_LOG_DIR)/$$stem.log"; \
	  set -o pipefail; $(MAKE) --no-print-directory $(TARGET) 2>&1 | tee "$(NPC_LOG_DIR)/$$stem.log"

logs-show: ## List all persisted test/benchmark logs under sim/build/ and nemu/build/logs/
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
	$(MAKE) -C $(RAPTOR_HOME)/hdl/chisel verilog

# ============================================================================
# NEMU Targets
# ============================================================================
NEMU_DEFCONFIG ?= riscv32_defconfig ## NEMU defconfig profile
NEMU64_DEFCONFIG ?= riscv64_defconfig ## NEMU RV64 defconfig profile
NEMU_DISK_ARG = $(if $(DISK),--disk=$(DISK),)
NEMU_SDCARD_ARG = $(if $(SDCARD),--sdcard=$(SDCARD),)

# Canned recipe: apply a NEMU defconfig then build. $(1) = defconfig name.
define nemu_config
	$(MAKE) -C $(NEMU_HOME) $(1)
	$(MAKE) -C $(NEMU_HOME) -j$(NPROC)
endef

config-nemu32: ## Configure NEMU (riscv32 default)
	$(call nemu_config,$(NEMU_DEFCONFIG))

config-nemu32-linux:
	$(call nemu_config,riscv32_linux_defconfig)

config-nemu32-ref:
	$(call nemu_config,riscv32_ref_defconfig)

menuconfig-nemu32: ## Open NEMU menuconfig
	$(MAKE) -C $(NEMU_HOME) menuconfig

# config-nemu* already builds, so build-nemu* are pure aliases.
build-nemu32: config-nemu32 ## Build NEMU (riscv32)

run-nemu32: build-nemu32 ## Build and run NEMU (riscv32)
	$(MAKE) -C $(NEMU_HOME) run $(if $(IMG),IMG=$(IMG)) ARGS="$(ARGS) $(NEMU_DISK_ARG) $(NEMU_SDCARD_ARG)"

run-nemu32-linux: config-nemu32-linux
	$(MAKE) -C $(NEMU_HOME) run $(if $(IMG),IMG=$(IMG)) ARGS="$(ARGS)"

config-nemu32-linux-device:
	$(call nemu_config,riscv32_linux_device_defconfig)

DEVICE_ARGS ?= -b ## Args for -device targets (interactive by default)

run-nemu32-linux-device: config-nemu32-linux-device ## Run NEMU RV32 with VGA screen + keyboard
	$(MAKE) -C $(NEMU_HOME) run $(if $(IMG),IMG=$(IMG)) ARGS="$(DEVICE_ARGS)"

# --- RV64 NEMU targets ---
config-nemu64: ## Configure NEMU (riscv64)
	$(call nemu_config,$(NEMU64_DEFCONFIG))

config-nemu64-ref:
	$(call nemu_config,riscv64_ref_defconfig)

build-nemu64: config-nemu64 ## Build NEMU (riscv64)

run-nemu64: build-nemu64 ## Build and run NEMU (riscv64)
	$(MAKE) -C $(NEMU_HOME) run $(if $(IMG),IMG=$(IMG)) ARGS="$(ARGS) $(NEMU_DISK_ARG) $(NEMU_SDCARD_ARG)"

config-nemu64-linux:
	$(call nemu_config,riscv64_linux_defconfig)

config-nemu64-linux-device:
	$(call nemu_config,riscv64_linux_device_defconfig)

run-nemu64-linux-device: config-nemu64-linux-device ## Run NEMU RV64 with VGA screen + keyboard
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

# RV64 mode: set via `make run-rv64` or explicitly `make run-rv32 VFLAGS="-DRAPT_RV64"`.
# sim Verilator simulation enables RTL assertions by default via RAPT_SIM_ASSERT;
# pack/STA/FPGA synthesis paths do not receive the default assertion define.
VFLAGS ?= ## Extra RTL defines for NPC (-DRAPT_RV64, etc.)
RAPT_SIM_ASSERT ?= 1## Enable RTL SVA assertions by default in NPC Verilator simulation (1=on, 0=off)
RAPT_SIM_ASSERT := $(strip $(RAPT_SIM_ASSERT))
export RAPT_SIM_ASSERT

config-rv32: ## Configure NPC simulator (o2 default)
	$(MAKE) -C $(NSIM_HOME) o2_difftest_defconfig
	@$(MAKE) --no-print-directory -C $(NSIM_HOME)

config-rv32-difftest: config-rv32 ## Configure NPC simulator with difftest

config-rv32-linux:
	$(MAKE) -C $(NSIM_HOME) o2linux_difftest_defconfig
	$(MAKE) -C $(NSIM_HOME) -j$(NPROC)

config-rv32-ysyxsoc:
	$(MAKE) -C $(NSIM_HOME) o2soc_defconfig
	$(MAKE) -C $(NSIM_HOME) -j$(NPROC)


# Auto-generate RTL from Chisel if generated/ doesn't exist
GENERATED_DIR := $(RAPTOR_HOME)/hdl/generated

$(GENERATED_DIR):
	$(MAKE) verilog

build-rv32: config-rv32 | $(GENERATED_DIR) ## Build NPC simulator
	@$(MAKE) --no-print-directory -q -C $(NSIM_HOME) VFLAGS="$(VFLAGS)" 2>/dev/null \
		|| $(MAKE) --no-print-directory -C $(NSIM_HOME) -j$(NPROC) VFLAGS="$(VFLAGS)"

run-rv32: build-rv32 ## Build and run NPC simulator
	$(MAKE) -C $(NSIM_HOME) run ARGS="$(ARGS)" VFLAGS="$(VFLAGS)" $(if $(IMG),IMG=$(IMG)) $(if $(DISK),DISK=$(DISK)) $(if $(SDCARD),SDCARD=$(SDCARD))

sim-rv32: verilog config-rv32 build-rv32 ## Full pipeline: verilog + config + build + run
	$(MAKE) -C $(NSIM_HOME) run ARGS="$(ARGS)" VFLAGS="$(VFLAGS)" $(if $(IMG),IMG=$(IMG)) $(if $(DISK),DISK=$(DISK)) $(if $(SDCARD),SDCARD=$(SDCARD))

# --- RV64 convenience targets (equivalent to VFLAGS="-DRAPT_RV64") ---
build-rv64: VFLAGS := -DRAPT_RV64
build-rv64: build-rv32 ## Build NPC in RV64 mode

run-rv64: VFLAGS := -DRAPT_RV64
run-rv64: run-rv32 ## Build and run NPC in RV64 mode

lint-rv64: VFLAGS := -DRAPT_RV64
lint-rv64: lint ## Lint RTL in RV64 mode

# ============================================================================
# AM Kernels / Benchmarks
# ============================================================================
AM_KERNELS = $(RAPTOR_HOME)/abstract-machine/app/am-kernels

$(AM_KERNELS):
	mkdir -p $(abspath $(AM_KERNELS))
	git clone --depth 1 https://github.com/kingfish404/am-kernels $(AM_KERNELS)

MAINARGS ?= test ## Benchmark arguments (test/train/ref)

coremark-nemu32: $(AM_KERNELS) config-nemu32 ## Run CoreMark on NEMU (riscv32)
	@set -o pipefail; $(MAKE) -C $(AM_KERNELS)/benchmarks/coremark_eembc ARCH=riscv32-nemu run ARGS="$(ARGS)" $(call tee_nemu,coremark-nemu32)

microbench-nemu32: $(AM_KERNELS) config-nemu32 ## Run MicroBench on NEMU (riscv32)
	@set -o pipefail; $(MAKE) -C $(AM_KERNELS)/benchmarks/microbench ARCH=riscv32-nemu run ARGS="$(ARGS)" mainargs=$(MAINARGS) $(call tee_nemu,microbench-nemu32-$(MAINARGS))

coremark-nemu64: $(AM_KERNELS) config-nemu64 ## Run CoreMark on NEMU (riscv64)
	@set -o pipefail; $(MAKE) -C $(AM_KERNELS)/benchmarks/coremark_eembc ARCH=riscv64-nemu run ARGS="$(ARGS)" $(call tee_nemu,coremark-nemu64)

microbench-nemu64: $(AM_KERNELS) config-nemu64 ## Run MicroBench on NEMU (riscv64)
	@set -o pipefail; $(MAKE) -C $(AM_KERNELS)/benchmarks/microbench ARCH=riscv64-nemu run ARGS="$(ARGS)" mainargs=$(MAINARGS) $(call tee_nemu,microbench-nemu64-$(MAINARGS))

am-kernels-hello-rv32: build-rv32 ## Run AM hello-world on NPC (riscv32)
	@set -o pipefail; $(MAKE) -C $(AM_KERNELS)/kernels/hello ARCH=$(NPC_ARCH) run ARGS="$(ARGS)" mainargs="i" VME=1 $(call tee_npc,am-kernels-hello-rv32)

am-tests-cache-tests-rv32: build-rv32 ## Run AM cache-tests on NPC (riscv32)
	@set -o pipefail; $(MAKE) -C $(AM_KERNELS)/tests/cache-tests ARCH=$(NPC_ARCH) ALL=icache run ARGS="$(ARGS)" mainargs="i" VME=1 $(call tee_npc,am-tests-cache-tests-rv32)

am-tests-nemu32: build-nemu32
	@set -o pipefail; $(MAKE) -C $(AM_KERNELS)/tests/am-tests ARCH=riscv32-nemu run ARGS="$(ARGS)" mainargs="i" VME=1 $(call tee_nemu,am-tests-nemu32)

am-tests-rv32: build-rv32
	@set -o pipefail; $(MAKE) -C $(AM_KERNELS)/tests/am-tests ARCH=$(NPC_ARCH) run ARGS="$(ARGS)" mainargs="i" VME=1 $(call tee_npc,am-tests-rv32)

CPU_TESTS_DIR := $(AM_KERNELS)/tests/cpu-tests
CPU_TESTS     := $(basename $(notdir $(wildcard $(CPU_TESTS_DIR)/tests/*.c)))

# Parallel cpu-tests runner.
# 1. Build all per-test .bin files sequentially (shares AM lib state).
# 2. Run resulting .bin files concurrently via xargs -P $(JOBS).
# Args (positional, all shell-quoted internally):
#   $(1) suite label (e.g. rv32 / nemu32) - used in log header
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
	        echo "$$out" | tail -20 | sed "s/^/  [$$name] /"; \
	        exit 1; \
	      fi' _; \
	  xargs_rc=$$?; \
	  echo "=== cpu-tests-$(1): done ==="; \
	  exit $$xargs_rc; \
	} 2>&1 | { mkdir -p $$(dirname $(4)); tee $(4); }
endef

cpu-tests-nemu32: build-nemu32 ## Run AM cpu-tests on NEMU (sequential; NEMU is not concurrency-safe here)
	@set -o pipefail; $(MAKE) -C $(AM_KERNELS)/tests/cpu-tests ARCH=riscv32-nemu run ARGS="$(ARGS)" mainargs="i" VME=1 $(call tee_nemu,cpu-tests-nemu32)

cpu-tests-rv32: build-rv32 ## Run AM cpu-tests on NPC (parallel)
	@set -o pipefail; \
	  NPC_CMD=$$($(MAKE) --no-print-directory -C $(NSIM_HOME) VFLAGS="$(VFLAGS)" print-npc-exec | tail -1) \
	    || { echo "[cpu-tests-rv32] ERROR: print-npc-exec failed"; exit 1; }; \
	  $(call run_cpu_tests_parallel,rv32,"$$NPC_CMD",$(NPC_ARCH),$(NPC_LOG_DIR)/cpu-tests-rv32.log)

# --- Bare-metal IRQ tests (PLIC, etc) -------------------------------------
# Each test is a standalone M-mode .bin loaded directly at 0x80000000 via
# the sim positional IMG argument. No pk/AM dependency.
IRQ_TESTS_DIR  := $(RAPTOR_HOME)/app/build/rv32/tests/irq
IRQ_TESTS_SRC_DIR := $(RAPTOR_HOME)/app/tests/irq
IRQ_TESTS      := $(notdir $(basename $(wildcard $(IRQ_TESTS_SRC_DIR)/*.c)))

irq-tests-build: ## Build bare-metal PLIC IRQ tests
	$(MAKE) -C $(RAPTOR_HOME)/app/tests/irq build

# Parallel bare-metal IRQ test runner shared by plain/difftest variants.
# $(1) = suite label (shown in headers), $(2) = log stem for tee_npc.
define run_irq_tests_parallel
	@set -o pipefail; \
	  NPC_CMD=$$($(MAKE) --no-print-directory -C $(NSIM_HOME) VFLAGS="$(VFLAGS)" print-npc-exec | tail -1) \
	    || { echo "[$(2)] ERROR: print-npc-exec failed"; exit 1; }; \
	  { \
	    echo "=== IRQ tests ($(1), parallel JOBS=$(JOBS)) ==="; \
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
	    if [ $$rc -eq 0 ]; then echo "=== IRQ tests ($(1)): ALL PASSED ==="; \
	    else echo "=== IRQ tests ($(1)): FAILURES ==="; exit $$rc; fi; \
	  } $(call tee_npc,$(2))
endef

irq-tests-rv32: build-rv32 irq-tests-build ## Build & run bare-metal PLIC IRQ tests on NPC (parallel)
	$(call run_irq_tests_parallel,bare-metal,irq-tests-rv32)

irq-tests-rv32-difftest: build-rv32 config-nemu32-ref irq-tests-build ## Build & run bare-metal PLIC IRQ tests on NPC with difftest (parallel)
	$(call run_irq_tests_parallel,difftest,irq-tests-rv32-difftest)

# --- Minimal Linux-pattern repros -----------------------------------------
REPRO_TESTS_DIR := $(RAPTOR_HOME)/app/build/rv32/tests/repro

repro-tests-build: ## Build bare-metal minimal repro tests
	$(MAKE) -C $(RAPTOR_HOME)/app/tests/repro build

linux-ticket-spinlock-repro-rv32: build-rv32 repro-tests-build ## Run Linux ticket-spinlock AMO/SH/LW repro on NPC
	$(MAKE) --no-print-directory -C $(NSIM_HOME) run \
		ARGS="$(ARGS)" VFLAGS="$(VFLAGS)" \
		IMG=$(REPRO_TESTS_DIR)/linux_ticket_spinlock.bin

coremark-rv32: $(AM_KERNELS) config-rv32 ## Run CoreMark on NPC
	@set -o pipefail; $(MAKE) -C $(AM_KERNELS)/benchmarks/coremark_eembc ARCH=$(NPC_ARCH) run ARGS="$(ARGS)" $(call tee_npc,coremark-rv32)
	$(call coremark_mhz_report,$(NPC_LOG_DIR)/coremark-rv32.log)

coremark-rv32-difftest: $(AM_KERNELS) config-rv32 config-nemu32-ref ## Run CoreMark on NPC with difftest
	@set -o pipefail; $(MAKE) -C $(AM_KERNELS)/benchmarks/coremark_eembc ARCH=$(NPC_ARCH) run ARGS="$(ARGS)" mainargs=test $(call tee_npc,coremark-rv32-difftest)
	$(call coremark_mhz_report,$(NPC_LOG_DIR)/coremark-rv32-difftest.log)

coremark-ysyxsoc: $(AM_KERNELS) config-rv32-ysyxsoc config-nemu32-ref ## Run CoreMark on ysyxSoC
	@set -o pipefail; $(MAKE) -C $(AM_KERNELS)/benchmarks/coremark_eembc ARCH=$(YSYXSOC_ARCH) run ARGS="$(ARGS)" mainargs=test $(call tee_npc,coremark-ysyxsoc)
	$(call coremark_mhz_report,$(NPC_LOG_DIR)/coremark-ysyxsoc.log)

microbench-rv32: $(AM_KERNELS) config-rv32 ## Run MicroBench on NPC
	@set -o pipefail; $(MAKE) -C $(AM_KERNELS)/benchmarks/microbench ARCH=$(NPC_ARCH) run ARGS="$(ARGS)" mainargs=$(MAINARGS) $(call tee_npc,microbench-rv32-$(MAINARGS))

micorbench-rv32-difftest: microbench-rv32-difftest ## Typo-compat alias of microbench-rv32-difftest

# --- RV64 benchmark targets ---
coremark-rv64: VFLAGS := -DRAPT_RV64
coremark-rv64: $(AM_KERNELS) config-rv32 ## Run CoreMark on NPC (riscv64)
	@set -o pipefail; $(MAKE) -C $(AM_KERNELS)/benchmarks/coremark_eembc ARCH=riscv64-npc run ARGS="$(ARGS)" VFLAGS="$(VFLAGS)" $(call tee_npc,coremark-rv64)
	$(call coremark_mhz_report,$(NPC_LOG_DIR)/coremark-rv64.log)

coremark-rv64-difftest: VFLAGS := -DRAPT_RV64
coremark-rv64-difftest: $(AM_KERNELS) config-rv32 config-nemu64-ref ## Run CoreMark on NPC (riscv64) with difftest
	@set -o pipefail; $(MAKE) -C $(AM_KERNELS)/benchmarks/coremark_eembc ARCH=riscv64-npc run ARGS="$(ARGS)" VFLAGS="$(VFLAGS)" $(call tee_npc,coremark-rv64-difftest)
	$(call coremark_mhz_report,$(NPC_LOG_DIR)/coremark-rv64-difftest.log)

microbench-rv64: VFLAGS := -DRAPT_RV64
microbench-rv64: $(AM_KERNELS) config-rv32 ## Run MicroBench on NPC (riscv64)
	@set -o pipefail; $(MAKE) -C $(AM_KERNELS)/benchmarks/microbench ARCH=riscv64-npc run ARGS="$(ARGS)" VFLAGS="$(VFLAGS)" mainargs=$(MAINARGS) $(call tee_npc,microbench-rv64-$(MAINARGS))

microbench-rv64-difftest: VFLAGS := -DRAPT_RV64
microbench-rv64-difftest: $(AM_KERNELS) config-rv32 config-nemu64-ref ## Run MicroBench on NPC (riscv64) with difftest
	@set -o pipefail; $(MAKE) -C $(AM_KERNELS)/benchmarks/microbench ARCH=riscv64-npc run ARGS="$(ARGS)" VFLAGS="$(VFLAGS)" mainargs=$(MAINARGS) $(call tee_npc,microbench-rv64-difftest-$(MAINARGS))

microbench-rv32-difftest: $(AM_KERNELS) config-rv32 config-nemu32-ref ## Run MicroBench on NPC with difftest
	@set -o pipefail; $(MAKE) -C $(AM_KERNELS)/benchmarks/microbench ARCH=$(NPC_ARCH) run ARGS="$(ARGS)" mainargs=$(MAINARGS) $(call tee_npc,microbench-rv32-difftest-$(MAINARGS))

microbench-ysyxsoc: $(AM_KERNELS) config-rv32-ysyxsoc config-nemu32-ref ## Run MicroBench on ysyxSoC
	@set -o pipefail; $(MAKE) -C $(AM_KERNELS)/benchmarks/microbench ARCH=$(YSYXSOC_ARCH) run ARGS="$(ARGS)" mainargs=test $(call tee_npc,microbench-ysyxsoc)

# --- CoreMark "optimized" runs with CoreMark/MHz reporting ----------------
# COREMARK_OPTIM_CFLAGS holds aggressive GCC flags that maximize CoreMark/MHz on
# the Raptor core. They are injected into the CoreMark build (consumed by
# abstract-machine/app/am-kernels/benchmarks/coremark_eembc/Makefile) so the
# plain `coremark-*` targets keep the AM baseline flags. The CoreMark build is
# cleaned first because the AM build system does not track CFLAGS changes.
# CoreMark/MHz is frequency-independent: iterations * 1e6 / active_cycles
# (mirrors third_party/cvw/benchmarks/coremark's XCFLAGS + score extraction).
COREMARK_OPTIM_CFLAGS := \
	-O3 -funroll-all-loops -finline-functions \
	-falign-functions=16 -falign-jumps=4 -mbranch-cost=1 \
	-DSKIP_DEFAULT_MEMSET -mtune=sifive-3-series \
	--param=uninlined-function-insns=8 --param=loop-max-datarefs-for-datadeps=0 \
	-fipa-pta -fno-tree-vrp -fwrapv

# Parse a tee'd CoreMark + sim run log and print the CoreMark/MHz score.
# $(1) = path to the log file produced by tee_npc.
define coremark_mhz_report
@awk '/^[ \t]*Iterations[ \t]*:/{for(i=1;i<=NF;i++)if($$i~/^[0-9]+$$/)it=$$i} /#inst:/{if(match($$0,/cycle:[ \t]*[0-9]+/)){c=substr($$0,RSTART,RLENGTH);gsub(/[^0-9]/,"",c);cy=c}} END{if(it+0>0&&cy+0>0){printf "\n==================== CoreMark/MHz ====================\n";printf "Iterations    : %d\n",it;printf "Active cycles : %d\n",cy;printf "CoreMark/MHz  : %.4f  (= %d * 1e6 / %d)\n",it*1000000.0/cy,it,cy;printf "======================================================\n"}else{printf "[CoreMark/MHz] WARN: could not parse iterations(%s) / cycles(%s) from %s\n",it,cy,"$(1)"}}' "$(1)"
endef

coremark-rv32-optim: $(AM_KERNELS) config-rv32 ## Run  CoreMark on NPC with aggressive optim flags + CoreMark/MHz report
	$(MAKE) -C $(AM_KERNELS)/benchmarks/coremark_eembc ARCH=$(NPC_ARCH) clean
	@set -o pipefail; $(MAKE) -C $(AM_KERNELS)/benchmarks/coremark_eembc ARCH=$(NPC_ARCH) run ARGS="$(ARGS)" COREMARK_OPTIM_CFLAGS="$(COREMARK_OPTIM_CFLAGS)" $(call tee_npc,coremark-rv32-optim)
	$(call coremark_mhz_report,$(NPC_LOG_DIR)/coremark-rv32-optim.log)

coremark-rv64-optim: VFLAGS := -DRAPT_RV64
coremark-rv64-optim: $(AM_KERNELS) config-rv32 ## Run CoreMark on NPC (riscv64) with aggressive optim flags + CoreMark/MHz report
	$(MAKE) -C $(AM_KERNELS)/benchmarks/coremark_eembc ARCH=riscv64-npc clean
	@set -o pipefail; $(MAKE) -C $(AM_KERNELS)/benchmarks/coremark_eembc ARCH=riscv64-npc run ARGS="$(ARGS)" VFLAGS="$(VFLAGS)" COREMARK_OPTIM_CFLAGS="$(COREMARK_OPTIM_CFLAGS)" $(call tee_npc,coremark-rv64-optim)
	$(call coremark_mhz_report,$(NPC_LOG_DIR)/coremark-rv64-optim.log)

# --- Dhrystone (DMIPS / DMIPS/MHz) ----------------------------------------
# Mirrors the CoreMark integration. DMIPS/MHz is frequency-independent and
# derived from the sim PMU active-cycle count, matching how CoreMark/MHz is
# computed (so the frequency assumption is identical to CoreMark's). Absolute
# DMIPS is then DMIPS/MHz * DHRY_FREQ_MHZ.
#   DMIPS/MHz = Number_Of_Runs * 1e6 / (active_cycles * 1757)
#   DMIPS     = DMIPS/MHz * DHRY_FREQ_MHZ
# 1757 is the VAX-11/780 reference (1 DMIPS == 1757 Dhrystones/s).
DHRY_FREQ_MHZ ?= 180 ## Assumed clock (MHz) for absolute DMIPS (DMIPS/MHz is frequency-independent)

# Parse a tee'd Dhrystone + sim run log and print the DMIPS / DMIPS/MHz score.
# $(1) = path to the log file produced by tee_npc.
define dhrystone_dmips_report
@awk -v freq=$(DHRY_FREQ_MHZ) '/^[ \t]*Number_Of_Runs[ \t]*:/{for(i=1;i<=NF;i++)if($$i~/^[0-9]+$$/)runs=$$i} /#inst:/{if(match($$0,/cycle:[ \t]*[0-9]+/)){c=substr($$0,RSTART,RLENGTH);gsub(/[^0-9]/,"",c);cy=c}} END{if(runs+0>0&&cy+0>0){dpm=runs*1000000.0/(cy*1757.0);printf "\n==================== Dhrystone DMIPS ====================\n";printf "Runs          : %d\n",runs;printf "Active cycles : %d\n",cy;printf "Assumed freq  : %d MHz\n",freq;printf "DMIPS/MHz     : %.4f  (= %d * 1e6 / (%d * 1757))\n",dpm,runs,cy;printf "DMIPS         : %.2f  (= DMIPS/MHz * %d MHz)\n",dpm*freq,freq;printf "========================================================\n"}else{printf "[DMIPS] WARN: could not parse runs(%s) / cycles(%s) from %s\n",runs,cy,"$(1)"}}' "$(1)"
endef

dhrystone-rv32: $(AM_KERNELS) config-rv32 ## Run Dhrystone on NPC (DMIPS + DMIPS/MHz)
	@set -o pipefail; $(MAKE) -C $(AM_KERNELS)/benchmarks/dhrystone ARCH=$(NPC_ARCH) run ARGS="$(ARGS)" $(call tee_npc,dhrystone-rv32)
	$(call dhrystone_dmips_report,$(NPC_LOG_DIR)/dhrystone-rv32.log)

dhrystone-rv32-difftest: $(AM_KERNELS) config-rv32 config-nemu32-ref ## Run Dhrystone on NPC with difftest
	@set -o pipefail; $(MAKE) -C $(AM_KERNELS)/benchmarks/dhrystone ARCH=$(NPC_ARCH) run ARGS="$(ARGS)" $(call tee_npc,dhrystone-rv32-difftest)
	$(call dhrystone_dmips_report,$(NPC_LOG_DIR)/dhrystone-rv32-difftest.log)

dhrystone-rv64: VFLAGS := -DRAPT_RV64
dhrystone-rv64: $(AM_KERNELS) config-rv32 ## Run Dhrystone on NPC (riscv64)
	@set -o pipefail; $(MAKE) -C $(AM_KERNELS)/benchmarks/dhrystone ARCH=riscv64-npc run ARGS="$(ARGS)" VFLAGS="$(VFLAGS)" $(call tee_npc,dhrystone-rv64)
	$(call dhrystone_dmips_report,$(NPC_LOG_DIR)/dhrystone-rv64.log)

dhrystone-nemu32: $(AM_KERNELS) config-nemu32 ## Run Dhrystone on NEMU (riscv32, functional check)
	@set -o pipefail; $(MAKE) -C $(AM_KERNELS)/benchmarks/dhrystone ARCH=riscv32-nemu run ARGS="$(ARGS)" $(call tee_nemu,dhrystone-nemu32)

# Optimized Dhrystone codegen.
DHRYSTONE_OPTIM_CFLAGS := \
	-O3 -funroll-loops -finline-functions -falign-functions=16 \
	-fbuiltin -fno-builtin-printf -fno-builtin-puts -fno-builtin-putchar

dhrystone-rv32-optim: $(AM_KERNELS) config-rv32 ## Run Dhrystone on NPC with optimized codegen (builtins) + DMIPS report
	$(MAKE) -C $(AM_KERNELS)/benchmarks/dhrystone ARCH=$(NPC_ARCH) clean
	@set -o pipefail; $(MAKE) -C $(AM_KERNELS)/benchmarks/dhrystone ARCH=$(NPC_ARCH) run ARGS="$(ARGS)" DHRYSTONE_OPTIM_CFLAGS="$(DHRYSTONE_OPTIM_CFLAGS)" $(call tee_npc,dhrystone-rv32-optim)
	$(call dhrystone_dmips_report,$(NPC_LOG_DIR)/dhrystone-rv32-optim.log)

dhrystone-rv64-optim: VFLAGS := -DRAPT_RV64
dhrystone-rv64-optim: $(AM_KERNELS) config-rv32 ## Run Dhrystone on NPC (riscv64) with optimized codegen (builtins) + DMIPS report
	$(MAKE) -C $(AM_KERNELS)/benchmarks/dhrystone ARCH=riscv64-npc clean
	@set -o pipefail; $(MAKE) -C $(AM_KERNELS)/benchmarks/dhrystone ARCH=riscv64-npc run ARGS="$(ARGS)" VFLAGS="$(VFLAGS)" DHRYSTONE_OPTIM_CFLAGS="$(DHRYSTONE_OPTIM_CFLAGS)" $(call tee_npc,dhrystone-rv64-optim)
	$(call dhrystone_dmips_report,$(NPC_LOG_DIR)/dhrystone-rv64-optim.log)

# ============================================================================
# RISC-V Architecture Tests
# ============================================================================
RISCV_ARCH_TEST ?= $(RAPTOR_HOME)/third_party/kingfish404/riscv-arch-test-am

$(RISCV_ARCH_TEST):
	git clone --depth 1 https://github.com/Kingfish404/riscv-arch-test-am $@

archtest-rv32: build-rv32 $(RISCV_ARCH_TEST) ## Run RISC-V Architecture Test on NPC (riscv32)
	@set -o pipefail; $(MAKE) -C $(RISCV_ARCH_TEST) ARCH=$(NPC_ARCH) run ARGS="$(ARGS)" $(call tee_npc,archtest-rv32)

archtest-rv32e: build-rv32 $(RISCV_ARCH_TEST) ## Run RISC-V Architecture Test on NPC (riscv32e)
	@set -o pipefail; $(MAKE) -C $(RISCV_ARCH_TEST) ARCH=riscv32e-npc run ARGS="$(ARGS)" $(call tee_npc,archtest-rv32e)

# ============================================================================
# Nanos-lite OS
# ============================================================================
ISA ?= riscv32 ## ISA for nanos-lite targets

nanos-nemu32: ## Build and run nanos-lite on NEMU
	$(MAKE) -C $(NAVY_HOME) ISA=$(ISA) fsimg
	$(MAKE) -C $(NAVY_HOME)/apps/menu ISA=$(ISA) install
	$(MAKE) -C $(RAPTOR_HOME)/abstract-machine/app/nanos-lite ARCH=$(ISA)-nemu update run

nanos-rv32: ## Build and run nanos-lite on NPC
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

# Canned recipes: download payload, (re)build sim with VFLAGS, run + tee log.
# $(1) = rv32|rv64 (linux/Makefile download suffix), $(2) = payload image,
# $(3) = log stem.
# $(4) = optional sim variable override.
# $(5) = optional extra variables propagated to BOTH the `make -C sim` build
#        and the `make -C sim run` invocation (e.g. DT_SOURCE=...).
define linux_boot_npc
	$(MAKE) -C $(LINUX_HOME) download-$(1)
	$(MAKE) -C $(NSIM_HOME) -j$(NPROC) VFLAGS="$(VFLAGS)" $(5)
	@set -o pipefail; $(MAKE) -C $(NSIM_HOME) run IMG=$(2) ARGS="$(ARGS) $(if $(MAX_INST),-m $(MAX_INST))" VFLAGS="$(VFLAGS)" $(4) $(5) $(call tee_npc,$(3))
endef

define linux_boot_nemu
	$(MAKE) -C $(LINUX_HOME) download-$(1)
	@set -o pipefail; $(MAKE) -C $(NEMU_HOME) run IMG=$(2) ARGS="$(ARGS) $(if $(MAX_INST),-m $(MAX_INST))" $(call tee_nemu,$(3))
endef

linux-boot-nemu32: config-nemu32-linux ## Boot Linux on NEMU (riscv32)
	$(call linux_boot_nemu,rv32,$(LINUX_RV32_PAYLOAD),linux-boot-nemu32)

linux-boot-nemu64: config-nemu64-linux ## Boot Linux on NEMU (riscv64)
	$(call linux_boot_nemu,rv64,$(LINUX_RV64_PAYLOAD),linux-boot-nemu64)

linux-boot-rv32: config-rv32-linux ## Boot Linux on NPC (riscv32)
	$(call linux_boot_npc,rv32,$(LINUX_RV32_PAYLOAD),linux-boot-rv32,DIFF_REF_SO=)

linux-boot-rv32-difftest: config-nemu32-ref config-rv32-linux ## Boot Linux on NPC with difftest
	$(call linux_boot_npc,rv32,$(LINUX_RV32_PAYLOAD),linux-boot-rv32-difftest)

# rv32gc Buildroot (hard-float F/D userspace) boot. Uses the spike-rv32gc.dts
# DTB (riscv,isa=rv32imafdc...) so the kernel sees the F/D extensions; payload
# defaults to third_party/linux-build's rv32 Buildroot fw_payload.bin and is NOT
# auto-downloaded (override LINUX_RV32GC_PAYLOAD to use a different image).
linux-boot-rv32gc: config-rv32-linux ## Boot rv32gc Buildroot Linux on NPC (hard-float F/D)
	@test -f "$(LINUX_RV32GC_PAYLOAD)" || { echo "[ERR] rv32gc payload not found: $(LINUX_RV32GC_PAYLOAD)"; \
		echo "      Build it via third_party/linux-build (qemu-rv32 buildroot preset),"; \
		echo "      or override LINUX_RV32GC_PAYLOAD=/path/to/fw_payload.bin"; exit 1; }
	$(call linux_boot_npc,rv32,$(LINUX_RV32GC_PAYLOAD),linux-boot-rv32gc,DIFF_REF_SO=,DT_SOURCE=spike-rv32gc.dts)

# rv64gc Buildroot (hard-float F/D userspace) boot; mirrors linux-boot-rv32gc.
# RV64 datapath via VFLAGS=-DRAPT_RV64; DTB via spike-rv64gc.dts (sv39).
linux-boot-rv64gc: VFLAGS := -DRAPT_RV64
linux-boot-rv64gc: config-rv32-linux ## Boot rv64gc Buildroot Linux on NPC (hard-float F/D)
	@test -f "$(LINUX_RV64GC_PAYLOAD)" || { echo "[ERR] rv64gc payload not found: $(LINUX_RV64GC_PAYLOAD)"; \
		echo "      Build it via third_party/linux-build (qemu-rv64 buildroot preset),"; \
		echo "      or override LINUX_RV64GC_PAYLOAD=/path/to/fw_payload.bin"; exit 1; }
	$(call linux_boot_npc,rv64,$(LINUX_RV64GC_PAYLOAD),linux-boot-rv64gc,DIFF_REF_SO=,DT_SOURCE=spike-rv64gc.dts)

LINUX_BOOT_MAX_INST ?= 120000000
LINUX_MEM_RANDOM_DELAY ?= 7
LINUX_MEM_STRESS_SEEDS ?= 1 2 7
LINUX_MEM_STRESS_MAX_INST ?= 400000000
LINUX_CKPT_STRESS_MAX_INST ?= 300000000
LINUX_BOOT_CHECK := $(RAPTOR_HOME)/verify/scripts/check_linux_boot.py

verify-linux-boot-rv32: ## Boot RV32 Linux with difftest and require the /init milestone
	$(MAKE) --no-print-directory linux-boot-rv32-difftest \
		ARGS="$(ARGS)" MAX_INST=$(LINUX_BOOT_MAX_INST)
	python3 $(LINUX_BOOT_CHECK) $(NPC_LOG_DIR)/linux-boot-rv32-difftest.log

verify-linux-memory-stress-rv32: config-nemu32-ref config-rv32-linux ## Boot RV32 Linux under randomized memory latency
	$(MAKE) -C $(LINUX_HOME) download-rv32
	@set -eu -o pipefail; \
	mkdir -p $(NPC_LOG_DIR); \
	for seed in $(LINUX_MEM_STRESS_SEEDS); do \
		echo "[Linux memory-stress] delay=$(LINUX_MEM_RANDOM_DELAY) seed=$$seed"; \
		log="$(NPC_LOG_DIR)/linux-memory-stress-delay$(LINUX_MEM_RANDOM_DELAY)-seed$$seed.log"; \
		$(MAKE) --no-print-directory -C $(NSIM_HOME) run IMG=$(LINUX_RV32_PAYLOAD) \
			ARGS="-b -n -m $(LINUX_MEM_STRESS_MAX_INST) --mem-random-delay=$(LINUX_MEM_RANDOM_DELAY) --mem-random-seed=$$seed" \
			2>&1 | tee "$$log"; \
		python3 $(LINUX_BOOT_CHECK) "$$log"; \
	done

linux-boot-rv64: VFLAGS := -DRAPT_RV64
linux-boot-rv64: config-rv32-linux ## Boot Linux on NPC (riscv64)
	$(call linux_boot_npc,rv64,$(LINUX_RV64_PAYLOAD),linux-boot-rv64,DIFF_REF_SO=)

linux-boot-rv64-difftest: VFLAGS := -DRAPT_RV64
linux-boot-rv64-difftest: config-nemu64-ref config-rv32-linux ## Boot Linux on NPC RV64 with difftest
	$(call linux_boot_npc,rv64,$(LINUX_RV64_PAYLOAD),linux-boot-rv64-difftest)

linux-boot-nemu32-device: config-nemu32-linux-device ## Boot Linux on NEMU RV32 (auto-download)
	$(MAKE) -C $(LINUX_HOME) download-rv32
	$(MAKE) -C $(NEMU_HOME) run IMG=$(LINUX_RV32_PAYLOAD) ARGS="$(DEVICE_ARGS)"

linux-boot-nemu64-device: config-nemu64-linux-device ## Boot Linux on NEMU RV64 (auto-download)
	$(MAKE) -C $(LINUX_HOME) download-rv64
	$(MAKE) -C $(NEMU_HOME) run IMG=$(LINUX_RV64_PAYLOAD) ARGS="$(DEVICE_ARGS)"

# ----------------------------------------------------------------------------
# Linux boot checkpoint save/restore (architectural snapshot of sim).
# Saves arch state + memory at a chosen cycle, restores via an MROM trampoline
# that re-runs through real lw/csrw/mret instructions. Pure architectural
# checkpoint — survives RTL/microarch changes.
# ----------------------------------------------------------------------------
# CKPT_DIR is the checkpoint save target and load source.
CKPT_DIR   ?= $(RAPTOR_HOME)/sim/data/ckpt-linux-rv32
# CKPT_CYCLE selects the cycle at which a checkpoint is saved.
CKPT_CYCLE ?= 100000000

linux-boot-rv32-ckpt-save: config-nemu32-ref config-rv32-linux ## Boot Linux on NPC, save checkpoint at CKPT_CYCLE -> CKPT_DIR
	$(MAKE) -C $(LINUX_HOME) download-rv32
	$(MAKE) -C $(NSIM_HOME) -j$(NPROC)
	rm -rf $(CKPT_DIR)
	$(MAKE) -C $(NSIM_HOME) run IMG=$(LINUX_RV32_PAYLOAD) \
		ARGS="$(ARGS) --ckpt-cycle=$(CKPT_CYCLE) --ckpt-save=$(CKPT_DIR) --ckpt-save-exit"

linux-boot-rv32-ckpt-load: config-nemu32-ref config-rv32-linux ## Resume Linux boot on NPC from CKPT_DIR
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
VERIBLE_FLAGS := $(RAPTOR_HOME)/.verible-format.flags
HDL_FORMAT_SOURCES := $(addprefix $(RAPTOR_HOME)/,$(shell git -C $(RAPTOR_HOME) ls-files \
	'hdl/*.v' 'hdl/*.vh' 'hdl/*.sv' 'hdl/*.svh' \
	'hdl/**/*.v' 'hdl/**/*.vh' 'hdl/**/*.sv' 'hdl/**/*.svh'))

.PHONY: hdl-format hdl-format-check
hdl-format: HDL_FORMAT_MODE := --inplace
hdl-format: ## Format tracked hand-written HDL sources with Verible

hdl-format-check: HDL_FORMAT_MODE := --verify --inplace
hdl-format-check: ## Fail if tracked hand-written HDL is not Verible-formatted

hdl-format hdl-format-check:
	@command -v $(VERIBLE_FORMAT) >/dev/null || { \
		echo "ERROR: $(VERIBLE_FORMAT) not found (brew install verible)" >&2; exit 1; }
	@$(VERIBLE_FORMAT) --flagfile="$(VERIBLE_FLAGS)" --failsafe_success=false \
		$(HDL_FORMAT_MODE) $(HDL_FORMAT_SOURCES)

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

compile-commands: ## Generate root compile_commands.json from real NEMU+sim build commands
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

sram-macros: ## Compile OpenRAM SRAM macros for cache data arrays (see sim/sram/README.md)
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
	-$(MAKE) -C $(RAPTOR_HOME)/hdl/chisel clean 2>/dev/null || true
	-$(MAKE) -C $(RAPTOR_HOME)/verify clean 2>/dev/null || true
	-$(MAKE) -C $(RAPTOR_HOME)/app clean 2>/dev/null || true

# ============================================================================
# Verification Suite (verify/)
# ============================================================================
VERIFY_HOME := $(RAPTOR_HOME)/verify

verify-fuzz: ## Random instruction fuzz with difftest
	@set -o pipefail; $(MAKE) -C $(VERIFY_HOME) fuzz $(call tee_verify,fuzz)

verify-unit-fpu: ## Run all Verilator FPU component tests
	$(MAKE) -C $(VERIFY_HOME) unit-fpu

verify-fp-smoke-rv32: ## Run the NEMU RV32F directed smoke test
	$(MAKE) -C $(RAPTOR_HOME)/app/tests/fp run ISA=rv32

verify-fp-smoke-rv64: ## Run the NEMU RV64F directed smoke test
	$(MAKE) -C $(RAPTOR_HOME)/app/tests/fp run ISA=rv64

verify-fp-spike-rv32: ## Run the RV32F smoke test with NEMU versus Spike
	$(MAKE) -C $(RAPTOR_HOME)/app/tests/fp run ISA=rv32 DIFFTEST=1

verify-fp-spike-rv64: ## Run the RV64F smoke test with NEMU versus Spike
	$(MAKE) -C $(RAPTOR_HOME)/app/tests/fp run ISA=rv64 DIFFTEST=1

verify-fp-arith-rv32: ## Run RV32F SoftFloat arithmetic regression
	$(MAKE) -C $(RAPTOR_HOME)/app/tests/fp arith ISA=rv32

verify-fp-arith-rv64: ## Run RV64F SoftFloat arithmetic regression
	$(MAKE) -C $(RAPTOR_HOME)/app/tests/fp arith ISA=rv64

verify-fp-arith-spike-rv32: ## Run RV32F arithmetic against Spike
	$(MAKE) -C $(RAPTOR_HOME)/app/tests/fp arith-spike ISA=rv32 DIFFTEST=1

verify-fp-arith-spike-rv64: ## Run RV64F arithmetic against Spike
	$(MAKE) -C $(RAPTOR_HOME)/app/tests/fp arith-spike ISA=rv64 DIFFTEST=1

verify-fp-double-rv32: ## Run RV32D NEMU directed regression
	$(MAKE) -C $(RAPTOR_HOME)/app/tests/fp double ISA=rv32

verify-fp-double-rv64: ## Run RV64D NEMU directed regression
	$(MAKE) -C $(RAPTOR_HOME)/app/tests/fp double ISA=rv64

verify-fuzz-inf: ## Continuous fuzz until Ctrl-C or failure
	@set -o pipefail; $(MAKE) -C $(VERIFY_HOME) fuzz-inf $(call tee_verify,fuzz-inf)

verify-fuzz-replay: ## Replay the last failing fuzz-inf batch
	@set -o pipefail; $(MAKE) -C $(VERIFY_HOME) fuzz-replay $(call tee_verify,fuzz-replay)

verify-sigtest: ## Signature-based ISA corner-case tests
	@set -o pipefail; $(MAKE) -C $(VERIFY_HOME) sigtest $(call tee_verify,sigtest)

verify-riscof-classic: ## RISCOF classic compliance tests (legacy, no difftest)
	@set -o pipefail; $(MAKE) -C $(VERIFY_HOME) riscof-classic $(call tee_verify,riscof-classic)

verify-riscof-classic-nemu: ## RISCOF classic compliance tests on NEMU reference
	@set -o pipefail; $(MAKE) -C $(VERIFY_HOME) riscof-classic-nemu $(call tee_verify,riscof-classic-nemu)

verify-riscof: ## RISCOF official compliance tests
	@set -o pipefail; $(MAKE) -C $(VERIFY_HOME) riscof $(call tee_verify,riscof)

verify-riscv-dv: ## riscv-dv privileged smoke across the memory-delay matrix
	@set -o pipefail; $(MAKE) -C $(VERIFY_HOME) riscv-dv $(call tee_verify,riscv-dv)

verify-riscv-dv-stress: ## riscv-dv exception stress across delay/seed matrix
	@set -o pipefail; $(MAKE) -C $(VERIFY_HOME) riscv-dv-stress $(call tee_verify,riscv-dv-stress)

verify-riscv-dv-mmu: ## Check riscv-dv Sv32/MMU generator availability
	@$(MAKE) -C $(VERIFY_HOME) riscv-dv-mmu

verify-coverage: ## Verilator line/toggle coverage
	@set -o pipefail; $(MAKE) -C $(VERIFY_HOME) coverage $(call tee_verify,coverage)

verify-all: ## Run all verification targets
	@set -o pipefail; $(MAKE) -C $(VERIFY_HOME) all $(call tee_verify,all)

verify-memory-stress-rv32: ## RaptOS: randomized Sv32 memory/atomic integration matrix
	$(MAKE) -C $(RAPTOR_HOME)/app/tinyos/raptos memory-stress \
		MEM_RANDOM_DELAY=$(or $(MEM_RANDOM_DELAY),32) \
		$(if $(MEM_STRESS_SEEDS),MEM_STRESS_SEEDS="$(MEM_STRESS_SEEDS)",) \
		$(if $(MEM_STRESS_PAYLOADS),MEM_STRESS_PAYLOADS="$(MEM_STRESS_PAYLOADS)",)

verify-clean: ## Clean verification artifacts
	$(MAKE) -C $(VERIFY_HOME) clean

# ============================================================================
# Standard Toolchain (app/, riscv-pk)
# ============================================================================
APP_HOME := $(RAPTOR_HOME)/app

app-run: build-rv32 ## [app] Run USER_ELF via pk on NPC
	@$(MAKE) --no-print-directory -C $(APP_HOME) pk-run USER_ELF=$(USER_ELF) ARGS="$(ARGS)"

app-run-nemu: build-nemu32 ## [app] Run USER_ELF via pk on NEMU
	@$(MAKE) --no-print-directory -C $(APP_HOME) nemu-run USER_ELF=$(USER_ELF) ARGS="$(ARGS)"

app-bbl-linux: build-rv32 ## [app] Boot Linux via BBL on NPC
	@$(MAKE) --no-print-directory -C $(APP_HOME) bbl-linux ARGS="$(ARGS)"

app-hello-rv32: build-rv32 ## [app] Hello world test via pk (rv32)
	@set -o pipefail; $(MAKE) --no-print-directory -C $(APP_HOME) hello-sim ARGS="$(ARGS)" $(call tee_app,hello-rv32)

app-coremark-rv32: build-rv32 ## [app] CoreMark via pk (rv32)
	@set -o pipefail; $(MAKE) --no-print-directory -C $(APP_HOME) coremark-sim ARGS="$(ARGS)" $(call tee_app,coremark-rv32)
	$(call coremark_mhz_report,$(APP_LOG_DIR)/coremark-rv32.log)

# CoreMark via pk with aggressive optim flags + CoreMark/MHz report. The app
# CoreMark build (app/benchmarks/coremark) does not track CFLAGS changes, so its
# build dir is cleaned first to force a rebuild with COREMARK_OPTIM_CFLAGS.
app-coremark-rv32-optim: build-rv32 ## [app] CoreMark via pk (rv32) with aggressive optim flags + CoreMark/MHz report
	@$(MAKE) --no-print-directory -C $(APP_HOME)/benchmarks/coremark clean
	@set -o pipefail; $(MAKE) --no-print-directory -C $(APP_HOME) coremark-sim ARGS="$(ARGS)" COREMARK_OPTIM_CFLAGS="$(COREMARK_OPTIM_CFLAGS)" $(call tee_app,coremark-rv32-optim)
	$(call coremark_mhz_report,$(APP_LOG_DIR)/coremark-rv32-optim.log)

app-coremark-rv64-optim: VFLAGS := -DRAPT_RV64
app-coremark-rv64-optim: build-rv64 ## [app] CoreMark via pk (rv64) with aggressive optim flags + CoreMark/MHz report
	@$(MAKE) --no-print-directory -C $(APP_HOME)/benchmarks/coremark ISA64=1 clean
	@set -o pipefail; $(MAKE) --no-print-directory -C $(APP_HOME) ISA64=1 coremark-sim ARGS="$(ARGS)" VFLAGS="$(VFLAGS)" COREMARK_OPTIM_CFLAGS="$(COREMARK_OPTIM_CFLAGS)" $(call tee_app,coremark-rv64-optim)
	$(call coremark_mhz_report,$(APP_LOG_DIR)/coremark-rv64-optim.log)

app-coremark-nemu32: config-nemu32 ## [app] CoreMark via pk on NEMU (rv32)
	@set -o pipefail; $(MAKE) --no-print-directory -C $(APP_HOME) coremark-nemu ARGS="$(ARGS)" $(call tee_app,coremark-nemu32)

app-embench-rv32: build-rv32 ## [app] Build, run, and report Embench-IoT via pk (rv32)
	@$(MAKE) --no-print-directory -C $(APP_HOME) embench-sim \
		ISA64=0 ARGS="$(ARGS)" EMBENCH_JOBS=$(JOBS)

app-embench-pk-run-rv32: build-rv32 ## [app] Run pk/MMU Embench-IoT and save logs (rv32)
	@$(MAKE) --no-print-directory -C $(APP_HOME) embench-pk-run-sim \
		ISA64=0 ARGS="$(ARGS)" EMBENCH_JOBS=$(JOBS)

app-embench-pk-report-rv32: ## [app] Generate Markdown from existing pk/MMU Embench logs (rv32)
	@$(MAKE) --no-print-directory -C $(APP_HOME) embench-pk-report-sim ISA64=0

app-embench-baremetal-rv32: build-rv32 ## [app] Bare-metal Embench-IoT with per-benchmark logs and score (rv32)
	@$(MAKE) --no-print-directory -C $(APP_HOME) embench-baremetal-sim \
		ISA64=0 ARGS="$(ARGS)" EMBENCH_JOBS=$(JOBS)

app-embench-baremetal-run-rv32: build-rv32 ## [app] Run bare-metal Embench-IoT and save logs (rv32)
	@$(MAKE) --no-print-directory -C $(APP_HOME) embench-baremetal-run-sim \
		ISA64=0 ARGS="$(ARGS)" EMBENCH_JOBS=$(JOBS)

app-embench-baremetal-report-rv32: ## [app] Generate Markdown from existing bare-metal Embench logs (rv32)
	@$(MAKE) --no-print-directory -C $(APP_HOME) embench-baremetal-report-sim ISA64=0

app-embench-nemu32: config-nemu32 ## [app] Embench-IoT via pk on NEMU (rv32)
	@set -o pipefail; $(MAKE) --no-print-directory -C $(APP_HOME) embench-nemu ARGS="$(ARGS)" $(call tee_app,embench-nemu32)

app-llm-rv32: build-rv32 ## [app] LLM operator/infer/train benchmarks via pk (rv32)
	@set -o pipefail; $(MAKE) --no-print-directory -C $(APP_HOME) llm-bench-report-sim ARGS="$(ARGS)" $(call tee_app,llm-rv32)

app-llm-nemu32: config-nemu32 ## [app] LLM operator/infer/train benchmarks via pk on NEMU (rv32)
	@set -o pipefail; $(MAKE) --no-print-directory -C $(APP_HOME) llm-bench-report-nemu ARGS="$(ARGS)" $(call tee_app,llm-nemu32)

# --- app tests/demos on NPC ---
app-tests-rv32: build-rv32 ## [app] All tests via pk on NPC (rv32)
	@set -o pipefail; $(MAKE) --no-print-directory -C $(APP_HOME) tests-sim ARGS="$(ARGS)" $(call tee_app,tests-rv32)

app-tests-rv32-difftest: config-rv32 config-nemu32-ref ## [app] All tests via pk on NPC with difftest
	@set -o pipefail; $(MAKE) --no-print-directory -C $(APP_HOME) tests-sim ARGS="$(ARGS)" $(call tee_app,tests-rv32-difftest)

app-demos-rv32: build-rv32 ## [app] All demos via pk on NPC (rv32)
	@set -o pipefail; $(MAKE) --no-print-directory -C $(APP_HOME) demos-sim ARGS="$(ARGS)" $(call tee_app,demos-rv32)

# --- app tests/demos on NEMU (default: with difftest) ---
app-tests-nemu32: config-nemu32 ## [app] All tests via pk on NEMU (rv32)
	@set -o pipefail; $(MAKE) --no-print-directory -C $(APP_HOME) tests-nemu ARGS="$(ARGS)" $(call tee_app,tests-nemu32)

app-demos-nemu32: config-nemu32 ## [app] All demos via pk on NEMU (rv32)
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

os-cli-nsim: ## [app] Boot upstream OS image on NPC/sim (OS=egos|xv6 or TINYOS_OS=egos|xv6)
	@$(MAKE) --no-print-directory -C $(APP_HOME) os-cli-nsim OS="$(OS)" TINYOS_OS="$(TINYOS_OS)" ARGS="$(ARGS)" MAX_INST="$(MAX_INST)" TIMEOUT="$(TIMEOUT)"

os-cli-nemu: ## [app] Boot upstream OS image on NEMU (OS=egos|xv6 or TINYOS_OS=egos|xv6)
	@$(MAKE) --no-print-directory -C $(APP_HOME) os-cli-nemu OS="$(OS)" TINYOS_OS="$(TINYOS_OS)" ARGS="$(ARGS)" MAX_INST="$(MAX_INST)"

egos-cli-nsim: ## [app] Boot upstream egos image on NPC/sim
	@$(MAKE) --no-print-directory -C $(APP_HOME) egos-cli-nsim ARGS="$(ARGS)" MAX_INST="$(MAX_INST)" TIMEOUT="$(TIMEOUT)"

egos-cli-nemu: ## [app] Boot upstream egos image on NEMU
	@$(MAKE) --no-print-directory -C $(APP_HOME) egos-cli-nemu ARGS="$(ARGS)" MAX_INST="$(MAX_INST)"

xv6-cli-nsim: ## [app] Boot upstream xv6-riscv on NPC/sim
	@$(MAKE) --no-print-directory -C $(APP_HOME) xv6-cli-nsim ARGS="$(ARGS)" MAX_INST="$(MAX_INST)" TIMEOUT="$(TIMEOUT)"

xv6-cli-nemu: ## [app] Boot upstream xv6-riscv on NEMU
	@$(MAKE) --no-print-directory -C $(APP_HOME) xv6-cli-nemu ARGS="$(ARGS)" MAX_INST="$(MAX_INST)"

app-pk-build: ## [app] Build riscv-pk
	@$(MAKE) --no-print-directory -C $(APP_HOME) pk-build

app-clean: ## [app] Clean app build artifacts
	@$(MAKE) --no-print-directory -C $(APP_HOME) clean

.PHONY: help setup setup-rtl verilog log logs-show logs-clean \
	config-nemu32 config-nemu32-linux config-nemu32-ref config-nemu32-linux-device menuconfig-nemu32 build-nemu32 run-nemu32 run-nemu32-linux run-nemu32-linux-device \
	config-nemu64 config-nemu64-ref config-nemu64-linux config-nemu64-linux-device build-nemu64 run-nemu64 run-nemu64-linux-device \
	config-rv32 config-rv32-difftest config-rv32-linux config-rv32-ysyxsoc build-rv32 run-rv32 sim-rv32 \
	build-rv64 run-rv64 lint-rv64 \
	am-kernels-hello-rv32 am-tests-cache-tests-rv32 am-tests-nemu32 am-tests-rv32 \
	cpu-tests-nemu32 cpu-tests-rv32 irq-tests-build irq-tests-rv32 irq-tests-rv32-difftest \
	repro-tests-build linux-ticket-spinlock-repro-rv32 sv32-sq-alias-repro-rv32 \
	coremark-rv32 coremark-rv64 coremark-rv32-optim coremark-rv64-optim coremark-rv32-difftest coremark-rv64-difftest coremark-ysyxsoc \
	microbench-rv32 microbench-rv64 microbench-rv32-difftest micorbench-rv32-difftest microbench-rv64-difftest microbench-ysyxsoc \
	dhrystone-rv32 dhrystone-rv32-difftest dhrystone-rv64 dhrystone-nemu32 dhrystone-rv32-optim dhrystone-rv64-optim \
	coremark-nemu32 microbench-nemu32 coremark-nemu64 microbench-nemu64 \
	archtest-rv32 archtest-rv32e \
	nanos-nemu32 nanos-rv32 \
	linux-download linux-download-rv32 linux-download-rv64 \
	linux-boot-nemu32 linux-boot-nemu64 linux-boot-rv32 linux-boot-rv32-difftest linux-boot-rv32gc linux-boot-rv64 linux-boot-rv64-difftest linux-boot-rv64gc linux-boot-nemu32-device linux-boot-nemu64-device \
	verify-linux-boot-rv32 verify-linux-memory-stress-rv32 verify-linux-memory-stress-from-ckpt-rv32 \
	linux-boot-rv32-ckpt-save linux-boot-rv32-ckpt-load \
	fpga-syn fpga-pnr pack lint lint-verible ide-setup compile-commands sta sta-detail sta-rv64 sta-detail-rv64 clean-npc clean \
	verify-fuzz verify-fp-smoke-rv32 verify-fp-smoke-rv64 verify-fp-spike-rv32 verify-fp-spike-rv64 verify-fp-arith-rv32 verify-fp-arith-rv64 verify-fp-arith-spike-rv32 verify-fp-arith-spike-rv64 verify-fp-double-rv32 verify-fp-double-rv64 verify-fuzz-inf verify-fuzz-replay verify-sigtest verify-riscof-classic verify-riscof-classic-nemu verify-riscof verify-riscv-dv verify-riscv-dv-stress verify-riscv-dv-mmu verify-coverage verify-all verify-clean \
	tinyos-sync os-cli-qemu egos-cli-qemu xv6-cli-qemu os-cli-nsim os-cli-nemu egos-cli-nsim egos-cli-nemu xv6-cli-nsim xv6-cli-nemu \
	app-hello-rv32 app-coremark-rv32 app-coremark-rv32-optim app-coremark-rv64-optim app-coremark-nemu32 \
	app-embench-rv32 app-embench-pk-run-rv32 app-embench-pk-report-rv32 \
	app-embench-baremetal-rv32 app-embench-baremetal-run-rv32 \
	app-embench-baremetal-report-rv32 app-embench-nemu32 app-llm-rv32 app-llm-nemu32 \
	app-tests-rv32 app-tests-rv32-difftest app-demos-rv32 \
	app-tests-nemu32 app-demos-nemu32 \
	app-run app-run-nemu app-bbl-linux app-pk-build app-clean

# ============================================================================
# Local overrides (private synthesis targets, not tracked by Git)
# ============================================================================
# Copy Makefile.local.example -> Makefile.local and fill in site-specific values.
-include Makefile.local

endif # Guard: root-only targets
