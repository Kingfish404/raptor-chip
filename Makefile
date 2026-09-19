# ============================================================================
# Environment variables (auto-sourced from env.sh, no manual `source` needed)
# ============================================================================
export RAPTOR_HOME := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
export NEMU_HOME := $(RAPTOR_HOME)/nemu
export NSIM_HOME := $(RAPTOR_HOME)/sim
export AM_HOME   := $(RAPTOR_HOME)/abstract-machine
export NAVY_HOME := $(RAPTOR_HOME)/abstract-machine/app/navy-apps
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
# Override `JOBS=N` to cap parallelism (default = half of NPROC).
# Override `JOBS=1` to recover deterministic interleaved output.
# ============================================================================
JOBS ?= $(shell awk 'BEGIN { n=$(NPROC); j=int(n / 2); print (j > 0 ? j : 1) }')## Parallel simulator instances (default: half of CPUs)

# Reuse GNU make's jobserver when this Makefile is entered recursively.  An
# explicit nested `-jN` disconnects that submake from the shared token pool,
# produces "resetting jobserver mode" warnings, and can oversubscribe a gate.
# Direct top-level invocations retain the historical NPROC parallel default.
SUBMAKE_JOBS = $(if $(filter --jobserver-auth=% --jobserver-fds=%,$(MAKEFLAGS)),,-j$(NPROC))

# Portable, pure-Verilator regression defaults.  The top-level gate runs
# independent suites concurrently, while keeping RV32/RV64/config-changing
# phases serialized so shared simulator and NEMU configuration cannot race.
VERILATOR_VERIFY_JOBS ?= $(JOBS)## Parallel suites/simulators in verify-verilator
VERILATOR_VERIFY_SUBMAKE_JOBS = $(if $(filter --jobserver-auth=% --jobserver-fds=%,$(MAKEFLAGS)),,-j$(VERILATOR_VERIFY_JOBS))
VERILATOR_VERIFY_BUILD_PROFILE ?= $(RAPT_CONFIG)-verify-verilator## Isolated NPC artifacts for the portable gate
VERILATOR_VERIFY_LINUX_BUILD_PROFILE ?= $(VERILATOR_VERIFY_BUILD_PROFILE)-linux-rv32## Keep Linux config/artifacts isolated
VERILATOR_VERIFY_RUN_JOBS ?= $(shell awk 'BEGIN { n=$(VERILATOR_VERIFY_JOBS); j=int(n / 2); print (j > 0 ? j : 1) }')## Per-suite jobs when CPU and IRQ run together
VERILATOR_VERIFY_SUITE_JOBS ?= $(shell awk 'BEGIN { n=$(VERILATOR_VERIFY_JOBS); print (n > 1 ? 2 : 1) }')## Concurrent CPU/IRQ suite drivers
VERILATOR_VERIFY_SUITE_SUBMAKE_JOBS = $(if $(filter --jobserver-auth=% --jobserver-fds=%,$(MAKEFLAGS)),,-j$(VERILATOR_VERIFY_SUITE_JOBS))
VERILATOR_VERIFY_DELAY ?= 31## Maximum randomized AXI wait cycles
VERILATOR_VERIFY_APP_DELAY ?= 3## App/PK AXI delay; high-delay stress runs in the other suites
VERILATOR_VERIFY_SEED ?= 1## Reproducible program and AXI timing seed
VERILATOR_VERIFY_TIMEOUT ?= 900## Wall-clock limit per whole-core test
VERILATOR_VERIFY_LINUX_DELAY ?= 7## Linux AXI delay; bounded so multi-seed boots remain practical
VERILATOR_VERIFY_LINUX_DT_SOURCE ?= spike-rv32ima-verilator.dts## Fast-boot DT used only by this gate
VERILATOR_VERIFY_FUZZ_NUM ?= 50## Random programs per XLEN in the gate
VERILATOR_VERIFY_FUZZ_LEN ?= 500## Instructions per random program
VERILATOR_VERIFY_RV64 ?= 1## Include RV64 whole-core fuzz/sigtest/app tests
VERILATOR_VERIFY_RISCV_DV ?= 1## Include riscv-dv delay/seed matrix
VERILATOR_VERIFY_RAPTOS ?= 1## Include modular RaptOS memory/atomic stress
VERILATOR_VERIFY_RISCOF ?= 1## Include ACT4 and classic RISCOF compliance
VERILATOR_VERIFY_LINUX ?= 1## Include RV32 Linux randomized-latency boots
VERILATOR_VERIFY_LINUX_TIMEOUT ?= 7200## Wall-clock limit per randomized Linux boot
VERILATOR_VERIFY_LINUX_SEEDS ?= 1## One deep Linux kernel-boot seed; override for soak runs
VERILATOR_VERIFY_MEM_SEEDS ?= 1 2 7## Multi-seed RaptOS memory/atomic stress
VERILATOR_VERIFY_DV_DELAYS ?= 0 7 31 63 233## AXI delay maxima for riscv-dv
VERILATOR_VERIFY_DV_SEEDS ?= 1 2 7## Preserve a multi-seed riscv-dv timing matrix
VERILATOR_VERIFY_ARGS = $(ARGS) -t $(VERILATOR_VERIFY_TIMEOUT) --no-lightsss \
	--mem-random-delay=$(VERILATOR_VERIFY_DELAY) \
	--mem-random-seed=$(VERILATOR_VERIFY_SEED)
VERILATOR_VERIFY_APP_ARGS = $(ARGS) -t $(VERILATOR_VERIFY_TIMEOUT) --no-lightsss \
	--mem-random-delay=$(VERILATOR_VERIFY_APP_DELAY) \
	--mem-random-seed=$(VERILATOR_VERIFY_SEED)

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
NPC_LOG_DIR  = $(NSIM_HOME)/build/$(or $(strip $(BUILD_PROFILE)),$(RAPT_CONFIG))/logs
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
define nemu_build
	+$(MAKE) -C $(NEMU_HOME) $(1)
	+$(MAKE) -C $(NEMU_HOME) $(SUBMAKE_JOBS)
endef

build-nemu32: ## Build NEMU (riscv32 default)
	$(call nemu_build,$(NEMU_DEFCONFIG))

build-nemu32-linux:
	$(call nemu_build,riscv32_linux_defconfig)

build-nemu32gc-linux: ## Build NEMU for RV32GC Buildroot Linux
	$(call nemu_build,riscv32gc_linux_defconfig)

build-nemu32-ref:
	$(call nemu_build,riscv32_ref_defconfig)

menuconfig-nemu32: ## Open NEMU menuconfig
	$(MAKE) -C $(NEMU_HOME) menuconfig


run-nemu32: build-nemu32 ## Build and run NEMU (riscv32)
	$(MAKE) -C $(NEMU_HOME) run $(if $(IMG),IMG=$(IMG)) ARGS="$(ARGS) $(NEMU_DISK_ARG) $(NEMU_SDCARD_ARG)"

run-nemu32-linux: build-nemu32-linux
	$(MAKE) -C $(NEMU_HOME) run $(if $(IMG),IMG=$(IMG)) ARGS="$(ARGS)"

build-nemu32-linux-device:
	$(call nemu_build,riscv32_linux_device_defconfig)

DEVICE_ARGS ?= -b ## Args for -device targets (interactive by default)

run-nemu32-linux-device: build-nemu32-linux-device ## Run NEMU RV32 with VGA screen + keyboard
	$(MAKE) -C $(NEMU_HOME) run $(if $(IMG),IMG=$(IMG)) ARGS="$(DEVICE_ARGS)"

# --- RV64 NEMU targets ---
build-nemu64: ## Build NEMU (riscv64)
	$(call nemu_build,$(NEMU64_DEFCONFIG))

build-nemu64-ref:
	$(call nemu_build,riscv64_ref_defconfig)

run-nemu64: build-nemu64 ## Build and run NEMU (riscv64)
	$(MAKE) -C $(NEMU_HOME) run $(if $(IMG),IMG=$(IMG)) ARGS="$(ARGS) $(NEMU_DISK_ARG) $(NEMU_SDCARD_ARG)"

build-nemu64-linux:
	$(call nemu_build,riscv64_linux_defconfig)

build-nemu64gc-linux: ## Build NEMU for RV64GC Buildroot Linux
	$(call nemu_build,riscv64gc_linux_defconfig)

build-nemu64-linux-device:
	$(call nemu_build,riscv64_linux_device_defconfig)

