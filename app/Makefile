# ============================================================================
# app/Makefile: Standard RISC-V ELF build system (pk)
#
# Builds standard ELFs with riscv64-unknown-elf-gcc (newlib), runs them on
# NPC via riscv-pk (proxy kernel).
# ============================================================================

APP_HOME := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
include $(APP_HOME)/common.mk

# Use bash so `set -o pipefail` works on systems where /bin/sh is dash
# (e.g. Ubuntu / GitHub Actions runners). Required by NPC tee wrappers below.
SHELL := /bin/bash

ARGS ?= -b -n## Simulator args for nsim/NEMU run targets (-b: batch, -n: no wave)
MAX_INST ?=## Optional maximum instruction limit for tinyos cli-nsim/cli-nemu
TIMEOUT ?=## Optional wall-clock timeout in seconds for tinyos cli-nsim
USER_ELF ?=## ELF binary for pk-run
# ----------------------------------------------------------------------------
# RLLMBench profile knobs.
# Per-platform defaults below target ~1-5s wall-clock per mode (Embench-style)
# while keeping RTL simulation tractable. Override any LLM_* knob on the
# command line to force a fixed profile across platforms (recommended for
# published comparisons, e.g. `make llm-... LLM_OP_ITERS=8192 LLM_GEN_TOKENS=16
# LLM_INFER_REPEATS=512 LLM_TRAIN_STEPS=1024`).
# ----------------------------------------------------------------------------
# NPC RTL simulator (~kHz model time): smallest profile.
LLM_NPC_OP_ITERS    ?= 8##  NPC operator iters
LLM_NPC_GEN_TOKENS  ?= 12## NPC generated tokens (<=16)
LLM_NPC_INFER_REPEATS ?= 1## NPC infer outer repeats
LLM_NPC_TRAIN_STEPS ?= 4##  NPC training steps
# NEMU software ISS (~100-500 MIPS): moderate profile.
LLM_NEMU_OP_ITERS    ?= 64##  NEMU operator iters
LLM_NEMU_GEN_TOKENS  ?= 16##  NEMU generated tokens (<=16)
LLM_NEMU_INFER_REPEATS ?= 2## NEMU infer outer repeats
LLM_NEMU_TRAIN_STEPS ?= 16##  NEMU training steps
# Native host (~GHz): large profile, ~3-5s per mode wall-clock on modern cores.
LLM_NATIVE_OP_ITERS    ?= 524288##  Native operator iters
LLM_NATIVE_GEN_TOKENS  ?= 16##       Native generated tokens (<=16)
LLM_NATIVE_INFER_REPEATS ?= 131072## Native infer outer repeats
LLM_NATIVE_TRAIN_STEPS ?= 262144##   Native training steps
# Generic fallback (also used for litex-build path); equivalent to NPC profile.
LLM_OP_ITERS ?= $(LLM_NPC_OP_ITERS)## LLM operator benchmark repeat count
LLM_GEN_TOKENS ?= $(LLM_NPC_GEN_TOKENS)## LLM inference generated token count
LLM_INFER_REPEATS ?= $(LLM_NPC_INFER_REPEATS)## LLM inference outer repeat count
LLM_TRAIN_STEPS ?= $(LLM_NPC_TRAIN_STEPS)## LLM training benchmark steps
RLLMBENCH_NPC_TIMEBASE_HZ ?= 10000000## NPC RISC-V time CSR frequency in Hz
RLLMBENCH_TIMEBASE_HZ ?= 1000000## RISC-V time CSR frequency in Hz
RLLMBENCH_NPC_CORE_CLOCK_MHZ ?= 1000## NPC core clock model in MHz for RLLMBench score/MHz
RLLMBENCH_CORE_CLOCK_MHZ ?= 0## Core clock in MHz for RLLMBench score/MHz (0=omit)
RLLMBENCH_NATIVE_CORE_CLOCK_MHZ ?= 0## Native host core clock in MHz for RLLMBench score/MHz (0=omit)
# ----------------------------------------------------------------------------
# RAgentBench profile knobs (agentic-workload CPU benchmark).
# Sized to keep NPC RTL sim tractable while remaining representative.
# ----------------------------------------------------------------------------
AGENT_NPC_TOOL_ITERS    ?= 16## NPC tool dispatch iterations (32 calls/iter)
AGENT_NPC_RAG_QUERIES   ?= 16## NPC retrieval queries
AGENT_NPC_FLOW_TURNS    ?= 16## NPC workflow agent loop turns
AGENT_NEMU_TOOL_ITERS   ?= 64## NEMU tool dispatch iterations
AGENT_NEMU_RAG_QUERIES  ?= 64## NEMU retrieval queries
AGENT_NEMU_FLOW_TURNS   ?= 64## NEMU workflow agent loop turns
AGENT_NATIVE_TOOL_ITERS  ?= 16384## Native tool dispatch iterations
AGENT_NATIVE_RAG_QUERIES ?= 4096## Native retrieval queries
AGENT_NATIVE_FLOW_TURNS  ?= 4096## Native workflow agent loop turns
AGENT_TOOL_ITERS  ?= $(AGENT_NPC_TOOL_ITERS)## Tool dispatch iterations
AGENT_RAG_QUERIES ?= $(AGENT_NPC_RAG_QUERIES)## Retrieval queries
AGENT_FLOW_TURNS  ?= $(AGENT_NPC_FLOW_TURNS)## Workflow agent loop turns
RAGENTBENCH_NPC_TIMEBASE_HZ ?= 10000000## NPC RISC-V time CSR frequency in Hz for RAgentBench
RAGENTBENCH_TIMEBASE_HZ ?= 1000000## RISC-V time CSR frequency in Hz for RAgentBench
RAGENTBENCH_NPC_CORE_CLOCK_MHZ ?= 1000## NPC core clock in MHz for RAgentBench score/MHz
RAGENTBENCH_CORE_CLOCK_MHZ ?= 0## Core clock in MHz for RAgentBench score/MHz (0=omit)
RAGENTBENCH_NATIVE_CORE_CLOCK_MHZ ?= 0## Native host core clock in MHz for RAgentBench score/MHz (0=omit)
PYTHON ?= python3## Python interpreter for benchmark report generation

ifneq ($(origin RUN_ON), undefined)
$(error RUN_ON is no longer supported; use explicit -npc/-nemu targets)
endif

RLLMBENCH_BACKEND := npc

export ISA64 ARGS CROSS_COMPILE

# ============================================================================
# Test/benchmark output logging (tee to nsim/build/<config>/logs/app/)
# Inherits NPC_LOG_DIR / NEMU_LOG_DIR / APP_LOG_DIR from the root Makefile when
# invoked as `make -C app …` from root. Falls back to local defaults otherwise.
# ============================================================================
NSIM_HOME    ?= $(abspath $(APP_HOME)/../nsim)
NEMU_HOME    ?= $(abspath $(APP_HOME)/../nemu)
RAPT_CONFIG  ?= default
APP_LOG_DIR  ?= $(NSIM_HOME)/build/$(RAPT_CONFIG)/logs/app
NPC_LOG_DIR  ?= $(NSIM_HOME)/build/$(RAPT_CONFIG)/logs
NEMU_LOG_DIR ?= $(NEMU_HOME)/build/logs

log: ## Run TARGET=<target> with stdout/stderr tee'd to $(APP_LOG_DIR)/$(LOG_NAME).log
	@test -n "$(TARGET)" || { echo "Usage: make -C app log TARGET=<target> [LOG_NAME=<stem>]"; exit 1; }
	@mkdir -p $(APP_LOG_DIR)
	@stem="$(if $(LOG_NAME),$(LOG_NAME),$(TARGET))"; \
	  echo "[log] $(APP_LOG_DIR)/$$stem.log"; \
	  set -o pipefail; $(MAKE) --no-print-directory $(TARGET) 2>&1 | tee "$(APP_LOG_DIR)/$$stem.log"

# ============================================================================
.DEFAULT_GOAL := help

help: ## Show this help
	@echo "Usage: make -C app <target> [VAR=value ...]"
	@awk '\
		BEGIN { state=0; pending=""; first=1 } \
		/^# =+$$/ { if (state==0) state=1; else if (state==2) { pending=section; state=0 } else state=0; next } \
		state==1 && /^# .+/ { section=substr($$0,3); state=2; next } \
		{ if (state==1) state=0 } \
		/^[a-zA-Z0-9_-]+:.*## / { \
			if (pending!="") { printf "\n%s:\n", pending; pending="" } \
			else if (first) printf "\nTargets:\n"; \
			first=0; \
			t=$$0; sub(/:.*/, "", t); \
			d=$$0; sub(/.*## /, "", d); \
			printf "  %-20s %s\n", t, d }' $(MAKEFILE_LIST)
	@echo ""
	@echo "Variables:"
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

