# ============================================================================
# Unified Verification Makefile
# ============================================================================
# Orchestrates: random fuzz, ACT4 compliance, coverage, assertion checks.
# Reuses the existing sim Verilator simulator and NEMU difftest reference.
#
# Usage:
#   make help                        Show all targets
# ============================================================================

SHELL := /bin/bash
.DEFAULT_GOAL := help

# --- Environment (inherited from root Makefile or set manually) ---
RAPTOR_HOME   ?= $(abspath ..)
NSIM_HOME   := $(RAPTOR_HOME)/sim
NEMU_HOME   := $(RAPTOR_HOME)/nemu
AM_HOME     := $(RAPTOR_HOME)/abstract-machine
VERIFY_HOME := $(abspath .)

# Export vars that sub-Makefiles (sim/, nemu/) expect.
export RAPTOR_HOME
export NSIM_HOME
export NEMU_HOME
export AM_HOME
export CROSS_COMPILE

ifeq ($(strip $(CROSS_COMPILE)),)
CROSS_COMPILE := riscv64-elf-
endif
CC  := $(CROSS_COMPILE)gcc
AS  := $(CROSS_COMPILE)as
LD  := $(CROSS_COMPILE)ld
OBJCOPY := $(CROSS_COMPILE)objcopy
OBJDUMP := $(CROSS_COMPILE)objdump

NPROC := $(shell nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
JOBS ?= $(shell awk 'BEGIN { n=$(NPROC); j=int(n / 2); print (j > 0 ? j : 1) }')
SUBMAKE_JOBS = $(if $(filter --jobserver-auth=% --jobserver-fds=%,$(MAKEFLAGS)),,-j$(NPROC))
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
# sim scopes outputs per RAPT_CONFIG (hdl/configs/<name>/). Keep this in
# sync with sim/Makefile; classic RISCOF is validated against the small profile.
RAPT_CONFIG ?= small
SIM_BUILD_PROFILE ?= $(if $(strip $(BUILD_PROFILE)),$(strip $(BUILD_PROFILE)),$(RAPT_CONFIG))
NPC_BIN_32  := $(NSIM_HOME)/build/$(SIM_BUILD_PROFILE)/riscv32-npc-sim
NPC_BIN_64  := $(NSIM_HOME)/build/$(SIM_BUILD_PROFILE)/riscv64-npc-sim
# RISCOF needs a simulator built without difftest.  Keep it in an isolated
# profile so a concurrent coverage/difftest config change cannot remove the
# binary while the compliance runner is using it.
RISCOF_BUILD_PROFILE ?= $(RAPT_CONFIG)-riscof
RISCOF_NPC_BIN_32 := $(NSIM_HOME)/build/$(RISCOF_BUILD_PROFILE)/riscv32-npc-sim
NEMU_SO_32  := $(NEMU_HOME)/build/riscv32-nemu-interpreter-so
NEMU_SO_64  := $(NEMU_HOME)/build/riscv64-nemu-interpreter-so
MROM_IMG    := $(NSIM_HOME)/csrc/mem/mrom-data/build/mrom-data.bin

# --- Configuration ---
SEED     ?= $(shell date +%s)	## Random seed for fuzz
FUZZ_NUM ?= 20	## Number of fuzz test programs to generate
FUZZ_LEN ?= 200	## Instructions per fuzz program
TIMEOUT  ?= 10	## Per-test timeout in seconds
ISA      ?= rv32## rv32 or rv64
MEM_RANDOM_DELAY ?= 0## Maximum randomized AXI wait cycles for NPC workloads
MEM_RANDOM_SEED  ?= 1## Reproducible randomized AXI timing seed
NPC_MEM_ARGS = --mem-random-delay=$(MEM_RANDOM_DELAY) --mem-random-seed=$(MEM_RANDOM_SEED)

BUILD_DIR := $(VERIFY_HOME)/build
FUZZ_DIR  := $(BUILD_DIR)/fuzz
COV_DIR   := $(BUILD_DIR)/coverage
AM_KERNELS := $(RAPTOR_HOME)/abstract-machine/app/am-kernels

# This pinned riscv-dv revision still imports Python's removed `imp` module,
# so it requires Python 3.10 or 3.11.  If neither is installed, setup uses
# uv to provision a local 3.11 interpreter inside the verification venv.
RISCV_DV_REV        ?= b7a0b4b0b51346a3c64f159f81ea262d867c14a9## Pinned upstream revision
RISCV_DV_DIR        := $(VERIFY_HOME)/riscv-dv
RISCV_DV_TARGET     := $(VERIFY_HOME)/riscv-dv-target
RISCV_DV_VENV       := $(BUILD_DIR)/riscv-dv-venv
RISCV_DV_PYTHON     ?= $(shell command -v python3.11 2>/dev/null || command -v python3.10 2>/dev/null)## Optional installed Python 3.10/3.11 interpreter
RISCV_DV_OUT        ?= $(BUILD_DIR)/riscv-dv## Generated programs and logs
RISCV_DV_TEST       ?= raptor_privileged_smoke## Test name from riscv-dv-target/testlist.yaml
RISCV_DV_ITERATIONS ?= 1## Override generated program count
RISCV_DV_SEED       ?= 1## Reproducible first random seed
RISCV_DV_TIMEOUT    ?= 120## NPC timeout per delay/seed case
RISCV_DV_MEM_DELAYS ?= 0 7 31 63 233## AXI random-delay maxima (0..N cycles per beat)
RISCV_DV_MEM_SEEDS  ?= 1## Reproducible AXI delay seeds

RISCV_DV_ENV = PATH="$(RISCV_DV_VENV)/bin:$$PATH" \
	PYTHONPATH="$(RISCV_DV_TARGET):$$PYTHONPATH" \
	RISCV_GCC="$(CC)" RISCV_OBJCOPY="$(OBJCOPY)"
RISCV_DV_RUN = cd $(RISCV_DV_DIR) && $(RISCV_DV_ENV) \
	$(RISCV_DV_VENV)/bin/python ./run.py --simulator pyflow \
	--target raptor_rv32imac --custom_target $(RISCV_DV_TARGET) \
	--isa rv32imac_zicsr_zifencei --mabi ilp32

define RISCV_DV_TIMEOUT_CMD
$(if $(TIMEOUT_BIN),$(TIMEOUT_RUN) --kill-after=2 $(1),$(TIMEOUT_RUN) $(1))
endef

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
			printf "  %-24s %s\n", target, desc }' $(MAKEFILE_LIST)
	@echo ""
	@echo "Variables (override with VAR=value):"
	@grep -hE '^[A-Z_]+\s*\?=' $(MAKEFILE_LIST) | \
		awk '{ \
			if (match($$0, /## /)) { \
				name=$$0; sub(/\s*\?=.*/, "", name); \
				desc=substr($$0, RSTART+3); \
				printf "  %-24s %s\n", name, desc } \
			else { \
				split($$0, a, "\\?="); \
				gsub(/^[ \t]+|[ \t]+$$/, "", a[1]); gsub(/^[ \t]+|[ \t]+$$/, "", a[2]); \
				printf "  %-24s %s\n", a[1], a[2] } }'
	@echo ""

# ============================================================================
# Prerequisites: ensure simulator and NEMU are built
# ============================================================================
$(NPC_BIN):
	@echo "[verify] Building NPC simulator (difftest enabled)..."
	+$(MAKE) -C $(RAPTOR_HOME) config-rv32-difftest
	+$(MAKE) -C $(NSIM_HOME) $(SUBMAKE_JOBS) RAPT_CONFIG=$(RAPT_CONFIG) VFLAGS="$(VFLAGS)"

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
check-prereqs: $(NPC_BIN) $(NEMU_SO) $(MROM_IMG) ## Verify all prerequisites are built
	@echo "[verify] Checking prerequisites..."
	@test -f $(NPC_BIN)  || (echo "ERROR: NPC binary not found: $(NPC_BIN)"  && echo "  Run: make -C $(RAPTOR_HOME) build-rv32" && exit 1)
	@test -f $(NEMU_SO)  || (echo "ERROR: NEMU SO not found: $(NEMU_SO)"    && echo "  Run: make -C $(RAPTOR_HOME) config-nemu32-ref" && exit 1)
	@echo "[verify] All prerequisites OK."

# ============================================================================
# riscv-dv privileged random verification
# ============================================================================
.PHONY: riscv-dv riscv-dv-setup riscv-dv-gen riscv-dv-run riscv-dv-smoke \
	riscv-dv-stress riscv-dv-mmu riscv-dv-clean

riscv-dv: riscv-dv-smoke ## Generate and run the M-mode privileged smoke test

riscv-dv-setup: $(RISCV_DV_VENV)/.ready ## Clone riscv-dv and install pyflow dependencies

$(RISCV_DV_DIR)/.git:
	git clone https://github.com/chipsalliance/riscv-dv.git $(RISCV_DV_DIR)
	git -C $(RISCV_DV_DIR) checkout $(RISCV_DV_REV)

$(RISCV_DV_DIR)/requirements.txt: $(RISCV_DV_DIR)/.git
	@test -f $@ || { echo "[riscv-dv] ERROR: upstream requirements.txt is missing"; exit 1; }

$(RISCV_DV_VENV)/.ready: $(RISCV_DV_DIR)/requirements.txt
	@rm -rf "$(RISCV_DV_VENV)"
	@if [ -n "$(RISCV_DV_PYTHON)" ]; then \
		"$(RISCV_DV_PYTHON)" -m venv "$(RISCV_DV_VENV)"; \
	elif command -v uv >/dev/null 2>&1; then \
		uv venv --python 3.11 --seed "$(RISCV_DV_VENV)"; \
	else \
		echo "[riscv-dv] ERROR: Python 3.10/3.11 or uv is required."; exit 1; \
	fi
	$(RISCV_DV_VENV)/bin/python -m pip install -r $(RISCV_DV_DIR)/requirements.txt
	@touch $@

riscv-dv-gen: riscv-dv-setup ## Generate and compile RISCV_DV_TEST programs
	@rm -rf "$(RISCV_DV_OUT)/$(RISCV_DV_TEST)"
	$(RISCV_DV_RUN) --steps gen \
		--test $(RISCV_DV_TEST) --iterations $(RISCV_DV_ITERATIONS) \
		--start_seed $(RISCV_DV_SEED) \
		--output "$(RISCV_DV_OUT)/$(RISCV_DV_TEST)"
	$(PYTHON) $(VERIFY_HOME)/scripts/patch_riscv_dv_npc.py \
		$(if $(filter raptor_exception_stress,$(RISCV_DV_TEST)),--illegal-burst-count 256) \
		"$(RISCV_DV_OUT)/$(RISCV_DV_TEST)/asm_test"
	$(RISCV_DV_RUN) --steps gcc_compile --noclean \
		--test $(RISCV_DV_TEST) --iterations $(RISCV_DV_ITERATIONS) \
		--start_seed $(RISCV_DV_SEED) \
		--output "$(RISCV_DV_OUT)/$(RISCV_DV_TEST)"

