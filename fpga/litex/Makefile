# ============================================================================
# fpga/litex/Makefile — Raptor LiteX SoC build system
# ============================================================================
# Run `make help` for the full target + variable list.
#
# Conventions follow the project-wide Makefile style (see root Makefile and
# docs-ref/dev.makefile-conventions.md):
#   * Targets carry inline `## description` for help extraction.
#   * Variables use `VAR ?= default ## description`.
#   * Section headers `# ====...` + `# Title` + `# ====...` group targets in
#     `make help` output.
#   * All `.PHONY` targets are collected in a single block at the bottom.

SHELL         := /bin/bash
.DEFAULT_GOAL := help

# --- Paths ---
LITEX_DIR   := $(abspath .)
RAPTOR_HOME := $(abspath ../..)
NSIM_DIR    := $(RAPTOR_HOME)/nsim
RTL_DIR     := $(RAPTOR_HOME)/rtl_sv
BUILD_DIR   := $(LITEX_DIR)/build
VENV_DIR    := $(LITEX_DIR)/.venv
PYTHON      := $(VENV_DIR)/bin/python3
PIP         := $(VENV_DIR)/bin/pip
HOST_PYTHON := $(shell if [ -x "$(PYTHON)" ]; then echo "$(PYTHON)"; elif command -v python3 >/dev/null 2>&1; then command -v python3; elif command -v python >/dev/null 2>&1; then command -v python; fi)
TIMEOUT_BIN := $(shell command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null)

export RAPTOR_HOME

ifeq ($(strip $(TIMEOUT_BIN)),)
	ifeq ($(strip $(HOST_PYTHON)),)
		$(error Neither timeout/gtimeout nor python3/python is available)
	endif
	TIMEOUT_RUN := $(HOST_PYTHON) $(LITEX_DIR)/scripts/run_with_timeout.py
	TIMEOUT_FOREGROUND :=
else
	TIMEOUT_RUN := $(TIMEOUT_BIN)
	TIMEOUT_FOREGROUND := --foreground
endif

# --- CPU variant ---
VARIANT     ?= standard ## CPU variant (standard|linux)
SYS_CLK     ?= 50000000 ## System clock in Hz
SIM_TIMEOUT ?= 30 ## Simulation timeout in seconds (0=unlimited)

# --- Verilator parallel threading ---
# Verilator multi-threaded simulation (biggest lever for OpenSBI/Linux boot time
# in Verilator). LiteX passes --threads=N through to the verilator invocation,
# which enables coarse-grained parallel evaluation (OpenMP-based). A value of 1
# disables threading. Practical speedups are typically 1.5-2.5x on 4-8 host
# cores; benefit diminishes above ~4 threads for a single-core RISC-V SoC.
#
# Override at the command line:  make sim SIM_THREADS=8
SIM_THREADS ?= 4 ## Verilator simulation threads (1=off)

# --- Wave / trace ---
# Off by default — tracing is a huge perf hit. Enable on demand:
#   make sim     TRACE=fst     # FST (compact binary, ~5-10x smaller & faster than VCD)
#   make sim     TRACE=vcd     # VCD (universal text format, slowest + largest)
#   make test-fib TRACE=fst    # works for any run target
# Wave files land in $(GW_DIR)/sim.{fst,vcd} (LiteX default).
# Changing TRACE re-hashes build_sim.sh → triggers Verilator rebuild.
# Partial files from Ctrl+C / timeout are viewable (LiteX flushes each tick).
TRACE ?= none ## Wave dump mode (none|fst|vcd)

# Windowed tracing (exact clock cycles, not ps).
# Default: TRACE_START=0 (dump from t=0), TRACE_END=-1 (no end).
TRACE_START ?= 0 ## Start dump at cycle N (0=from t=0)
TRACE_END   ?= -1 ## Stop dump at cycle N (-1=no end)