run-nemu64-linux-device: build-nemu64-linux-device ## Run NEMU RV64 with VGA screen + keyboard
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
build-nemu32-difftest: build-spike-diff32 ## Build NEMU RV32 binary with spike-diff enabled
	$(MAKE) -C $(NEMU_HOME) riscv32_difftest_defconfig
	$(MAKE) -C $(NEMU_HOME) $(SUBMAKE_JOBS)

build-nemu64-difftest: build-spike-diff64 ## Build NEMU RV64 binary with spike-diff enabled
	$(MAKE) -C $(NEMU_HOME) riscv64_difftest_defconfig
	$(MAKE) -C $(NEMU_HOME) $(SUBMAKE_JOBS)


# ============================================================================
# NPC Simulation Targets
# ============================================================================
NPC_DEFCONFIG ?= $(if $(filter 1,$(DIFFTEST)),o2_difftest_defconfig,o2_defconfig) ## NPC simulator defconfig profile
DIFFTEST ?= 1## Enable NEMU differential checking in sim (0|1)
DIFFTEST := $(strip $(DIFFTEST))
ifeq ($(filter $(DIFFTEST),0 1),)
$(error DIFFTEST must be 0 or 1)
endif
export DIFFTEST
NPC_ARCH ?= riscv32-npc ## Override ARCH for AM targets

# RV64 mode: set via `make run-rv64` or explicitly `make run-rv32 VFLAGS="-DRAPT_RV64"`.
# sim Verilator simulation enables RTL assertions by default via RAPT_SIM_ASSERT;
# pack/STA/FPGA synthesis paths do not receive the default assertion define.
VFLAGS ?= ## Extra RTL defines for NPC (-DRAPT_RV64, etc.)
RAPT_SIM_ASSERT ?= 1## Enable RTL SVA assertions by default in NPC Verilator simulation (1=on, 0=off)
RAPT_SIM_ASSERT := $(strip $(RAPT_SIM_ASSERT))
export RAPT_SIM_ASSERT

configure-rv32: ## Apply RV32 simulator configuration only
configure-rv64: ## Apply RV64 simulator configuration only
configure-rv32 configure-rv64:
	$(MAKE) -C $(NSIM_HOME) $(NPC_DEFCONFIG) VFLAGS="$(if $(filter configure-rv64,$@),-DRAPT_RV64,$(VFLAGS))"

menuconfig-rv32: ## Open simulator Kconfig for the selected profile
	$(MAKE) -C $(NSIM_HOME) menuconfig VFLAGS="$(VFLAGS)"

# Each build has its own recipe: make -j build-rv32 build-rv64 must not share
# a prerequisite whose target-specific VFLAGS depend on visitation order.
build-rv32: ## Configure and build the RV32 simulator
build-rv64: ## Configure and build the RV64 simulator
build-rv32 build-rv64:
	$(MAKE) --no-print-directory configure-$(lastword $(subst -, ,$@))
	$(MAKE) -C $(NSIM_HOME) all VFLAGS="$(if $(filter build-rv64,$@),-DRAPT_RV64,$(VFLAGS))"

build-rv32-linux: ## Configure and build the RV32 Linux simulator
build-rv64-linux: ## Configure and build the RV64 Linux simulator
build-rv32-linux build-rv64-linux:
	$(MAKE) -C $(NSIM_HOME) $(if $(filter 1,$(DIFFTEST)),o2linux_difftest_defconfig,o2linux_defconfig) VFLAGS="$(if $(filter build-rv64-linux,$@),-DRAPT_RV64,$(VFLAGS))"
	$(MAKE) -C $(NSIM_HOME) all VFLAGS="$(if $(filter build-rv64-linux,$@),-DRAPT_RV64,$(VFLAGS))"

run-rv32: build-rv32 ## Build and run the RV32 simulator
	$(MAKE) -C $(NSIM_HOME) run ARGS="$(ARGS)" VFLAGS="$(VFLAGS)" $(if $(IMG),IMG=$(IMG)) $(if $(DISK),DISK=$(DISK)) $(if $(SDCARD),SDCARD=$(SDCARD))

run-rv64: build-rv64 ## Build and run the RV64 simulator
	$(MAKE) -C $(NSIM_HOME) run ARGS="$(ARGS)" VFLAGS="-DRAPT_RV64" $(if $(IMG),IMG=$(IMG)) $(if $(DISK),DISK=$(DISK)) $(if $(SDCARD),SDCARD=$(SDCARD))

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

coremark-nemu32: $(AM_KERNELS) build-nemu32 ## Run CoreMark on NEMU (riscv32)
	@set -o pipefail; $(COREMARK_MAKE) ARCH=riscv32-nemu run ARGS="$(ARGS)" $(call tee_nemu,coremark-nemu32)

microbench-nemu32: $(AM_KERNELS) build-nemu32 ## Run MicroBench on NEMU (riscv32)
	@set -o pipefail; $(MAKE) -C $(AM_KERNELS)/benchmarks/microbench ARCH=riscv32-nemu run ARGS="$(ARGS)" mainargs=$(MAINARGS) $(call tee_nemu,microbench-nemu32-$(MAINARGS))

coremark-nemu64: $(AM_KERNELS) build-nemu64 ## Run CoreMark on NEMU (riscv64)
	@set -o pipefail; $(COREMARK_MAKE) ARCH=riscv64-nemu run ARGS="$(ARGS)" $(call tee_nemu,coremark-nemu64)

microbench-nemu64: $(AM_KERNELS) build-nemu64 ## Run MicroBench on NEMU (riscv64)
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
	      || { echo "[cpu-tests-$(1)] BUILD FAIL: $$t"; build_fail=1; }; \
	  done; \
	  rm -f Makefile.*; \
	  if [ "$${build_fail:-0}" -ne 0 ]; then exit 1; fi; \
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

cpu-tests-rv32: build-rv32 ## Build and run AM cpu-tests on NPC (parallel)
	$(MAKE) cpu-tests-rv32-run

cpu-tests-rv64: build-rv64 ## Build and run AM cpu-tests on RV64 (parallel)
	$(MAKE) cpu-tests-rv64-run

cpu-tests-rv32-run: ## Run AM cpu-tests on an already-built NPC (parallel)
	+@set -o pipefail; \
	  NPC_CMD=$$($(MAKE) --no-print-directory -C $(NSIM_HOME) VFLAGS="$(VFLAGS)" print-npc-exec | tail -1) \
	    || { echo "[cpu-tests-rv32] ERROR: print-npc-exec failed"; exit 1; }; \
	  $(call run_cpu_tests_parallel,rv32,"$$NPC_CMD",$(NPC_ARCH),$(NPC_LOG_DIR)/cpu-tests-rv32.log)

