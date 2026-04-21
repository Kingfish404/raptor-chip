# ============================================================================
# Unified Verification Makefile
# ============================================================================
# Orchestrates: random fuzz, ACT4 compliance, coverage, assertion checks.
# Reuses the existing nsim Verilator simulator and NEMU difftest reference.
#
# Usage:
#   make help                        Show all targets
# ============================================================================

SHELL := /bin/bash
.DEFAULT_GOAL := help

# --- Environment (inherited from root Makefile or set manually) ---
RAPTOR_HOME   ?= $(abspath ..)
NSIM_HOME   := $(RAPTOR_HOME)/nsim
NEMU_HOME   := $(RAPTOR_HOME)/nemu
AM_HOME     := $(RAPTOR_HOME)/abstract-machine
VERIFY_HOME := $(abspath .)

# Export vars that sub-Makefiles (nsim/, nemu/) expect. YSYX_HOME is a
# back-compat alias of RAPTOR_HOME required by nsim/Makefile's repo guard.
export RAPTOR_HOME
export YSYX_HOME := $(RAPTOR_HOME)
export NSIM_HOME
export NEMU_HOME
export AM_HOME

CROSS_COMPILE ?= riscv64-elf-
CC  := $(CROSS_COMPILE)gcc
AS  := $(CROSS_COMPILE)as
LD  := $(CROSS_COMPILE)ld
OBJCOPY := $(CROSS_COMPILE)objcopy
OBJDUMP := $(CROSS_COMPILE)objdump