# Inline `## description` comments above leave trailing whitespace in the value.
# Strip before using in ifeq/ifneq (exact-match) comparisons.
VARIANT     := $(strip $(VARIANT))
SYS_CLK     := $(strip $(SYS_CLK))
SIM_TIMEOUT := $(strip $(SIM_TIMEOUT))
SIM_THREADS := $(strip $(SIM_THREADS))
TRACE       := $(strip $(TRACE))
TRACE_START := $(strip $(TRACE_START))
TRACE_END   := $(strip $(TRACE_END))

ifeq ($(TRACE),fst)
  TRACE_FLAGS := --trace --trace-fst
  TRACE_MSG   := FST tracing ON
else ifeq ($(TRACE),vcd)
  TRACE_FLAGS := --trace
  TRACE_MSG   := VCD tracing ON (consider TRACE=fst for ~5-10x less overhead)
else ifeq ($(TRACE),none)
  TRACE_FLAGS :=
  TRACE_MSG   :=
else
  $(error Invalid TRACE='$(TRACE)'. Use TRACE=fst, TRACE=vcd, or TRACE=none)
endif

# Pass cycle-based TRACE_START/TRACE_END to raptor_soc.py, which gates
# LiteX's `sim_trace` pin with an internal cycle counter.
ifneq ($(TRACE),none)
	TRACE_FLAGS += --trace-start-cycle=$(TRACE_START)
	TRACE_MSG   := $(TRACE_MSG) [start @ cycle $(TRACE_START)]
	ifneq ($(TRACE_END),-1)
		TRACE_FLAGS += --trace-end-cycle=$(TRACE_END)
		TRACE_MSG   := $(TRACE_MSG) [end(exclusive) @ cycle $(TRACE_END)]
	endif
endif

# --- Derived paths (per-variant) ---
GW_DIR      := $(BUILD_DIR)/$(VARIANT)/gateware
SIM_V       := $(GW_DIR)/sim.v
VSIM        := $(GW_DIR)/obj_dir/Vsim

# --- Extra flags (user-overridable) ---
EXTRA_FLAGS ?= ## Extra flags passed to raptor_soc.py

# ==============================================================================
# Environment
# ==============================================================================

setup: ## Install LiteX environment + register Raptor CPU
	@bash setup_env.sh

setup-skip: ## Activate venv without reinstalling
	@bash setup_env.sh --skip-install

$(VENV_DIR)/bin/activate:
	@echo "[INFO] Run 'make setup' first to create the virtual environment."
	@exit 1

# ==============================================================================
# RTL Packing
# ==============================================================================

PACK_SV := $(NSIM_DIR)/build/ysyx_pack.sv

# All hand-written RTL sources + headers. Any change must trigger re-pack.
# Chisel-generated sources under rtl_sv/generated/ are regenerated by
# `make verilog` in the top-level Makefile; we include them as deps too so
# an upstream decoder change is picked up.
RTL_SOURCES := $(shell find $(RTL_DIR) -type f \( -name '*.sv' -o -name '*.svh' -o -name '*.v' -o -name '*.vh' \) 2>/dev/null)

pack: ## Pack all RTL into single preprocessed SV file
	$(MAKE) -C $(NSIM_DIR) pack

# Re-pack whenever any RTL file is newer than the packed output.
$(PACK_SV): $(RTL_SOURCES)
	$(MAKE) -C $(NSIM_DIR) pack

# ==============================================================================
# Firmware (minimal boot ROM)
# ==============================================================================

CROSS     ?= riscv64-unknown-elf-
FW_SRC    := $(LITEX_DIR)/firmware
FW_DIR    := $(BUILD_DIR)/firmware
FW_BIN    := $(FW_DIR)/boot.bin
FW_ELF    := $(FW_DIR)/boot.elf
FW_DTB    := $(FW_DIR)/litex-soc.dtb
FW_DTS    := $(FW_SRC)/litex-soc.dts

$(FW_DIR):
	@mkdir -p $@

$(FW_DTB): $(FW_DTS) | $(FW_DIR)
	dtc -I dts -O dtb -o $@ $<

$(FW_ELF): $(FW_SRC)/boot.S $(FW_SRC)/link.ld $(FW_DTB) | $(FW_DIR)
	$(CROSS)gcc -march=rv32imac -mabi=ilp32 -nostdlib -nostartfiles \
		-T $(FW_SRC)/link.ld -I$(FW_DIR) -o $@ $(FW_SRC)/boot.S