# ============================================================================
# Environment
# ============================================================================
env-check: ## Check RISC-V toolchain availability
	@echo "Toolchain: $(CC)"
	@if command -v $(CC) >/dev/null 2>&1; then \
		echo "  Version: $$($(CC) --version | head -1)"; \
		echo "  Path:    $$(which $(CC))"; \
	else \
		echo "  ERROR: $(CC) not found"; \
		echo ""; \
		echo "Install with:"; \
		if [ "$$(uname)" = "Darwin" ]; then \
			echo "  brew tap riscv-software-src/riscv"; \
			echo "  brew install riscv-software-src/riscv/riscv-gnu-toolchain"; \
		else \
			echo "  sudo apt install gcc-riscv64-unknown-elf   # newlib (bare-metal)"; \
			echo "  sudo apt install gcc-riscv64-linux-gnu     # glibc (Linux userspace)"; \
		fi; \
		exit 1; \
	fi

setup: ## Install RISC-V toolchain (macOS: brew, Linux: apt)
	@if command -v $(CC) >/dev/null 2>&1; then \
		echo "Toolchain already installed: $$($(CC) --version | head -1)"; \
	elif [ "$$(uname)" = "Darwin" ]; then \
		echo "=== Installing RISC-V GNU Toolchain via Homebrew ==="; \
		brew tap riscv-software-src/riscv; \
		brew install riscv-software-src/riscv/riscv-gnu-toolchain; \
	elif command -v apt >/dev/null 2>&1; then \
		echo "=== Installing RISC-V GNU Toolchain via apt ==="; \
		sudo apt update && sudo apt install -y gcc-riscv64-unknown-elf || \
		sudo apt install -y gcc-riscv64-linux-gnu; \
	else \
		echo "ERROR: unsupported platform, install $(CC) manually"; \
		exit 1; \
	fi

# ============================================================================
# pk / BBL targets (delegate to pk/Makefile)
# ============================================================================
pk-build: ## Build riscv-pk
	@$(MAKE) $(Q) -C $(APP_HOME)/pk pk-build

pk-run: ## Run USER_ELF via pk on NPC
	@$(MAKE) $(Q) -C $(APP_HOME)/pk pk-run USER_ELF=$(abspath $(USER_ELF))

nemu-run: ## Run USER_ELF via pk on NEMU
	@$(MAKE) $(Q) -C $(APP_HOME)/pk nemu-run USER_ELF=$(abspath $(USER_ELF))

bbl-linux: ## Boot Linux via BBL
	@$(MAKE) $(Q) -C $(APP_HOME)/pk bbl-linux

# ============================================================================
# Runner helpers: explicit pk/NEMU targets
#   These are internal macros used by all run targets below.
#
# NPC payload runs (pk-target=pk-run / backend=npc) tee stdout+stderr to
# $(APP_LOG_DIR)/<elf-stem>.log so results are persisted alongside other
# nsim/build/<config>/logs/ artifacts. NEMU runs stay unredirected because
# they already log via NEMU's own --log facility.
# ============================================================================
# Strip directory + extension for log file naming.
_log_stem = $(basename $(notdir $(1)))

# Run a single ELF: $(call _pk_run_with,<pk-target>,<elf-path>)
define _pk_run_with
	$(if $(filter pk-run,$(1)),mkdir -p $(APP_LOG_DIR) && set -o pipefail && $(MAKE) $(Q) -C $(APP_HOME)/pk $(1) USER_ELF=$(2) 2>&1 | tee "$(APP_LOG_DIR)/$(call _log_stem,$(2)).log",$(MAKE) $(Q) -C $(APP_HOME)/pk $(1) USER_ELF=$(2))
endef

# Run a list of ELFs: $(call _pk_run_suite_with,<suite-name>,<backend>,<pk-target>,<elf-dir>,<test-list>)
define _pk_run_suite_with
	@echo "=== Running $(1) ($(2)) ==="
	@$(if $(filter npc,$(2)),mkdir -p $(APP_LOG_DIR);)for t in $(5); do \
		echo "--- $$t ---"; \
		$(if $(filter npc,$(2)),set -o pipefail && $(MAKE) $(Q) -C $(APP_HOME)/pk $(3) USER_ELF=$(4)/$$t.elf 2>&1 | tee "$(APP_LOG_DIR)/$$t.log",$(MAKE) $(Q) -C $(APP_HOME)/pk $(3) USER_ELF=$(4)/$$t.elf) \
			|| true; \
	done
	@echo "=== $(1) complete ==="
endef

# ============================================================================
# CoreMark
# ============================================================================
coremark-build: ## Build CoreMark ELF
	@$(MAKE) $(Q) -C $(APP_HOME)/benchmarks/coremark build

coremark-npc: coremark-build ## Build and run CoreMark on NPC/nsim via pk
	@$(call _pk_run_with,pk-run,$(APP_HOME)/build/rv$(XLEN)/coremark/coremark.elf)

coremark-nemu: coremark-build ## Build and run CoreMark on NEMU via pk
	@$(call _pk_run_with,nemu-run,$(APP_HOME)/build/rv$(XLEN)/coremark/coremark.elf)

# ============================================================================
# Embench-IoT
# ============================================================================
EMBENCH_BENCHMARKS := aha-mont64 crc32 depthconv edn huffbench matmult-int \
					  md5sum nettle-aes nettle-sha256 nsichneu picojpeg \
					  qrduino sglib-combined slre statemate tarfind ud \
					  wikisort xgboost

EMBENCH_JOBS ?= $(NPROC)## Parallel NPC/nsim instances for embench-npc
PK_BUILD     = $(APP_HOME)/build/pk-build-rv$(XLEN)

embench-build: ## Build all Embench ELFs
	@$(MAKE) $(Q) -C $(APP_HOME)/benchmarks/embench build

# Pre-embed each ELF into pk, producing per-bench .bin files.
# Sequential (shares PK_BUILD dir), but each relink is fast (~1s).
embench-pk-bins: embench-build
	@$(MAKE) $(Q) -C $(APP_HOME)/pk $(PK_BUILD)/Makefile
	@for bench in $(EMBENCH_BENCHMARKS); do \
		elf=$(APP_HOME)/build/rv$(XLEN)/embench/$$bench/$$bench.elf; \
		bin=$(APP_HOME)/build/rv$(XLEN)/embench/$$bench/$$bench.bin; \
		if [ ! -f "$$elf" ]; then echo "[embench] SKIP $$bench (no ELF)"; continue; fi; \
		cp "$$elf" $(PK_BUILD)/payload.elf; \
		rm -f $(PK_BUILD)/pk_payload.o $(PK_BUILD)/pk; \
		env -u CFLAGS -u CPPFLAGS -u LDFLAGS $(MAKE) $(Q) -C $(PK_BUILD) -j$(NPROC) > /dev/null; \
		$(OBJCOPY) -S -O binary $(PK_BUILD)/pk "$$bin"; \
	done

embench-npc: embench-pk-bins ## Build and run all Embench benchmarks on NPC/nsim via pk (parallel)
	@echo "=== Running Embench-IoT (npc, JOBS=$(EMBENCH_JOBS)) ==="
	@NPC_CMD=$$($(MAKE) --no-print-directory -C $(NSIM_HOME) ISA=riscv$(XLEN) \
		VFLAGS="$(VFLAGS)" print-npc-exec 2>/dev/null) || \
		{ echo "ERROR: cannot resolve NPC command"; exit 1; }; \
	export NPC_CMD NSIM_HOME="$(NSIM_HOME)" BENCH_DIR="$(APP_HOME)/build/rv$(XLEN)/embench" \
		NPC_ARGS="$(ARGS)"; \
	for bench in $(EMBENCH_BENCHMARKS); do \
		[ -f "$$BENCH_DIR/$$bench/$$bench.bin" ] && printf '%s\n' "$$bench"; \
	done | xargs -P $(EMBENCH_JOBS) -I{} sh -c ' \
		echo "--- {} ---"; \
		cd "$$NSIM_HOME" && $$NPC_CMD $$NPC_ARGS "$$BENCH_DIR/{}/{}.bin" \
			|| true'
	@echo "=== Embench-IoT complete ==="

embench-nemu: embench-build ## Build and run all Embench benchmarks on NEMU via pk
	@echo "=== Running Embench-IoT (nemu) ==="
	@for bench in $(EMBENCH_BENCHMARKS); do \
		elf=$(APP_HOME)/build/rv$(XLEN)/embench/$$bench/$$bench.elf; \
		if [ ! -f "$$elf" ]; then echo "[embench] SKIP $$bench (no ELF)"; continue; fi; \
		echo "--- $$bench ---"; \
		$(MAKE) $(Q) -C $(APP_HOME)/pk nemu-run USER_ELF=$$elf || true; \
	done
	@echo "=== Embench-IoT complete ==="