riscv-dv-run: check-prereqs ## Run generated RISCV_DV_TEST binaries with NEMU difftest
	@set -e; found=0; total=0; pass=0; fail=0; fail_list=""; \
	for bin in "$(RISCV_DV_OUT)/$(RISCV_DV_TEST)"/asm_test/*.bin; do \
		[ -f "$$bin" ] || continue; found=$$((found + 1)); \
		name=$$(basename "$$bin" .bin); \
		for delay in $(RISCV_DV_MEM_DELAYS); do \
			for mem_seed in $(RISCV_DV_MEM_SEEDS); do \
				total=$$((total + 1)); case_id="$${name}.delay$${delay}-seed$${mem_seed}"; \
				log="$${bin%.bin}.delay$${delay}-seed$${mem_seed}.run.log"; \
				printf "  [RUN ] %s\n" "$$case_id"; \
				set +e; cd "$(NSIM_HOME)" && $(call RISCV_DV_TIMEOUT_CMD,$(RISCV_DV_TIMEOUT)) \
					"$(NPC_BIN)" -b -n --trap-on-ebreak \
					--mem-random-delay="$$delay" --mem-random-seed="$$mem_seed" \
					-d "$(NEMU_SO)" -r "$(MROM_IMG)" "$$bin" \
					</dev/null >"$$log" 2>&1; rc=$$?; set -e; \
				cd "$(VERIFY_HOME)"; \
				if [ $$rc -ne 0 ] || grep -qiE "BAD TRAP|ABORT|mismatch" "$$log" || \
					! grep -q "HIT GOOD TRAP" "$$log"; then \
					echo "  [FAIL] $$case_id (exit $$rc)"; tail -20 "$$log"; \
					fail=$$((fail + 1)); fail_list="$$fail_list $$case_id"; \
				else \
					echo "  [PASS] $$case_id"; pass=$$((pass + 1)); \
				fi; \
			done; \
		done; \
	done; \
	[ $$found -gt 0 ] || { echo "[riscv-dv] No binaries found; run riscv-dv-gen first."; exit 1; }; \
	echo "[riscv-dv] $$pass/$$total matrix cases passed with NPC + NEMU difftest"; \
	[ $$fail -eq 0 ] || { echo "[riscv-dv] Failed:$$fail_list"; exit 1; }

riscv-dv-smoke: ## Generate and run one short M-mode privileged test
	$(MAKE) --no-print-directory riscv-dv-gen \
		RISCV_DV_TEST=raptor_privileged_smoke RISCV_DV_ITERATIONS=1
	$(MAKE) --no-print-directory riscv-dv-run \
		RISCV_DV_TEST=raptor_privileged_smoke RISCV_DV_ITERATIONS=1

riscv-dv-stress: ## Run privileged exception stress with riscv-dv pyflow
	$(MAKE) --no-print-directory riscv-dv-gen \
		RISCV_DV_TEST=raptor_exception_stress RISCV_DV_MEM_SEEDS="1 42 31337"
	$(MAKE) --no-print-directory riscv-dv-run \
		RISCV_DV_TEST=raptor_exception_stress RISCV_DV_MEM_SEEDS="1 42 31337"

riscv-dv-mmu: ## Report the upstream simulator needed for riscv-dv Sv32/MMU tests
	@echo "[riscv-dv] Sv32/MMU generation is unavailable in the pyflow backend:"
	@echo "[riscv-dv] create_page_table(), page-table sections, and fault handlers are TODO upstream."
	@echo "[riscv-dv] Use the SV/UVM generator with VCS, Questa, Xcelium, or Riviera-PRO."
	@exit 2

riscv-dv-clean: ## Clean riscv-dv generated programs (keep clone and venv)
	rm -rf $(RISCV_DV_OUT)

# ============================================================================
# Random Instruction Fuzz
# ============================================================================
FUZZ_INF_BATCH    ?= 20## Programs per batch in fuzz-inf mode
FUZZ_STALE_LIMIT  ?= 10## Stop after N batches with no new coverage (0=disable)
FUZZ_SRC_DIR   ?= $(FUZZ_DIR)## Directory containing .S + manifest.txt to run
FUZZ_LINKER    := $(VERIFY_HOME)/scripts/fuzz_link.ld
FUZZ_LAST_FAIL := $(FUZZ_DIR)/last_fail

.PHONY: fuzz fuzz-gen fuzz-run fuzz-replay fuzz-run-one fuzz-inf fuzz-clean

fuzz: fuzz-gen ## Generate and run random instruction fuzz tests
	$(MAKE) --no-print-directory fuzz-run

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
		set +e; $(TIMEOUT_RUN) $(TIMEOUT) $(NPC_BIN) -b -n $(NPC_MEM_ARGS) -d $(NEMU_SO) -r $(MROM_IMG) "$$bin" </dev/null >"$$log" 2>&1; \
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
RUN_BUILD_DIR ?=## Optional output directory for fuzz-run-one artifacts
fuzz-run-one: check-prereqs ## Run a single .S test file (SRC=path/to/test.S)
	@test -n "$(SRC)" || { echo "[fuzz-run-one] ERROR: specify SRC=path/to/test.S"; exit 1; }
	@test -f "$(SRC)" || { echo "[fuzz-run-one] ERROR: $(SRC) not found"; exit 1; }
	@src_base="$${SRC%.S}"; out_base="$$src_base"; \
	if [ -n "$(RUN_BUILD_DIR)" ]; then \
		mkdir -p "$(RUN_BUILD_DIR)"; \
		out_base="$(RUN_BUILD_DIR)/$$(basename "$$src_base")"; \
	fi; \
	elf="$$out_base.elf"; bin="$$out_base.bin"; log="$$out_base.run.log"; \
	echo "[fuzz-run-one] $(SRC)"; \
	$(CC) -march=$(MARCH) -mabi=$(MABI) -nostdlib -nostartfiles \
		-T $(FUZZ_LINKER) -o "$$elf" "$(SRC)"; \
	$(OBJCOPY) -O binary "$$elf" "$$bin"; \
	$(NPC_BIN) -b -n $(NPC_MEM_ARGS) -d $(NEMU_SO) -r $(MROM_IMG) "$$bin" 2>&1 | tee "$$log"; \
	echo "[fuzz-run-one] Log: $$log"

zbb-strlen: ## Run the Linux RV64 strlen_zbb sequence through NPC/NEMU difftest
	@$(MAKE) --no-print-directory fuzz-run-one ISA=rv64 \
		SRC=$(RAPTOR_HOME)/app/tests/zbb/strlen.S \
		RUN_BUILD_DIR=$(RAPTOR_HOME)/app/build/rv64/tests/zbb

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
ACT4_CONFIG    := $(ACT4_DIR)/raptor-rv32gc/test_config.yaml
ifeq ($(ISA),rv64)
  ACT4_CONFIG  := $(ACT4_DIR)/raptor-rv64imac/test_config.yaml
endif
ACT4_ELF_DIR    = $(ACT4_WORKDIR)/raptor-rv32gc/elfs
ifeq ($(ISA),rv64)
  ACT4_ELF_DIR  = $(ACT4_WORKDIR)/raptor-rv64imac/elfs
endif
# Only generate tests for implemented extensions (positive filter).
# Using EXTENSIONS instead of EXCLUDE_EXTENSIONS avoids generating tests for
# unsupported extensions such as Zfh/V, which bloat tests/ and waste Sail time.
ACT4_EXTENSIONS ?= I,M,F,D,Zca,Zcf,Zcd,Zicsr,Zicntr,Zifencei,Zaamo,Zalrsc,Zba,Zbb,Zbc,Zbs
SAIL_VERSION    ?= 0.13.1
ACT4_SAIL_DIR   ?= $(HOME)/.local/opt/sail-riscv-$(SAIL_VERSION)/bin
ACT4_RUBY_DIR   ?= $(shell if command -v brew >/dev/null 2>&1; then dir="$$(brew --prefix ruby@3.2 2>/dev/null)/bin"; test -x "$$dir/ruby" && printf '%s' "$$dir"; fi)
ACT4_GEM_BIN    ?= $(shell if [ -n "$(ACT4_RUBY_DIR)" ]; then PATH="$(ACT4_RUBY_DIR):$(PATH)" ruby -e 'print Gem.bindir' 2>/dev/null; fi)
ACT4_PATH       := $(if $(ACT4_RUBY_DIR),$(ACT4_RUBY_DIR):)$(if $(ACT4_GEM_BIN),$(ACT4_GEM_BIN):)$(ACT4_SAIL_DIR):$(PATH)
ACT4_UV_CACHE_DIR ?= $(BUILD_DIR)/uv-cache
ACT4_XDG_DATA_HOME ?= $(BUILD_DIR)/xdg-data

.PHONY: riscof riscof-setup riscof-gen riscof-run riscof-build-npc riscof-clean

riscof: riscof-setup ## Run ACT4 compliance tests
	+$(MAKE) --no-print-directory riscof-gen
	+$(MAKE) --no-print-directory riscof-run

riscof-setup: ## Clone ACT4 repo and check prerequisites
	@if [ ! -d "$(ACT4_REPO)" ]; then \
		echo "[act4] Cloning riscv-arch-test (act4 branch)..."; \
		mkdir -p "$(ACT4_DIR)"; \
		git clone --depth 1 -b act4 https://github.com/riscv-non-isa/riscv-arch-test.git "$(ACT4_REPO)"; \
	else echo "[act4] Repo already present at $(ACT4_REPO)"; fi
	@python3 $(VERIFY_HOME)/scripts/patch_act4_sail.py --repo "$(ACT4_REPO)"
	@echo "[act4] Checking prerequisites..."
	@command -v uv >/dev/null 2>&1 \
		&& echo "[act4] uv: $$(uv --version)" \
		|| { echo "[act4] ERROR: 'uv' not found. Install: curl -LsSf https://astral.sh/uv/install.sh | sh"; exit 1; }
	@ACT4_RUBY_VERSION=$$(PATH="$(ACT4_PATH)" ruby -e 'print RUBY_VERSION[/^[0-9]+\.[0-9]+/]') \
		&& [ "$$ACT4_RUBY_VERSION" = "3.2" ] \
		&& echo "[act4] ruby: $$(PATH="$(ACT4_PATH)" ruby --version)" \
		&& echo "[act4] bundle: $$(PATH="$(ACT4_PATH)" command -v bundle)" \
		|| { echo "[act4] ERROR: Ruby 3.2 is required by the ACT4 UDB Gemfile."; \
		echo "  Install ruby@3.2 or set ACT4_RUBY_DIR."; exit 1; }
	@PATH="$(ACT4_PATH)" command -v udb >/dev/null 2>&1 \
		&& echo "[act4] udb: $$(PATH="$(ACT4_PATH)" command -v udb)" \
		|| { echo "[act4] ERROR: UDB command not found in the Ruby 3.2 gem bindir."; exit 1; }
	@ACT4_SAIL_VERSION=$$(PATH="$(ACT4_PATH)" sail_riscv_sim --version 2>/dev/null) \
		&& [ "$$ACT4_SAIL_VERSION" = "$(SAIL_VERSION)" ] \
		&& echo "[act4] sail: $$ACT4_SAIL_VERSION ($$(PATH="$(ACT4_PATH)" command -v sail_riscv_sim))" \
		|| { echo "[act4] ERROR: Sail $(SAIL_VERSION) is required for ACT4."; \
		echo "  Install under $(ACT4_SAIL_DIR) or set ACT4_SAIL_DIR."; exit 1; }
	@PATH="$(ACT4_PATH)" sail_riscv_sim --rv32 --config-override \
		"$(ACT4_DIR)/raptor-rv32gc/sail.json" --validate-config >/dev/null
	@echo "[act4] Setup complete.  Config: $(ACT4_CONFIG)"

riscof-gen: ## Generate self-checking ELFs via ACT4 framework
	@test -d "$(ACT4_REPO)" || { echo "[act4] ERROR: repo not found. Run 'make riscof-setup' first."; exit 1; }
	@test -f "$(ACT4_CONFIG)" || { echo "[act4] ERROR: config not found: $(ACT4_CONFIG)"; exit 1; }
	@python3 $(VERIFY_HOME)/scripts/patch_act4_sail.py --repo "$(ACT4_REPO)"
	@echo "[act4] Generating self-checking ELFs..."
	@echo "  Config:  $(ACT4_CONFIG)"
	@echo "  Workdir: $(ACT4_WORKDIR)"
	@mkdir -p "$(ACT4_WORKDIR)" "$(ACT4_UV_CACHE_DIR)" "$(ACT4_XDG_DATA_HOME)"
	cd "$(ACT4_REPO)" && \
		PATH="$(ACT4_PATH)" UV_CACHE_DIR="$(ACT4_UV_CACHE_DIR)" \
		XDG_DATA_HOME="$(ACT4_XDG_DATA_HOME)" \
		$(MAKE) elfs \
		CONFIG_FILES="$(ACT4_CONFIG)" \
		WORKDIR="$(ACT4_WORKDIR)" \
		EXTENSIONS="$(ACT4_EXTENSIONS)" \
		FAST=1 \
		--jobs $(NPROC)
	@echo "[act4] ELFs generated in $(ACT4_ELF_DIR)"

riscof-build-npc: ## Build the RV32 NPC without difftest for ACT4 self-checking ELFs
	@# ACT4 binaries report their own result and run without a NEMU -d argument.
	@# A difftest-configured simulator aborts during initialization instead.
	@if [ ! -f $(RISCOF_NPC_BIN_32) ] || grep -q '^CONFIG_DIFFTEST=y' $(NSIM_HOME)/.config 2>/dev/null; then \
		echo "[act4] (Re)building RV32 NPC without difftest (RAPT_CONFIG=$(RAPT_CONFIG), BUILD_PROFILE=$(RISCOF_BUILD_PROFILE))..."; \
		$(MAKE) -C $(NSIM_HOME) o2_defconfig; \
	else \
		echo "[act4] NPC config OK (RV32, no difftest)."; \
	fi
	@$(MAKE) -C $(NSIM_HOME) $(SUBMAKE_JOBS) RAPT_CONFIG=$(RAPT_CONFIG) \
		BUILD_PROFILE=$(RISCOF_BUILD_PROFILE) VFLAGS=""
	@test -f $(RISCOF_NPC_BIN_32) || { echo "[act4] ERROR: NPC build failed: $(RISCOF_NPC_BIN_32)"; exit 1; }

riscof-run: riscof-build-npc $(MROM_IMG) ## Run ACT4 ELFs on Raptor NPC
	@test -d "$(ACT4_ELF_DIR)" || { echo "[act4] ERROR: ELF directory not found: $(ACT4_ELF_DIR)"; \
		echo "  Run 'make riscof-gen' first to generate self-checking ELFs."; exit 1; }
	@echo "================================================================"
	@echo "[act4] Running ACT4 tests on Raptor NPC"
	@echo "  NPC:    $(RISCOF_NPC_BIN_32)"
	@echo "  ELFs:   $(ACT4_ELF_DIR)"
	@echo "  Logs:   $(ACT4_WORKDIR)/logs"
	@echo "================================================================"
	python3 $(VERIFY_HOME)/scripts/run_act4.py \
		--npc-bin "$(RISCOF_NPC_BIN_32)" \
		--objcopy "$(OBJCOPY)" \
		--mrom-img "$(MROM_IMG)" \
		--mem-random-delay $(MEM_RANDOM_DELAY) \
		--mem-random-seed $(MEM_RANDOM_SEED) \
		--jobs $(JOBS) \
		--log-dir "$(ACT4_WORKDIR)/logs" \
		--timeout $(TIMEOUT) \
		"$(ACT4_ELF_DIR)"

riscof-clean: ## Clean ACT4 artifacts
	rm -rf $(ACT4_WORKDIR)

# ============================================================================
# Classic RISCOF (upstream riscv-arch-test main branch, sail reference model)
# ============================================================================
# Independent of ACT4: runs the stock RISCOF framework with a Raptor DUT plugin
# that drives `sim` via the new --sig signature dump option. Serves as a
# cross-check against the ACT4 flow and is closer to how most RISC-V projects
# (e.g. neorv32, hazard3) exercise RISCOF.
# ============================================================================
RISCOF_CLASSIC_DIR      := $(VERIFY_HOME)/riscof/classic
RISCOF_CLASSIC_SUITE    := $(RISCOF_CLASSIC_DIR)/riscv-arch-test
RISCOF_CLASSIC_WORKDIR  := $(BUILD_DIR)/riscof-classic
RISCOF_CLASSIC_TESTLIST := $(RISCOF_CLASSIC_WORKDIR)/test_list.yaml
RISCOF_CLASSIC_FILTERED_TESTLIST := $(BUILD_DIR)/riscof-classic.raptor-test_list.yaml
RISCOF_CLASSIC_ENV_PATCH := $(VERIFY_HOME)/scripts/patch_riscof_classic_env.py
RISCOF_CLASSIC_VENV ?= $(BUILD_DIR)/riscof-classic-venv
RISCOF_CLASSIC_BIN ?= $(RISCOF_CLASSIC_VENV)/bin/riscof
RISCOF_CLASSIC_PYTHON ?= $(RISCOF_CLASSIC_VENV)/bin/python
# Use old-framework-3.x: the upstream 'main' branch was replaced by the ACT4
# layout, which drops riscv-test-suite/ in favour of a Makefile+Python flow.
# The classic RISCOF driver still expects the 3.x layout.
RISCOF_CLASSIC_BRANCH   ?= old-framework-3.x

.PHONY: riscof-classic riscof-classic-setup riscof-classic-run riscof-classic-clean riscof-classic-build-npc

riscof-classic: riscof-classic-setup ## Run classic RISCOF compliance flow
	+$(MAKE) --no-print-directory riscof-classic-run

riscof-classic-build-npc: ## (Re)build NPC simulator without difftest for RISCOF
	@# RISCOF's DUT plugin invokes sim without `--diff`, so the simulator
	@# must be built with the plain (non-difftest) config; otherwise
	@# init_difftest aborts with `ref_so_file != NULL`.
	@if [ ! -f $(RISCOF_NPC_BIN_32) ] || grep -q '^CONFIG_DIFFTEST=y' $(NSIM_HOME)/.config 2>/dev/null; then \
		echo "[riscof-classic] (Re)building NPC without difftest (RAPT_CONFIG=$(RAPT_CONFIG), BUILD_PROFILE=$(RISCOF_BUILD_PROFILE))..."; \
		$(MAKE) -C $(NSIM_HOME) o2_defconfig; \
	else \
		echo "[riscof-classic] NPC config OK (no difftest)."; \
	fi
	@$(MAKE) -C $(NSIM_HOME) $(SUBMAKE_JOBS) RAPT_CONFIG=$(RAPT_CONFIG) \
		BUILD_PROFILE=$(RISCOF_BUILD_PROFILE) VFLAGS=""
	@test -f $(RISCOF_NPC_BIN_32) || { echo "[riscof-classic] ERROR: NPC build failed: $(RISCOF_NPC_BIN_32)"; exit 1; }

riscof-classic-setup: ## Clone upstream riscv-arch-test suite
	@if [ ! -d "$(RISCOF_CLASSIC_SUITE)" ]; then \
		echo "[riscof-classic] Cloning riscv-non-isa/riscv-arch-test ($(RISCOF_CLASSIC_BRANCH))..."; \
		mkdir -p "$(RISCOF_CLASSIC_DIR)"; \
		git clone --depth 1 -b $(RISCOF_CLASSIC_BRANCH) https://github.com/riscv-non-isa/riscv-arch-test.git "$(RISCOF_CLASSIC_SUITE)"; \
	else echo "[riscof-classic] Suite already present at $(RISCOF_CLASSIC_SUITE)"; fi
	@if [ ! -x "$(RISCOF_CLASSIC_BIN)" ] && ! command -v riscof >/dev/null 2>&1; then \
		echo "[riscof-classic] 'riscof' not found; bootstrapping venv at $(RISCOF_CLASSIC_VENV)..."; \
		$(PYTHON) -m venv "$(RISCOF_CLASSIC_VENV)" || { echo "[riscof-classic] ERROR: python venv creation failed."; exit 1; }; \
		"$(RISCOF_CLASSIC_VENV)/bin/pip" install --quiet --upgrade pip && \
		"$(RISCOF_CLASSIC_VENV)/bin/pip" install --quiet riscof || { \
			echo "[riscof-classic] ERROR: pip install riscof failed (network?)."; \
			echo "  Manual fix: $(PYTHON) -m venv $(RISCOF_CLASSIC_VENV) && $(RISCOF_CLASSIC_VENV)/bin/pip install riscof"; \
			exit 1; }; \
	fi
	@SAIL_FOUND_VERSION=$$(sail_riscv_sim --version 2>/dev/null) \
		&& [ "$$SAIL_FOUND_VERSION" = "$(SAIL_VERSION)" ] \
		|| { echo "[riscof-classic] ERROR: Sail $(SAIL_VERSION) is required (found '$$SAIL_FOUND_VERSION')."; exit 1; }
	@sail_riscv_sim --rv32 --validate-config >/dev/null
	@echo "[riscof-classic] Setup complete."

riscof-classic-run: $(MROM_IMG) riscof-classic-build-npc ## Execute classic RISCOF flow
	@test -d "$(RISCOF_CLASSIC_SUITE)" || { echo "[riscof-classic] ERROR: suite not found. Run 'make riscof-classic-setup' first."; exit 1; }
	@# RISCOF's framework creates per-test dirs with os.mkdir() (no exist_ok),
	@# so a stale work-dir from a previous run crashes with FileExistsError.
	@# Wipe it before each run.
	rm -rf "$(RISCOF_CLASSIC_WORKDIR)"
	@mkdir -p "$(RISCOF_CLASSIC_WORKDIR)"
	@echo "================================================================"
	@echo "[riscof-classic] Running classic RISCOF flow"
	@echo "  NPC:     $(RISCOF_NPC_BIN_32)"
	@echo "  Suite:   $(RISCOF_CLASSIC_SUITE)"
	@echo "  Workdir: $(RISCOF_CLASSIC_WORKDIR)"
	@echo "================================================================"
	@$(PYTHON) "$(RISCOF_CLASSIC_ENV_PATCH)" \
		--env="$(RISCOF_CLASSIC_SUITE)/riscv-test-suite/env"
	cd "$(RISCOF_CLASSIC_DIR)" && \
		export NPC_BIN="$(RISCOF_NPC_BIN_32)" MROM_IMG="$(MROM_IMG)" \
			NSIM_HOME="$(NSIM_HOME)" RAPT_TIMEOUT="$(TIMEOUT)" \
			RAPT_JOBS="$(JOBS)" \
			RAPT_MEM_RANDOM_DELAY="$(MEM_RANDOM_DELAY)" \
			RAPT_MEM_RANDOM_SEED="$(MEM_RANDOM_SEED)"; \
		RISCOF_BIN="$(if $(wildcard $(RISCOF_CLASSIC_BIN)),$(RISCOF_CLASSIC_BIN),riscof)"; \
		"$$RISCOF_BIN" testlist \
			--config=config.ini \
			--suite=$(RISCOF_CLASSIC_SUITE)/riscv-test-suite/ \
			--env=$(RISCOF_CLASSIC_SUITE)/riscv-test-suite/env \
			--work-dir="$(RISCOF_CLASSIC_WORKDIR)" && \
		$(if $(wildcard $(RISCOF_CLASSIC_PYTHON)),$(RISCOF_CLASSIC_PYTHON),$(PYTHON)) "$(VERIFY_HOME)/scripts/filter_riscof_testlist.py" \
			--input="$(RISCOF_CLASSIC_TESTLIST)" \
			--output="$(RISCOF_CLASSIC_FILTERED_TESTLIST)" \
			--drop-legacy-ad && \
		export NPC_BIN="$(RISCOF_NPC_BIN_32)" MROM_IMG="$(MROM_IMG)" \
			NSIM_HOME="$(NSIM_HOME)" RAPT_TIMEOUT="$(TIMEOUT)" \
			RAPT_JOBS="$(JOBS)" \
			RAPT_MEM_RANDOM_DELAY="$(MEM_RANDOM_DELAY)" \
			RAPT_MEM_RANDOM_SEED="$(MEM_RANDOM_SEED)"; \
		"$$RISCOF_BIN" run \
			--config=config.ini \
			--suite=$(RISCOF_CLASSIC_SUITE)/riscv-test-suite/ \
			--env=$(RISCOF_CLASSIC_SUITE)/riscv-test-suite/env \
			--testfile="$(RISCOF_CLASSIC_FILTERED_TESTLIST)" \
			--work-dir="$(RISCOF_CLASSIC_WORKDIR)" \
			--no-browser
	@if ! grep -q 'class="col-result">Failed' "$(RISCOF_CLASSIC_WORKDIR)/report.html" 2>/dev/null; then \
		echo "[riscof-classic] PASS"; \
	else \
		echo "[riscof-classic] FAIL (see $(RISCOF_CLASSIC_WORKDIR)/report.html)"; \
		exit 1; \
	fi

riscof-classic-clean: ## Clean classic RISCOF artifacts
	rm -rf $(RISCOF_CLASSIC_WORKDIR)

# ============================================================================
# Classic RISCOF (NEMU as DUT)
# ============================================================================
# Runs the same riscv-arch-test compliance suite through NEMU (standalone
# executable) rather than the Raptor sim simulator. This verifies that
# NEMU itself passes the RISCOF suite and produces signatures byte-identical
# to sail_cSim, giving us confidence in the difftest reference model.
# Test suite is shared with the classic flow via symlink; workdir is
# separate so the two flows don't overwrite each other's results.
# ============================================================================
RISCOF_CLASSIC_NEMU_DIR     := $(VERIFY_HOME)/riscof/classic-nemu
RISCOF_CLASSIC_NEMU_SUITE   := $(RISCOF_CLASSIC_NEMU_DIR)/riscv-arch-test
RISCOF_CLASSIC_NEMU_WORKDIR := $(BUILD_DIR)/riscof-classic-nemu
RISCOF_CLASSIC_NEMU_TESTLIST := $(RISCOF_CLASSIC_NEMU_WORKDIR)/test_list.yaml
RISCOF_CLASSIC_NEMU_FILTERED_TESTLIST := $(BUILD_DIR)/riscof-classic-nemu.raptor-test_list.yaml
NEMU_BIN_32  := $(NEMU_HOME)/build/riscv32-nemu-interpreter
NEMU_BIN_64  := $(NEMU_HOME)/build/riscv64-nemu-interpreter

ifeq ($(ISA),rv64)
  NEMU_BIN := $(NEMU_BIN_64)
else
  NEMU_BIN := $(NEMU_BIN_32)
endif

.PHONY: riscof-classic-nemu riscof-classic-nemu-setup riscof-classic-nemu-run riscof-classic-nemu-clean riscof-classic-build-nemu

$(NEMU_BIN_32):
	@echo "[riscof-classic-nemu] Building NEMU standalone executable (rv32)..."
	$(MAKE) -C $(RAPTOR_HOME) config-nemu32

$(NEMU_BIN_64):
	@echo "[riscof-classic-nemu] Building NEMU standalone executable (rv64)..."
	+$(MAKE) -C $(NEMU_HOME) riscv64_defconfig
	+$(MAKE) -C $(NEMU_HOME) $(SUBMAKE_JOBS)

riscof-classic-build-nemu: ## Build NEMU standalone executable for classic RISCOF
ifeq ($(ISA),rv64)
	@echo "[riscof-classic-nemu] Building NEMU standalone executable (rv64)..."
	+$(MAKE) -C $(NEMU_HOME) riscv64_defconfig
	+$(MAKE) -C $(NEMU_HOME) $(SUBMAKE_JOBS)
else
	@echo "[riscof-classic-nemu] Building NEMU standalone executable (rv32)..."
	$(MAKE) -C $(RAPTOR_HOME) config-nemu32
endif
	@test -f $(NEMU_BIN) || { echo "[riscof-classic-nemu] ERROR: NEMU build failed: $(NEMU_BIN)"; exit 1; }

riscof-classic-nemu: riscof-classic-nemu-setup riscof-classic-nemu-run ## Run classic RISCOF flow against NEMU

riscof-classic-nemu-setup: riscof-classic-setup riscof-classic-build-nemu ## Ensure NEMU and the arch-test suite are ready
	@mkdir -p "$(RISCOF_CLASSIC_NEMU_DIR)"
	@if [ ! -e "$(RISCOF_CLASSIC_NEMU_SUITE)" ]; then \
		ln -s ../classic/riscv-arch-test "$(RISCOF_CLASSIC_NEMU_SUITE)"; \
		echo "[riscof-classic-nemu] Linked shared architecture test suite"; \
	fi
	@test -L "$(RISCOF_CLASSIC_NEMU_SUITE)" || { \
		echo "[riscof-classic-nemu] ERROR: missing symlink $(RISCOF_CLASSIC_NEMU_SUITE) -> ../classic/riscv-arch-test"; \
		exit 1; }
	@test -x "$(RISCOF_CLASSIC_BIN)" || command -v riscof >/dev/null 2>&1 || { echo "[riscof-classic-nemu] ERROR: 'riscof' not found."; exit 1; }
	@SAIL_FOUND_VERSION=$$(sail_riscv_sim --version 2>/dev/null) \
		&& [ "$$SAIL_FOUND_VERSION" = "$(SAIL_VERSION)" ] \
		|| { echo "[riscof-classic-nemu] ERROR: Sail $(SAIL_VERSION) is required (found '$$SAIL_FOUND_VERSION')."; exit 1; }
	@echo "[riscof-classic-nemu] Setup complete. NEMU_BIN=$(NEMU_BIN)"

riscof-classic-nemu-run: $(NEMU_BIN) ## Execute classic RISCOF flow with NEMU as DUT
	@test -d "$(RISCOF_CLASSIC_NEMU_SUITE)" || { echo "[riscof-classic-nemu] ERROR: suite not found. Run 'make riscof-classic-setup' first."; exit 1; }
	@# Same FileExistsError guard as riscof-classic-run: wipe stale work-dir.
	rm -rf "$(RISCOF_CLASSIC_NEMU_WORKDIR)"
	@mkdir -p "$(RISCOF_CLASSIC_NEMU_WORKDIR)"
	@echo "================================================================"
	@echo "[riscof-classic-nemu] Running classic RISCOF flow (NEMU as DUT)"
	@echo "  NEMU:    $(NEMU_BIN)"
	@echo "  Suite:   $(RISCOF_CLASSIC_NEMU_SUITE)"
	@echo "  Workdir: $(RISCOF_CLASSIC_NEMU_WORKDIR)"
	@echo "================================================================"
	@$(PYTHON) "$(RISCOF_CLASSIC_ENV_PATCH)" \
		--env="$(RISCOF_CLASSIC_NEMU_SUITE)/riscv-test-suite/env"
	cd "$(RISCOF_CLASSIC_NEMU_DIR)" && \
		export NEMU_BIN="$(NEMU_BIN)" NEMU_HOME="$(NEMU_HOME)" \
			RAPT_TIMEOUT="$(TIMEOUT)"; \
		RISCOF_BIN="$(if $(wildcard $(RISCOF_CLASSIC_BIN)),$(RISCOF_CLASSIC_BIN),riscof)"; \
		"$$RISCOF_BIN" testlist \
			--config=config.ini \
			--suite=$(RISCOF_CLASSIC_NEMU_SUITE)/riscv-test-suite/ \
			--env=$(RISCOF_CLASSIC_NEMU_SUITE)/riscv-test-suite/env \
			--work-dir="$(RISCOF_CLASSIC_NEMU_WORKDIR)" && \
		$(if $(wildcard $(RISCOF_CLASSIC_PYTHON)),$(RISCOF_CLASSIC_PYTHON),$(PYTHON)) "$(VERIFY_HOME)/scripts/filter_riscof_testlist.py" \
			--input="$(RISCOF_CLASSIC_NEMU_TESTLIST)" \
			--output="$(RISCOF_CLASSIC_NEMU_FILTERED_TESTLIST)" \
			--drop-legacy-ad && \
		"$$RISCOF_BIN" run \
			--config=config.ini \
			--suite=$(RISCOF_CLASSIC_NEMU_SUITE)/riscv-test-suite/ \
			--env=$(RISCOF_CLASSIC_NEMU_SUITE)/riscv-test-suite/env \
			--testfile="$(RISCOF_CLASSIC_NEMU_FILTERED_TESTLIST)" \
			--work-dir="$(RISCOF_CLASSIC_NEMU_WORKDIR)" \
			--no-browser
	@if grep -q '>0Failed<' "$(RISCOF_CLASSIC_NEMU_WORKDIR)/report.html" 2>/dev/null; then \
		echo "[riscof-classic-nemu] PASS"; \
	else \
		echo "[riscof-classic-nemu] FAIL (see $(RISCOF_CLASSIC_NEMU_WORKDIR)/report.html)"; \
		exit 1; \
	fi

riscof-classic-nemu-clean: ## Clean classic-nemu RISCOF artifacts
	rm -rf $(RISCOF_CLASSIC_NEMU_WORKDIR)

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
COV_PK_TIMEOUT      ?= 600## Wall-clock timeout for each pk coverage workload
COV_COREMARK_ITERATIONS ?= 1## Coverage needs one CoreMark control-flow pass
COV_MEMTEST_WORDS   ?= 512## Run all memtest algorithms on a coverage-sized buffer
COV_IRQ_REPEATS     ?= 12## Repeat short directed IRQ tests past coverage hit threshold
COV_LINE_MIN        ?= 80.0## Minimum accepted aggregate HDL line coverage
COV_BUILD_PROFILE   ?= $(RAPT_CONFIG)-coverage## Isolate instrumented NPC artifacts
COV_NPC_BIN         := $(NSIM_HOME)/build/$(COV_BUILD_PROFILE)/$(if $(filter rv64,$(ISA)),riscv64,riscv32)-npc-sim

define RUN_AND_SAVE_COVERAGE
	@echo "[coverage] Running $(1) workload..."
	@set -o pipefail; \
		raw_dir="$(COV_DIR)/raw/$(1)"; status=0; \
		rm -rf "$$raw_dir"; mkdir -p "$$raw_dir"; \
		rm -f $(NSIM_HOME)/coverage*.dat $(VERIFY_HOME)/coverage*.dat; \
		RAPT_COVERAGE_DIR="$$raw_dir" $(2) 2>&1 \
			| tee "$(COV_DIR)/$(1).log" || status=$$?; \
		shopt -s nullglob; coverage_files=("$$raw_dir"/*.dat); \
		if [ $${#coverage_files[@]} -gt 0 ]; then \
			if verilator_coverage --write "$(COV_DIR)/coverage_$(1).dat" \
				"$${coverage_files[@]}"; then \
				echo "[coverage] Merged $${#coverage_files[@]} run(s): $(COV_DIR)/coverage_$(1).dat"; \
			else \
				echo "[coverage] ERROR: failed to merge $(1) data"; status=1; \
			fi; \
		elif [ -f "$(NSIM_HOME)/coverage.dat" ]; then \
			cp "$(NSIM_HOME)/coverage.dat" "$(COV_DIR)/coverage_$(1).dat"; \
			echo "[coverage] Saved: $(COV_DIR)/coverage_$(1).dat"; \
		elif [ -f "$(VERIFY_HOME)/coverage.dat" ]; then \
			cp "$(VERIFY_HOME)/coverage.dat" "$(COV_DIR)/coverage_$(1).dat"; \
			echo "[coverage] Saved: $(COV_DIR)/coverage_$(1).dat"; \
		else \
			echo "[coverage] ERROR: $(1) did not produce coverage data"; status=1; \
		fi; \
		exit $$status
endef

.PHONY: coverage coverage-build coverage-run coverage-run-coremark \
	coverage-run-coremark-pk coverage-run-hello-pk coverage-run-isa-tests-pk \
	coverage-run-memory-pk coverage-run-algo-pk coverage-run-security-pk \
	coverage-run-microbench coverage-run-fp coverage-run-fp-directed \
	coverage-run-irq coverage-run-jtag coverage-run-fuzz coverage-run-sigtest \
	coverage-report coverage-clean check-coverage-bin

coverage: coverage-build ## Full coverage flow
	@status=0; \
		$(MAKE) --no-print-directory coverage-run || status=$$?; \
		$(MAKE) --no-print-directory coverage-report || status=$$?; \
		exit $$status

COV_VERILATOR_EXTRA := --coverage-line -Wno-UNOPTFLAT

coverage-build: ## Build NPC with coverage instrumentation
	@echo "[coverage] Building NPC with --coverage-line..."
	@rm -rf $(NSIM_HOME)/build/$(COV_BUILD_PROFILE)/obj_dir* $(NSIM_HOME)/build/$(COV_BUILD_PROFILE)/riscv*-npc-*
	$(MAKE) -C $(NSIM_HOME) o2_difftest_defconfig RAPT_CONFIG=$(RAPT_CONFIG)
	# Coverage build: disable RTL SVA (RAPT_SIM_ASSERT=0) and use line-only
	# coverage. `--coverage-toggle` was observed to crash the simulator on CI
	# during microbench (queen) due to combined memory pressure with toggle
	# counters on a design that has UNOPTFLAT loops. Line coverage is enough
	# to track structural coverage of RTL.
	+$(MAKE) -C $(NSIM_HOME) $(SUBMAKE_JOBS) RAPT_CONFIG=$(RAPT_CONFIG) BUILD_PROFILE=$(COV_BUILD_PROFILE) \
		VFLAGS="$(VFLAGS)" RAPT_SIM_ASSERT=0 \
		VERILATOR_EXTRA="$(COV_VERILATOR_EXTRA)"

coverage-run: ## Run test suite to collect coverage
	@mkdir -p $(COV_DIR)
	@rm -rf $(COV_DIR)/raw
	@rm -f $(COV_DIR)/coverage_*.dat $(COV_DIR)/coverage.dat \
		$(NSIM_HOME)/coverage*.dat $(VERIFY_HOME)/coverage*.dat
	@echo "================================================================"
	@echo "[coverage] Running tests to collect coverage"
	@echo "  ISA:    $(ISA)"
	@echo "  Output: $(COV_DIR)"
	@echo "================================================================"
	@status=0; failed=""; \
		for target in coverage-run-coremark coverage-run-coremark-pk \
			coverage-run-hello-pk coverage-run-isa-tests-pk \
			coverage-run-memory-pk coverage-run-algo-pk coverage-run-security-pk \
			coverage-run-microbench coverage-run-fp coverage-run-fp-directed \
			coverage-run-irq coverage-run-jtag \
			coverage-run-fuzz coverage-run-sigtest; do \
			if ! $(MAKE) --no-print-directory "$$target"; then \
				status=1; failed="$$failed $${target#coverage-run-}"; \
			fi; \
		done; \
		if [ $$status -eq 0 ]; then \
			echo "[coverage] All workloads completed successfully."; \
		else \
			echo "[coverage] Workloads with failures:$$failed"; \
		fi; \
		exit $$status
	@ls -la "$(COV_DIR)/"coverage_*.dat 2>/dev/null || echo "[coverage] No coverage_*.dat files found (coverage build may be needed)"

# app/ (pk mode) ISA64 flag: rv64 -> 1, rv32 -> empty (unset)
APP_ISA64 := $(if $(filter rv64,$(ISA)),1,)

# All coverage-run-* targets must propagate the same simulation and Verilator
# flags that `coverage-build` used. Recursive workload Makefiles can otherwise
# rebuild the simulator without coverage instrumentation.
COV_PASS_ENV := RAPT_CONFIG=$(RAPT_CONFIG) BUILD_PROFILE=$(COV_BUILD_PROFILE) \
	NPC_BIN=$(COV_NPC_BIN) PK_BUILD_PROFILE=coverage \
	RAPT_SIM_ASSERT=0 SKIP_CONFIG_INVALIDATION=1 \
	VERILATOR_EXTRA="$(COV_VERILATOR_EXTRA)"

# Sanity check that the expected NPC sim binary exists. The workload sub-make
# (am-kernels / app) ultimately invokes `make -C sim run`, which picks
# whichever simulator variant is built per the current `sim/.config`. If the
# user has `CONFIG_ysyxSoC=y` left over from a previous session, only
# `riscv32-npc-soc` exists and loading an `riscv32-npc` binary into it fails
# (wrong memory map). Guard the per-workload runners so they fail fast.
.PHONY: check-coverage-bin
check-coverage-bin:
	@if [ ! -x "$(COV_NPC_BIN)" ]; then \
		echo "[coverage] ERROR: simulator $(COV_NPC_BIN) not found."; \
		echo "[coverage]        Run 'make -C verify coverage-build' first"; \
		echo "[coverage]        (the current sim/.config may be a non-NPC variant, e.g. ysyxSoC)."; \
		exit 1; \
	fi

coverage-run-coremark: check-coverage-bin ## Run only coremark coverage workload
	$(MAKE) -C $(AM_KERNELS)/benchmarks/coremark_eembc ARCH=$(NPC_ARCH_COV) clean
	$(call RUN_AND_SAVE_COVERAGE,coremark,$(MAKE) -C $(AM_KERNELS)/benchmarks/coremark_eembc ARCH=$(NPC_ARCH_COV) run ITERATIONS=$(COV_COREMARK_ITERATIONS) ARGS="-b -n -t $(COV_PK_TIMEOUT)" VFLAGS="$(VFLAGS)" $(COV_PASS_ENV))

coverage-run-coremark-pk: check-coverage-bin ## Run coremark under pk (app/) for coverage
	$(MAKE) -C $(RAPTOR_HOME)/app/benchmarks/coremark ISA64=$(APP_ISA64) clean
	$(call RUN_AND_SAVE_COVERAGE,coremark-pk,$(MAKE) -C $(RAPTOR_HOME)/app coremark-sim ISA64=$(APP_ISA64) ITERATIONS=$(COV_COREMARK_ITERATIONS) ARGS="-b -n -t $(COV_PK_TIMEOUT)" VFLAGS="$(VFLAGS)" $(COV_PASS_ENV) DIFF_REF_SO=)

coverage-run-hello-pk: check-coverage-bin ## Run hello under pk (app/) for coverage
	$(call RUN_AND_SAVE_COVERAGE,hello-pk,$(MAKE) -C $(RAPTOR_HOME)/app hello-sim ISA64=$(APP_ISA64) ARGS="-b -n -t $(COV_PK_TIMEOUT)" VFLAGS="$(VFLAGS)" $(COV_PASS_ENV) DIFF_REF_SO=)

coverage-run-isa-tests-pk: check-coverage-bin ## Run ISA tests under pk (app/) for coverage
	$(call RUN_AND_SAVE_COVERAGE,isa-tests-pk,$(MAKE) -C $(RAPTOR_HOME)/app isa-tests-sim ISA64=$(APP_ISA64) ARGS="-b -n -t $(COV_PK_TIMEOUT)" VFLAGS="$(VFLAGS)" $(COV_PASS_ENV) DIFF_REF_SO=)

coverage-run-memory-pk: check-coverage-bin ## Run memory subsystem tests under pk
	$(MAKE) -C $(RAPTOR_HOME)/app/tests/memory clean
	$(call RUN_AND_SAVE_COVERAGE,memory-pk,$(MAKE) -C $(RAPTOR_HOME)/app memory-tests-sim ISA64=$(APP_ISA64) MEMTEST_WORDS=$(COV_MEMTEST_WORDS) ARGS="-b -n -t $(COV_PK_TIMEOUT)" VFLAGS="$(VFLAGS)" $(COV_PASS_ENV) DIFF_REF_SO=)

coverage-run-algo-pk: check-coverage-bin ## Run algorithm tests under pk
	$(call RUN_AND_SAVE_COVERAGE,algo-pk,$(MAKE) -C $(RAPTOR_HOME)/app algo-tests-sim ISA64=$(APP_ISA64) ARGS="-b -n -t $(COV_PK_TIMEOUT)" VFLAGS="$(VFLAGS)" $(COV_PASS_ENV) DIFF_REF_SO=)

coverage-run-security-pk: check-coverage-bin ## Run cache and speculation tests under pk
	$(call RUN_AND_SAVE_COVERAGE,security-pk,$(MAKE) -C $(RAPTOR_HOME)/app security-tests-sim ISA64=$(APP_ISA64) SECURITY_SIM_FAST=1 ARGS="-b -n -t $(COV_PK_TIMEOUT)" VFLAGS="$(VFLAGS)" $(COV_PASS_ENV) DIFF_REF_SO=)


coverage-run-microbench: check-coverage-bin ## Run only microbench coverage workload
	$(call RUN_AND_SAVE_COVERAGE,microbench,$(MAKE) -C $(AM_KERNELS)/benchmarks/microbench ARCH=$(NPC_ARCH_COV) run ARGS="-b -n -t $(COV_PK_TIMEOUT)" mainargs=$(COV_MICROBENCH_ARGS) VFLAGS="$(VFLAGS)" $(COV_PASS_ENV))

FP_COVERAGE_TARGETS := npc-arith npc-d-arith npc-minmax npc-compare \
	npc-convert npc-fma npc-divsqrt npc-fcsr npc-rm-illegal npc-fs \
	npc-fs-mem npc-compressed-mem

coverage-run-fp: check-coverage-bin ## Run RV32 F/D architectural tests for FEU coverage
	$(call RUN_AND_SAVE_COVERAGE,fp,$(MAKE) -C $(RAPTOR_HOME)/app/tests/fp \
		ISA=rv32 NPC_VFLAGS= NPC_ARGS="-b -n -t 60 --no-lightsss" \
		$(COV_PASS_ENV) $(FP_COVERAGE_TARGETS))

coverage-run-fp-directed: check-coverage-bin ## Run directed S/D/H floating-point coverage
	$(call RUN_AND_SAVE_COVERAGE,fp-directed,$(MAKE) -C $(RAPTOR_HOME)/app/tests/fp \
		ISA=rv32 NPC_VFLAGS= NPC_ARGS="-b -n -t 60 --no-lightsss" \
		$(COV_PASS_ENV) npc-coverage)

coverage-run-irq: check-coverage-bin ## Run directed PLIC/CLINT/PMP/interrupt paths
	$(call RUN_AND_SAVE_COVERAGE,irq,$(MAKE) -C $(RAPTOR_HOME)/app/tests/irq \
		ISA64=0 IRQ_REPEATS=$(COV_IRQ_REPEATS) \
		NPC_ARGS="-b -n -t 30 --no-lightsss --trap-on-ebreak" \
		$(COV_PASS_ENV) npc-coverage)

coverage-run-jtag: check-coverage-bin ## Run DTM/DM compliance probe for debug coverage
	$(call RUN_AND_SAVE_COVERAGE,jtag,$(COV_NPC_BIN) --jtag-selftest \
		+verilator+coverage+file+$(COV_DIR)/raw/jtag/coverage-jtag.dat)

coverage-run-fuzz: check-coverage-bin ## Run only fuzz coverage workload
	$(call RUN_AND_SAVE_COVERAGE,fuzz,$(MAKE) --no-print-directory fuzz SEED=$(COV_FUZZ_SEED) FUZZ_NUM=$(COV_FUZZ_NUM) FUZZ_LEN=$(COV_FUZZ_LEN) TIMEOUT=$(TIMEOUT) $(COV_PASS_ENV))

coverage-run-sigtest: check-coverage-bin ## Run only sigtest coverage workload
	$(call RUN_AND_SAVE_COVERAGE,sigtest,$(MAKE) --no-print-directory sigtest TIMEOUT=$(TIMEOUT) $(COV_PASS_ENV))

coverage-report: ## Generate coverage report
	@echo "[coverage] Generating report..."
	@if ls $(COV_DIR)/coverage_*.dat 1>/dev/null 2>&1; then \
		verilator_coverage --write $(COV_DIR)/merged.dat \
			$(COV_DIR)/coverage_*.dat; \
		verilator_coverage --report summary $(COV_DIR)/merged.dat \
			| tee $(COV_DIR)/summary.log; \
		verilator_coverage --annotate $(COV_DIR)/annotated \
			$(COV_DIR)/merged.dat 2>/dev/null; \
		echo "[coverage] Report at $(COV_DIR)/annotated/"; \
		line_pct=$$(awk '/^[[:space:]]*line[[:space:]]*:/ { gsub(/%/, "", $$3); print $$3 }' $(COV_DIR)/summary.log); \
		awk -v actual="$$line_pct" -v minimum="$(COV_LINE_MIN)" \
			'BEGIN { if (actual + 0 < minimum + 0) { printf "[coverage] ERROR: HDL line coverage %.1f%% is below %.1f%%\n", actual, minimum; exit 1 } printf "[coverage] HDL line coverage %.1f%% meets %.1f%% minimum\n", actual, minimum }'; \
	else \
		echo "[coverage] No coverage_*.dat files found. Run coverage-run first."; \
		exit 1; \
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
		set +e; $(TIMEOUT_RUN) $(TIMEOUT) $(NPC_BIN) -b -n $(NPC_MEM_ARGS) -d $(NEMU_SO) -r $(MROM_IMG) "$$bin" </dev/null >"$$log" 2>&1; \
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

.PHONY: formal formal-setup formal-bus formal-ieu-alu formal-ieu-mul \
	formal-pmp formal-plru formal-rnu-maptable formal-clint formal-plic formal-dtm formal-divsqrt \
	formal-rvfi formal-rvfi-gen formal-rvfi-check formal-rvfi-clean formal-clean

formal-setup: ## Install oss-cad-suite (yosys, sby, solvers)
	$(MAKE) -C $(FORMAL_DIR) setup

formal-bus: ## Formal: verify AXI bus properties
	$(MAKE) -C $(FORMAL_DIR) formal_bus

formal-ieu-mul: ## Formal: verify IEU multiplier
	$(MAKE) -C $(FORMAL_DIR) formal_ieu_mul

formal-ieu-alu: ## Formal: verify RV32 IEU ALU and bit-manipulation operations
	$(MAKE) -C $(FORMAL_DIR) formal_ieu_alu

formal-pmp: ## Formal: verify RV32/RV64 PMP matching and permissions
	$(MAKE) -C $(FORMAL_DIR) formal_pmp

formal-plru: ## Formal: verify 2/4/8-way PLRU replacement
	$(MAKE) -C $(FORMAL_DIR) formal_plru

formal-rnu-maptable: ## Formal: verify rename MAP/RAT recovery and WAW priority
	$(MAKE) -C $(FORMAL_DIR) formal_rnu_maptable

formal-clint: ## Formal: verify CLINT timer and software-interrupt semantics
	$(MAKE) -C $(FORMAL_DIR) formal_clint

formal-plic: ## Formal: verify PLIC arbitration and gateway lifecycle
	$(MAKE) -C $(FORMAL_DIR) formal_plic

formal-dtm: ## Formal: verify the single-clock JTAG TAP and DMI transport
	$(MAKE) -C $(FORMAL_DIR) formal_dtm

formal-divsqrt: ## Formal: verify FPU divide/square-root control contract
	$(MAKE) -C $(FORMAL_DIR) formal_divsqrt

formal: formal-ieu-alu formal-ieu-mul formal-pmp formal-plru \
	formal-rnu-maptable formal-clint formal-plic formal-dtm formal-bus formal-divsqrt ## Run all standalone formal checks

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
# FPU Component Verification (Verilator)
# ============================================================================
FPU_TB_DIR := $(VERIFY_HOME)/xsim/fpu

.PHONY: unit-fpu unit-fpu-addsub unit-fpu-mul unit-fpu-fma \
	unit-fpu-convert unit-fpu-int-to-fp unit-fpu-half unit-fpu-divsqrt unit-clean

unit-fpu: ## Unit: run all FPU RTL component tests
	$(MAKE) -C $(FPU_TB_DIR) all

unit-fpu-addsub: ## Unit: run FPU add/sub differential test
	$(MAKE) -C $(FPU_TB_DIR) addsub

unit-fpu-mul: ## Unit: run FPU multiply differential test
	$(MAKE) -C $(FPU_TB_DIR) mul

unit-fpu-fma: ## Unit: run FPU FMA directed regression
	$(MAKE) -C $(FPU_TB_DIR) fma

unit-fpu-convert: ## Unit: run FPU format-conversion differential test
	$(MAKE) -C $(FPU_TB_DIR) convert

unit-fpu-int-to-fp: ## Unit: run integer-to-FP differential test
	$(MAKE) -C $(FPU_TB_DIR) int_to_fp

unit-fpu-divsqrt: ## Unit: run FPU divide/sqrt differential test
	$(MAKE) -C $(FPU_TB_DIR) divsqrt

unit-fpu-half: ## Unit: verify Zfhmin binary16 conversions and NaN boxing
	$(MAKE) -C $(FPU_TB_DIR) half

unit-clean: ## Unit: clean RTL unit-test artifacts
	$(MAKE) -C $(FPU_TB_DIR) clean

# ============================================================================
# JTAG / RISC-V Debug verification
# ============================================================================
# Layer 1 (selftest)  - 23-point in-tree DTM/DM compliance probe (runs today).
# Layer 2 (debug-tests) - upstream riscv-tests/debug GDB suite (P1-blocked;
#                          target prints a checklist and exits 1 until the
#                          OpenOCD bridge + halt/resume infra exists).
# See verify/jtag/README.md for the full coverage matrix and gap list.
JTAG_DIR := $(VERIFY_HOME)/jtag

.PHONY: jtag jtag-selftest jtag-debug-tests-setup jtag-debug-tests jtag-clean

jtag: jtag-selftest ## Run the JTAG default verification (= jtag-selftest)

jtag-selftest: ## JTAG: 23-point DTM/DM compliance probe (no NEMU needed)
	$(MAKE) -C $(JTAG_DIR) selftest

jtag-debug-tests-setup: ## JTAG: clone upstream riscv-tests/debug suite
	$(MAKE) -C $(JTAG_DIR) debug-tests-setup

jtag-debug-tests: ## JTAG: run upstream debug suite (BLOCKED, see verify/jtag/README.md)
	$(MAKE) -C $(JTAG_DIR) debug-tests

jtag-clean: ## JTAG: clean cloned riscv-tests + scratch artifacts
	$(MAKE) -C $(JTAG_DIR) clean

# ============================================================================
# UVM Module Verification
# ============================================================================
UVM_DIR := $(VERIFY_HOME)/uvm
UVM_BUILD_DIR := $(BUILD_DIR)/uvm
UVM_RAPT_CONFIG ?= default
UVM_CYCLES ?= 500## Random issue-queue cycles (for a class-capable simulator)

UVM_COMMON_INCLUDES := \
	-i "$(RAPTOR_HOME)/hdl/configs/$(UVM_RAPT_CONFIG)" \
	-i "$(RAPTOR_HOME)/hdl/include" \
	-i "$(RAPTOR_HOME)/hdl/include/dpic_mock" \
	-i "$(RAPTOR_HOME)/hdl/include/npc"

UVM_IQ_SOURCES := \
	"$(RAPTOR_HOME)/hdl/rapt_pkg.sv" \
	"$(UVM_DIR)/iq/rapt_iq_uvm_if.sv" \
	"$(UVM_DIR)/iq/rapt_iq_uvm_pkg.sv" \
	"$(RAPTOR_HOME)/hdl/backend/rapt_iq.sv" \
	"$(UVM_DIR)/iq/tb_rapt_iq_uvm.sv"

UVM_CSR_SOURCES := \
	"$(RAPTOR_HOME)/hdl/rapt_pkg.sv" \
	"$(UVM_DIR)/csr/rapt_csr_uvm_if.sv" \
	"$(UVM_DIR)/csr/rapt_csr_uvm_pkg.sv" \
	"$(RAPTOR_HOME)/hdl/frontend/rapt_csr.sv" \
	"$(UVM_DIR)/csr/tb_rapt_csr_uvm.sv"

.PHONY: uvm uvm-smoke uvm-iq-compile uvm-csr-sret uvm-clean

uvm: uvm-smoke uvm-iq-compile uvm-csr-sret ## UVM: run module-level UVM verification

uvm-smoke: ## UVM: run a minimal UVM 1.2 test on XSim
	@set -e; \
	if ! command -v xvlog >/dev/null 2>&1 && [ -f "$(VIVADO_SETTINGS)" ]; then source "$(VIVADO_SETTINGS)"; fi; \
	command -v xvlog >/dev/null 2>&1 || { echo "[uvm] ERROR: xvlog not found"; exit 1; }; \
	rm -rf "$(UVM_BUILD_DIR)/smoke"; mkdir -p "$(UVM_BUILD_DIR)/smoke"; \
	cd "$(UVM_BUILD_DIR)/smoke"; \
	xvlog -sv --uvm_version 1.2 -L uvm "$(UVM_DIR)/xsim_uvm_smoke.sv"; \
	xelab -mt off -L uvm xsim_uvm_smoke -s xsim_uvm_smoke_sim; \
	xsim xsim_uvm_smoke_sim -testplusarg UVM_NO_RELNOTES -runall

uvm-iq-compile: ## UVM: compile the IQ agent, sequences, scoreboard, coverage, and DUT
	@set -e; \
	if ! command -v xvlog >/dev/null 2>&1 && [ -f "$(VIVADO_SETTINGS)" ]; then source "$(VIVADO_SETTINGS)"; fi; \
	command -v xvlog >/dev/null 2>&1 || { echo "[uvm] ERROR: xvlog not found"; exit 1; }; \
	rm -rf "$(UVM_BUILD_DIR)/iq"; mkdir -p "$(UVM_BUILD_DIR)/iq"; \
	cd "$(UVM_BUILD_DIR)/iq"; \
	xvlog -sv --uvm_version 1.2 -L uvm -d RAPT_ASSERT_EN \
		$(UVM_COMMON_INCLUDES) $(UVM_IQ_SOURCES); \
	echo "[uvm] IQ environment compiled. See uvm/README.md for simulator support."

uvm-csr-sret: ## UVM: stress Linux-shaped U-ecall/SRET and mtvec contamination
	@set -e; \
	if ! command -v xvlog >/dev/null 2>&1 && [ -f "$(VIVADO_SETTINGS)" ]; then source "$(VIVADO_SETTINGS)"; fi; \
	command -v xvlog >/dev/null 2>&1 || { echo "[uvm] ERROR: xvlog not found"; exit 1; }; \
	rm -rf "$(UVM_BUILD_DIR)/csr"; mkdir -p "$(UVM_BUILD_DIR)/csr"; \
	cd "$(UVM_BUILD_DIR)/csr"; \
	xvlog -sv --uvm_version 1.2 -L uvm -d RAPT_ASSERT_EN \
		$(UVM_COMMON_INCLUDES) $(UVM_CSR_SOURCES); \
	xelab -mt off -L uvm tb_rapt_csr_uvm -s tb_rapt_csr_uvm_sim; \
	xsim tb_rapt_csr_uvm_sim -testplusarg UVM_NO_RELNOTES -testplusarg ntb_random_seed=1 -runall; \
	! grep -Eq "UVM_(ERROR|FATAL) *: *[1-9]|FAIL:" xsim.log

uvm-clean: ## UVM: clean module-level UVM artifacts
	rm -rf $(UVM_BUILD_DIR)

# ============================================================================
# Vivado xsim Directed Checks
# ============================================================================
XSIM_DIR := $(VERIFY_HOME)/xsim
XSIM_BUILD_DIR := $(BUILD_DIR)/xsim
XSIM_RAPT_CONFIG ?= default
VIVADO_SETTINGS ?= /opt/Xilinx/2025.2/Vivado/settings64.sh

XSIM_COMMON_INCLUDES := \
	-i "$(RAPTOR_HOME)/hdl/configs/$(XSIM_RAPT_CONFIG)" \
	-i "$(RAPTOR_HOME)/hdl/include" \
	-i "$(RAPTOR_HOME)/hdl/include/dpic_mock" \
	-i "$(RAPTOR_HOME)/hdl/include/npc" \
	-i "$(XSIM_DIR)"

XSIM_L2_SOURCES := \
	"$(RAPTOR_HOME)/hdl/rapt_pkg.sv" \
	"$(RAPTOR_HOME)/hdl/memory/rapt_sram_1rw.sv" \
	"$(RAPTOR_HOME)/hdl/memory/rapt_l2.sv"

XSIM_L1D_SOURCES := \
	"$(RAPTOR_HOME)/hdl/rapt_pkg.sv" \
	"$(RAPTOR_HOME)/hdl/memory/rapt_sram_1rw.sv" \
	"$(RAPTOR_HOME)/hdl/memory/rapt_pmp.sv" \
	"$(RAPTOR_HOME)/hdl/memory/rapt_tlb.sv" \
	"$(RAPTOR_HOME)/hdl/memory/rapt_ptw.sv" \
	"$(RAPTOR_HOME)/hdl/memory/rapt_l1d.sv"

XSIM_L1I_SOURCES := \
	"$(RAPTOR_HOME)/hdl/rapt_pkg.sv" \
	"$(RAPTOR_HOME)/hdl/memory/rapt_sram_1rw.sv" \
	"$(RAPTOR_HOME)/hdl/memory/rapt_l1i_tagmem.sv" \
	"$(RAPTOR_HOME)/hdl/memory/rapt_plru.sv" \
	"$(RAPTOR_HOME)/hdl/memory/rapt_pmp.sv" \
	"$(RAPTOR_HOME)/hdl/memory/rapt_tlb.sv" \
	"$(RAPTOR_HOME)/hdl/memory/rapt_ptw.sv" \
	"$(RAPTOR_HOME)/hdl/memory/rapt_l1i.sv"

XSIM_PTW_SOURCES := \
	"$(RAPTOR_HOME)/hdl/rapt_pkg.sv" \
	"$(RAPTOR_HOME)/hdl/memory/rapt_ptw.sv"

XSIM_IDU_SOURCES := \
	"$(RAPTOR_HOME)/hdl/rapt_pkg.sv" \
	"$(RAPTOR_HOME)/hdl/generated/rapt_idu_decoder.sv" \
	"$(RAPTOR_HOME)/hdl/generated/rapt_idu_decoder_c.sv" \
	"$(RAPTOR_HOME)/hdl/frontend/rapt_idu.sv"

XSIM_TLB_SOURCES := \
	"$(RAPTOR_HOME)/hdl/rapt_pkg.sv" \
	"$(RAPTOR_HOME)/hdl/memory/rapt_tlb.sv"

XSIM_BUS_SOURCES := \
	"$(RAPTOR_HOME)/hdl/rapt_pkg.sv" \
	"$(RAPTOR_HOME)/hdl/memory/rapt_bus.sv" \
	"$(RAPTOR_HOME)/hdl/memory/rapt_axi_master.sv"

XSIM_CSR_SOURCES := \
	"$(RAPTOR_HOME)/hdl/rapt_pkg.sv" \
	"$(RAPTOR_HOME)/hdl/memory/rapt_pmp.sv" \
	"$(RAPTOR_HOME)/hdl/frontend/rapt_csr.sv"

XSIM_IOQ_SOURCES := \
	"$(RAPTOR_HOME)/hdl/rapt_pkg.sv" \
	"$(RAPTOR_HOME)/hdl/memory/rapt_pmp.sv" \
	"$(RAPTOR_HOME)/hdl/backend/lsu/rapt_lsu_ioq.sv"

XSIM_LSU_SOURCES := \
	"$(RAPTOR_HOME)/hdl/rapt_pkg.sv" \
	"$(RAPTOR_HOME)/hdl/memory/rapt_pmp.sv" \
	"$(RAPTOR_HOME)/hdl/backend/lsu/rapt_lsu_sq.sv"

XSIM_ROU_SOURCES := \
	"$(RAPTOR_HOME)/hdl/rapt_pkg.sv" \
	"$(RAPTOR_HOME)/hdl/backend/rapt_rou.sv" \
	"$(RAPTOR_HOME)/hdl/backend/rapt_cmu.sv"

XSIM_MULDIV_SOURCES := \
	"$(RAPTOR_HOME)/hdl/rapt_pkg.sv" \
	"$(RAPTOR_HOME)/hdl/backend/ieu/rapt_ieu_mul.sv" \
	"$(RAPTOR_HOME)/hdl/backend/ieu/rapt_ieu_muldiv.sv"

XSIM_ALU_SOURCES := \
	"$(RAPTOR_HOME)/hdl/backend/ieu/rapt_ieu_alu.sv"

XSIM_TARGETS := \
	xsim-l2 \
	xsim-l1d-byte-rom \
	xsim-l1d-store-coherence \
	xsim-l1d-flush-ordered \
	xsim-l1d-cmo-permissions \
	xsim-l1i-sret-priv-epoch \
	xsim-ptw-kill-drain \
	xsim-ptw-profile-negative \
	xsim-idu-illegal-stval \
	xsim-idu-zfhmin \
	xsim-idu-cmo \
	xsim-tlb-flush-asid \
	xsim-bus-axi \
	xsim-bus-read-ownership \
	xsim-csr-sret-roundtrip \
	xsim-addr-classification \
	xsim-pmp-endpoint \
	xsim-sram-l1d-lutram \
	xsim-sram-l1d-lutram-post-synth \
	xsim-lsu-lr-sq-forward \
	xsim-lsu-cbo-zero \
	xsim-lsu-sq-random \
	xsim-ioq \
	xsim-clint \
	xsim-plic-gateway \
	xsim-alu-zbb-strlen \
	xsim-muldiv-flush-reuse \
	xsim-rou-dual-commit

define XSIM_RUN
	@set -e; \
	if ! command -v xvlog >/dev/null 2>&1; then \
		if [ -f "$(VIVADO_SETTINGS)" ]; then source "$(VIVADO_SETTINGS)"; fi; \
	fi; \
	command -v xvlog >/dev/null 2>&1 || { \
		echo "[xsim] ERROR: xvlog not found; source Vivado settings or set VIVADO_SETTINGS=/path/to/settings64.sh"; \
		exit 1; \
	}; \
	rm -rf "$(XSIM_BUILD_DIR)/$(1)"; \
	mkdir -p "$(XSIM_BUILD_DIR)/$(1)"; \
	cd "$(XSIM_BUILD_DIR)/$(1)"; \
	xvlog -sv $(4) \
		$(XSIM_COMMON_INCLUDES) \
		$(3) \
		"$(XSIM_DIR)/$(2).sv"; \
	xelab -debug typical --timescale 1ns/1ps --override_timeunit \
		--override_timeprecision $(2) -s $(2)_sim; \
	xsim $(2)_sim $(5) -runall; \
	if grep -Eiq "^error:|FATAL_ERROR|FAIL:" xsim.log; then \
		echo "[xsim] ERROR: $(2) reported FAIL/FATAL; see $(XSIM_BUILD_DIR)/$(1)/xsim.log"; \
		exit 1; \
	fi
endef

.PHONY: xsim $(XSIM_TARGETS) xsim-l2-ordered-mmio xsim-l2-write-stream \
	xsim-bus-l1d-rlast xsim-bus-write-aw-before-w \
	xsim-ioq-lrsc-reservation xsim-ioq-pending-lock xsim-clean

xsim: $(XSIM_TARGETS) ## xsim: run all directed checks

xsim-alu-zbb-strlen: ## xsim: verify the RV64 ORC.B/CTZ strlen sequence
	$(call XSIM_RUN,alu_zbb_strlen,tb_alu_zbb_strlen,$(XSIM_ALU_SOURCES),-d RAPT_RV64)

xsim-l2: ## xsim: verify L2 ordering, cache fills, and posted write streams
	$(call XSIM_RUN,l2,tb_l2_ordered_mmio,$(XSIM_L2_SOURCES),-d RAPT_L2_EN)

xsim-l2-ordered-mmio xsim-l2-write-stream: xsim-l2

xsim-l1d-byte-rom: ## xsim: verify L1D ROM byte reads across cache fills/hits
	$(call XSIM_RUN,l1d_byte_rom,tb_l1d_byte_rom,$(XSIM_L1D_SOURCES),)

xsim-l1d-store-coherence: ## xsim: verify L1D load-after-store coherence
	$(call XSIM_RUN,l1d_store_coherence,tb_l1d_store_coherence,$(XSIM_L1D_SOURCES),)

xsim-l1d-flush-ordered: ## xsim: verify L1D flush drain and non-cacheable ordering
	$(call XSIM_RUN,l1d_flush_ordered,tb_l1d_flush_ordered,$(XSIM_L1D_SOURCES),-d RAPT_ASSERT_EN)

xsim-l1d-cmo-permissions: ## xsim: verify Zicbom R-or-W/A-only PTE checks and store faults
	$(call XSIM_RUN,l1d_cmo_permissions,tb_l1d_cmo_permissions,$(XSIM_L1D_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN)

xsim-l1i-sret-priv-epoch: ## xsim: verify SRET target privilege and stale PTW response kill
	$(call XSIM_RUN,l1i_sret_priv_epoch,tb_l1i_sret_priv_epoch,$(XSIM_L1I_SOURCES),-d RAPT_ASSERT_EN)

xsim-ptw-kill-drain: ## xsim: verify PTW cancel-before-accept and drain-after-accept
	$(call XSIM_RUN,ptw_kill_drain,tb_ptw_kill_drain,$(XSIM_PTW_SOURCES),-d RAPT_ASSERT_EN)

xsim-ptw-profile-negative: ## xsim: verify RVA20S64 Svade and Sv39 canonical faults
	$(call XSIM_RUN,ptw_profile_negative,tb_ptw_profile_negative,$(XSIM_PTW_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN)

xsim-idu-illegal-stval: ## xsim: verify Sstvala reports raw illegal C instruction bits
	$(call XSIM_RUN,idu_illegal_stval,tb_idu_illegal_stval,$(XSIM_IDU_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN)

xsim-idu-zfhmin: ## xsim: verify all mandatory Zfhmin instructions decode and use halfword LSU widths
	$(call XSIM_RUN,idu_zfhmin,tb_idu_zfhmin,$(XSIM_IDU_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN)

xsim-idu-cmo: ## xsim: verify RVA22 CMO decode and xenvcfg privilege gating
	$(call XSIM_RUN,idu_cmo,tb_idu_cmo,$(XSIM_IDU_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN)

xsim-tlb-flush-asid: ## xsim: verify TLB ASID matching and flush priority
	$(call XSIM_RUN,tlb_flush_asid,tb_tlb_flush_asid,$(XSIM_TLB_SOURCES),-d RAPT_ASSERT_EN)

xsim-bus-axi: ## xsim: verify bus AXI reads and independent AW/W handshakes
	$(call XSIM_RUN,bus_axi,tb_bus_l1d_rlast,$(XSIM_BUS_SOURCES),)

xsim-bus-l1d-rlast xsim-bus-write-aw-before-w: xsim-bus-axi

xsim-bus-read-ownership: ## xsim: verify read response ID ownership and interleaving
	$(call XSIM_RUN,bus_read_ownership,tb_bus_read_ownership,$(XSIM_BUS_SOURCES),)

xsim-csr-sret-roundtrip: ## xsim: verify CSR reset and U-ecall/SRET round trip
	$(call XSIM_RUN,csr_sret_roundtrip_$(ISA),tb_csr_sret_roundtrip,$(XSIM_CSR_SOURCES),$(if $(filter rv64,$(ISA)),-d RAPT_RV64,))

xsim-addr-classification: ## xsim: reject malformed RV64 physical-address upper bits
	$(call XSIM_RUN,addr_classification,tb_addr_classification,"$(RAPTOR_HOME)/hdl/rapt_pkg.sv",-d RAPT_RV64)

xsim-pmp-endpoint: ## xsim: verify variable-size PMP endpoint boundary checks
	$(call XSIM_RUN,pmp_endpoint,tb_pmp_endpoint,"$(RAPTOR_HOME)/hdl/rapt_pkg.sv" "$(RAPTOR_HOME)/hdl/memory/rapt_pmp.sv",)

xsim-lsu-lr-sq-forward: ## xsim: verify LR waits for SQ drain instead of forwarding
	$(call XSIM_RUN,lsu_lr_sq_forward,tb_lsu_lr_sq_forward,$(XSIM_LSU_SOURCES),-d RAPT_ASSERT_EN)

xsim-lsu-cbo-zero: ## xsim: verify Zicboz emits eight aligned zero dword stores
	$(call XSIM_RUN,lsu_cbo_zero,tb_lsu_cbo_zero,$(XSIM_LSU_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN)

LSU_SQ_RANDOM_SEED ?= 1370169382
xsim-lsu-sq-random: ## xsim: constrained-random SQ ordering, alias, wrap, flush, and backpressure
	$(call XSIM_RUN,lsu_sq_random,tb_lsu_sq_random,$(XSIM_LSU_SOURCES),-d RAPT_ASSERT_EN,-testplusarg SEED=$(LSU_SQ_RANDOM_SEED))

xsim-ioq: ## xsim: verify IOQ LR/SC reservations, pending loads, and flush kills
	$(call XSIM_RUN,ioq,tb_ioq_pending_lock,$(XSIM_IOQ_SOURCES),)

xsim-ioq-lrsc-reservation xsim-ioq-pending-lock: xsim-ioq

xsim-clint: ## xsim: verify CLINT divider, compare, and software interrupt semantics
	$(call XSIM_RUN,clint,tb_clint,"$(RAPTOR_HOME)/hdl/perip/rapt_clint.sv",)

xsim-plic-gateway: ## xsim: verify PLIC gateway and claim/complete semantics
	$(call XSIM_RUN,plic_gateway,tb_plic_gateway,"$(RAPTOR_HOME)/hdl/perip/rapt_plic.sv",)

xsim-muldiv-flush-reuse: ## xsim: verify flush kills DIV completion before MDQ slot reuse
	$(call XSIM_RUN,muldiv_flush_reuse,tb_muldiv_flush_reuse,$(XSIM_MULDIV_SOURCES),-d RAPT_ASSERT_EN)

xsim-rou-dual-commit: ## xsim: verify ROU dual commit and slot1 flush serialization
	$(call XSIM_RUN,rou_dual_commit,tb_rou_dual_commit,$(XSIM_ROU_SOURCES),-d RAPT_ASSERT_EN)

xsim-clean: ## Clean xsim directed-check artifacts
	rm -rf $(XSIM_BUILD_DIR)

# ============================================================================
# Portable Verilator Directed Checks
# ============================================================================
# The directed benches above are simulator-neutral SystemVerilog.  Reuse the
# same DUT source lists and testbench files with Verilator so the main server
# regression does not require Vivado/XSim.  Invoke this target with `-jN`; each
# test owns a separate Mdir and can compile/run independently.
VERILATOR ?= verilator
VERILATOR_DIRECTED_BUILD_DIR := $(BUILD_DIR)/verilator-directed
VERILATOR_DIRECTED_FLAGS ?= --binary --timing --assert -Wno-fatal -j 1
VERILATOR_DIRECTED_DELAY ?= 63## Random response-delay maximum for module checks
VERILATOR_DIRECTED_SEED ?= 1## Reproducible seed for randomized module checks

VERILATOR_DIRECTED_TARGETS := \
	verilator-alu-zbb-strlen \
	verilator-l2 \
	verilator-l1d-byte-rom \
	verilator-l1d-store-coherence \
	verilator-l1d-flush-ordered \
	verilator-l1d-cmo-permissions \
	verilator-l1i-sret-priv-epoch \
	verilator-ptw-kill-drain \
	verilator-ptw-profile-negative \
	verilator-idu-illegal-stval \
	verilator-idu-zfhmin \
	verilator-idu-cmo \
	verilator-tlb-flush-asid \
	verilator-bus-axi \
	verilator-bus-read-ownership \
	verilator-csr-sret-roundtrip-rv32 \
	verilator-csr-sret-roundtrip-rv64 \
	verilator-addr-classification \
	verilator-pmp-endpoint \
	verilator-lsu-lr-sq-forward \
	verilator-lsu-cbo-zero \
	verilator-lsu-sq-random \
	verilator-ioq \
	verilator-clint \
	verilator-plic-gateway \
	verilator-muldiv-flush-reuse \
	verilator-muldiv-word-rv64 \
	verilator-rou-dual-commit

# $(1)=build/log stem, $(2)=top/testbench, $(3)=DUT sources,
# $(4)=XSim-style defines (`-d NAME`, translated to `-DNAME`),
# $(5)=runtime plusargs.
define VERILATOR_DIRECTED_RUN
	+@set -e -o pipefail; \
	command -v $(VERILATOR) >/dev/null 2>&1 || { \
		echo "[verilator-directed] ERROR: $(VERILATOR) not found"; exit 1; }; \
	rm -rf "$(VERILATOR_DIRECTED_BUILD_DIR)/$(1)"; \
	mkdir -p "$(VERILATOR_DIRECTED_BUILD_DIR)/$(1)"; \
	$(VERILATOR) $(VERILATOR_DIRECTED_FLAGS) \
		--timescale 1ns/1ps --top-module $(2) \
		$(subst -d ,-D,$(4)) \
		$(addprefix -I,$(patsubst -i%,%,$(XSIM_COMMON_INCLUDES))) \
		$(3) "$(XSIM_DIR)/$(2).sv" \
		--Mdir "$(VERILATOR_DIRECTED_BUILD_DIR)/$(1)/obj" -o $(2) \
		>"$(VERILATOR_DIRECTED_BUILD_DIR)/$(1)/build.log" 2>&1; \
	"$(VERILATOR_DIRECTED_BUILD_DIR)/$(1)/obj/$(2)" $(5) \
		2>&1 | tee "$(VERILATOR_DIRECTED_BUILD_DIR)/$(1)/run.log"; \
	grep -q "PASS:" "$(VERILATOR_DIRECTED_BUILD_DIR)/$(1)/run.log" || { \
		echo "[verilator-directed] ERROR: $(2) did not report PASS"; exit 1; }; \
	echo "[verilator-directed] PASS $(1)"
endef

.PHONY: verilator-directed verilator-directed-clean $(VERILATOR_DIRECTED_TARGETS)

verilator-directed: $(VERILATOR_DIRECTED_TARGETS) ## Run all module checks with portable Verilator
	@echo "[verilator-directed] all $(words $(VERILATOR_DIRECTED_TARGETS)) checks passed"

verilator-alu-zbb-strlen:
	$(call VERILATOR_DIRECTED_RUN,alu_zbb_strlen,tb_alu_zbb_strlen,$(XSIM_ALU_SOURCES),-d RAPT_RV64,)
verilator-l2:
	$(call VERILATOR_DIRECTED_RUN,l2,tb_l2_ordered_mmio,$(XSIM_L2_SOURCES),-d RAPT_L2_EN,)
verilator-l1d-byte-rom:
	$(call VERILATOR_DIRECTED_RUN,l1d_byte_rom,tb_l1d_byte_rom,$(XSIM_L1D_SOURCES),,)
verilator-l1d-store-coherence:
	$(call VERILATOR_DIRECTED_RUN,l1d_store_coherence,tb_l1d_store_coherence,$(XSIM_L1D_SOURCES),,+BUS_DELAY_MAX=$(VERILATOR_DIRECTED_DELAY) +SEED=$(VERILATOR_DIRECTED_SEED))
verilator-l1d-flush-ordered:
	$(call VERILATOR_DIRECTED_RUN,l1d_flush_ordered,tb_l1d_flush_ordered,$(XSIM_L1D_SOURCES),-d RAPT_ASSERT_EN,)
verilator-l1d-cmo-permissions:
	$(call VERILATOR_DIRECTED_RUN,l1d_cmo_permissions,tb_l1d_cmo_permissions,$(XSIM_L1D_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,)
verilator-l1i-sret-priv-epoch:
	$(call VERILATOR_DIRECTED_RUN,l1i_sret_priv_epoch,tb_l1i_sret_priv_epoch,$(XSIM_L1I_SOURCES),-d RAPT_ASSERT_EN,)
verilator-ptw-kill-drain:
	$(call VERILATOR_DIRECTED_RUN,ptw_kill_drain,tb_ptw_kill_drain,$(XSIM_PTW_SOURCES),-d RAPT_ASSERT_EN,)
verilator-ptw-profile-negative:
	$(call VERILATOR_DIRECTED_RUN,ptw_profile_negative,tb_ptw_profile_negative,$(XSIM_PTW_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,)
verilator-idu-illegal-stval:
	$(call VERILATOR_DIRECTED_RUN,idu_illegal_stval,tb_idu_illegal_stval,$(XSIM_IDU_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,)
verilator-idu-zfhmin:
	$(call VERILATOR_DIRECTED_RUN,idu_zfhmin,tb_idu_zfhmin,$(XSIM_IDU_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,)
verilator-idu-cmo:
	$(call VERILATOR_DIRECTED_RUN,idu_cmo,tb_idu_cmo,$(XSIM_IDU_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,)
verilator-tlb-flush-asid:
	$(call VERILATOR_DIRECTED_RUN,tlb_flush_asid,tb_tlb_flush_asid,$(XSIM_TLB_SOURCES),-d RAPT_ASSERT_EN,)
verilator-bus-axi:
	$(call VERILATOR_DIRECTED_RUN,bus_axi,tb_bus_l1d_rlast,$(XSIM_BUS_SOURCES),,)
verilator-bus-read-ownership:
	$(call VERILATOR_DIRECTED_RUN,bus_read_ownership,tb_bus_read_ownership,$(XSIM_BUS_SOURCES),,)
verilator-csr-sret-roundtrip-rv32:
	$(call VERILATOR_DIRECTED_RUN,csr_sret_roundtrip_rv32,tb_csr_sret_roundtrip,$(XSIM_CSR_SOURCES),,)
verilator-csr-sret-roundtrip-rv64:
	$(call VERILATOR_DIRECTED_RUN,csr_sret_roundtrip_rv64,tb_csr_sret_roundtrip,$(XSIM_CSR_SOURCES),-d RAPT_RV64,)
verilator-addr-classification:
	$(call VERILATOR_DIRECTED_RUN,addr_classification,tb_addr_classification,"$(RAPTOR_HOME)/hdl/rapt_pkg.sv",-d RAPT_RV64,)
verilator-pmp-endpoint:
	$(call VERILATOR_DIRECTED_RUN,pmp_endpoint,tb_pmp_endpoint,"$(RAPTOR_HOME)/hdl/rapt_pkg.sv" "$(RAPTOR_HOME)/hdl/memory/rapt_pmp.sv",,)
verilator-lsu-lr-sq-forward:
	$(call VERILATOR_DIRECTED_RUN,lsu_lr_sq_forward,tb_lsu_lr_sq_forward,$(XSIM_LSU_SOURCES),-d RAPT_ASSERT_EN,)
verilator-lsu-cbo-zero:
	$(call VERILATOR_DIRECTED_RUN,lsu_cbo_zero,tb_lsu_cbo_zero,$(XSIM_LSU_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,)
verilator-lsu-sq-random:
	$(call VERILATOR_DIRECTED_RUN,lsu_sq_random,tb_lsu_sq_random,$(XSIM_LSU_SOURCES),-d RAPT_ASSERT_EN,+SEED=$(VERILATOR_DIRECTED_SEED))
verilator-ioq:
	$(call VERILATOR_DIRECTED_RUN,ioq,tb_ioq_pending_lock,$(XSIM_IOQ_SOURCES),,)
verilator-clint:
	$(call VERILATOR_DIRECTED_RUN,clint,tb_clint,"$(RAPTOR_HOME)/hdl/perip/rapt_clint.sv",,)
verilator-plic-gateway:
	$(call VERILATOR_DIRECTED_RUN,plic_gateway,tb_plic_gateway,"$(RAPTOR_HOME)/hdl/perip/rapt_plic.sv",,)
verilator-muldiv-flush-reuse:
	$(call VERILATOR_DIRECTED_RUN,muldiv_flush_reuse,tb_muldiv_flush_reuse,$(XSIM_MULDIV_SOURCES),-d RAPT_ASSERT_EN,)
verilator-muldiv-word-rv64:
	$(call VERILATOR_DIRECTED_RUN,muldiv_word_rv64,tb_muldiv_flush_reuse,$(XSIM_MULDIV_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,)
verilator-rou-dual-commit:
	$(call VERILATOR_DIRECTED_RUN,rou_dual_commit,tb_rou_dual_commit,$(XSIM_ROU_SOURCES),-d RAPT_ASSERT_EN,)

verilator-directed-clean: ## Clean portable Verilator directed-check artifacts
	rm -rf $(VERILATOR_DIRECTED_BUILD_DIR)


# ============================================================================
# All-in-one
# ============================================================================
.PHONY: all clean

all: fuzz sigtest ## Run all lightweight verification

clean: fuzz-clean riscof-clean coverage-clean sigtest-clean formal-clean jtag-clean uvm-clean xsim-clean verilator-directed-clean ## Clean all verify artifacts
	rm -rf $(BUILD_DIR)