$(FW_BIN): $(FW_ELF)
	$(CROSS)objcopy -O binary $< $@

firmware: $(FW_BIN) ## Build minimal boot firmware (-> build/firmware/)

firmware-clean:
	rm -rf $(FW_DIR)
	@# Legacy in-tree artifacts from older versions of this Makefile:
	rm -f $(FW_SRC)/boot.elf $(FW_SRC)/boot.bin $(FW_SRC)/litex-soc.dtb

# ==============================================================================
# Verilator Simulation
# ==============================================================================

# --- Parameterized core helpers ---
# Three composable building blocks. Each takes a parameter so targets with
# different output directories / SoC configurations share the same logic.
# Eliminates the copy-paste that previously existed in run-litex and linux.

# $(call _soc_gen,<all raptor_soc.py flags>)
# Activates venv and invokes raptor_soc.py.
define _soc_gen
	source $(VENV_DIR)/bin/activate && \
	$(PYTHON) raptor_soc.py $(1) $(EXTRA_FLAGS)
endef

# Presets: common flags shared by most targets.
_BASE_FLAGS = --sys-clk-freq=$(SYS_CLK) --threads=$(SIM_THREADS) $(TRACE_FLAGS)
_STD_FLAGS  = --cpu-variant=$(VARIANT) --output-dir=$(BUILD_DIR)/$(VARIANT) \
	--no-compile-software --integrated-rom-init=$(FW_BIN) $(_BASE_FLAGS)

# $(call _compile_if_needed,<gw_dir>)
# Compiles the Verilator binary only when sim.v + sim_init.cpp + build_sim.sh
# content has changed (hash-based). sim_init.cpp is included because LiteX
# bakes trace window parameters into it.
define _compile_if_needed
	@mkdir -p $(1)
	@SIM_V_HASH=$$({ \
		grep -v -e '^// Date' -e '^//  Auto-Generated by LiteX on' $(1)/sim.v 2>/dev/null; \
		cat $(1)/sim_init.cpp 2>/dev/null; \
		cat $(1)/build_sim.sh 2>/dev/null; \
	} | md5 -q 2>/dev/null || { \
		grep -v -e '^// Date' -e '^//  Auto-Generated by LiteX on' $(1)/sim.v 2>/dev/null; \
		cat $(1)/sim_init.cpp 2>/dev/null; \
		cat $(1)/build_sim.sh 2>/dev/null; \
	} | md5sum | cut -d' ' -f1); \
	OLD_HASH=$$(cat $(1)/.sim_v_hash 2>/dev/null || echo ""); \
	if [ ! -f $(1)/obj_dir/Vsim ] || [ "$$SIM_V_HASH" != "$$OLD_HASH" ]; then \
		echo "[INFO] Compiling Verilator simulation (this may take several minutes)..."; \
		cd $(1) && bash build_sim.sh; \
		echo "$$SIM_V_HASH" > $(1)/.sim_v_hash; \
		echo "[INFO] Verilator compilation complete."; \
	else \
		echo "[INFO] Verilator binary up to date, skipping compilation."; \
	fi
endef

# $(call _run_vsim,<gw_dir>)
# Runs Vsim with timeout + Ctrl+C/SIGTERM handling + wave summary.
define _run_vsim
	@if [ ! -f $(1)/obj_dir/Vsim ]; then \
		echo "[ERR] No sim binary at $(1). Run 'make sim-build' first."; exit 1; fi
	@echo "[INFO] Running sim (timeout=$(SIM_TIMEOUT)s, Ctrl+C to stop)"
	@if [ -n "$(TRACE_MSG)" ]; then echo "[INFO] $(TRACE_MSG) — wave -> $(1)/sim.$(TRACE)"; fi
	@cd $(1) && \
		$(TIMEOUT_RUN) $(TIMEOUT_FOREGROUND) $(SIM_TIMEOUT) obj_dir/Vsim; \
		rc=$$?; \
		if [ $$rc -eq 124 ]; then \
			echo ""; echo "[INFO] Simulation timed out after $(SIM_TIMEOUT)s."; \
		elif [ $$rc -eq 130 ] || [ $$rc -eq 143 ]; then \
			echo ""; echo "[INFO] Simulation interrupted (Ctrl+C / SIGTERM)."; \
		elif [ $$rc -ne 0 ]; then \
			exit $$rc; \
		fi
	@if [ -n "$(TRACE_MSG)" ] && [ -f $(1)/sim.$(TRACE) ]; then \
		sz=$$(wc -c < $(1)/sim.$(TRACE)); \
		echo "[INFO] Wave: $(1)/sim.$(TRACE) ($$sz bytes)"; \
	fi