# ============================================================================
# LLM-style AI benchmarks
# ============================================================================
LLM_BENCHMARKS := llm-ops llm-infer llm-train
# NOTE: LLM_VARS is intentionally deferred (=, not :=) so that target-specific
# variable overrides for $(LLM_NPC_TARGETS) / $(LLM_NEMU_TARGETS) / native take
# effect in the recursive sub-make.
LLM_VARS = LLM_OP_ITERS=$(LLM_OP_ITERS) \
           LLM_GEN_TOKENS=$(LLM_GEN_TOKENS) \
           LLM_INFER_REPEATS=$(LLM_INFER_REPEATS) \
           LLM_TRAIN_STEPS=$(LLM_TRAIN_STEPS) \
           RLLMBENCH_TIMEBASE_HZ=$(RLLMBENCH_TIMEBASE_HZ)
LLM_PROFILE_TAG = ops$(LLM_OP_ITERS)-gen$(LLM_GEN_TOKENS)x$(LLM_INFER_REPEATS)-train$(LLM_TRAIN_STEPS)
LLM_BUILD_DIR = $(APP_HOME)/build/rv$(XLEN)/benchmarks/llm/$(LLM_PROFILE_TAG)
LLM_LOG_DIR = $(LLM_BUILD_DIR)/logs/$(RLLMBENCH_BACKEND)
LLM_REPORT_DIR := $(LLM_BUILD_DIR)/reports
LLM_REPORT_MD = $(LLM_REPORT_DIR)/rllmbench-$(RLLMBENCH_BACKEND).md
LLM_REPORT_CSV = $(LLM_REPORT_DIR)/rllmbench-$(RLLMBENCH_BACKEND).csv
LLM_REPORT_JSON = $(LLM_REPORT_DIR)/rllmbench-$(RLLMBENCH_BACKEND).json
LLM_REPORT_SCRIPT := $(APP_HOME)/benchmarks/llm/report.py
LLM_NPC_TARGETS := llm-ops-npc llm-infer-npc llm-train-npc llm-bench-run-npc llm-bench-report-npc
LLM_NEMU_TARGETS := llm-ops-nemu llm-infer-nemu llm-train-nemu llm-bench-run-nemu llm-bench-report-nemu

$(LLM_NPC_TARGETS): RLLMBENCH_BACKEND := npc
$(LLM_NPC_TARGETS): RLLMBENCH_TIMEBASE_HZ := $(RLLMBENCH_NPC_TIMEBASE_HZ)
$(LLM_NPC_TARGETS): RLLMBENCH_CORE_CLOCK_MHZ := $(RLLMBENCH_NPC_CORE_CLOCK_MHZ)
$(LLM_NPC_TARGETS): LLM_OP_ITERS := $(LLM_NPC_OP_ITERS)
$(LLM_NPC_TARGETS): LLM_GEN_TOKENS := $(LLM_NPC_GEN_TOKENS)
$(LLM_NPC_TARGETS): LLM_INFER_REPEATS := $(LLM_NPC_INFER_REPEATS)
$(LLM_NPC_TARGETS): LLM_TRAIN_STEPS := $(LLM_NPC_TRAIN_STEPS)
$(LLM_NEMU_TARGETS): RLLMBENCH_BACKEND := nemu
$(LLM_NEMU_TARGETS): RLLMBENCH_TIMEBASE_HZ := 1000000
$(LLM_NEMU_TARGETS): RLLMBENCH_CORE_CLOCK_MHZ := 0
$(LLM_NEMU_TARGETS): LLM_OP_ITERS := $(LLM_NEMU_OP_ITERS)
$(LLM_NEMU_TARGETS): LLM_GEN_TOKENS := $(LLM_NEMU_GEN_TOKENS)
$(LLM_NEMU_TARGETS): LLM_INFER_REPEATS := $(LLM_NEMU_INFER_REPEATS)
$(LLM_NEMU_TARGETS): LLM_TRAIN_STEPS := $(LLM_NEMU_TRAIN_STEPS)
llm-native-build llm-native-test: LLM_OP_ITERS := $(LLM_NATIVE_OP_ITERS)
llm-native-build llm-native-test: LLM_GEN_TOKENS := $(LLM_NATIVE_GEN_TOKENS)
llm-native-build llm-native-test: LLM_INFER_REPEATS := $(LLM_NATIVE_INFER_REPEATS)
llm-native-build llm-native-test: LLM_TRAIN_STEPS := $(LLM_NATIVE_TRAIN_STEPS)

llm-bench-build: ## Build LLM operator/infer/train benchmark ELFs
	@$(MAKE) $(Q) -C $(APP_HOME)/benchmarks/llm build $(LLM_VARS)

llm-litex-build: ## Build LLM benchmarks as LiteX-native flat binaries
	@$(MAKE) $(Q) -C $(APP_HOME)/benchmarks/llm litex-build $(LLM_VARS)

llm-native-build: ## Build LLM benchmarks as host-native executables
	@$(MAKE) $(Q) -C $(APP_HOME)/benchmarks/llm native-build $(LLM_VARS)

llm-native-test: ## Build, run, and report host-native RLLMBench
	@$(MAKE) $(Q) -C $(APP_HOME)/benchmarks/llm native-test $(LLM_VARS) PYTHON=$(PYTHON) \
		RLLMBENCH_CORE_CLOCK_MHZ=$(RLLMBENCH_NATIVE_CORE_CLOCK_MHZ)

define _llm_bench_report_with
	@mkdir -p $(LLM_LOG_DIR) $(LLM_REPORT_DIR)
	@find $(LLM_LOG_DIR) -type f -name '*.log' -delete
	@rm -f $(LLM_REPORT_MD) $(LLM_REPORT_CSV) $(LLM_REPORT_JSON)
	@echo "=== Running RLLMBench ($(RLLMBENCH_BACKEND), profile=ops$(LLM_OP_ITERS)-gen$(LLM_GEN_TOKENS)x$(LLM_INFER_REPEATS)-train$(LLM_TRAIN_STEPS)) ==="
	@fail=0; for bench in $(LLM_BENCHMARKS); do \
		elf=$(LLM_BUILD_DIR)/$$bench.elf; \
		log=$(LLM_LOG_DIR)/$$bench.log; \
		echo "--- $$bench ---"; \
		if $(MAKE) $(Q) -C $(APP_HOME)/pk $(1) USER_ELF=$$elf > $$log 2>&1; then \
			grep -E '^(RLLMBench|RLLMBENCH_|last_token=|llm_bench_done)' $$log || cat $$log; \
			if ! grep -q 'RLLMBENCH_END .*status=PASS' $$log; then \
				echo "[RLLMBench] $$bench log missing PASS marker"; fail=1; \
			fi; \
		else \
			rc=$$?; cat $$log; echo "[RLLMBench] $$bench failed (exit $$rc)"; fail=1; \
		fi; \
	done; \
	for bench in $(LLM_BENCHMARKS); do \
		log=$(LLM_LOG_DIR)/$$bench.log; \
		if [ ! -s $$log ]; then echo "[RLLMBench] missing or empty log: $$log"; fail=1; fi; \
	done; \
	$(PYTHON) $(LLM_REPORT_SCRIPT) \
		--log-dir $(LLM_LOG_DIR) \
		--markdown $(LLM_REPORT_MD) \
		--csv $(LLM_REPORT_CSV) \
		--json $(LLM_REPORT_JSON) \
		--core-clock-mhz $(RLLMBENCH_CORE_CLOCK_MHZ) \
		--suite RLLMBench; \
	report_rc=$$?; \
	if [ $$report_rc -ne 0 ]; then exit $$report_rc; fi; \
	exit $$fail
endef

llm-ops-npc: llm-bench-build ## Build and run LLM operator benchmark on NPC/nsim via pk
	@$(call _pk_run_with,pk-run,$(APP_HOME)/build/rv$(XLEN)/benchmarks/llm/llm-ops.elf)

llm-ops-nemu: llm-bench-build ## Build and run LLM operator benchmark on NEMU via pk
	@$(call _pk_run_with,nemu-run,$(APP_HOME)/build/rv$(XLEN)/benchmarks/llm/llm-ops.elf)

llm-infer-npc: llm-bench-build ## Build and run LLM E2E inference benchmark on NPC/nsim via pk
	@$(call _pk_run_with,pk-run,$(APP_HOME)/build/rv$(XLEN)/benchmarks/llm/llm-infer.elf)

llm-infer-nemu: llm-bench-build ## Build and run LLM E2E inference benchmark on NEMU via pk
	@$(call _pk_run_with,nemu-run,$(APP_HOME)/build/rv$(XLEN)/benchmarks/llm/llm-infer.elf)

llm-train-npc: llm-bench-build ## Build and run LLM E2E training benchmark on NPC/nsim via pk
	@$(call _pk_run_with,pk-run,$(APP_HOME)/build/rv$(XLEN)/benchmarks/llm/llm-train.elf)

