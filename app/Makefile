# ============================================================================
# app/Makefile: Standard RISC-V ELF build system (pk)
#
# Builds standard ELFs with riscv64-unknown-elf-gcc (newlib), runs them on
# NPC via riscv-pk (proxy kernel).
# ============================================================================

APP_HOME := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
include $(APP_HOME)/common.mk

ARGS ?= -b ## NPC simulator args (-b: batch, -n: no wave)
USER_ELF ?= ## ELF binary for pk-run

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
# Runner helpers: _PK_RUN_CMD / _PK_RUN_CMD_SUITE
#   RUN_ON = npc (default) | nemu
#   These are internal macros used by all run targets below.
# ============================================================================
RUN_ON ?= npc ## Runtime: npc or nemu

ifeq ($(RUN_ON),nemu)
  _PK_RUN_TARGET := nemu-run
else
  _PK_RUN_TARGET := pk-run
endif

# Run a single ELF: $(call _pk_run,<elf-path>)
define _pk_run
	$(MAKE) $(Q) -C $(APP_HOME)/pk $(_PK_RUN_TARGET) USER_ELF=$(1)
endef

# Run a list of ELFs: $(call _pk_run_suite,<suite-name>,<elf-dir>,<test-list>)
define _pk_run_suite
	@echo "=== Running $(1) ($(RUN_ON)) ==="
	@for t in $(3); do \
		echo "--- $$t ---"; \
		$(MAKE) $(Q) -C $(APP_HOME)/pk $(_PK_RUN_TARGET) \
			USER_ELF=$(2)/$$t.elf \
			|| true; \
	done
	@echo "=== $(1) complete ==="
endef

# ============================================================================
# CoreMark
# ============================================================================
coremark-build: ## Build CoreMark ELF
	@$(MAKE) $(Q) -C $(APP_HOME)/benchmarks/coremark build

coremark: coremark-build ## Build and run CoreMark via pk
	@$(call _pk_run,$(APP_HOME)/build/rv$(XLEN)/coremark/coremark.elf)

# ============================================================================
# Embench-IoT
# ============================================================================
EMBENCH_BENCHMARKS := aha-mont64 crc32 edn matmult-int \
                      md5sum nettle-aes nettle-sha256 \
                      nsichneu picojpeg qrduino \
                      sglib-combined slre statemate tarfind

embench-build: ## Build all Embench ELFs
	@$(MAKE) $(Q) -C $(APP_HOME)/benchmarks/embench build

embench: embench-build ## Build and run all Embench benchmarks via pk
	@echo "=== Running Embench-IoT benchmarks ($(RUN_ON)) ==="
	@for bench in $(EMBENCH_BENCHMARKS); do \
		echo "--- $$bench ---"; \
		$(MAKE) $(Q) -C $(APP_HOME)/pk $(_PK_RUN_TARGET) \
			USER_ELF=$(APP_HOME)/build/rv$(XLEN)/embench/$$bench/$$bench.elf \
			|| true; \
	done
	@echo "=== Embench-IoT complete ==="

# ============================================================================
# Hello world test
# ============================================================================
hello-build: ## Build hello ELF
	@$(MAKE) $(Q) -C $(APP_HOME)/tests/hello build

hello: hello-build ## Build and run hello via pk
	@$(call _pk_run,$(APP_HOME)/build/rv$(XLEN)/tests/hello/hello.elf)

# ============================================================================
# ISA correctness tests
# ============================================================================
isa-tests-build: ## Build ISA verification tests
	@$(MAKE) $(Q) -C $(APP_HOME)/tests/isa build

ISA_TESTS := rv_add rv_shift rv_logic rv_mul_div rv_branch rv_slt rv_bitmanip rv_compressed \
             rv_zicond rv_zicsr rv_zifencei rv_zcb rv_zimop

isa-tests: isa-tests-build ## Build and run all ISA tests via pk
	$(call _pk_run_suite,ISA tests,$(APP_HOME)/build/rv$(XLEN)/tests/isa,$(ISA_TESTS))

# ============================================================================
# Memory subsystem tests
# ============================================================================
memory-tests-build: ## Build memory tests
	@$(MAKE) $(Q) -C $(APP_HOME)/tests/memory build

MEMORY_TESTS := load_store memory_pattern stack_test

memory-tests: memory-tests-build ## Build and run all memory tests via pk
	$(call _pk_run_suite,Memory tests,$(APP_HOME)/build/rv$(XLEN)/tests/memory,$(MEMORY_TESTS))

# ============================================================================
# Algorithm tests
# ============================================================================
algo-tests-build: ## Build algorithm tests
	@$(MAKE) $(Q) -C $(APP_HOME)/tests/algo build

ALGO_TESTS := sorting crc32 math_test string_ops

algo-tests: algo-tests-build ## Build and run all algorithm tests via pk
	$(call _pk_run_suite,Algorithm tests,$(APP_HOME)/build/rv$(XLEN)/tests/algo,$(ALGO_TESTS))

# ============================================================================
# Security / side-channel tests
# ============================================================================
security-tests-build: ## Build security / side-channel tests
	@$(MAKE) $(Q) -C $(APP_HOME)/tests/security build

SECURITY_TESTS := cache-timing fence-timing bpu-collision \
                  spectre-v1 spectre-v2 spec-store-bypass

security-tests: security-tests-build ## Build and run all security tests via pk
	$(call _pk_run_suite,Security tests,$(APP_HOME)/build/rv$(XLEN)/tests/security,$(SECURITY_TESTS))

# ============================================================================
# All tests
# ============================================================================
tests-build: hello-build isa-tests-build memory-tests-build algo-tests-build security-tests-build ## Build all tests

tests: hello isa-tests memory-tests algo-tests security-tests ## Run all tests via pk

# ============================================================================
# Demo programs
# ============================================================================
demos-build: ## Build demo programs
	@$(MAKE) $(Q) -C $(APP_HOME)/demos build

DEMOS := donut cmatrix langton life hanoi mandelbrot sysinfo

demos: demos-build ## Build and run all demos via pk
	$(call _pk_run_suite,Demo programs,$(APP_HOME)/build/rv$(XLEN)/demos,$(DEMOS))

# ============================================================================
# Build all
# ============================================================================
all: tests-build demos-build coremark-build embench-build ## Build everything

# ============================================================================
# Clean
# ============================================================================
clean: ## Clean all build artifacts
	rm -rf $(APP_HOME)/build

.PHONY: help env-check setup pk-build pk-run nemu-run bbl-linux \
        coremark-build coremark embench-build embench \
        hello-build hello \
        isa-tests-build isa-tests \
        memory-tests-build memory-tests \
        algo-tests-build algo-tests \
        security-tests-build security-tests \
        tests-build tests \
        demos-build demos \
        all clean