endef

# --- Top-level sim targets ---

sim-gen: $(PACK_SV) $(FW_BIN) ## Generate SoC Verilog (no compile, no run)
	$(call _soc_gen,$(_STD_FLAGS))

sim-build: sim-gen ## Generate SoC + compile Verilator binary
	$(call _compile_if_needed,$(GW_DIR))
	@echo ""
	@echo "========================================="
	@echo " Simulation binary ready."
	@echo " Run: make sim-run"
	@echo "========================================="

sim: sim-build ## Build + run simulation (no payload, boot firmware only)
	$(call _run_vsim,$(GW_DIR))

sim-run: ## Run already-built simulation
	$(call _run_vsim,$(GW_DIR))

sim-trace: ## Build + run simulation with FST trace (alias for: make sim TRACE=fst)
	@$(MAKE) --no-print-directory sim TRACE=fst

sim-trace-vcd: ## Build + run simulation with VCD trace (slower/larger than FST)
	@$(MAKE) --no-print-directory sim TRACE=vcd

# ==============================================================================
# LiteX default BIOS (logo + memtest + interactive prompt)
# ==============================================================================
# Uses LiteX's upstream BIOS (built from litex/soc/software/bios) as the boot
# ROM instead of our minimal custom firmware. Shows the familiar LiteX
# banner/logo, runs memory tests, and drops into the `litex>` prompt.
#
# Isolated build dir (build/litex-bios/) so its ROM-init hash doesn't clobber
# the `standard` variant's Verilator cache.
#
# Picolibc path compat patch
# --------------------------
# Newer `pythondata-software-picolibc` (>=1.7) relocates sources under
# `newlib/libc/` and splits tinystdio into `newlib/libc/tinystdio/`. LiteX's
# libc/common.mak still reference the old `libc/...` layout, so we patch the
# two LiteX files in-place (and restore via `git checkout` on exit) — mirroring
# the `_patch_sim_c` / `_litex_libc_patch` pattern. No venv mutation.
LITEX_PATH       := $(RAPTOR_HOME)/third_party/enjoy-digital/litex
define _litex_picolibc_patch
	$(PYTHON) $(LITEX_DIR)/scripts/patch_litex_picolibc.py $(LITEX_PATH)
endef
define _litex_picolibc_restore
	cd $(LITEX_PATH) && git checkout -- litex/soc/software/common.mak litex/soc/software/libc/Makefile 2>/dev/null || true
endef

LITEX_BIOS_DIR    := $(BUILD_DIR)/litex-bios
LITEX_BIOS_GW_DIR := $(LITEX_BIOS_DIR)/gateware

run-litex: $(PACK_SV) ## Build + run sim with default LiteX BIOS (logo + memtest)
	$(call _litex_picolibc_patch)
	@trap '$(call _litex_picolibc_restore)' EXIT; \
	$(call _soc_gen,--cpu-variant=$(VARIANT) --output-dir=$(LITEX_BIOS_DIR) $(_BASE_FLAGS))
	$(call _compile_if_needed,$(LITEX_BIOS_GW_DIR))
	$(call _run_vsim,$(LITEX_BIOS_GW_DIR))

run-litex-clean: ## Remove LiteX-BIOS sim build artifacts
	rm -rf $(LITEX_BIOS_DIR)