llm-train-nemu: llm-bench-build ## Build and run LLM E2E training benchmark on NEMU via pk
	@$(call _pk_run_with,nemu-run,$(APP_HOME)/build/rv$(XLEN)/benchmarks/llm/llm-train.elf)

llm-bench-run-npc: llm-bench-build ## Build and run all LLM benchmarks on NPC/nsim via pk without report files
	$(call _pk_run_suite_with,RLLMBench,npc,pk-run,$(LLM_BUILD_DIR),$(LLM_BENCHMARKS))

llm-bench-run-nemu: llm-bench-build ## Build and run all LLM benchmarks on NEMU via pk without report files
	$(call _pk_run_suite_with,RLLMBench,nemu,nemu-run,$(LLM_BUILD_DIR),$(LLM_BENCHMARKS))

llm-bench-report-npc: llm-bench-build ## Build, run, log, and summarize RLLMBench on NPC/nsim
	$(call _llm_bench_report_with,pk-run)

llm-bench-report-nemu: llm-bench-build ## Build, run, log, and summarize RLLMBench on NEMU
	$(call _llm_bench_report_with,nemu-run)

# ============================================================================
# RAgentBench: agentic-workload CPU benchmarks
# ============================================================================
AGENT_BENCHMARKS := agent-tools agent-rag agent-workflow
AGENT_VARS = AGENT_TOOL_ITERS=$(AGENT_TOOL_ITERS) \
             AGENT_RAG_QUERIES=$(AGENT_RAG_QUERIES) \
             AGENT_FLOW_TURNS=$(AGENT_FLOW_TURNS) \
             RAGENTBENCH_TIMEBASE_HZ=$(RAGENTBENCH_TIMEBASE_HZ)
AGENT_BUILD_DIR := $(APP_HOME)/build/rv$(XLEN)/benchmarks/agent
AGENT_LOG_DIR = $(AGENT_BUILD_DIR)/logs/$(RAGENTBENCH_BACKEND)
AGENT_REPORT_DIR := $(AGENT_BUILD_DIR)/reports
AGENT_REPORT_MD = $(AGENT_REPORT_DIR)/ragentbench-$(RAGENTBENCH_BACKEND).md
AGENT_REPORT_CSV = $(AGENT_REPORT_DIR)/ragentbench-$(RAGENTBENCH_BACKEND).csv
AGENT_REPORT_JSON = $(AGENT_REPORT_DIR)/ragentbench-$(RAGENTBENCH_BACKEND).json
AGENT_REPORT_SCRIPT := $(APP_HOME)/benchmarks/agent/report.py
AGENT_NPC_TARGETS := agent-tools-npc agent-rag-npc agent-workflow-npc agent-bench-run-npc agent-bench-report-npc
AGENT_NEMU_TARGETS := agent-tools-nemu agent-rag-nemu agent-workflow-nemu agent-bench-run-nemu agent-bench-report-nemu

RAGENTBENCH_BACKEND := npc

$(AGENT_NPC_TARGETS): RAGENTBENCH_BACKEND := npc
$(AGENT_NPC_TARGETS): RAGENTBENCH_TIMEBASE_HZ := $(RAGENTBENCH_NPC_TIMEBASE_HZ)
$(AGENT_NPC_TARGETS): RAGENTBENCH_CORE_CLOCK_MHZ := $(RAGENTBENCH_NPC_CORE_CLOCK_MHZ)
$(AGENT_NPC_TARGETS): AGENT_TOOL_ITERS := $(AGENT_NPC_TOOL_ITERS)
$(AGENT_NPC_TARGETS): AGENT_RAG_QUERIES := $(AGENT_NPC_RAG_QUERIES)
$(AGENT_NPC_TARGETS): AGENT_FLOW_TURNS := $(AGENT_NPC_FLOW_TURNS)
$(AGENT_NEMU_TARGETS): RAGENTBENCH_BACKEND := nemu
$(AGENT_NEMU_TARGETS): RAGENTBENCH_TIMEBASE_HZ := 1000000
$(AGENT_NEMU_TARGETS): RAGENTBENCH_CORE_CLOCK_MHZ := 0
$(AGENT_NEMU_TARGETS): AGENT_TOOL_ITERS := $(AGENT_NEMU_TOOL_ITERS)
$(AGENT_NEMU_TARGETS): AGENT_RAG_QUERIES := $(AGENT_NEMU_RAG_QUERIES)
$(AGENT_NEMU_TARGETS): AGENT_FLOW_TURNS := $(AGENT_NEMU_FLOW_TURNS)
agent-native-build agent-native-test: AGENT_TOOL_ITERS := $(AGENT_NATIVE_TOOL_ITERS)
agent-native-build agent-native-test: AGENT_RAG_QUERIES := $(AGENT_NATIVE_RAG_QUERIES)
agent-native-build agent-native-test: AGENT_FLOW_TURNS := $(AGENT_NATIVE_FLOW_TURNS)

agent-bench-build: ## Build RAgentBench tools/rag/workflow benchmark ELFs
	@$(MAKE) $(Q) -C $(APP_HOME)/benchmarks/agent build $(AGENT_VARS)

agent-litex-build: ## Build RAgentBench benchmarks as LiteX-native flat binaries
	@$(MAKE) $(Q) -C $(APP_HOME)/benchmarks/agent litex-build $(AGENT_VARS)

agent-native-build: ## Build RAgentBench benchmarks as host-native executables
	@$(MAKE) $(Q) -C $(APP_HOME)/benchmarks/agent native-build $(AGENT_VARS)

agent-native-test: ## Build, run, and report host-native RAgentBench
	@$(MAKE) $(Q) -C $(APP_HOME)/benchmarks/agent native-test $(AGENT_VARS) PYTHON=$(PYTHON) \
		RAGENTBENCH_CORE_CLOCK_MHZ=$(RAGENTBENCH_NATIVE_CORE_CLOCK_MHZ)

define _agent_bench_report_with
	@mkdir -p $(AGENT_LOG_DIR) $(AGENT_REPORT_DIR)
	@find $(AGENT_LOG_DIR) -type f -name '*.log' -delete
	@rm -f $(AGENT_REPORT_MD) $(AGENT_REPORT_CSV) $(AGENT_REPORT_JSON)
	@echo "=== Running RAgentBench ($(RAGENTBENCH_BACKEND), profile=tools$(AGENT_TOOL_ITERS)-rag$(AGENT_RAG_QUERIES)-flow$(AGENT_FLOW_TURNS)) ==="
	@fail=0; for bench in $(AGENT_BENCHMARKS); do \
		elf=$(AGENT_BUILD_DIR)/$$bench.elf; \
		log=$(AGENT_LOG_DIR)/$$bench.log; \
		echo "--- $$bench ---"; \
		if $(MAKE) $(Q) -C $(APP_HOME)/pk $(1) USER_ELF=$$elf > $$log 2>&1; then \
			grep -E '^(RAgentBench|RAGENTBENCH_|agent_bench_done)' $$log || cat $$log; \
			if ! grep -q 'RAGENTBENCH_END .*status=PASS' $$log; then \
				echo "[RAgentBench] $$bench log missing PASS marker"; fail=1; \
			fi; \
		else \
			rc=$$?; cat $$log; echo "[RAgentBench] $$bench failed (exit $$rc)"; fail=1; \
		fi; \
	done; \
	for bench in $(AGENT_BENCHMARKS); do \
		log=$(AGENT_LOG_DIR)/$$bench.log; \
		if [ ! -s $$log ]; then echo "[RAgentBench] missing or empty log: $$log"; fail=1; fi; \
	done; \
	$(PYTHON) $(AGENT_REPORT_SCRIPT) \
		--log-dir $(AGENT_LOG_DIR) \
		--markdown $(AGENT_REPORT_MD) \
		--csv $(AGENT_REPORT_CSV) \
		--json $(AGENT_REPORT_JSON) \
		--core-clock-mhz $(RAGENTBENCH_CORE_CLOCK_MHZ) \
		--suite RAgentBench; \
	report_rc=$$?; \
	if [ $$report_rc -ne 0 ]; then exit $$report_rc; fi; \
	exit $$fail
endef

agent-tools-npc: agent-bench-build ## Build and run RAgentBench tool dispatch benchmark on NPC/nsim via pk
	@$(call _pk_run_with,pk-run,$(APP_HOME)/build/rv$(XLEN)/benchmarks/agent/agent-tools.elf)

agent-tools-nemu: agent-bench-build ## Build and run RAgentBench tool dispatch benchmark on NEMU via pk
	@$(call _pk_run_with,nemu-run,$(APP_HOME)/build/rv$(XLEN)/benchmarks/agent/agent-tools.elf)