NPROC := $(shell nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
TIMEOUT_BIN := $(shell command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null)
PYTHON := $(shell command -v python3 2>/dev/null || command -v python 2>/dev/null)

ifeq ($(strip $(TIMEOUT_BIN)),)
	ifeq ($(strip $(PYTHON)),)
		$(error Neither timeout/gtimeout nor python3/python is available)
	endif
	TIMEOUT_RUN := $(PYTHON) $(VERIFY_HOME)/scripts/run_with_timeout.py
else
	TIMEOUT_RUN := $(TIMEOUT_BIN)
endif

# --- Paths to existing build artifacts ---
NPC_BIN_32  := $(NSIM_HOME)/build/riscv32-npc-sim
NPC_BIN_64  := $(NSIM_HOME)/build/riscv64-npc-sim
NEMU_SO_32  := $(NEMU_HOME)/build/riscv32-nemu-interpreter-so
NEMU_SO_64  := $(NEMU_HOME)/build/riscv64-nemu-interpreter-so
MROM_IMG    := $(NSIM_HOME)/csrc/mem/mrom-data/build/mrom-data.bin

# --- Configuration ---
SEED     ?= $(shell date +%s)	## Random seed for fuzz
FUZZ_NUM ?= 20	## Number of fuzz test programs to generate
FUZZ_LEN ?= 200	## Instructions per fuzz program
TIMEOUT  ?= 3	## Per-test timeout in seconds
ISA      ?= rv32## rv32 or rv64

BUILD_DIR := $(VERIFY_HOME)/build
FUZZ_DIR  := $(BUILD_DIR)/fuzz
COV_DIR   := $(BUILD_DIR)/coverage
AM_KERNELS := $(RAPTOR_HOME)/abstract-machine/app/am-kernels

ifeq ($(ISA),rv64)
  NPC_BIN  := $(NPC_BIN_64)
  NEMU_SO  := $(NEMU_SO_64)
  MARCH    := rv64imac_zicntr_zicond_zicsr_zifencei_zcb_zba_zbb_zbc_zbs
  MABI     := lp64
  VFLAGS   := -DRAPT_RV64
  ISA_XLEN := 64
else
  NPC_BIN  := $(NPC_BIN_32)
  NEMU_SO  := $(NEMU_SO_32)
  MARCH    := rv32imac_zicntr_zicond_zicsr_zifencei_zcb_zba_zbb_zbc_zbs
  MABI     := ilp32
  VFLAGS   :=
  ISA_XLEN := 32
endif

# ============================================================================
# Default / Help
# ============================================================================
help: ## Show this help message
	@echo "Raptor Chip Verification Suite"
	@echo "=============================="
	@echo ""
	@echo "Targets:"
	@grep -E '^[a-zA-Z0-9_-]+:.*## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS=":.*## "}; {printf "  %-24s %s\n", $$1, $$2}'
	@echo ""
	@echo "Variables:"
	@echo "  ISA=rv32|rv64           Target ISA (default: rv32)"
	@echo "  SEED=<int>              Random seed for fuzz (default: timestamp)"
	@echo "  FUZZ_NUM=<int>          Number of fuzz programs (default: 20)"
	@echo "  FUZZ_LEN=<int>          Instructions per program (default: 200)"
	@echo "  TIMEOUT=<int>           Per-test timeout in seconds (default: 30)"
	@echo "  FUZZ_INF_BATCH=<int>    Programs per batch in fuzz-inf (default: 20)"
	@echo "  FUZZ_STALE_LIMIT=<int>  Stop fuzz-inf after N stale batches (default: 10, 0=off)"
	@echo "  FUZZ_SRC_DIR=<dir>      Directory for fuzz-run (default: build/fuzz/)"
	@echo "  SRC=<file>              Single .S file for fuzz-run-one"
	@echo "  COV_FUZZ_NUM=<int>      Fuzz test count in coverage-run (default: 40)"
	@echo "  COV_FUZZ_LEN=<int>      Fuzz length in coverage-run (default: 200)"
	@echo "  COV_MICROBENCH_ARGS=<s> Microbench mainargs in coverage-run (default: test)"

# ============================================================================
# Prerequisites: ensure simulator and NEMU are built
# ============================================================================
$(NPC_BIN):
	@echo "[verify] Building NPC simulator (difftest enabled)..."
	$(MAKE) -C $(RAPTOR_HOME) config-npc32-difftest
	$(MAKE) -C $(NSIM_HOME) -j$(NPROC) VFLAGS="$(VFLAGS)"

$(NEMU_SO):
	@echo "[verify] Building NEMU reference SO..."
ifeq ($(ISA),rv64)
	$(MAKE) -C $(RAPTOR_HOME) config-nemu64-ref
else
	$(MAKE) -C $(RAPTOR_HOME) config-nemu32-ref
endif

$(MROM_IMG):
	$(MAKE) -C $(NSIM_HOME)/csrc/mem/mrom-data

.PHONY: check-prereqs
check-prereqs: $(MROM_IMG) ## Verify all prerequisites are built
	@echo "[verify] Checking prerequisites..."
	@test -f $(NPC_BIN)  || (echo "ERROR: NPC binary not found: $(NPC_BIN)"  && echo "  Run: make -C $(RAPTOR_HOME) build-npc32" && exit 1)
	@test -f $(NEMU_SO)  || (echo "ERROR: NEMU SO not found: $(NEMU_SO)"    && echo "  Run: make -C $(RAPTOR_HOME) config-nemu32-ref" && exit 1)
	@echo "[verify] All prerequisites OK."

# ============================================================================
# Random Instruction Fuzz
# ============================================================================
FUZZ_INF_BATCH    ?= 20## Programs per batch in fuzz-inf mode
FUZZ_STALE_LIMIT  ?= 10## Stop after N batches with no new coverage (0=disable)
FUZZ_SRC_DIR   ?= $(FUZZ_DIR)## Directory containing .S + manifest.txt to run
FUZZ_LINKER    := $(VERIFY_HOME)/scripts/fuzz_link.ld
FUZZ_LAST_FAIL := $(FUZZ_DIR)/last_fail

.PHONY: fuzz fuzz-gen fuzz-run fuzz-replay fuzz-run-one fuzz-inf fuzz-clean

fuzz: fuzz-gen fuzz-run ## Generate and run random instruction fuzz tests

fuzz-gen: ## Generate random instruction test programs
	@mkdir -p $(FUZZ_DIR)
	python3 $(VERIFY_HOME)/scripts/riscv_fuzz_gen.py \
		--seed $(SEED) \
		--num $(FUZZ_NUM) \
		--length $(FUZZ_LEN) \
		--xlen $(ISA_XLEN) \
		--outdir $(FUZZ_DIR)
	@echo "[fuzz] Generated $(FUZZ_NUM) programs (seed=$(SEED)) in $(FUZZ_DIR)/"

# ---------------------------------------------------------------------------
# fuzz-run: run all .S tests in FUZZ_SRC_DIR (default: build/fuzz/)
#   Override FUZZ_SRC_DIR to replay a specific batch:
#     make fuzz-run FUZZ_SRC_DIR=build/fuzz/batch_42
# ---------------------------------------------------------------------------
fuzz-run: check-prereqs ## Run fuzz tests in FUZZ_SRC_DIR with difftest
	@test -f "$(FUZZ_SRC_DIR)/manifest.txt" || \
		{ echo "[fuzz-run] ERROR: $(FUZZ_SRC_DIR)/manifest.txt not found."; \
		  echo "  Generate tests first:  make fuzz-gen"; \
		  echo "  Or specify directory:  make fuzz-run FUZZ_SRC_DIR=build/fuzz/batch_N"; exit 1; }
	@echo "================================================================"
	@echo "[fuzz-run] Running tests from $(FUZZ_SRC_DIR)"
	@echo "  NPC:     $(NPC_BIN)"
	@echo "  NEMU:    $(NEMU_SO)"
	@echo "  Timeout: $(TIMEOUT)s per test"
	@echo "================================================================"
	@PASS=0; FAIL=0; ERR=0; TOTAL=0; FAIL_LIST=""; \
	while IFS= read -r name; do \
		TOTAL=$$((TOTAL + 1)); \
		src="$(FUZZ_SRC_DIR)/$${name}.S"; \
		elf="$(FUZZ_SRC_DIR)/$${name}.elf"; \
		bin="$(FUZZ_SRC_DIR)/$${name}.bin"; \
		log="$(FUZZ_SRC_DIR)/$${name}.run.log"; \
		if [ ! -f "$$src" ]; then echo "  [SKIP] $$name"; ERR=$$((ERR+1)); continue; fi; \
		if ! $(CC) -march=$(MARCH) -mabi=$(MABI) -nostdlib -nostartfiles \
			-T $(FUZZ_LINKER) -o "$$elf" "$$src" 2>"$(FUZZ_SRC_DIR)/$${name}.compile.log"; then \
			echo "  [CERR] $$name"; ERR=$$((ERR+1)); continue; fi; \
		$(OBJCOPY) -O binary "$$elf" "$$bin"; \
		set +e; $(TIMEOUT_RUN) $(TIMEOUT) $(NPC_BIN) -b -n -d $(NEMU_SO) -r $(MROM_IMG) "$$bin" >"$$log" 2>&1; \
		rc=$$?; set -e; \
		if [ $$rc -eq 0 ]; then \
			if grep -qiE "BAD TRAP|ABORT" "$$log"; then \
				echo "  [FAIL] $$name: BAD TRAP"; FAIL=$$((FAIL+1)); FAIL_LIST="$$FAIL_LIST $$name"; \
				tail -3 "$$log" | sed 's/^/         /'; \
			else echo "  [PASS] $$name"; PASS=$$((PASS+1)); fi; \
		elif [ $$rc -eq 124 ]; then \
			echo "  [TIME] $$name"; FAIL=$$((FAIL+1)); FAIL_LIST="$$FAIL_LIST $$name(timeout)"; \
		else \
			echo "  [FAIL] $$name: exit $$rc"; FAIL=$$((FAIL+1)); FAIL_LIST="$$FAIL_LIST $$name"; \
			tail -5 "$$log" | sed 's/^/         /'; \
		fi; \
	done < "$(FUZZ_SRC_DIR)/manifest.txt"; \
	echo ""; \
	echo "================================================================"; \
	echo "[fuzz-run] Results: $$PASS passed, $$FAIL failed, $$ERR errors (total $$TOTAL)"; \
	if [ -n "$$FAIL_LIST" ]; then echo "[fuzz-run] Failed:$$FAIL_LIST"; fi; \
	echo "================================================================"; \
	[ $$FAIL -eq 0 ] && [ $$ERR -eq 0 ]

# ---------------------------------------------------------------------------
# fuzz-replay: re-run the last failing batch from fuzz-inf
# ---------------------------------------------------------------------------
fuzz-replay: ## Replay the last failing fuzz-inf batch
	@if [ -L "$(FUZZ_LAST_FAIL)" ] && [ -d "$(FUZZ_LAST_FAIL)" ]; then \
		echo "[fuzz-replay] Replaying: $$(readlink $(FUZZ_LAST_FAIL))"; \
		$(MAKE) --no-print-directory fuzz-run FUZZ_SRC_DIR="$(FUZZ_LAST_FAIL)"; \
	elif ls -d $(FUZZ_DIR)/batch_* 1>/dev/null 2>&1; then \
		LAST=$$(ls -dt $(FUZZ_DIR)/batch_* | head -1); \
		echo "[fuzz-replay] No last_fail link; using most recent batch: $$LAST"; \
		$(MAKE) --no-print-directory fuzz-run FUZZ_SRC_DIR="$$LAST"; \
	else \
		echo "[fuzz-replay] No batch directories found in $(FUZZ_DIR)/"; \
		echo "  Run 'make fuzz-inf' first."; exit 1; \
	fi

# ---------------------------------------------------------------------------
# fuzz-run-one: compile & run a single .S file (for debugging a specific case)
#   make fuzz-run-one SRC=build/fuzz/batch_42/fuzz_0003.S
# ---------------------------------------------------------------------------
SRC ?=## Single .S file to run
fuzz-run-one: check-prereqs ## Run a single .S test file (SRC=path/to/test.S)
	@test -n "$(SRC)" || { echo "[fuzz-run-one] ERROR: specify SRC=path/to/test.S"; exit 1; }
	@test -f "$(SRC)" || { echo "[fuzz-run-one] ERROR: $(SRC) not found"; exit 1; }
	@elf="$${SRC%.S}.elf"; bin="$${SRC%.S}.bin"; log="$${SRC%.S}.run.log"; \
	echo "[fuzz-run-one] $(SRC)"; \
	$(CC) -march=$(MARCH) -mabi=$(MABI) -nostdlib -nostartfiles \
		-T $(FUZZ_LINKER) -o "$$elf" "$(SRC)"; \
	$(OBJCOPY) -O binary "$$elf" "$$bin"; \
	$(NPC_BIN) -b -n -d $(NEMU_SO) -r $(MROM_IMG) "$$bin" 2>&1 | tee "$$log"; \
	echo "[fuzz-run-one] Log: $$log"

fuzz-inf: check-prereqs ## Continuous fuzz until Ctrl-C or saturation
	@python3 $(VERIFY_HOME)/scripts/run_fuzz_inf.py \
		--npc-bin "$(NPC_BIN)" --nemu-so "$(NEMU_SO)" --mrom-img "$(MROM_IMG)" \
		--fuzz-dir "$(FUZZ_DIR)" --timeout $(TIMEOUT) --cc "$(CC)" \
		--objcopy "$(OBJCOPY)" --march "$(MARCH)" --mabi "$(MABI)" \
		--xlen $(ISA_XLEN) --fuzz-gen "$(VERIFY_HOME)/scripts/riscv_fuzz_gen.py" \
		--batch-size $(FUZZ_INF_BATCH) --fuzz-len $(FUZZ_LEN) \
		--linker "$(FUZZ_LINKER)" --stale-limit $(FUZZ_STALE_LIMIT)

fuzz-clean: ## Clean fuzz artifacts
	rm -rf $(FUZZ_DIR)

# ============================================================================
# ACT4 Architectural Certification Testing (replaces deprecated RISCOF)
# ============================================================================
# Uses riscv-arch-test ACT4 framework: Makefile + Python based flow with
# Sail reference model for self-checking ELF generation.
# See: https://github.com/riscv-non-isa/riscv-arch-test (act4 branch)
# ============================================================================
ACT4_DIR       := $(VERIFY_HOME)/riscof
ACT4_REPO      := $(ACT4_DIR)/riscv-arch-test
ACT4_WORKDIR   := $(BUILD_DIR)/riscof
ACT4_CONFIG    := $(ACT4_DIR)/raptor-rv32imac/test_config.yaml
ifeq ($(ISA),rv64)
  ACT4_CONFIG  := $(ACT4_DIR)/raptor-rv64imac/test_config.yaml
endif
ACT4_ELF_DIR    = $(ACT4_WORKDIR)/raptor-rv32imac/elfs
ifeq ($(ISA),rv64)
  ACT4_ELF_DIR  = $(ACT4_WORKDIR)/raptor-rv64imac/elfs
endif
# Only generate tests for implemented extensions (positive filter).
# Using EXTENSIONS instead of EXCLUDE_EXTENSIONS avoids generating tests for
# F/D/Zfh/etc which bloats tests/ by ~600MB and wastes Sail simulation time.
ACT4_EXTENSIONS ?= I,M,Zca,Zicsr,Zicntr,Zifencei,Zaamo,Zalrsc,Zba,Zbb,Zbc,Zbs

.PHONY: riscof riscof-setup riscof-gen riscof-run riscof-clean

riscof: riscof-setup riscof-gen riscof-run ## Run ACT4 compliance tests

riscof-setup: ## Clone ACT4 repo and check prerequisites
	@if [ ! -d "$(ACT4_REPO)" ]; then \
		echo "[act4] Cloning riscv-arch-test (act4 branch)..."; \
		mkdir -p "$(ACT4_DIR)"; \
		git clone --depth 1 -b act4 https://github.com/riscv-non-isa/riscv-arch-test.git "$(ACT4_REPO)"; \
	else echo "[act4] Repo already present at $(ACT4_REPO)"; fi
	@echo "[act4] Checking prerequisites..."
	@command -v uv >/dev/null 2>&1 \
		&& echo "[act4] uv: $$(uv --version)" \
		|| { echo "[act4] ERROR: 'uv' not found. Install: curl -LsSf https://astral.sh/uv/install.sh | sh"; exit 1; }
	@command -v sail_riscv_sim >/dev/null 2>&1 \
		&& echo "[act4] sail: $$(sail_riscv_sim --version 2>&1 | head -1)" \
		|| { echo "[act4] WARN: 'sail_riscv_sim' not found (needed for riscof-gen)."; \
		echo "  Install: see https://github.com/riscv/sail-riscv/releases"; }
	@echo "[act4] Setup complete.  Config: $(ACT4_CONFIG)"

riscof-gen: ## Generate self-checking ELFs via ACT4 framework
	@test -d "$(ACT4_REPO)" || { echo "[act4] ERROR: repo not found. Run 'make riscof-setup' first."; exit 1; }
	@test -f "$(ACT4_CONFIG)" || { echo "[act4] ERROR: config not found: $(ACT4_CONFIG)"; exit 1; }
	@echo "[act4] Generating self-checking ELFs..."
	@echo "  Config:  $(ACT4_CONFIG)"
	@echo "  Workdir: $(ACT4_WORKDIR)"
	@mkdir -p "$(ACT4_WORKDIR)"
	cd "$(ACT4_REPO)" && \
		$(MAKE) elfs \
		CONFIG_FILES="$(ACT4_CONFIG)" \
		WORKDIR="$(ACT4_WORKDIR)" \
		EXTENSIONS="$(ACT4_EXTENSIONS)" \
		FAST=1 \
		--jobs $(NPROC)
	@echo "[act4] ELFs generated in $(ACT4_ELF_DIR)"

riscof-run: check-prereqs ## Run ACT4 ELFs on Raptor NPC
	@test -d "$(ACT4_ELF_DIR)" || { echo "[act4] ERROR: ELF directory not found: $(ACT4_ELF_DIR)"; \
		echo "  Run 'make riscof-gen' first to generate self-checking ELFs."; exit 1; }
	@echo "================================================================"
	@echo "[act4] Running ACT4 tests on Raptor NPC"
	@echo "  NPC:    $(NPC_BIN)"
	@echo "  ELFs:   $(ACT4_ELF_DIR)"
	@echo "  Logs:   $(ACT4_WORKDIR)/logs"
	@echo "================================================================"
	python3 $(VERIFY_HOME)/scripts/run_act4.py \
		--npc-bin "$(NPC_BIN)" \
		--objcopy "$(OBJCOPY)" \
		--mrom-img "$(MROM_IMG)" \
		--log-dir "$(ACT4_WORKDIR)/logs" \
		--timeout $(TIMEOUT) \
		"$(ACT4_ELF_DIR)"

riscof-clean: ## Clean ACT4 artifacts
	rm -rf $(ACT4_WORKDIR)

# ============================================================================
# Verilator Coverage
# ============================================================================
NPC_ARCH_COV := riscv32-npc
ifeq ($(ISA),rv64)
  NPC_ARCH_COV := riscv64-npc
endif

COV_FUZZ_SEED       ?= 123## Fuzz seed used by coverage-run
COV_FUZZ_NUM        ?= 40## Fuzz test count used by coverage-run
COV_FUZZ_LEN        ?= 200## Fuzz test length used by coverage-run
COV_MICROBENCH_ARGS ?= test## Microbench mainargs used by coverage-run

define RUN_AND_SAVE_COVERAGE
	@echo "[coverage] Running $(1) workload..."
	@mkdir -p $(COV_DIR)
	@rm -f $(NSIM_HOME)/coverage*.dat $(VERIFY_HOME)/coverage*.dat
	-$(2) 2>&1 | tee "$(COV_DIR)/$(1).log"
	@if [ -f "$(NSIM_HOME)/coverage.dat" ]; then \
		cp "$(NSIM_HOME)/coverage.dat" "$(COV_DIR)/coverage_$(1).dat"; \
		echo "[coverage] Saved: $(COV_DIR)/coverage_$(1).dat"; \
	elif [ -f "$(VERIFY_HOME)/coverage.dat" ]; then \
		cp "$(VERIFY_HOME)/coverage.dat" "$(COV_DIR)/coverage_$(1).dat"; \
		echo "[coverage] Saved: $(COV_DIR)/coverage_$(1).dat"; \
	else \
		echo "[coverage] WARN: $(1) did not produce coverage.dat"; \
	fi
endef

.PHONY: coverage coverage-build coverage-run coverage-run-coremark \
	coverage-run-coremark-pk coverage-run-hello-pk coverage-run-isa-tests-pk \
	coverage-run-microbench coverage-run-fuzz coverage-run-sigtest \
	coverage-report coverage-clean

coverage: coverage-build coverage-run coverage-report ## Full coverage flow

coverage-build: ## Build NPC with coverage instrumentation
	@echo "[coverage] Building NPC with --coverage..."
	@rm -rf $(NSIM_HOME)/build/obj_dir $(NSIM_HOME)/build/riscv*-npc-*
	$(MAKE) -C $(NSIM_HOME) o2_difftest_defconfig
	$(MAKE) -C $(NSIM_HOME) -j$(NPROC) VFLAGS="$(VFLAGS)" \
		VERILATOR_EXTRA="--coverage --coverage-line --coverage-toggle -Wno-UNOPTFLAT"

coverage-run: ## Run test suite to collect coverage
	@mkdir -p $(COV_DIR)
	@rm -f $(COV_DIR)/coverage_*.dat $(COV_DIR)/coverage.dat \
		$(NSIM_HOME)/coverage*.dat $(VERIFY_HOME)/coverage*.dat
	@echo "================================================================"
	@echo "[coverage] Running tests to collect coverage"
	@echo "  ISA:    $(ISA)"
	@echo "  Output: $(COV_DIR)"
	@echo "================================================================"
	$(MAKE) --no-print-directory coverage-run-coremark
	$(MAKE) --no-print-directory coverage-run-coremark-pk
	$(MAKE) --no-print-directory coverage-run-hello-pk
	$(MAKE) --no-print-directory coverage-run-isa-tests-pk
	$(MAKE) --no-print-directory coverage-run-microbench
	$(MAKE) --no-print-directory coverage-run-fuzz
	$(MAKE) --no-print-directory coverage-run-sigtest
	@echo "[coverage] Data collection complete."
	@ls -la "$(COV_DIR)/"coverage_*.dat 2>/dev/null || echo "[coverage] No coverage_*.dat files found (coverage build may be needed)"

# app/ (pk mode) ISA64 flag: rv64 -> 1, rv32 -> empty (unset)
APP_ISA64 := $(if $(filter rv64,$(ISA)),1,)

coverage-run-coremark: ## Run only coremark coverage workload
	$(call RUN_AND_SAVE_COVERAGE,coremark,$(MAKE) -C $(AM_KERNELS)/benchmarks/coremark_eembc ARCH=$(NPC_ARCH_COV) run ARGS="-b -n" VFLAGS="$(VFLAGS)")

coverage-run-coremark-pk: ## Run coremark under pk (app/) for coverage
	$(call RUN_AND_SAVE_COVERAGE,coremark-pk,$(MAKE) -C $(RAPTOR_HOME)/app coremark ISA64=$(APP_ISA64) ARGS="-b -n" VFLAGS="$(VFLAGS)")

coverage-run-hello-pk: ## Run hello under pk (app/) for coverage
	$(call RUN_AND_SAVE_COVERAGE,hello-pk,$(MAKE) -C $(RAPTOR_HOME)/app hello ISA64=$(APP_ISA64) ARGS="-b -n" VFLAGS="$(VFLAGS)")

coverage-run-isa-tests-pk: ## Run ISA tests under pk (app/) for coverage
	$(call RUN_AND_SAVE_COVERAGE,isa-tests-pk,$(MAKE) -C $(RAPTOR_HOME)/app isa-tests ISA64=$(APP_ISA64) ARGS="-b -n" VFLAGS="$(VFLAGS)")


coverage-run-microbench: ## Run only microbench coverage workload
	$(call RUN_AND_SAVE_COVERAGE,microbench,$(MAKE) -C $(AM_KERNELS)/benchmarks/microbench ARCH=$(NPC_ARCH_COV) run ARGS="-b -n" mainargs=$(COV_MICROBENCH_ARGS) VFLAGS="$(VFLAGS)")

coverage-run-fuzz: ## Run only fuzz coverage workload
	$(call RUN_AND_SAVE_COVERAGE,fuzz,$(MAKE) --no-print-directory fuzz SEED=$(COV_FUZZ_SEED) FUZZ_NUM=$(COV_FUZZ_NUM) FUZZ_LEN=$(COV_FUZZ_LEN) TIMEOUT=$(TIMEOUT))

coverage-run-sigtest: ## Run only sigtest coverage workload
	$(call RUN_AND_SAVE_COVERAGE,sigtest,$(MAKE) --no-print-directory sigtest TIMEOUT=$(TIMEOUT))

coverage-report: ## Generate coverage report
	@echo "[coverage] Generating report..."
	@if ls $(COV_DIR)/coverage_*.dat 1>/dev/null 2>&1; then \
		verilator_coverage --annotate $(COV_DIR)/annotated \
			$(COV_DIR)/coverage_*.dat 2>/dev/null || \
		verilator_coverage --write $(COV_DIR)/merged.dat \
			$(COV_DIR)/coverage_*.dat 2>/dev/null; \
		echo "[coverage] Report at $(COV_DIR)/annotated/"; \
	else \
		echo "[coverage] No coverage_*.dat files found. Run coverage-run first."; \
	fi

coverage-clean: ## Clean coverage artifacts
	rm -rf $(COV_DIR)

# ============================================================================
# Signature-based ISA Tests (lightweight, no ACT4 dependency)
# ============================================================================
SIGTEST_DIR    := $(BUILD_DIR)/sigtest
SIGTEST_LINKER := $(VERIFY_HOME)/scripts/fuzz_link.ld

.PHONY: sigtest sigtest-gen sigtest-run sigtest-clean

sigtest: sigtest-gen sigtest-run ## Generate and run signature-based ISA tests

sigtest-gen: ## Generate signature test programs
	@mkdir -p $(SIGTEST_DIR)
	python3 $(VERIFY_HOME)/scripts/gen_sigtests.py \
		--xlen $(ISA_XLEN) --outdir $(SIGTEST_DIR)
	@echo "[sigtest] Generated tests in $(SIGTEST_DIR)/"

sigtest-run: check-prereqs ## Run signature tests with difftest
	@test -f "$(SIGTEST_DIR)/manifest.txt" || \
		{ echo "[sigtest] ERROR: $(SIGTEST_DIR)/manifest.txt not found. Run 'make sigtest-gen' first."; exit 1; }
	@echo "================================================================"
	@echo "[sigtest] Running signature-based ISA tests with difftest"
	@echo "================================================================"
	@PASS=0; FAIL=0; ERR=0; TOTAL=0; FAIL_LIST=""; \
	while IFS= read -r name; do \
		TOTAL=$$((TOTAL + 1)); \
		src="$(SIGTEST_DIR)/$${name}.S"; \
		elf="$(SIGTEST_DIR)/$${name}.elf"; \
		bin="$(SIGTEST_DIR)/$${name}.bin"; \
		log="$(SIGTEST_DIR)/$${name}.run.log"; \
		if [ ! -f "$$src" ]; then echo "  [SKIP] $$name"; ERR=$$((ERR+1)); continue; fi; \
		if ! $(CC) -march=$(MARCH) -mabi=$(MABI) -nostdlib -nostartfiles \
			-T $(SIGTEST_LINKER) -o "$$elf" "$$src" 2>"$(SIGTEST_DIR)/$${name}.compile.log"; then \
			echo "  [CERR] $$name: compilation failed"; \
			head -5 "$(SIGTEST_DIR)/$${name}.compile.log" | sed 's/^/         /'; \
			ERR=$$((ERR+1)); continue; fi; \
		$(OBJCOPY) -O binary "$$elf" "$$bin"; \
		set +e; $(TIMEOUT_RUN) $(TIMEOUT) $(NPC_BIN) -b -n -d $(NEMU_SO) -r $(MROM_IMG) "$$bin" >"$$log" 2>&1; \
		rc=$$?; set -e; \
		if [ $$rc -eq 0 ]; then \
			if grep -qiE "BAD TRAP|ABORT" "$$log"; then \
				echo "  [FAIL] $$name: BAD TRAP"; FAIL=$$((FAIL+1)); FAIL_LIST="$$FAIL_LIST $$name"; \
				tail -3 "$$log" | sed 's/^/         /'; \
			else echo "  [PASS] $$name"; PASS=$$((PASS+1)); fi; \
		elif [ $$rc -eq 124 ]; then \
			echo "  [TIME] $$name"; FAIL=$$((FAIL+1)); FAIL_LIST="$$FAIL_LIST $$name(timeout)"; \
		else \
			echo "  [FAIL] $$name (exit $$rc)"; FAIL=$$((FAIL+1)); FAIL_LIST="$$FAIL_LIST $$name"; \
			tail -5 "$$log" | sed 's/^/         /'; \
		fi; \
	done < "$(SIGTEST_DIR)/manifest.txt"; \
	echo ""; \
	echo "================================================================"; \
	echo "[sigtest] Results: $$PASS passed, $$FAIL failed, $$ERR errors (total $$TOTAL)"; \
	if [ -n "$$FAIL_LIST" ]; then echo "[sigtest] Failed:$$FAIL_LIST"; fi; \
	echo "================================================================"; \
	[ $$FAIL -eq 0 ] && [ $$ERR -eq 0 ]

sigtest-clean: ## Clean sigtest artifacts
	rm -rf $(SIGTEST_DIR)

# ============================================================================
# Formal Verification (delegates to formal/Makefile)
# ============================================================================
FORMAL_DIR := $(VERIFY_HOME)/formal

.PHONY: formal formal-setup formal-bus formal-exu-mul \
	formal-rvfi formal-rvfi-gen formal-rvfi-check formal-rvfi-clean formal-clean

formal-setup: ## Install oss-cad-suite (yosys, sby, solvers)
	$(MAKE) -C $(FORMAL_DIR) setup

formal-bus: ## Formal: verify AXI bus properties
	$(MAKE) -C $(FORMAL_DIR) formal_bus

formal-exu-mul: ## Formal: verify EXU multiplier
	$(MAKE) -C $(FORMAL_DIR) formal_exu_mul

formal: formal-bus formal-exu-mul ## Run all standalone formal checks

formal-rvfi-gen: ## Formal: generate riscv-formal checks (auto-clones repo)
	$(MAKE) -C $(FORMAL_DIR) formal_rvfi_gen

formal-rvfi: ## Formal: run all 150 riscv-formal RVFI checks
	$(MAKE) -C $(FORMAL_DIR) formal_rvfi

formal-rvfi-check: ## Formal: run single RVFI check (CHECK=insn_add_ch0)
	$(MAKE) -C $(FORMAL_DIR) formal_rvfi_check CHECK=$(CHECK)

formal-rvfi-clean: ## Formal: clean generated RVFI checks
	$(MAKE) -C $(FORMAL_DIR) formal_rvfi_clean

formal-clean: ## Formal: clean all formal artifacts
	$(MAKE) -C $(FORMAL_DIR) formal_rvfi_clean

# ============================================================================
# All-in-one
# ============================================================================
.PHONY: all clean

all: fuzz sigtest ## Run all lightweight verification

clean: fuzz-clean riscof-clean coverage-clean sigtest-clean formal-clean ## Clean all verify artifacts
	rm -rf $(BUILD_DIR)