# ==============================================================================
# Payloads
# ==============================================================================
# Workflow: generate SoC (ROM firmware + payload in main_ram) → compile if
# sim.v changed → run. Subsequent runs with the same SoC topology skip
# recompilation (~10 min saved).

# --- Helper: generate + compile + run with payload ---
# Usage: $(call _payload_sim,<--ram-init=path>)
define _payload_sim
	$(call _soc_gen,$(_STD_FLAGS) $(1))
	$(call _compile_if_needed,$(GW_DIR))
	$(call _run_vsim,$(GW_DIR))
endef

# --- CoreMark ---
COREMARK_BENCH := $(LITEX_DIR)/benchmarks/coremark
COREMARK_BIN   := $(COREMARK_BENCH)/build/coremark.bin

coremark-build: ## Build CoreMark binary (clone + compile)
	$(MAKE) -C $(COREMARK_BENCH) build

coremark: $(PACK_SV) $(FW_BIN) coremark-build ## Build + run CoreMark in sim
	$(call _payload_sim,--ram-init=$(COREMARK_BIN))

coremark-clean: ## Remove CoreMark build artifacts (keep cloned source)
	$(MAKE) -C $(COREMARK_BENCH) clean

# --- Embench-IoT ---
EMBENCH_BENCH    := $(LITEX_DIR)/benchmarks/embench
EMBENCH_BENCHES  := aha-mont64 crc32 depthconv edn huffbench matmult-int \
					md5sum nettle-aes nettle-sha256 nsichneu picojpeg \
					qrduino sglib-combined slre statemate tarfind ud \
					wikisort xgboost
EMBENCH_LOG_DIR  := $(BUILD_DIR)/embench-logs
EMBENCH_TARGETS  := $(addprefix embench-run-,$(EMBENCH_BENCHES))

embench-build: ## Build all Embench-IoT benchmarks (one BIN per bench)
	$(MAKE) -C $(EMBENCH_BENCH) build SYS_CLK_HZ=$(SYS_CLK)

embench-build-one: ## Build one Embench bench (BENCH=<name>)
	@if [ -z "$(BENCH)" ]; then echo "[ERR] Set BENCH=<name>"; exit 1; fi
	$(MAKE) -C $(EMBENCH_BENCH) build BENCH=$(BENCH) SYS_CLK_HZ=$(SYS_CLK)

# Per-bench runner: builds that single bench then runs it in sim.
# Usage: make embench-run-crc32  (or: make embench-run BENCH=crc32)
$(EMBENCH_TARGETS): embench-run-%: $(PACK_SV) $(FW_BIN) ## Run one Embench bench in sim
	$(MAKE) -C $(EMBENCH_BENCH) build BENCH=$* SYS_CLK_HZ=$(SYS_CLK)
	@if [ ! -f $(EMBENCH_BENCH)/build/$*/$*.bin ]; then \
		echo "[ERR] Embench bin for '$*' not built"; exit 1; fi
	$(call _payload_sim,--ram-init=$(EMBENCH_BENCH)/build/$*/$*.bin)

embench-run: ## Run one Embench bench (BENCH=<name>) in sim
	@if [ -z "$(BENCH)" ]; then echo "[ERR] Set BENCH=<name>"; exit 1; fi
	$(MAKE) --no-print-directory embench-run-$(BENCH)

embench: $(PACK_SV) $(FW_BIN) sim-build ## Build + run all Embench benches (parallel) + Embench Score report
	@mkdir -p $(EMBENCH_LOG_DIR)
	@bash $(EMBENCH_BENCH)/run-embench.sh

embench-report: ## Re-run Embench Score report from existing logs
	@bash $(EMBENCH_BENCH)/report-embench.sh $(EMBENCH_LOG_DIR)

embench-clean: ## Remove Embench build artifacts and run logs
	$(MAKE) -C $(EMBENCH_BENCH) clean
	rm -rf $(EMBENCH_LOG_DIR)

# --- MicroBench ---
MICROBENCH_DIR := $(RAPTOR_HOME)/abstract-machine/app/am-kernels/benchmarks/microbench
MICROBENCH_BIN := $(MICROBENCH_DIR)/build/microbench-riscv32-npc.bin