agent-rag-npc: agent-bench-build ## Build and run RAgentBench RAG benchmark on NPC/nsim via pk
	@$(call _pk_run_with,pk-run,$(APP_HOME)/build/rv$(XLEN)/benchmarks/agent/agent-rag.elf)

agent-rag-nemu: agent-bench-build ## Build and run RAgentBench RAG benchmark on NEMU via pk
	@$(call _pk_run_with,nemu-run,$(APP_HOME)/build/rv$(XLEN)/benchmarks/agent/agent-rag.elf)

agent-workflow-npc: agent-bench-build ## Build and run RAgentBench workflow benchmark on NPC/nsim via pk
	@$(call _pk_run_with,pk-run,$(APP_HOME)/build/rv$(XLEN)/benchmarks/agent/agent-workflow.elf)

agent-workflow-nemu: agent-bench-build ## Build and run RAgentBench workflow benchmark on NEMU via pk
	@$(call _pk_run_with,nemu-run,$(APP_HOME)/build/rv$(XLEN)/benchmarks/agent/agent-workflow.elf)

agent-bench-run-npc: agent-bench-build ## Build and run all RAgentBench benchmarks on NPC/nsim via pk without report files
	$(call _pk_run_suite_with,RAgentBench,npc,pk-run,$(AGENT_BUILD_DIR),$(AGENT_BENCHMARKS))

agent-bench-run-nemu: agent-bench-build ## Build and run all RAgentBench benchmarks on NEMU via pk without report files
	$(call _pk_run_suite_with,RAgentBench,nemu,nemu-run,$(AGENT_BUILD_DIR),$(AGENT_BENCHMARKS))

agent-bench-report-npc: agent-bench-build ## Build, run, log, and summarize RAgentBench on NPC/nsim
	$(call _agent_bench_report_with,pk-run)

agent-bench-report-nemu: agent-bench-build ## Build, run, log, and summarize RAgentBench on NEMU
	$(call _agent_bench_report_with,nemu-run)

# ============================================================================
# TinyOS / OS bring-up targets (delegate to tinyos/Makefile)
# ============================================================================
TINYOS_OS ?=## TinyOS payload selector: egos or xv6
OS ?=## Generic OS selector for cli helpers: egos or xv6
QEMU ?=## Override QEMU executable for os-cli-qemu helpers (optional)
TINYOS_OS_SELECTED := $(strip $(if $(OS),$(OS),$(TINYOS_OS)))

tinyos-sync: ## Clone or update egos-2000 and xv6-riscv under app/tinyos
	@$(MAKE) $(Q) -C $(APP_HOME)/tinyos sync

os-cli-qemu: ## Enter upstream OS CLI on QEMU (OS=egos|xv6 or TINYOS_OS=egos|xv6) {OS,TINYOS_OS,QEMU}
	@if [ -z "$(TINYOS_OS_SELECTED)" ]; then echo "[ERR] Set OS=egos|xv6 or TINYOS_OS=egos|xv6"; exit 1; fi
	@$(MAKE) $(Q) -C $(APP_HOME)/tinyos cli-qemu OS=$(TINYOS_OS_SELECTED) $(if $(QEMU),QEMU=$(QEMU),)

egos-cli-qemu: ## Enter egos CLI on QEMU
	@$(MAKE) $(Q) -C $(APP_HOME)/tinyos egos-cli-qemu $(if $(QEMU),QEMU=$(QEMU),)

xv6-cli-qemu: ## Enter xv6 CLI on QEMU
	@$(MAKE) $(Q) -C $(APP_HOME)/tinyos xv6-cli-qemu $(if $(QEMU),QEMU=$(QEMU),)

os-cli-nsim: ## Boot upstream OS image on NPC/nsim where supported (OS=egos|xv6 or TINYOS_OS=egos|xv6) {OS,TINYOS_OS,ARGS,MAX_INST,TIMEOUT}
	@if [ -z "$(TINYOS_OS_SELECTED)" ]; then echo "[ERR] Set OS=egos|xv6 or TINYOS_OS=egos|xv6"; exit 1; fi
	@$(MAKE) $(Q) -C $(APP_HOME)/tinyos cli-nsim OS=$(TINYOS_OS_SELECTED) ARGS="$(ARGS)" MAX_INST="$(MAX_INST)" TIMEOUT="$(TIMEOUT)"

os-cli-nemu: ## Boot upstream OS image on NEMU where supported (OS=egos|xv6 or TINYOS_OS=egos|xv6) {OS,TINYOS_OS,ARGS,MAX_INST}
	@if [ -z "$(TINYOS_OS_SELECTED)" ]; then echo "[ERR] Set OS=egos|xv6 or TINYOS_OS=egos|xv6"; exit 1; fi
	@$(MAKE) $(Q) -C $(APP_HOME)/tinyos cli-nemu OS=$(TINYOS_OS_SELECTED) ARGS="$(ARGS)" MAX_INST="$(MAX_INST)"

egos-cli-nsim: ## Boot upstream egos image on NPC/nsim
	@$(MAKE) $(Q) -C $(APP_HOME)/tinyos egos-cli-nsim ARGS="$(ARGS)" MAX_INST="$(MAX_INST)" TIMEOUT="$(TIMEOUT)"

egos-cli-nsim-difftest: ## Boot upstream egos image on NPC/nsim with NEMU difftest (auto-configure nsim+ref)
	@$(MAKE) $(Q) -C $(APP_HOME)/.. config-npc32-difftest config-nemu32-ref
	@$(MAKE) $(Q) -C $(APP_HOME)/tinyos egos-cli-nsim-difftest ARGS="$(ARGS)" MAX_INST="$(MAX_INST)" TIMEOUT="$(TIMEOUT)"

egos-cli-nemu: ## Boot upstream egos image on NEMU
	@$(MAKE) $(Q) -C $(APP_HOME)/tinyos egos-cli-nemu ARGS="$(ARGS)" MAX_INST="$(MAX_INST)"

xv6-cli-nsim: ## Boot upstream xv6-riscv on NPC/nsim
	@$(MAKE) $(Q) -C $(APP_HOME)/tinyos xv6-cli-nsim ARGS="$(ARGS)" MAX_INST="$(MAX_INST)" TIMEOUT="$(TIMEOUT)"

xv6-cli-nsim-difftest: ## Boot upstream xv6-riscv on NPC/nsim with NEMU difftest (auto-configure nsim+ref)
	@$(MAKE) $(Q) -C $(APP_HOME)/.. config-npc32-difftest config-nemu64-ref
	@$(MAKE) $(Q) -C $(APP_HOME)/tinyos xv6-cli-nsim-difftest ARGS="$(ARGS)" MAX_INST="$(MAX_INST)" TIMEOUT="$(TIMEOUT)"

xv6-cli-nemu: ## Boot upstream xv6-riscv on NEMU
	@$(MAKE) $(Q) -C $(APP_HOME)/tinyos xv6-cli-nemu ARGS="$(ARGS)" MAX_INST="$(MAX_INST)"

# ============================================================================
# Hello world test
# ============================================================================
hello-build: ## Build hello ELF
	@$(MAKE) $(Q) -C $(APP_HOME)/tests/hello build

hello-npc: hello-build ## Build and run hello on NPC/nsim via pk
	@$(call _pk_run_with,pk-run,$(APP_HOME)/build/rv$(XLEN)/tests/hello/hello.elf)

hello-nemu: hello-build ## Build and run hello on NEMU via pk
	@$(call _pk_run_with,nemu-run,$(APP_HOME)/build/rv$(XLEN)/tests/hello/hello.elf)

# ============================================================================
# ISA correctness tests
# ============================================================================
isa-tests-build: ## Build ISA verification tests
	@$(MAKE) $(Q) -C $(APP_HOME)/tests/isa build

ISA_TESTS := rv_add rv_shift rv_logic rv_mul_div rv_branch rv_slt rv_bitmanip rv_compressed \
             rv_zicond rv_zicsr rv_zifencei rv_zcb rv_zimop

isa-tests-npc: isa-tests-build ## Build and run all ISA tests on NPC/nsim via pk
	$(call _pk_run_suite_with,ISA tests,npc,pk-run,$(APP_HOME)/build/rv$(XLEN)/tests/isa,$(ISA_TESTS))

isa-tests-nemu: isa-tests-build ## Build and run all ISA tests on NEMU via pk
	$(call _pk_run_suite_with,ISA tests,nemu,nemu-run,$(APP_HOME)/build/rv$(XLEN)/tests/isa,$(ISA_TESTS))

# ============================================================================
# Memory subsystem tests
# ============================================================================
memory-tests-build: ## Build memory tests
	@$(MAKE) $(Q) -C $(APP_HOME)/tests/memory build

MEMORY_TESTS := load_store memory_pattern stack_test memtest

memory-tests-npc: memory-tests-build ## Build and run all memory tests on NPC/nsim via pk
	$(call _pk_run_suite_with,Memory tests,npc,pk-run,$(APP_HOME)/build/rv$(XLEN)/tests/memory,$(MEMORY_TESTS))

