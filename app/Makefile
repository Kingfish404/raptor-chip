# ============================================================================
# app/Makefile: Standard RISC-V ELF build system (pk)
#
# Builds standard ELFs with riscv64-unknown-elf-gcc (newlib), runs them on
# NPC via riscv-pk (proxy kernel).
# ============================================================================

APP_HOME := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
include $(APP_HOME)/common.mk

ARGS ?= -b -n## Simulator args for nsim/NEMU run targets (-b: batch, -n: no wave)
MAX_INST ?=## Optional maximum instruction limit for tinyos cli-nsim/cli-nemu
TIMEOUT ?=## Optional wall-clock timeout in seconds for tinyos cli-nsim
USER_ELF ?=## ELF binary for pk-run
LLM_OP_ITERS ?= 8## LLM operator benchmark repeat count
LLM_GEN_TOKENS ?= 12## LLM inference generated token count
LLM_TRAIN_STEPS ?= 4## LLM training benchmark steps
RLLMBENCH_NPC_TIMEBASE_HZ ?= 10000000## NPC RISC-V time CSR frequency in Hz
RLLMBENCH_TIMEBASE_HZ ?= 1000000## RISC-V time CSR frequency in Hz
RLLMBENCH_NPC_CORE_CLOCK_MHZ ?= 1000## NPC core clock model in MHz for RLLMBench score/MHz
RLLMBENCH_CORE_CLOCK_MHZ ?= 0## Core clock in MHz for RLLMBench score/MHz (0=omit)
RLLMBENCH_NATIVE_CORE_CLOCK_MHZ ?= 0## Native host core clock in MHz for RLLMBench score/MHz (0=omit)
PYTHON ?= python3## Python interpreter for benchmark report generation

ifneq ($(origin RUN_ON), undefined)
$(error RUN_ON is no longer supported; use explicit -npc/-nemu targets)
endif

RLLMBENCH_BACKEND := npc

export ISA64 ARGS CROSS_COMPILE

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
# ============================================================================
# Run a single ELF: $(call _pk_run_with,<pk-target>,<elf-path>)
define _pk_run_with
	$(MAKE) $(Q) -C $(APP_HOME)/pk $(1) USER_ELF=$(2)
endef

# Run a list of ELFs: $(call _pk_run_suite_with,<suite-name>,<backend>,<pk-target>,<elf-dir>,<test-list>)
define _pk_run_suite_with
	@echo "=== Running $(1) ($(2)) ==="
	@for t in $(5); do \
		echo "--- $$t ---"; \
		$(MAKE) $(Q) -C $(APP_HOME)/pk $(3) \
			USER_ELF=$(4)/$$t.elf \
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
LLM_VARS := LLM_OP_ITERS=$(LLM_OP_ITERS) \
            LLM_GEN_TOKENS=$(LLM_GEN_TOKENS) \
			LLM_TRAIN_STEPS=$(LLM_TRAIN_STEPS) \
			RLLMBENCH_TIMEBASE_HZ=$(RLLMBENCH_TIMEBASE_HZ)
LLM_BUILD_DIR := $(APP_HOME)/build/rv$(XLEN)/benchmarks/llm
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
$(LLM_NEMU_TARGETS): RLLMBENCH_BACKEND := nemu
$(LLM_NEMU_TARGETS): RLLMBENCH_TIMEBASE_HZ := 1000000
$(LLM_NEMU_TARGETS): RLLMBENCH_CORE_CLOCK_MHZ := 0

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
	@echo "=== Running RLLMBench ($(RLLMBENCH_BACKEND), profile=ops$(LLM_OP_ITERS)-gen$(LLM_GEN_TOKENS)-train$(LLM_TRAIN_STEPS)) ==="
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

egos-cli-nemu: ## Boot upstream egos image on NEMU
	@$(MAKE) $(Q) -C $(APP_HOME)/tinyos egos-cli-nemu ARGS="$(ARGS)" MAX_INST="$(MAX_INST)"

xv6-cli-nsim: ## Boot upstream xv6-riscv on NPC/nsim
	@$(MAKE) $(Q) -C $(APP_HOME)/tinyos xv6-cli-nsim ARGS="$(ARGS)" MAX_INST="$(MAX_INST)" TIMEOUT="$(TIMEOUT)"

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

MEMORY_TESTS := load_store memory_pattern stack_test

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
# Clean
# ============================================================================
clean: ## Clean all build artifacts
	rm -rf $(APP_HOME)/build

.PHONY: help env-check setup pk-build pk-run nemu-run bbl-linux \
		coremark-build coremark-npc coremark-nemu embench-build embench-pk-bins embench-npc embench-nemu \
		llm-bench-build llm-litex-build llm-native-build llm-native-test \
		llm-ops-npc llm-ops-nemu llm-infer-npc llm-infer-nemu llm-train-npc llm-train-nemu \
		llm-bench-run-npc llm-bench-run-nemu llm-bench-report-npc llm-bench-report-nemu \
		tinyos-sync \
		os-cli-qemu egos-cli-qemu xv6-cli-qemu \
		os-cli-nsim os-cli-nemu egos-cli-nsim egos-cli-nemu xv6-cli-nsim xv6-cli-nemu \
		hello-build hello-npc hello-nemu \
		isa-tests-build isa-tests-npc isa-tests-nemu \
		memory-tests-build memory-tests-npc memory-tests-nemu \
		algo-tests-build algo-tests-npc algo-tests-nemu \
		security-tests-build security-tests-npc security-tests-nemu \
		tests-build tests-npc tests-nemu \
		demos-build demos-npc demos-nemu \
        all clean