microbench-build: ## Build MicroBench binary
	$(MAKE) -C $(MICROBENCH_DIR) ARCH=riscv32-npc

microbench: $(PACK_SV) $(FW_BIN) microbench-build ## Build + run MicroBench in sim
	$(call _payload_sim,--ram-init=$(MICROBENCH_BIN))

# --- Self-contained C microbenchmarks (fpga/litex/tests) ---
# Standalone payloads that do NOT depend on AM / nanos-lite / libc. They talk
# directly to LiteX UART (0xf000_1800) and read `rdcycle`, so they exercise the
# core and memory system without any build-cache or MMIO-map pitfalls. Ideal
# for quickly smoke-testing a LiteX build after RTL / soc.py changes.
TESTS_DIR       := $(LITEX_DIR)/tests
TESTS_BUILD_DIR := $(BUILD_DIR)/tests
TEST_NAMES      := hello text fib prime memcpy mul
TEST_TARGETS    := $(addprefix test-,$(TEST_NAMES))


tests: ## Build all standalone C microbenchmarks (build/tests/*.bin)
	$(MAKE) -C $(TESTS_DIR) BUILD_DIR=$(TESTS_BUILD_DIR)

tests-clean: ## Clean standalone microbenchmark build artifacts
	$(MAKE) -C $(TESTS_DIR) BUILD_DIR=$(TESTS_BUILD_DIR) clean

# Static pattern rule (not an implicit pattern rule): make DOES resolve these
# for phony targets. `make test-fib` → builds sim + test + runs it.
$(TEST_TARGETS): test-%: $(PACK_SV) $(FW_BIN) tests ## Run a single standalone test (e.g. test-hello)
	@if [ ! -f $(TESTS_BUILD_DIR)/$*.bin ]; then \
		echo "[ERR] $(TESTS_BUILD_DIR)/$*.bin not found"; exit 1; fi
	$(call _payload_sim,--ram-init=$(TESTS_BUILD_DIR)/$*.bin)

tests-run: $(PACK_SV) $(FW_BIN) tests ## Run every standalone test sequentially
	@set -e; for t in $(TEST_NAMES); do \
		echo "================================================================"; \
		echo "[tests-run] Running test-$$t"; \
		echo "================================================================"; \
		$(MAKE) --no-print-directory test-$$t SIM_TIMEOUT=$(SIM_TIMEOUT) || exit 1; \
	done
	@echo "[tests-run] All tests completed."

# --- OpenSBI (standalone test payload) ---
LINUX_DIR      := $(RAPTOR_HOME)/linux
OPENSBI_FW_DIR := $(LINUX_DIR)/opensbi/build/platform/generic/firmware
OPENSBI_BIN    := $(OPENSBI_FW_DIR)/fw_payload.bin

opensbi-build: ## Build OpenSBI (standalone, from linux/opensbi)
	$(MAKE) -C $(LINUX_DIR) opensbi

opensbi: $(PACK_SV) $(FW_BIN) opensbi-build ## Build + run OpenSBI in sim
	@if [ ! -f $(OPENSBI_BIN) ]; then \
		echo "[ERR] OpenSBI fw_payload.bin not found. Run 'make opensbi-build' first."; exit 1; fi
	$(call _payload_sim,--ram-init=$(OPENSBI_BIN))

opensbi-clean: ## Clean OpenSBI build artifacts
	$(MAKE) -C $(LINUX_DIR) opensbi-clean

# --- Custom payload ---
# Usage: make payload IMG=/path/to/binary.bin
IMG ?= ## Custom payload binary (for 'make payload')

payload: $(PACK_SV) $(FW_BIN) ## Run custom binary in sim (IMG=/path/to.bin)
	@if [ -z "$(IMG)" ]; then echo "[ERR] Set IMG=/path/to/binary.bin"; exit 1; fi
	$(call _payload_sim,--ram-init=$(IMG))

# --- Linux (OpenSBI + Kernel) ---
LINUX_IMG     = $(wildcard $(LINUX_DIR)/build/linux-riscv-rv32-*/fw_payload.bin)