memory-tests-nemu: memory-tests-build ## Build and run all memory tests on NEMU via pk
	$(call _pk_run_suite_with,Memory tests,nemu,nemu-run,$(APP_HOME)/build/rv$(XLEN)/tests/memory,$(MEMORY_TESTS))

# ============================================================================
# Algorithm tests
# ============================================================================
algo-tests-build: ## Build algorithm tests
	@$(MAKE) $(Q) -C $(APP_HOME)/tests/algo build

ALGO_TESTS := sorting crc32 math_test string_ops

algo-tests-npc: algo-tests-build ## Build and run all algorithm tests on NPC/nsim via pk
	$(call _pk_run_suite_with,Algorithm tests,npc,pk-run,$(APP_HOME)/build/rv$(XLEN)/tests/algo,$(ALGO_TESTS))

algo-tests-nemu: algo-tests-build ## Build and run all algorithm tests on NEMU via pk
	$(call _pk_run_suite_with,Algorithm tests,nemu,nemu-run,$(APP_HOME)/build/rv$(XLEN)/tests/algo,$(ALGO_TESTS))

# ============================================================================
# Security / side-channel tests
# ============================================================================
security-tests-build: ## Build security / side-channel tests
	@$(MAKE) $(Q) -C $(APP_HOME)/tests/security build

SECURITY_TESTS := cache-timing fence-timing bpu-collision \
                  spectre-v1 spectre-v2 spec-store-bypass

security-tests-npc: security-tests-build ## Build and run all security tests on NPC/nsim via pk
	$(call _pk_run_suite_with,Security tests,npc,pk-run,$(APP_HOME)/build/rv$(XLEN)/tests/security,$(SECURITY_TESTS))

security-tests-nemu: security-tests-build ## Build and run all security tests on NEMU via pk
	$(call _pk_run_suite_with,Security tests,nemu,nemu-run,$(APP_HOME)/build/rv$(XLEN)/tests/security,$(SECURITY_TESTS))

# ============================================================================
# All tests
# ============================================================================
tests-build: hello-build isa-tests-build memory-tests-build algo-tests-build security-tests-build ## Build all tests

tests-npc: hello-npc isa-tests-npc memory-tests-npc algo-tests-npc security-tests-npc ## Run all tests on NPC/nsim via pk

tests-nemu: hello-nemu isa-tests-nemu memory-tests-nemu algo-tests-nemu security-tests-nemu ## Run all tests on NEMU via pk

# ============================================================================
# Demo programs
# ============================================================================
demos-build: ## Build demo programs
	@$(MAKE) $(Q) -C $(APP_HOME)/demos build

DEMOS := donut cmatrix langton life hanoi mandelbrot sysinfo

demos-npc: demos-build ## Build and run all demos on NPC/nsim via pk
	$(call _pk_run_suite_with,Demo programs,npc,pk-run,$(APP_HOME)/build/rv$(XLEN)/demos,$(DEMOS))

demos-nemu: demos-build ## Build and run all demos on NEMU via pk
	$(call _pk_run_suite_with,Demo programs,nemu,nemu-run,$(APP_HOME)/build/rv$(XLEN)/demos,$(DEMOS))

# ============================================================================
# Build all
# ============================================================================
all: tests-build demos-build coremark-build embench-build llm-bench-build ## Build everything

# ============================================================================
# Architecture / difftest variants
#
# For every base <stem>-npc / <stem>-nemu target below, the following sized
# variants are auto-generated via the _arch_variants template:
#   <stem>-npc32             rv32 NPC (ISA64=0)
#   <stem>-npc64             rv64 NPC (ISA64=1, VFLAGS=-DRAPT_RV64)
#   <stem>-npc32-difftest    rv32 NPC + NEMU rv32 reference (difftest)
#   <stem>-npc64-difftest    rv64 NPC + NEMU rv64 reference (difftest)
#   <stem>-nemu32            NEMU rv32 (auto config-nemu32)
#   <stem>-nemu64            NEMU rv64 (auto config-nemu64)
#
# Use these instead of the bare *-npc / *-nemu targets when you need an
# explicit XLEN selection or difftest verification. The bare *-npc / *-nemu
# targets still respect ISA64=0/1 if set on the command line.
#
# NOTE: auto-generated targets do not appear in `make help` (awk parses the
# Makefile source). Use this comment block as the catalog.
# ============================================================================