cpu-tests-rv64-run: VFLAGS := -DRAPT_RV64
cpu-tests-rv64-run: ## Run AM cpu-tests on an already-built RV64 NPC (parallel)
	+@set -o pipefail; \
	  NPC_CMD=$$($(MAKE) --no-print-directory -C $(NSIM_HOME) VFLAGS="$(VFLAGS)" print-npc-exec | tail -1) \
	    || { echo "[cpu-tests-rv64] ERROR: print-npc-exec failed"; exit 1; }; \
	  $(call run_cpu_tests_parallel,rv64,"$$NPC_CMD",riscv64-npc,$(NPC_LOG_DIR)/cpu-tests-rv64.log)


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
	+@set -o pipefail; \
	  NPC_CMD=$$($(MAKE) --no-print-directory -C $(NSIM_HOME) VFLAGS="$(VFLAGS)" print-npc-exec | tail -1) \
	    || { echo "[$(2)] ERROR: print-npc-exec failed"; exit 1; }; \
	  { \
	    echo "=== IRQ tests ($(1), parallel JOBS=$(JOBS)) ==="; \
	    ( for t in $(IRQ_TESTS); do printf '%s|%s\n' "$$t" "$(IRQ_TESTS_DIR)/$$t.bin"; done ) \
	    | NPC_CMD="$$NPC_CMD" SIM_ARGS="$(ARGS) --trap-on-ebreak" NSIM_HOME="$(NSIM_HOME)" \
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

irq-tests-rv32: build-rv32 ## Build and run bare-metal PLIC IRQ tests
	$(MAKE) irq-tests-rv32-run

irq-tests-rv32-run: irq-tests-build ## Run bare-metal PLIC IRQ tests on an already-built NPC
	$(call run_irq_tests_parallel,bare-metal,irq-tests-rv32)

# --- Minimal Linux-pattern repros -----------------------------------------
REPRO_TESTS_DIR := $(RAPTOR_HOME)/app/build/rv32/tests/repro

repro-tests-build: ## Build bare-metal minimal repro tests
	$(MAKE) -C $(RAPTOR_HOME)/app/tests/repro build

linux-ticket-spinlock-repro-rv32: build-rv32 repro-tests-build ## Run Linux ticket-spinlock AMO/SH/LW repro on NPC
	$(MAKE) --no-print-directory -C $(NSIM_HOME) run \
		ARGS="$(ARGS)" VFLAGS="$(VFLAGS)" \
		IMG=$(REPRO_TESTS_DIR)/linux_ticket_spinlock.bin

COREMARK_MAKE = $(MAKE) -C $(AM_KERNELS)/benchmarks/coremark_eembc -f Makefile -f $(RAPTOR_HOME)/verify/benchmark-build.mk

coremark-rv32: $(AM_KERNELS) build-rv32 ## Run CoreMark on NPC
	@set -o pipefail; $(COREMARK_MAKE) ARCH=$(NPC_ARCH) run ARGS="$(ARGS)" mainargs=$(MAINARGS) $(call tee_npc,coremark-rv32)
	$(call coremark_mhz_report,$(NPC_LOG_DIR)/coremark-rv32.log)

microbench-rv32: $(AM_KERNELS) build-rv32 ## Run MicroBench on NPC
	@set -o pipefail; $(MAKE) -C $(AM_KERNELS)/benchmarks/microbench ARCH=$(NPC_ARCH) run ARGS="$(ARGS)" mainargs=$(MAINARGS) $(call tee_npc,microbench-rv32-$(MAINARGS))

# --- RV64 benchmark targets ---
coremark-rv64: VFLAGS := -DRAPT_RV64
coremark-rv64: $(AM_KERNELS) build-rv64 ## Run CoreMark on NPC (riscv64)
	@set -o pipefail; $(COREMARK_MAKE) ARCH=riscv64-npc run ARGS="$(ARGS)" VFLAGS="$(VFLAGS)" $(call tee_npc,coremark-rv64)
	$(call coremark_mhz_report,$(NPC_LOG_DIR)/coremark-rv64.log)

microbench-rv64: VFLAGS := -DRAPT_RV64
microbench-rv64: $(AM_KERNELS) build-rv64 ## Run MicroBench on NPC (riscv64)
	@set -o pipefail; $(MAKE) -C $(AM_KERNELS)/benchmarks/microbench ARCH=riscv64-npc run ARGS="$(ARGS)" VFLAGS="$(VFLAGS)" mainargs=$(MAINARGS) $(call tee_npc,microbench-rv64-$(MAINARGS))

SIM_RANDOM_DELAY ?= 0## Maximum randomized memory delay (0 disables)
SIM_RANDOM_SEED ?= 1## Reproducible memory-delay seed
export SIM_RANDOM_DELAY SIM_RANDOM_SEED
include $(RAPTOR_HOME)/verify/benchmark-options.mk

# Parse a tee'd CoreMark + sim run log and print the CoreMark/MHz score. The pk
# port publishes cycle/instret deltas for CoreMark's timed region; older ports
# fall back to the simulator-wide PMU cycle count.
# $(1) = path to the log file produced by tee_npc.
define coremark_mhz_report
@awk '/^[ \t]*Iterations[ \t]*:/{for(i=1;i<=NF;i++)if($$i~/^[0-9]+$$/)it=$$i} /^CoreMark ROI cycles[ \t]*:/{roi_cy=$$NF} /^CoreMark ROI instructions[ \t]*:/{roi_in=$$NF} /#inst:/{if(match($$0,/cycle:[ \t]*[0-9]+/)){c=substr($$0,RSTART,RLENGTH);gsub(/[^0-9]/,"",c);sim_cy=c}} END{cy=(roi_cy+0>0)?roi_cy:sim_cy;label=(roi_cy+0>0)?"ROI cycles":"Active cycles (fallback)";if(it+0>0&&cy+0>0){printf "\n==================== CoreMark/MHz ====================\n";printf "Iterations    : %d\n",it;printf "%-14s: %d\n",label,cy;printf "CoreMark/MHz  : %.4f  (= %d * 1e6 / %d)\n",it*1000000.0/cy,it,cy;if(roi_in+0>0)printf "Core IPC      : %.4f  (= %d / %d)\n",roi_in/cy,roi_in,cy;printf "======================================================\n"}else{printf "[CoreMark/MHz] WARN: could not parse iterations(%s) / cycles(%s) from %s\n",it,cy,"$(1)"}}' "$(1)"
endef

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

dhrystone-rv32: $(AM_KERNELS) build-rv32 ## Run Dhrystone on NPC (DMIPS + DMIPS/MHz)
	@set -o pipefail; $(MAKE) -C $(AM_KERNELS)/benchmarks/dhrystone -f Makefile -f $(RAPTOR_HOME)/verify/benchmark-build.mk ARCH=$(NPC_ARCH) run ARGS="$(ARGS)" $(call tee_npc,dhrystone-rv32)
	$(call dhrystone_dmips_report,$(NPC_LOG_DIR)/dhrystone-rv32.log)

dhrystone-rv64: VFLAGS := -DRAPT_RV64
dhrystone-rv64: $(AM_KERNELS) build-rv64 ## Run Dhrystone on NPC (riscv64)
	@set -o pipefail; $(MAKE) -C $(AM_KERNELS)/benchmarks/dhrystone -f Makefile -f $(RAPTOR_HOME)/verify/benchmark-build.mk ARCH=riscv64-npc run ARGS="$(ARGS)" VFLAGS="$(VFLAGS)" $(call tee_npc,dhrystone-rv64)
	$(call dhrystone_dmips_report,$(NPC_LOG_DIR)/dhrystone-rv64.log)

dhrystone-nemu32: $(AM_KERNELS) build-nemu32 ## Run Dhrystone on NEMU (riscv32, functional check)
	@set -o pipefail; $(MAKE) -C $(AM_KERNELS)/benchmarks/dhrystone -f Makefile -f $(RAPTOR_HOME)/verify/benchmark-build.mk ARCH=riscv32-nemu run ARGS="$(ARGS)" $(call tee_nemu,dhrystone-nemu32)

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

# Linux/OpenSBI legitimately executes EBREAK while probing semihosting and
# handles the resulting breakpoint through mtvec.  Do not interpret those
# instructions as the bare-metal AM good/bad-trap convention.
LINUX_NPC_ARGS ?= --trap-on-ebreak
# Stop as soon as the boot milestone checked by check_linux_boot.py is complete;
# waiting for a later interactive-shell prompt adds userspace work to this CPU
# boot gate without strengthening the milestone that the checker validates.
LINUX_VERIFY_NPC_ARGS ?= $(LINUX_NPC_ARGS) --serial-exit-on=process --no-lightsss

linux-download-rv32: ## Download pre-built Linux (RV32 only)
	$(MAKE) -C $(LINUX_HOME) download-rv32

linux-download-rv64: ## Download pre-built Linux (RV64 only)
	$(MAKE) -C $(LINUX_HOME) download-rv64

linux-download-rv32gc: ## Download fast RV32GC Buildroot Linux for simulation
	$(MAKE) -C $(LINUX_HOME) download-rv32gc

linux-download-rv64gc: ## Download fast RV64GC Buildroot Linux for simulation
	$(MAKE) -C $(LINUX_HOME) download-rv64gc

linux-download-rv32gc-fpga: ## Download complete RV32GC Buildroot Linux for FPGA
	$(MAKE) -C $(LINUX_HOME) download-rv32gc-fpga

linux-download: ## Download pre-built Linux (RV32 + RV64)
	$(MAKE) -C $(LINUX_HOME) download

# Canned recipes: download payload, (re)build sim with VFLAGS, run + tee log.
# $(1) = rv32|rv64 (linux/Makefile download suffix), $(2) = payload image,
# $(3) = log stem.
# $(4) = optional sim variable override. Linux NPC targets leave this unset so
#        sim/Makefile supplies the matching NEMU difftest reference by default;
#        pass DIFF_REF_SO= explicitly only when isolating a simulator failure.
# $(5) = optional extra variables propagated to BOTH the `make -C sim` build
#        and the `make -C sim run` invocation (e.g. DT_SOURCE=...).
define linux_boot_npc
	+@if ! test -f "$(2)"; then $(MAKE) -C $(LINUX_HOME) download-$(1); fi
	+$(MAKE) -C $(NSIM_HOME) $(SUBMAKE_JOBS) VFLAGS="$(VFLAGS)" $(5)
	+@set -o pipefail; $(MAKE) -C $(NSIM_HOME) run IMG=$(2) ARGS="$(LINUX_NPC_ARGS) $(ARGS) $(if $(MAX_INST),-m $(MAX_INST))" VFLAGS="$(VFLAGS)" $(4) $(5) $(call tee_npc,$(3))
endef

define linux_boot_nemu
	+@if ! test -f "$(2)"; then $(MAKE) -C $(LINUX_HOME) download-$(1); fi
	@set -o pipefail; $(MAKE) -C $(NEMU_HOME) run IMG=$(2) ARGS="$(ARGS) $(if $(MAX_INST),-m $(MAX_INST))" $(call tee_nemu,$(3))
endef

linux-boot-nemu32: build-nemu32-linux ## Boot Linux on NEMU (riscv32)
	$(call linux_boot_nemu,rv32,$(LINUX_RV32_PAYLOAD),linux-boot-nemu32)

linux-boot-nemu32gc: build-nemu32gc-linux ## Boot RV32GC Buildroot Linux on NEMU
	$(if $(filter $(LINUX_RV32GC_SIM_PAYLOAD),$(LINUX_RV32GC_PAYLOAD)),$(MAKE) -C $(LINUX_HOME) opensbi-rv32gc-payload)
	@test -f "$(LINUX_RV32GC_PAYLOAD)" || { echo "[ERR] rv32gc payload not found: $(LINUX_RV32GC_PAYLOAD)"; \
		echo "      Run 'make linux-download-rv32gc' or override LINUX_RV32GC_PAYLOAD=/path/to/fw_payload.bin"; exit 1; }
	@set -o pipefail; $(MAKE) -C $(NEMU_HOME) run IMG=$(LINUX_RV32GC_PAYLOAD) \
		ARGS="$(ARGS) $(if $(MAX_INST),-m $(MAX_INST))" $(call tee_nemu,linux-boot-nemu32gc)

linux-boot-nemu64: build-nemu64-linux ## Boot Linux on NEMU (riscv64)
	$(call linux_boot_nemu,rv64,$(LINUX_RV64_PAYLOAD),linux-boot-nemu64)

linux-boot-nemu64gc: build-nemu64gc-linux ## Boot RV64GC Buildroot Linux on NEMU
	$(if $(filter $(LINUX_RV64GC_SIM_PAYLOAD),$(LINUX_RV64GC_PAYLOAD)),$(MAKE) -C $(LINUX_HOME) opensbi-rv64gc-payload)
	@test -f "$(LINUX_RV64GC_PAYLOAD)" || { echo "[ERR] rv64gc payload not found: $(LINUX_RV64GC_PAYLOAD)"; \
		echo "      Run 'make linux-download-rv64gc' or override LINUX_RV64GC_PAYLOAD=/path/to/fw_payload.bin"; exit 1; }
	@set -o pipefail; $(MAKE) -C $(NEMU_HOME) run IMG=$(LINUX_RV64GC_PAYLOAD) \
		ARGS="$(ARGS) $(if $(MAX_INST),-m $(MAX_INST))" $(call tee_nemu,linux-boot-nemu64gc)

linux-boot-rv32: build-nemu32-ref build-rv32-linux ## Boot Linux on NPC with NEMU difftest (riscv32)
	$(call linux_boot_npc,rv32,$(LINUX_RV32_PAYLOAD),linux-boot-rv32)

# rv32gc Buildroot (hard-float F/D userspace) boot. Uses the spike-rv32gc.dts
# DTB (riscv,isa=rv32imafdc...) so the kernel sees the F/D extensions. By
# default, the fast Buildroot Image is re-wrapped with simulation-safe OpenSBI;
# override LINUX_RV32GC_PAYLOAD to use a different ready-made payload.
linux-boot-rv32gc: build-nemu32-ref build-rv32-linux ## Boot rv32gc Buildroot Linux on NPC with NEMU difftest
	$(if $(filter $(LINUX_RV32GC_SIM_PAYLOAD),$(LINUX_RV32GC_PAYLOAD)),$(MAKE) -C $(LINUX_HOME) opensbi-rv32gc-payload)
	@test -f "$(LINUX_RV32GC_PAYLOAD)" || { echo "[ERR] rv32gc payload not found: $(LINUX_RV32GC_PAYLOAD)"; \
		echo "      Run 'make linux-download-rv32gc' to fetch the release image,"; \
		echo "      or override LINUX_RV32GC_PAYLOAD=/path/to/fw_payload.bin"; exit 1; }
	$(call linux_boot_npc,rv32,$(LINUX_RV32GC_PAYLOAD),linux-boot-rv32gc,,DT_SOURCE=spike-rv32gc.dts)

# rv64gc Buildroot (hard-float F/D userspace) boot; mirrors linux-boot-rv32gc.
# RV64 datapath via VFLAGS=-DRAPT_RV64; DTB via spike-rv64gc.dts (sv39).
linux-boot-rv64gc: VFLAGS := -DRAPT_RV64
linux-boot-rv64gc: build-nemu64-ref build-rv64-linux ## Boot rv64gc Buildroot Linux on NPC with NEMU difftest
	$(if $(filter $(LINUX_RV64GC_SIM_PAYLOAD),$(LINUX_RV64GC_PAYLOAD)),$(MAKE) -C $(LINUX_HOME) opensbi-rv64gc-payload)
	@test -f "$(LINUX_RV64GC_PAYLOAD)" || { echo "[ERR] rv64gc payload not found: $(LINUX_RV64GC_PAYLOAD)"; \
		echo "      Run 'make linux-download-rv64gc' to fetch the release image,"; \
		echo "      or override LINUX_RV64GC_PAYLOAD=/path/to/fw_payload.bin"; exit 1; }
	$(call linux_boot_npc,rv64,$(LINUX_RV64GC_PAYLOAD),linux-boot-rv64gc,,DT_SOURCE=spike-rv64gc.dts)

LINUX_BOOT_MAX_INST ?= 120000000
LINUX_MEM_RANDOM_DELAY ?= 7
LINUX_MEM_STRESS_SEEDS ?= 1 2 7
LINUX_MEM_STRESS_MAX_INST ?= 400000000
LINUX_MEM_STRESS_TIMEOUT ?= 7200
LINUX_MEM_PROGRESS_CYCLES ?= 10000000
# The portable gate stops after memory, IRQ, timer, networking/DMA, and S-mode
# exception-delegation initialization.  Later debug-kernel initcalls take longer
# than the outer CI process lifetime under cycle-accurate simulation;
# verify-linux-boot-rv32 retains the full /init requirement.
LINUX_MEM_STRESS_MILESTONE ?= SBI misaligned access exception delegation ok
LINUX_MEM_STRESS_NPC_ARGS ?= $(LINUX_NPC_ARGS) --serial-exit-on='delegation ok' --no-lightsss
LINUX_CKPT_STRESS_MAX_INST ?= 300000000
LINUX_BOOT_CHECK := $(RAPTOR_HOME)/verify/scripts/check_linux_boot.py
LINUX_MEM_STRESS_PROFILE := $(or $(strip $(BUILD_PROFILE)),$(RAPT_CONFIG))
LINUX_MEM_STRESS_DT_SOURCE := $(if $(strip $(DT_SOURCE)),$(DT_SOURCE),spike-rv32ima.dts)
LINUX_MEM_STRESS_MROM_DIR := $(NSIM_HOME)/csrc/mem/mrom-data/build/rv32-$(basename $(notdir $(LINUX_MEM_STRESS_DT_SOURCE)))
LINUX_MEM_STRESS_MROM_IMG := $(LINUX_MEM_STRESS_MROM_DIR)/mrom-data.bin
LINUX_MEM_STRESS_NPC_BIN := $(NSIM_HOME)/build/$(LINUX_MEM_STRESS_PROFILE)/riscv32-npc-sim
LINUX_MEM_STRESS_NEMU_REF := $(NEMU_HOME)/build/riscv32-nemu-interpreter-so

verify-linux-boot-rv32: ## Boot RV32 Linux with difftest and require the /init milestone
	$(MAKE) --no-print-directory linux-boot-rv32 \
		ARGS="$(ARGS)" LINUX_NPC_ARGS="$(LINUX_VERIFY_NPC_ARGS)" \
		MAX_INST=$(LINUX_BOOT_MAX_INST)
	python3 $(LINUX_BOOT_CHECK) $(NPC_LOG_DIR)/linux-boot-rv32.log

verify-linux-memory-stress-rv32: build-nemu32-ref build-rv32-linux ## Boot RV32 Linux under randomized memory latency
	$(MAKE) -C $(LINUX_HOME) download-rv32
	+$(MAKE) -C $(NSIM_HOME)/csrc/mem/mrom-data BUILD_DIR=$(LINUX_MEM_STRESS_MROM_DIR) \
		ISA64=0 DT_SOURCE=$(LINUX_MEM_STRESS_DT_SOURCE)
	@set -eu -o pipefail; \
	mkdir -p $(NPC_LOG_DIR); \
	test -x "$(LINUX_MEM_STRESS_NPC_BIN)"; \
	test -f "$(LINUX_MEM_STRESS_NEMU_REF)"; \
	test -f "$(LINUX_MEM_STRESS_MROM_IMG)"; \
	for seed in $(LINUX_MEM_STRESS_SEEDS); do \
		echo "[Linux memory-stress] delay=$(LINUX_MEM_RANDOM_DELAY) seed=$$seed"; \
		log="$(NPC_LOG_DIR)/linux-memory-stress-delay$(LINUX_MEM_RANDOM_DELAY)-seed$$seed.log"; \
		( cd "$(NSIM_HOME)" && NSIM_PROGRESS_CYCLES=$(LINUX_MEM_PROGRESS_CYCLES) \
			"$(LINUX_MEM_STRESS_NPC_BIN)" $(LINUX_MEM_STRESS_NPC_ARGS) -b -n \
			-t $(LINUX_MEM_STRESS_TIMEOUT) -m $(LINUX_MEM_STRESS_MAX_INST) \
			--mem-random-delay=$(LINUX_MEM_RANDOM_DELAY) --mem-random-seed=$$seed \
			-d "$(LINUX_MEM_STRESS_NEMU_REF)" -r "$(LINUX_MEM_STRESS_MROM_IMG)" \
			"$(LINUX_RV32_PAYLOAD)" ) \
			2>&1 | tee "$$log"; \
		python3 $(LINUX_BOOT_CHECK) --success-marker "$(LINUX_MEM_STRESS_MILESTONE)" "$$log"; \
	done

linux-boot-rv64: VFLAGS := -DRAPT_RV64
linux-boot-rv64: build-nemu64-ref build-rv64-linux ## Boot Linux on NPC with NEMU difftest (riscv64)
	$(call linux_boot_npc,rv64,$(LINUX_RV64_PAYLOAD),linux-boot-rv64)

linux-boot-nemu32-device: build-nemu32-linux-device ## Boot Linux on NEMU RV32 (auto-download)
	$(MAKE) -C $(LINUX_HOME) download-rv32
	$(MAKE) -C $(NEMU_HOME) run IMG=$(LINUX_RV32_PAYLOAD) ARGS="$(DEVICE_ARGS)"

linux-boot-nemu64-device: build-nemu64-linux-device ## Boot Linux on NEMU RV64 (auto-download)
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

linux-boot-rv32-ckpt-save: build-nemu32-ref build-rv32-linux ## Boot Linux on NPC, save checkpoint at CKPT_CYCLE -> CKPT_DIR
	$(MAKE) -C $(LINUX_HOME) download-rv32
	+$(MAKE) -C $(NSIM_HOME) $(SUBMAKE_JOBS)
	rm -rf $(CKPT_DIR)
	$(MAKE) -C $(NSIM_HOME) run IMG=$(LINUX_RV32_PAYLOAD) \
		ARGS="$(LINUX_NPC_ARGS) $(ARGS) --ckpt-cycle=$(CKPT_CYCLE) --ckpt-save=$(CKPT_DIR) --ckpt-save-exit"

linux-boot-rv32-ckpt-load: build-nemu32-ref build-rv32-linux ## Resume Linux boot on NPC from CKPT_DIR
	+$(MAKE) -C $(NSIM_HOME) $(SUBMAKE_JOBS)
	$(MAKE) -C $(NSIM_HOME) run IMG=$(LINUX_RV32_PAYLOAD) \
		ARGS="$(LINUX_NPC_ARGS) $(ARGS) --ckpt-load=$(CKPT_DIR) $(if $(MAX_INST),-m $(MAX_INST))"

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
# Extend the HDL scope with every tracked SystemVerilog compilation unit.  Keep
# non-HDL .svh include fragments out: many are not parseable as standalone files.
ALL_SV_FORMAT_SOURCES := $(sort $(HDL_FORMAT_SOURCES) \
	$(addprefix $(RAPTOR_HOME)/,$(shell git -C $(RAPTOR_HOME) ls-files '*.sv')))

FORMAT_SCOPE ?= all## Formatting scope: hdl or all (includes testbenches)
FORMAT_SCOPE := $(strip $(FORMAT_SCOPE))
ifeq ($(filter $(FORMAT_SCOPE),hdl all),)
$(error FORMAT_SCOPE must be hdl or all)
endif
VERIBLE_FORMAT_SOURCES = $(if $(filter hdl,$(FORMAT_SCOPE)),$(HDL_FORMAT_SOURCES),$(ALL_SV_FORMAT_SOURCES))
format: ## Format tracked HDL/SystemVerilog (FORMAT_SCOPE=hdl|all)
format-check: ## Check formatting without changing files (FORMAT_SCOPE=hdl|all)
format format-check:
	@command -v $(VERIBLE_FORMAT) >/dev/null || { echo "ERROR: $(VERIBLE_FORMAT) not found"; exit 1; }
	@$(VERIBLE_FORMAT) --flagfile="$(VERIBLE_FLAGS)" --failsafe_success=false \
		$(if $(filter format-check,$@),--verify,--inplace) $(VERIBLE_FORMAT_SOURCES)

pack: ## Pack all SV files into one
	$(MAKE) -C $(NSIM_HOME) pack VFLAGS="$(VFLAGS)"

lint: ## Lint RTL with Verilator
	$(MAKE) -C $(NSIM_HOME) lint VFLAGS="$(VFLAGS)"

lint-verible: ## Lint RTL with Verible
	$(MAKE) -C $(NSIM_HOME) lint-verible

compile-commands: ## Generate root compile_commands.json from real NEMU+sim build commands
	bash $(RAPTOR_HOME)/.github/scripts/gen_compile_commands.sh

STA_PLATFORM ?= nangate45 ## STA platform: nangate45, asap7, sky130hd (alias: sky130)
CLK_FREQ_MHZ ?= 50 ## Target clock frequency for STA (MHz)
STA_SUMMARY_DETAIL ?= 0 ## Show per-module LSPD STA rows (0=grouped summary, 1=detail)

MEMORY ?= sram## STA storage model: sram or dff
XLEN ?= $(if $(findstring DRAPT_RV64,$(VFLAGS)),64,32)## STA datapath width (32|64)
sta: ## Synthesize and run STA (MEMORY=sram|dff XLEN=32|64)
sta-detail: ## STA with detailed path reports, using the same memory model
sta-check: ## Check packed RTL elaboration without technology mapping or STA
sta sta-detail sta-check:
	$(MAKE) -C $(NSIM_HOME) $@ MEMORY=$(MEMORY) XLEN=$(XLEN) STA_PLATFORM=$(STA_PLATFORM) CLK_FREQ_MHZ=$(CLK_FREQ_MHZ) VFLAGS="$(VFLAGS)"

sta-summary: ## Display all existing STA results without running STA
	@python3 "$(RAPTOR_HOME)/verify/scripts/sta_summary.py" \
		--whole-root "$(RAPTOR_HOME)/third_party/yosys-opensta/result" \
		--module-root "$(RAPTOR_HOME)/lspd/syn/build" \
		$(if $(filter 1,$(STA_SUMMARY_DETAIL)),--detail,)

SRAM_PLATFORM ?= $(strip $(STA_PLATFORM)) ## SRAM timing-model platform (defaults to STA_PLATFORM)

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
	@set -o pipefail; $(MAKE) -C $(VERIFY_HOME) riscof-classic RAPT_CONFIG=$(RAPT_CONFIG) $(call tee_verify,riscof-classic)

verify-riscof-classic-nemu: ## RISCOF classic compliance tests on NEMU reference
	@set -o pipefail; $(MAKE) -C $(VERIFY_HOME) riscof-classic-nemu $(call tee_verify,riscof-classic-nemu)

verify-riscof: ## RISCOF official compliance tests
	@set -o pipefail; $(MAKE) -C $(VERIFY_HOME) riscof RAPT_CONFIG=$(RAPT_CONFIG) $(call tee_verify,riscof)

verify-riscv-dv: ## riscv-dv privileged smoke across the memory-delay matrix
	@set -o pipefail; $(MAKE) -C $(VERIFY_HOME) riscv-dv $(call tee_verify,riscv-dv)

verify-riscv-dv-stress: ## riscv-dv exception stress across delay/seed matrix
	@set -o pipefail; $(MAKE) -C $(VERIFY_HOME) riscv-dv-stress $(call tee_verify,riscv-dv-stress)

verify-riscv-dv-mmu: ## Check riscv-dv Sv32/MMU generator availability
	@$(MAKE) -C $(VERIFY_HOME) riscv-dv-mmu

verify-coverage: ## Verilator line/toggle coverage
	@set -o pipefail; $(MAKE) -C $(VERIFY_HOME) coverage $(call tee_verify,coverage)

verify-light: ## Run lightweight fuzz and signature tests
	@set -o pipefail; $(MAKE) -C $(VERIFY_HOME) light $(call tee_verify,light)

# Regression owns its subprocess parallelism; parent make -j is not the budget.
REGRESSION_JOBS ?= 3
REGRESSION_TOOL_JOBS ?= 4
REGRESSION_TIMEOUT ?= 14400
REGRESSION_BOARD ?= mlk_cu08_ku15p
REGRESSION_XLENS ?= 32 64
REGRESSION_SUITES ?= format coremark sta fpga
REGRESSION_ITERATIONS ?= 2
REGRESSION_OUTPUT ?=
REGRESSION_OPTIONS = --preset "$(RAPT_CONFIG)" --board "$(REGRESSION_BOARD)" \
	--platform "$(strip $(STA_PLATFORM))" --clock-mhz "$(strip $(CLK_FREQ_MHZ))" \
	--jobs "$(REGRESSION_JOBS)" --tool-jobs "$(REGRESSION_TOOL_JOBS)" \
	--timeout "$(REGRESSION_TIMEOUT)" --iterations "$(REGRESSION_ITERATIONS)" \
	--xlens $(REGRESSION_XLENS) --suites $(REGRESSION_SUITES) \
	$(if $(REGRESSION_OUTPUT),--output "$(REGRESSION_OUTPUT)",)

regression: ## Format, then run CoreMark/STA/FPGA lanes with isolated logs and a JSON summary
	python3 $(VERIFY_HOME)/scripts/regression.py $(REGRESSION_OPTIONS)

regression-plan: ## Print regression commands and concurrency without running any submake
	@python3 $(VERIFY_HOME)/scripts/regression.py --plan $(REGRESSION_OPTIONS)

regression-test: ## Test regression scheduling, failure handling and output validation without EDA tools
	PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s $(VERIFY_HOME)/scripts -p test_regression.py

verify-memory-stress-rv32: ## RaptOS: randomized Sv32 memory/atomic integration matrix
	$(MAKE) -C $(RAPTOR_HOME)/app/tinyos/raptos memory-stress \
		MEM_RANDOM_DELAY=$(or $(MEM_RANDOM_DELAY),32) \
		$(if $(TIMEOUT),TIMEOUT=$(TIMEOUT),) \
		$(if $(MEM_STRESS_FAST),MEM_STRESS_FAST=$(MEM_STRESS_FAST),) \
		$(if $(MEM_STRESS_SEEDS),MEM_STRESS_SEEDS="$(MEM_STRESS_SEEDS)",) \
		$(if $(MEM_STRESS_PAYLOADS),MEM_STRESS_PAYLOADS="$(MEM_STRESS_PAYLOADS)",)

# --------------------------------------------------------------------------
# Portable server gate: every DUT simulation below is Verilator based.  The
# phase barriers still protect NEMU's legacy selected ISA and other shared
# test assets. Simulator Kconfig/model caches are now profile/XLEN-local.
# Within a stable phase, independent test families run concurrently.
# --------------------------------------------------------------------------

verify-verilator: export BUILD_PROFILE := $(VERILATOR_VERIFY_BUILD_PROFILE)
verify-verilator: ## Pure-Verilator parallel regression: modules, RV32/RV64, apps, random AXI, RISCOF, Linux
	@set -eu; \
	command -v verilator >/dev/null || { echo "[verify-verilator] ERROR: verilator not found"; exit 1; }; \
	command -v $(CROSS_COMPILE)gcc >/dev/null || { echo "[verify-verilator] ERROR: $(CROSS_COMPILE)gcc not found"; exit 1; }; \
	command -v python3 >/dev/null || { echo "[verify-verilator] ERROR: python3 not found"; exit 1; }; \
	echo "[verify-verilator] jobs=$(VERILATOR_VERIFY_JOBS) profile=$(BUILD_PROFILE) delay=0..$(VERILATOR_VERIFY_DELAY) app-delay=0..$(VERILATOR_VERIFY_APP_DELAY) linux-delay=0..$(VERILATOR_VERIFY_LINUX_DELAY) seed=$(VERILATOR_VERIFY_SEED)"
	+@$(MAKE) --no-print-directory $(VERILATOR_VERIFY_SUBMAKE_JOBS) \
		_verify-verilator-directed _verify-verilator-rv32-build
	+@$(MAKE) --no-print-directory $(VERILATOR_VERIFY_SUBMAKE_JOBS) \
		_verify-verilator-fuzz32 _verify-verilator-sig32 \
		_verify-verilator-fpu _verify-verilator-app32 \
		$(if $(filter 1,$(VERILATOR_VERIFY_RISCV_DV)),_verify-verilator-riscv-dv,)
	+@$(MAKE) --no-print-directory -C $(NSIM_HOME) VFLAGS="$(VFLAGS)" print-npc-exec >/dev/null
	+@$(MAKE) --no-print-directory $(VERILATOR_VERIFY_SUITE_SUBMAKE_JOBS) \
		_verify-verilator-cpu32 _verify-verilator-irq32
	+@set -eu; if [ "$(VERILATOR_VERIFY_RAPTOS)" = "1" ]; then \
		$(MAKE) --no-print-directory verify-memory-stress-rv32 \
			NPROC=$(VERILATOR_VERIFY_JOBS) JOBS=$(VERILATOR_VERIFY_JOBS) \
			MEM_RANDOM_DELAY=$(VERILATOR_VERIFY_DELAY) \
			MEM_STRESS_FAST=1 \
			TIMEOUT=$(VERILATOR_VERIFY_TIMEOUT) \
			MEM_STRESS_SEEDS="$(VERILATOR_VERIFY_MEM_SEEDS)"; \
	else echo "[verify-verilator] SKIP RaptOS (VERILATOR_VERIFY_RAPTOS=0)"; fi
	+@set -eu; if [ "$(VERILATOR_VERIFY_RV64)" = "1" ]; then \
		$(MAKE) --no-print-directory _verify-verilator-rv64-build; \
		$(MAKE) --no-print-directory $(VERILATOR_VERIFY_SUBMAKE_JOBS) \
			_verify-verilator-fuzz64 _verify-verilator-sig64 _verify-verilator-app64; \
	else echo "[verify-verilator] SKIP RV64 (VERILATOR_VERIFY_RV64=0)"; fi
	+@set -eu; if [ "$(VERILATOR_VERIFY_RISCOF)" = "1" ]; then \
		$(MAKE) --no-print-directory verify-riscof \
			NPROC=$(VERILATOR_VERIFY_JOBS) JOBS=$(VERILATOR_VERIFY_JOBS) \
			MEM_RANDOM_DELAY=$(VERILATOR_VERIFY_DELAY) MEM_RANDOM_SEED=$(VERILATOR_VERIFY_SEED) \
			TIMEOUT=$(VERILATOR_VERIFY_TIMEOUT); \
		$(MAKE) --no-print-directory verify-riscof-classic \
			NPROC=$(VERILATOR_VERIFY_JOBS) JOBS=$(VERILATOR_VERIFY_JOBS) \
			MEM_RANDOM_DELAY=$(VERILATOR_VERIFY_DELAY) MEM_RANDOM_SEED=$(VERILATOR_VERIFY_SEED) \
			TIMEOUT=$(VERILATOR_VERIFY_TIMEOUT); \
	else echo "[verify-verilator] SKIP RISCOF (VERILATOR_VERIFY_RISCOF=0)"; fi
	+@set -eu; if [ "$(VERILATOR_VERIFY_LINUX)" = "1" ]; then \
		$(MAKE) --no-print-directory verify-linux-memory-stress-rv32 \
			NPROC=$(VERILATOR_VERIFY_JOBS) JOBS=$(VERILATOR_VERIFY_JOBS) \
			BUILD_PROFILE=$(VERILATOR_VERIFY_LINUX_BUILD_PROFILE) \
			VFLAGS="" DT_SOURCE=$(VERILATOR_VERIFY_LINUX_DT_SOURCE) \
			LINUX_MEM_RANDOM_DELAY=$(VERILATOR_VERIFY_LINUX_DELAY) \
			LINUX_MEM_STRESS_TIMEOUT=$(VERILATOR_VERIFY_LINUX_TIMEOUT) \
			LINUX_MEM_STRESS_SEEDS="$(VERILATOR_VERIFY_LINUX_SEEDS)"; \
	else echo "[verify-verilator] SKIP Linux (VERILATOR_VERIFY_LINUX=0)"; fi
	@echo "[verify-verilator] PASS: portable Verilator regression completed"

_verify-verilator-directed:
	$(MAKE) -C $(VERIFY_HOME) verilator-directed \
		RAPT_CONFIG=$(RAPT_CONFIG) XSIM_RAPT_CONFIG=$(RAPT_CONFIG) \
		VERILATOR_DIRECTED_DELAY=$(VERILATOR_VERIFY_DELAY) \
		VERILATOR_DIRECTED_SEED=$(VERILATOR_VERIFY_SEED)

_verify-verilator-rv32-build:
	$(MAKE) --no-print-directory build-nemu32-ref NPROC=$(VERILATOR_VERIFY_JOBS)
	$(MAKE) --no-print-directory build-rv32 NPROC=$(VERILATOR_VERIFY_JOBS)

_verify-verilator-fuzz32:
	$(MAKE) -C $(VERIFY_HOME) fuzz ISA=rv32 RAPT_CONFIG=$(RAPT_CONFIG) \
		SEED=$(VERILATOR_VERIFY_SEED) FUZZ_NUM=$(VERILATOR_VERIFY_FUZZ_NUM) \
		FUZZ_LEN=$(VERILATOR_VERIFY_FUZZ_LEN) TIMEOUT=$(VERILATOR_VERIFY_TIMEOUT) \
		MEM_RANDOM_DELAY=$(VERILATOR_VERIFY_DELAY) MEM_RANDOM_SEED=$(VERILATOR_VERIFY_SEED)

_verify-verilator-sig32:
	$(MAKE) -C $(VERIFY_HOME) sigtest ISA=rv32 RAPT_CONFIG=$(RAPT_CONFIG) \
		TIMEOUT=$(VERILATOR_VERIFY_TIMEOUT) MEM_RANDOM_DELAY=$(VERILATOR_VERIFY_DELAY) \
		MEM_RANDOM_SEED=$(VERILATOR_VERIFY_SEED)

_verify-verilator-riscv-dv:
	$(MAKE) -C $(VERIFY_HOME) riscv-dv RAPT_CONFIG=$(RAPT_CONFIG) \
		RISCV_DV_MEM_DELAYS="$(VERILATOR_VERIFY_DV_DELAYS)" \
		RISCV_DV_MEM_SEEDS="$(VERILATOR_VERIFY_DV_SEEDS)" \
		RISCV_DV_TIMEOUT=$(VERILATOR_VERIFY_TIMEOUT)

_verify-verilator-fpu:
	$(MAKE) -C $(VERIFY_HOME) unit-fpu

_verify-verilator-app32:
	$(MAKE) -C $(RAPTOR_HOME)/app tests-sim ISA64=0 \
		NPROC=$(VERILATOR_VERIFY_JOBS) \
		PK_BUILD_PROFILE=verify-verilator \
		MEMTEST_WORDS=512 \
		SECURITY_SIM_FAST=1 \
		DT_SOURCE=spike-rv32ima-app.dts \
		ARGS="$(VERILATOR_VERIFY_APP_ARGS)"

_verify-verilator-cpu32:
	$(MAKE) --no-print-directory cpu-tests-rv32-run JOBS=$(VERILATOR_VERIFY_RUN_JOBS) \
		ARGS="$(VERILATOR_VERIFY_ARGS)"

_verify-verilator-irq32:
	$(MAKE) --no-print-directory irq-tests-rv32-run JOBS=$(VERILATOR_VERIFY_RUN_JOBS) \
		ARGS="$(VERILATOR_VERIFY_ARGS)"

_verify-verilator-rv64-build:
	$(MAKE) --no-print-directory build-nemu64-ref NPROC=$(VERILATOR_VERIFY_JOBS)
	$(MAKE) --no-print-directory build-rv64 NPROC=$(VERILATOR_VERIFY_JOBS)

_verify-verilator-fuzz64:
	$(MAKE) -C $(VERIFY_HOME) fuzz ISA=rv64 RAPT_CONFIG=$(RAPT_CONFIG) \
		SEED=$(VERILATOR_VERIFY_SEED) FUZZ_NUM=$(VERILATOR_VERIFY_FUZZ_NUM) \
		FUZZ_LEN=$(VERILATOR_VERIFY_FUZZ_LEN) TIMEOUT=$(VERILATOR_VERIFY_TIMEOUT) \
		MEM_RANDOM_DELAY=$(VERILATOR_VERIFY_DELAY) MEM_RANDOM_SEED=$(VERILATOR_VERIFY_SEED)

_verify-verilator-sig64:
	$(MAKE) -C $(VERIFY_HOME) sigtest ISA=rv64 RAPT_CONFIG=$(RAPT_CONFIG) \
		TIMEOUT=$(VERILATOR_VERIFY_TIMEOUT) MEM_RANDOM_DELAY=$(VERILATOR_VERIFY_DELAY) \
		MEM_RANDOM_SEED=$(VERILATOR_VERIFY_SEED)

_verify-verilator-app64:
	$(MAKE) -C $(RAPTOR_HOME)/app tests-sim ISA64=1 \
		NPROC=$(VERILATOR_VERIFY_JOBS) \
		PK_BUILD_PROFILE=verify-verilator \
		MEMTEST_WORDS=512 \
		SECURITY_SIM_FAST=1 \
		DT_SOURCE=spike-rv64ima-app.dts \
		ARGS="$(VERILATOR_VERIFY_APP_ARGS)"

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

app-coremark-rv64: build-rv64 ## [app] CoreMark via pk (rv64)
	@set -o pipefail; $(MAKE) --no-print-directory -C $(APP_HOME) coremark-sim ISA64=1 ARGS="$(ARGS)" $(call tee_app,coremark-rv64)
	$(call coremark_mhz_report,$(APP_LOG_DIR)/coremark-rv64.log)

app-coremark-rv32: build-rv32 ## [app] CoreMark via pk (rv32)
	@set -o pipefail; $(MAKE) --no-print-directory -C $(APP_HOME) coremark-sim ARGS="$(ARGS)" $(call tee_app,coremark-rv32)
	$(call coremark_mhz_report,$(APP_LOG_DIR)/coremark-rv32.log)

app-coremark-nemu32: build-nemu32 ## [app] CoreMark via pk on NEMU (rv32)
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

app-embench-nemu32: build-nemu32 ## [app] Embench-IoT via pk on NEMU (rv32)
	@set -o pipefail; $(MAKE) --no-print-directory -C $(APP_HOME) embench-nemu ARGS="$(ARGS)" $(call tee_app,embench-nemu32)

app-llm-rv32: build-rv32 ## [app] LLM operator/infer/train benchmarks via pk (rv32)
	@set -o pipefail; $(MAKE) --no-print-directory -C $(APP_HOME) llm-bench-report-sim ARGS="$(ARGS)" $(call tee_app,llm-rv32)

app-llm-nemu32: build-nemu32 ## [app] LLM operator/infer/train benchmarks via pk on NEMU (rv32)
	@set -o pipefail; $(MAKE) --no-print-directory -C $(APP_HOME) llm-bench-report-nemu ARGS="$(ARGS)" $(call tee_app,llm-nemu32)

# --- app tests/demos on NPC ---
app-tests-rv32: build-rv32 ## [app] All tests via pk on NPC (rv32)
	@set -o pipefail; $(MAKE) --no-print-directory -C $(APP_HOME) tests-sim ARGS="$(ARGS)" $(call tee_app,tests-rv32)

app-demos-rv32: build-rv32 ## [app] All demos via pk on NPC (rv32)
	@set -o pipefail; $(MAKE) --no-print-directory -C $(APP_HOME) demos-sim ARGS="$(ARGS)" $(call tee_app,demos-rv32)

# --- app tests/demos on NEMU (default: with difftest) ---
app-tests-nemu32: build-nemu32 ## [app] All tests via pk on NEMU (rv32)
	@set -o pipefail; $(MAKE) --no-print-directory -C $(APP_HOME) tests-nemu ARGS="$(ARGS)" $(call tee_app,tests-nemu32)

app-demos-nemu32: build-nemu32 ## [app] All demos via pk on NEMU (rv32)
	@set -o pipefail; $(MAKE) --no-print-directory -C $(APP_HOME) demos-nemu ARGS="$(ARGS)" $(call tee_app,demos-nemu32)

# --- TinyOS / OS CLI helpers ---
tinyos-sync: ## [app] Clone or update egos-2000 and xv6-riscv under app/tinyos
	@$(MAKE) --no-print-directory -C $(APP_HOME) tinyos-sync

os-cli-qemu: ## [app] Enter upstream OS CLI on QEMU (OS=egos|xv6 or TINYOS_OS=egos|xv6)
	@$(MAKE) --no-print-directory -C $(APP_HOME) os-cli-qemu OS="$(OS)" TINYOS_OS="$(TINYOS_OS)" $(if $(QEMU),QEMU="$(QEMU)",)

os-cli-nsim: ## [app] Boot upstream OS image on NPC/sim (OS=egos|xv6 or TINYOS_OS=egos|xv6)
	@$(MAKE) --no-print-directory -C $(APP_HOME) os-cli-nsim OS="$(OS)" TINYOS_OS="$(TINYOS_OS)" ARGS="$(ARGS)" MAX_INST="$(MAX_INST)" TIMEOUT="$(TIMEOUT)"

os-cli-nemu: ## [app] Boot upstream OS image on NEMU (OS=egos|xv6 or TINYOS_OS=egos|xv6)
	@$(MAKE) --no-print-directory -C $(APP_HOME) os-cli-nemu OS="$(OS)" TINYOS_OS="$(TINYOS_OS)" ARGS="$(ARGS)" MAX_INST="$(MAX_INST)"

app-pk-build: ## [app] Build riscv-pk
	@$(MAKE) --no-print-directory -C $(APP_HOME) pk-build

app-clean: ## [app] Clean app build artifacts
	@$(MAKE) --no-print-directory -C $(APP_HOME) clean


# ============================================================================
# Local overrides (private synthesis targets, not tracked by Git)
# ============================================================================
# Copy Makefile.local.example -> Makefile.local and fill in site-specific values.
-include Makefile.local

# Upstream ysyxSoC integration through hdl/perip/wrap_ysyxsoc.sv.
YSYXSOC_ARCH ?= riscv32-ysyxsoc
YSYXSOC_HOME ?= $(RAPTOR_HOME)/third_party/OSCPU/ysyxSoC
build-rv32-ysyxsoc:
	$(MAKE) -C $(NSIM_HOME) o2soc_defconfig
	$(MAKE) -C $(NSIM_HOME) all SIM_PLATFORM=ysyxsoc SOC_HOME=$(YSYXSOC_HOME)

coremark-ysyxsoc: $(AM_KERNELS) build-rv32-ysyxsoc ## Run CoreMark on upstream ysyxSoC (RV32)
	$(MAKE) -C $(AM_KERNELS)/benchmarks/coremark_eembc ARCH=$(YSYXSOC_ARCH) run ARGS="$(ARGS)" mainargs=test SOC_HOME=$(YSYXSOC_HOME)

microbench-ysyxsoc: $(AM_KERNELS) build-rv32-ysyxsoc ## Run MicroBench on upstream ysyxSoC (RV32)
	$(MAKE) -C $(AM_KERNELS)/benchmarks/microbench ARCH=$(YSYXSOC_ARCH) run ARGS="$(ARGS)" mainargs=$(MAINARGS) SOC_HOME=$(YSYXSOC_HOME)


YSYXSOC_MILL ?=
YSYXSOC_JAVA_HOME ?=
ysyxsoc-setup: ## Fetch and generate the pinned, unmodified upstream ysyxSoC
	python3 sim/ysyxsoc/setup.py --soc $(YSYXSOC_HOME) $(if $(YSYXSOC_MILL),--mill $(YSYXSOC_MILL),) $(if $(YSYXSOC_JAVA_HOME),--java-home $(YSYXSOC_JAVA_HOME),)


.PHONY: _verify-verilator-app32 _verify-verilator-app64 _verify-verilator-cpu32 _verify-verilator-directed _verify-verilator-fpu _verify-verilator-fuzz32 \
	_verify-verilator-fuzz64 _verify-verilator-irq32 _verify-verilator-riscv-dv _verify-verilator-rv32-build _verify-verilator-rv64-build _verify-verilator-sig32 \
	_verify-verilator-sig64 am-kernels-hello-rv32 am-tests-cache-tests-rv32 am-tests-nemu32 am-tests-rv32 app-bbl-linux \
	app-clean app-coremark-nemu32 app-coremark-rv32 app-coremark-rv64 app-demos-nemu32 app-demos-rv32 \
	app-embench-baremetal-report-rv32 app-embench-baremetal-run-rv32 app-embench-baremetal-rv32 app-embench-nemu32 app-embench-pk-report-rv32 app-embench-pk-run-rv32 \
	app-embench-rv32 app-hello-rv32 app-llm-nemu32 app-llm-rv32 app-pk-build app-run \
	app-run-nemu app-tests-nemu32 app-tests-rv32 archtest-rv32 archtest-rv32e build-nemu32 \
	build-nemu32-difftest build-nemu32-linux build-nemu32-linux-device build-nemu32-ref build-nemu32gc-linux build-nemu64 \
	build-nemu64-difftest build-nemu64-linux build-nemu64-linux-device build-nemu64-ref build-nemu64gc-linux build-rv32 \
	build-rv32-linux build-rv32-ysyxsoc build-rv64 build-rv64-linux build-spike-diff32 build-spike-diff64 \
	clean clean-npc compile-commands configure-rv32 configure-rv64 coremark-nemu32 \
	coremark-nemu64 coremark-rv32 coremark-rv64 coremark-ysyxsoc cpu-tests-nemu32 cpu-tests-rv32 \
	cpu-tests-rv32-run cpu-tests-rv64 cpu-tests-rv64-run dhrystone-nemu32 dhrystone-rv32 dhrystone-rv64 \
	format format-check fpga-pnr fpga-syn help irq-tests-build \
	irq-tests-rv32 irq-tests-rv32-run lint lint-rv64 lint-verible linux-boot-nemu32 \
	linux-boot-nemu32-device linux-boot-nemu32gc linux-boot-nemu64 linux-boot-nemu64-device linux-boot-nemu64gc linux-boot-rv32 \
	linux-boot-rv32-ckpt-load linux-boot-rv32-ckpt-save linux-boot-rv32gc linux-boot-rv64 linux-boot-rv64gc linux-download \
	linux-download-rv32 linux-download-rv32gc linux-download-rv32gc-fpga linux-download-rv64 linux-download-rv64gc linux-ticket-spinlock-repro-rv32 \
	log logs-clean logs-show menuconfig-nemu32 menuconfig-rv32 microbench-nemu32 \
	microbench-nemu64 microbench-rv32 microbench-rv64 microbench-ysyxsoc nanos-nemu32 nanos-rv32 \
	os-cli-nemu os-cli-nsim os-cli-qemu pack regression regression-plan \
	regression-test repro-tests-build run-nemu32 run-nemu32-linux run-nemu32-linux-device run-nemu64 \
	run-nemu64-linux-device run-rv32 run-rv64 setup setup-rtl sram-doctor \
	sram-macros sram-stubs sram-test sram-test-sta sta sta-check \
	sta-detail sta-summary tinyos-sync verify-clean verify-coverage verify-fp-arith-rv32 \
	verify-fp-arith-rv64 verify-fp-arith-spike-rv32 verify-fp-arith-spike-rv64 verify-fp-double-rv32 verify-fp-double-rv64 verify-fp-smoke-rv32 \
	verify-fp-smoke-rv64 verify-fp-spike-rv32 verify-fp-spike-rv64 verify-fuzz verify-fuzz-inf verify-fuzz-replay \
	verify-light verify-linux-boot-rv32 verify-linux-memory-stress-rv32 verify-memory-stress-rv32 verify-riscof verify-riscof-classic \
	verify-riscof-classic-nemu verify-riscv-dv verify-riscv-dv-mmu verify-riscv-dv-stress verify-sigtest verify-unit-fpu \
	verify-verilator verilog ysyxsoc-setup

endif # Guard: root-only targets