linux-build: ## Download pre-built Linux payload (if needed)
	$(MAKE) -s -C $(LINUX_DIR) download-rv32

LINUX_GW_DIR := $(BUILD_DIR)/linux/gateware

linux: $(PACK_SV) $(FW_BIN) linux-build ## Build + run Linux payload in sim
	@if [ -z "$(LINUX_IMG)" ]; then echo "[ERR] Linux payload not found. Run 'make linux-build' first."; exit 1; fi
	@echo "[INFO] Using Linux payload: $(LINUX_IMG)"
	$(call _soc_gen,--cpu-variant=linux --output-dir=$(BUILD_DIR)/linux --no-compile-software --integrated-rom-init=$(FW_BIN) --ram-init=$(LINUX_IMG) $(_BASE_FLAGS))
	$(call _compile_if_needed,$(LINUX_GW_DIR))
	$(call _run_vsim,$(LINUX_GW_DIR))

# ==============================================================================
# FPGA Targets (future — placeholder)
# ==============================================================================



# ==============================================================================
# Utilities
# ==============================================================================

clean: ## Remove build artifacts
	rm -rf $(BUILD_DIR)
	@echo "Build artifacts cleaned."

sim-clean: ## Force next sim-build to recompile (clear verilator cache)
	@rm -f $(GW_DIR)/.sim_v_hash $(LINUX_GW_DIR)/.sim_v_hash
	@rm -rf $(GW_DIR)/obj_dir $(LINUX_GW_DIR)/obj_dir
	@echo "Verilator binary + hash cache cleared ($(VARIANT) + linux variant)."

clean-all: clean firmware-clean ## Remove build artifacts + firmware + venv
	rm -rf $(VENV_DIR)
	@echo "Virtual environment removed."

lint: ## Lint RTL (via nsim)
	$(MAKE) -C $(RAPTOR_HOME) lint

info: ## Show configuration info
	@echo "RAPTOR_HOME  = $(RAPTOR_HOME)"
	@echo "LITEX_DIR    = $(LITEX_DIR)"
	@echo "VARIANT      = $(VARIANT)"
	@echo "SYS_CLK      = $(SYS_CLK)"
	@echo "SIM_TIMEOUT  = $(SIM_TIMEOUT)"
	@echo "PACK_SV      = $(PACK_SV)"
	@echo "BUILD_DIR    = $(BUILD_DIR)"
	@echo "GW_DIR       = $(GW_DIR)"
	@echo "VSIM         = $(VSIM) (exists: $(shell test -f $(VSIM) && echo yes || echo no))"
	@echo "PYTHON       = $(PYTHON)"

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
	@grep -hE '^[A-Z_][A-Z_0-9]*\s*\?=' $(MAKEFILE_LIST) | \
		awk '!seen[$$1]++ { \
			if (match($$0, /## /)) { \
				name=$$0; sub(/\s*\?=.*/, "", name); \
				desc=substr($$0, RSTART+3); \
				printf "  %-20s %s\n", name, desc } \
			else { \
				split($$0, a, "\\?="); \
				gsub(/^[ \t]+|[ \t]+$$/, "", a[1]); gsub(/^[ \t]+|[ \t]+$$/, "", a[2]); \
				if (a[2] != "") printf "  %-20s (default: %s)\n", a[1], a[2] } }'
	@echo ""

# ==============================================================================
# PHONY declarations
# ==============================================================================
.PHONY: help setup setup-skip \
	pack \
	firmware firmware-clean \
	sim-gen sim-build sim sim-run sim-trace sim-trace-vcd sim-clean \
	run-litex run-litex-clean \
	coremark coremark-build coremark-clean \
	embench embench-build embench-build-one embench-run embench-report embench-clean \
	$(EMBENCH_TARGETS) \
	microbench microbench-build \
	tests tests-clean tests-run $(TEST_TARGETS) \
	opensbi opensbi-build opensbi-clean \
	payload \
	linux linux-build \
	tang-nano-20k \
	lint info clean clean-all