# --- Generated variants (kept as literal targets so shell tab-completion works) ---
coremark-npc32: ; @$(MAKE) $(Q) -C $(APP_HOME) coremark-npc ISA64=0
coremark-npc64: ; @$(MAKE) $(Q) -C $(APP_HOME) coremark-npc ISA64=1
coremark-npc32-difftest: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-npc32-difftest config-nemu32-ref && $(MAKE) $(Q) -C $(APP_HOME) coremark-npc ISA64=0
coremark-npc64-difftest: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-npc32-difftest config-nemu64-ref && $(MAKE) $(Q) -C $(APP_HOME) coremark-npc ISA64=1
coremark-nemu32: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-nemu32-difftest && $(MAKE) $(Q) -C $(APP_HOME) coremark-nemu ISA64=0
coremark-nemu64: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-nemu64-difftest && $(MAKE) $(Q) -C $(APP_HOME) coremark-nemu ISA64=1
embench-npc32: ; @$(MAKE) $(Q) -C $(APP_HOME) embench-npc ISA64=0
embench-npc64: ; @$(MAKE) $(Q) -C $(APP_HOME) embench-npc ISA64=1
embench-npc32-difftest: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-npc32-difftest config-nemu32-ref && $(MAKE) $(Q) -C $(APP_HOME) embench-npc ISA64=0
embench-npc64-difftest: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-npc32-difftest config-nemu64-ref && $(MAKE) $(Q) -C $(APP_HOME) embench-npc ISA64=1
embench-nemu32: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-nemu32-difftest && $(MAKE) $(Q) -C $(APP_HOME) embench-nemu ISA64=0
embench-nemu64: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-nemu64-difftest && $(MAKE) $(Q) -C $(APP_HOME) embench-nemu ISA64=1
llm-ops-npc32: ; @$(MAKE) $(Q) -C $(APP_HOME) llm-ops-npc ISA64=0
llm-ops-npc64: ; @$(MAKE) $(Q) -C $(APP_HOME) llm-ops-npc ISA64=1
llm-ops-npc32-difftest: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-npc32-difftest config-nemu32-ref && $(MAKE) $(Q) -C $(APP_HOME) llm-ops-npc ISA64=0
llm-ops-npc64-difftest: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-npc32-difftest config-nemu64-ref && $(MAKE) $(Q) -C $(APP_HOME) llm-ops-npc ISA64=1
llm-ops-nemu32: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-nemu32-difftest && $(MAKE) $(Q) -C $(APP_HOME) llm-ops-nemu ISA64=0
llm-ops-nemu64: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-nemu64-difftest && $(MAKE) $(Q) -C $(APP_HOME) llm-ops-nemu ISA64=1
llm-infer-npc32: ; @$(MAKE) $(Q) -C $(APP_HOME) llm-infer-npc ISA64=0
llm-infer-npc64: ; @$(MAKE) $(Q) -C $(APP_HOME) llm-infer-npc ISA64=1
llm-infer-npc32-difftest: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-npc32-difftest config-nemu32-ref && $(MAKE) $(Q) -C $(APP_HOME) llm-infer-npc ISA64=0
llm-infer-npc64-difftest: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-npc32-difftest config-nemu64-ref && $(MAKE) $(Q) -C $(APP_HOME) llm-infer-npc ISA64=1
llm-infer-nemu32: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-nemu32-difftest && $(MAKE) $(Q) -C $(APP_HOME) llm-infer-nemu ISA64=0
llm-infer-nemu64: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-nemu64-difftest && $(MAKE) $(Q) -C $(APP_HOME) llm-infer-nemu ISA64=1
llm-train-npc32: ; @$(MAKE) $(Q) -C $(APP_HOME) llm-train-npc ISA64=0
llm-train-npc64: ; @$(MAKE) $(Q) -C $(APP_HOME) llm-train-npc ISA64=1
llm-train-npc32-difftest: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-npc32-difftest config-nemu32-ref && $(MAKE) $(Q) -C $(APP_HOME) llm-train-npc ISA64=0
llm-train-npc64-difftest: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-npc32-difftest config-nemu64-ref && $(MAKE) $(Q) -C $(APP_HOME) llm-train-npc ISA64=1
llm-train-nemu32: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-nemu32-difftest && $(MAKE) $(Q) -C $(APP_HOME) llm-train-nemu ISA64=0
llm-train-nemu64: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-nemu64-difftest && $(MAKE) $(Q) -C $(APP_HOME) llm-train-nemu ISA64=1
llm-bench-run-npc32: ; @$(MAKE) $(Q) -C $(APP_HOME) llm-bench-run-npc ISA64=0
llm-bench-run-npc64: ; @$(MAKE) $(Q) -C $(APP_HOME) llm-bench-run-npc ISA64=1
llm-bench-run-npc32-difftest: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-npc32-difftest config-nemu32-ref && $(MAKE) $(Q) -C $(APP_HOME) llm-bench-run-npc ISA64=0
llm-bench-run-npc64-difftest: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-npc32-difftest config-nemu64-ref && $(MAKE) $(Q) -C $(APP_HOME) llm-bench-run-npc ISA64=1
llm-bench-run-nemu32: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-nemu32-difftest && $(MAKE) $(Q) -C $(APP_HOME) llm-bench-run-nemu ISA64=0
llm-bench-run-nemu64: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-nemu64-difftest && $(MAKE) $(Q) -C $(APP_HOME) llm-bench-run-nemu ISA64=1
llm-bench-report-npc32: ; @$(MAKE) $(Q) -C $(APP_HOME) llm-bench-report-npc ISA64=0
llm-bench-report-npc64: ; @$(MAKE) $(Q) -C $(APP_HOME) llm-bench-report-npc ISA64=1
llm-bench-report-npc32-difftest: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-npc32-difftest config-nemu32-ref && $(MAKE) $(Q) -C $(APP_HOME) llm-bench-report-npc ISA64=0
llm-bench-report-npc64-difftest: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-npc32-difftest config-nemu64-ref && $(MAKE) $(Q) -C $(APP_HOME) llm-bench-report-npc ISA64=1
llm-bench-report-nemu32: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-nemu32-difftest && $(MAKE) $(Q) -C $(APP_HOME) llm-bench-report-nemu ISA64=0
llm-bench-report-nemu64: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-nemu64-difftest && $(MAKE) $(Q) -C $(APP_HOME) llm-bench-report-nemu ISA64=1
agent-tools-npc32: ; @$(MAKE) $(Q) -C $(APP_HOME) agent-tools-npc ISA64=0
agent-tools-npc64: ; @$(MAKE) $(Q) -C $(APP_HOME) agent-tools-npc ISA64=1
agent-tools-npc32-difftest: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-npc32-difftest config-nemu32-ref && $(MAKE) $(Q) -C $(APP_HOME) agent-tools-npc ISA64=0
agent-tools-npc64-difftest: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-npc32-difftest config-nemu64-ref && $(MAKE) $(Q) -C $(APP_HOME) agent-tools-npc ISA64=1
agent-tools-nemu32: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-nemu32-difftest && $(MAKE) $(Q) -C $(APP_HOME) agent-tools-nemu ISA64=0
agent-tools-nemu64: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-nemu64-difftest && $(MAKE) $(Q) -C $(APP_HOME) agent-tools-nemu ISA64=1
agent-rag-npc32: ; @$(MAKE) $(Q) -C $(APP_HOME) agent-rag-npc ISA64=0
agent-rag-npc64: ; @$(MAKE) $(Q) -C $(APP_HOME) agent-rag-npc ISA64=1
agent-rag-npc32-difftest: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-npc32-difftest config-nemu32-ref && $(MAKE) $(Q) -C $(APP_HOME) agent-rag-npc ISA64=0
agent-rag-npc64-difftest: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-npc32-difftest config-nemu64-ref && $(MAKE) $(Q) -C $(APP_HOME) agent-rag-npc ISA64=1
agent-rag-nemu32: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-nemu32-difftest && $(MAKE) $(Q) -C $(APP_HOME) agent-rag-nemu ISA64=0
agent-rag-nemu64: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-nemu64-difftest && $(MAKE) $(Q) -C $(APP_HOME) agent-rag-nemu ISA64=1
agent-workflow-npc32: ; @$(MAKE) $(Q) -C $(APP_HOME) agent-workflow-npc ISA64=0
agent-workflow-npc64: ; @$(MAKE) $(Q) -C $(APP_HOME) agent-workflow-npc ISA64=1
agent-workflow-npc32-difftest: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-npc32-difftest config-nemu32-ref && $(MAKE) $(Q) -C $(APP_HOME) agent-workflow-npc ISA64=0
agent-workflow-npc64-difftest: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-npc32-difftest config-nemu64-ref && $(MAKE) $(Q) -C $(APP_HOME) agent-workflow-npc ISA64=1
agent-workflow-nemu32: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-nemu32-difftest && $(MAKE) $(Q) -C $(APP_HOME) agent-workflow-nemu ISA64=0
agent-workflow-nemu64: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-nemu64-difftest && $(MAKE) $(Q) -C $(APP_HOME) agent-workflow-nemu ISA64=1
agent-bench-run-npc32: ; @$(MAKE) $(Q) -C $(APP_HOME) agent-bench-run-npc ISA64=0
agent-bench-run-npc64: ; @$(MAKE) $(Q) -C $(APP_HOME) agent-bench-run-npc ISA64=1
agent-bench-run-npc32-difftest: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-npc32-difftest config-nemu32-ref && $(MAKE) $(Q) -C $(APP_HOME) agent-bench-run-npc ISA64=0
agent-bench-run-npc64-difftest: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-npc32-difftest config-nemu64-ref && $(MAKE) $(Q) -C $(APP_HOME) agent-bench-run-npc ISA64=1
agent-bench-run-nemu32: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-nemu32-difftest && $(MAKE) $(Q) -C $(APP_HOME) agent-bench-run-nemu ISA64=0
agent-bench-run-nemu64: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-nemu64-difftest && $(MAKE) $(Q) -C $(APP_HOME) agent-bench-run-nemu ISA64=1
agent-bench-report-npc32: ; @$(MAKE) $(Q) -C $(APP_HOME) agent-bench-report-npc ISA64=0
agent-bench-report-npc64: ; @$(MAKE) $(Q) -C $(APP_HOME) agent-bench-report-npc ISA64=1
agent-bench-report-npc32-difftest: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-npc32-difftest config-nemu32-ref && $(MAKE) $(Q) -C $(APP_HOME) agent-bench-report-npc ISA64=0
agent-bench-report-npc64-difftest: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-npc32-difftest config-nemu64-ref && $(MAKE) $(Q) -C $(APP_HOME) agent-bench-report-npc ISA64=1
agent-bench-report-nemu32: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-nemu32-difftest && $(MAKE) $(Q) -C $(APP_HOME) agent-bench-report-nemu ISA64=0
agent-bench-report-nemu64: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-nemu64-difftest && $(MAKE) $(Q) -C $(APP_HOME) agent-bench-report-nemu ISA64=1
hello-npc32: ; @$(MAKE) $(Q) -C $(APP_HOME) hello-npc ISA64=0
hello-npc64: ; @$(MAKE) $(Q) -C $(APP_HOME) hello-npc ISA64=1
hello-npc32-difftest: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-npc32-difftest config-nemu32-ref && $(MAKE) $(Q) -C $(APP_HOME) hello-npc ISA64=0
hello-npc64-difftest: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-npc32-difftest config-nemu64-ref && $(MAKE) $(Q) -C $(APP_HOME) hello-npc ISA64=1
hello-nemu32: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-nemu32-difftest && $(MAKE) $(Q) -C $(APP_HOME) hello-nemu ISA64=0
hello-nemu64: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-nemu64-difftest && $(MAKE) $(Q) -C $(APP_HOME) hello-nemu ISA64=1
isa-tests-npc32: ; @$(MAKE) $(Q) -C $(APP_HOME) isa-tests-npc ISA64=0
isa-tests-npc64: ; @$(MAKE) $(Q) -C $(APP_HOME) isa-tests-npc ISA64=1
isa-tests-npc32-difftest: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-npc32-difftest config-nemu32-ref && $(MAKE) $(Q) -C $(APP_HOME) isa-tests-npc ISA64=0
isa-tests-npc64-difftest: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-npc32-difftest config-nemu64-ref && $(MAKE) $(Q) -C $(APP_HOME) isa-tests-npc ISA64=1
isa-tests-nemu32: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-nemu32-difftest && $(MAKE) $(Q) -C $(APP_HOME) isa-tests-nemu ISA64=0
isa-tests-nemu64: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-nemu64-difftest && $(MAKE) $(Q) -C $(APP_HOME) isa-tests-nemu ISA64=1
memory-tests-npc32: ; @$(MAKE) $(Q) -C $(APP_HOME) memory-tests-npc ISA64=0
memory-tests-npc64: ; @$(MAKE) $(Q) -C $(APP_HOME) memory-tests-npc ISA64=1
memory-tests-npc32-difftest: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-npc32-difftest config-nemu32-ref && $(MAKE) $(Q) -C $(APP_HOME) memory-tests-npc ISA64=0
memory-tests-npc64-difftest: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-npc32-difftest config-nemu64-ref && $(MAKE) $(Q) -C $(APP_HOME) memory-tests-npc ISA64=1
memory-tests-nemu32: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-nemu32-difftest && $(MAKE) $(Q) -C $(APP_HOME) memory-tests-nemu ISA64=0
memory-tests-nemu64: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-nemu64-difftest && $(MAKE) $(Q) -C $(APP_HOME) memory-tests-nemu ISA64=1
algo-tests-npc32: ; @$(MAKE) $(Q) -C $(APP_HOME) algo-tests-npc ISA64=0
algo-tests-npc64: ; @$(MAKE) $(Q) -C $(APP_HOME) algo-tests-npc ISA64=1
algo-tests-npc32-difftest: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-npc32-difftest config-nemu32-ref && $(MAKE) $(Q) -C $(APP_HOME) algo-tests-npc ISA64=0
algo-tests-npc64-difftest: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-npc32-difftest config-nemu64-ref && $(MAKE) $(Q) -C $(APP_HOME) algo-tests-npc ISA64=1
algo-tests-nemu32: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-nemu32-difftest && $(MAKE) $(Q) -C $(APP_HOME) algo-tests-nemu ISA64=0
algo-tests-nemu64: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-nemu64-difftest && $(MAKE) $(Q) -C $(APP_HOME) algo-tests-nemu ISA64=1
security-tests-npc32: ; @$(MAKE) $(Q) -C $(APP_HOME) security-tests-npc ISA64=0
security-tests-npc64: ; @$(MAKE) $(Q) -C $(APP_HOME) security-tests-npc ISA64=1
security-tests-npc32-difftest: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-npc32-difftest config-nemu32-ref && $(MAKE) $(Q) -C $(APP_HOME) security-tests-npc ISA64=0
security-tests-npc64-difftest: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-npc32-difftest config-nemu64-ref && $(MAKE) $(Q) -C $(APP_HOME) security-tests-npc ISA64=1
security-tests-nemu32: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-nemu32-difftest && $(MAKE) $(Q) -C $(APP_HOME) security-tests-nemu ISA64=0
security-tests-nemu64: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-nemu64-difftest && $(MAKE) $(Q) -C $(APP_HOME) security-tests-nemu ISA64=1
tests-npc32: ; @$(MAKE) $(Q) -C $(APP_HOME) tests-npc ISA64=0
tests-npc64: ; @$(MAKE) $(Q) -C $(APP_HOME) tests-npc ISA64=1
tests-npc32-difftest: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-npc32-difftest config-nemu32-ref && $(MAKE) $(Q) -C $(APP_HOME) tests-npc ISA64=0
tests-npc64-difftest: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-npc32-difftest config-nemu64-ref && $(MAKE) $(Q) -C $(APP_HOME) tests-npc ISA64=1
tests-nemu32: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-nemu32-difftest && $(MAKE) $(Q) -C $(APP_HOME) tests-nemu ISA64=0
tests-nemu64: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-nemu64-difftest && $(MAKE) $(Q) -C $(APP_HOME) tests-nemu ISA64=1
demos-npc32: ; @$(MAKE) $(Q) -C $(APP_HOME) demos-npc ISA64=0
demos-npc64: ; @$(MAKE) $(Q) -C $(APP_HOME) demos-npc ISA64=1
demos-npc32-difftest: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-npc32-difftest config-nemu32-ref && $(MAKE) $(Q) -C $(APP_HOME) demos-npc ISA64=0
demos-npc64-difftest: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-npc32-difftest config-nemu64-ref && $(MAKE) $(Q) -C $(APP_HOME) demos-npc ISA64=1
demos-nemu32: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-nemu32-difftest && $(MAKE) $(Q) -C $(APP_HOME) demos-nemu ISA64=0
demos-nemu64: ; @$(MAKE) $(Q) -C $(APP_HOME)/.. config-nemu64-difftest && $(MAKE) $(Q) -C $(APP_HOME) demos-nemu ISA64=1

.PHONY: \
	coremark-npc32 coremark-npc64 coremark-npc32-difftest coremark-npc64-difftest coremark-nemu32 coremark-nemu64 \
	embench-npc32 embench-npc64 embench-npc32-difftest embench-npc64-difftest embench-nemu32 embench-nemu64 \
	llm-ops-npc32 llm-ops-npc64 llm-ops-npc32-difftest llm-ops-npc64-difftest llm-ops-nemu32 llm-ops-nemu64 \
	llm-infer-npc32 llm-infer-npc64 llm-infer-npc32-difftest llm-infer-npc64-difftest llm-infer-nemu32 llm-infer-nemu64 \
	llm-train-npc32 llm-train-npc64 llm-train-npc32-difftest llm-train-npc64-difftest llm-train-nemu32 llm-train-nemu64 \
	llm-bench-run-npc32 llm-bench-run-npc64 llm-bench-run-npc32-difftest llm-bench-run-npc64-difftest llm-bench-run-nemu32 llm-bench-run-nemu64 \
	llm-bench-report-npc32 llm-bench-report-npc64 llm-bench-report-npc32-difftest llm-bench-report-npc64-difftest llm-bench-report-nemu32 llm-bench-report-nemu64 \
	agent-tools-npc32 agent-tools-npc64 agent-tools-npc32-difftest agent-tools-npc64-difftest agent-tools-nemu32 agent-tools-nemu64 \
	agent-rag-npc32 agent-rag-npc64 agent-rag-npc32-difftest agent-rag-npc64-difftest agent-rag-nemu32 agent-rag-nemu64 \
	agent-workflow-npc32 agent-workflow-npc64 agent-workflow-npc32-difftest agent-workflow-npc64-difftest agent-workflow-nemu32 agent-workflow-nemu64 \
	agent-bench-run-npc32 agent-bench-run-npc64 agent-bench-run-npc32-difftest agent-bench-run-npc64-difftest agent-bench-run-nemu32 agent-bench-run-nemu64 \
	agent-bench-report-npc32 agent-bench-report-npc64 agent-bench-report-npc32-difftest agent-bench-report-npc64-difftest agent-bench-report-nemu32 agent-bench-report-nemu64 \
	hello-npc32 hello-npc64 hello-npc32-difftest hello-npc64-difftest hello-nemu32 hello-nemu64 \
	isa-tests-npc32 isa-tests-npc64 isa-tests-npc32-difftest isa-tests-npc64-difftest isa-tests-nemu32 isa-tests-nemu64 \
	memory-tests-npc32 memory-tests-npc64 memory-tests-npc32-difftest memory-tests-npc64-difftest memory-tests-nemu32 memory-tests-nemu64 \
	algo-tests-npc32 algo-tests-npc64 algo-tests-npc32-difftest algo-tests-npc64-difftest algo-tests-nemu32 algo-tests-nemu64 \
	security-tests-npc32 security-tests-npc64 security-tests-npc32-difftest security-tests-npc64-difftest security-tests-nemu32 security-tests-nemu64 \
	tests-npc32 tests-npc64 tests-npc32-difftest tests-npc64-difftest tests-nemu32 tests-nemu64 \
	demos-npc32 demos-npc64 demos-npc32-difftest demos-npc64-difftest demos-nemu32 demos-nemu64

# ============================================================================
# Clean
# ============================================================================
clean: ## Clean all build artifacts
	rm -rf $(APP_HOME)/build

.PHONY: help env-check setup pk-build pk-run nemu-run bbl-linux log \
		coremark-build coremark-npc coremark-nemu embench-build embench-pk-bins embench-npc embench-nemu \
		llm-bench-build llm-litex-build llm-native-build llm-native-test \
		llm-ops-npc llm-ops-nemu llm-infer-npc llm-infer-nemu llm-train-npc llm-train-nemu \
		llm-bench-run-npc llm-bench-run-nemu llm-bench-report-npc llm-bench-report-nemu \
		agent-bench-build agent-litex-build agent-native-build agent-native-test \
		agent-tools-npc agent-tools-nemu agent-rag-npc agent-rag-nemu agent-workflow-npc agent-workflow-nemu \
		agent-bench-run-npc agent-bench-run-nemu agent-bench-report-npc agent-bench-report-nemu \
		tinyos-sync \
		os-cli-qemu egos-cli-qemu xv6-cli-qemu \
		os-cli-nsim os-cli-nemu egos-cli-nsim egos-cli-nsim-difftest egos-cli-nemu xv6-cli-nsim xv6-cli-nsim-difftest xv6-cli-nemu \
		hello-build hello-npc hello-nemu \
		isa-tests-build isa-tests-npc isa-tests-nemu \
		memory-tests-build memory-tests-npc memory-tests-nemu \
		algo-tests-build algo-tests-npc algo-tests-nemu \
		security-tests-build security-tests-npc security-tests-nemu \
		tests-build tests-npc tests-nemu \
		demos-build demos-npc demos-nemu \
        all clean
