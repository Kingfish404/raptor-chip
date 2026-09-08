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

.PHONY: pma-span-check
pma-span-check: ## Prove RV32/RV64 scalar PMA first-fault offsets against bytewise decoding
	$(PYTHON) scripts/formal_contract.py pma-span --output "$(BUILD_DIR)/pma-span"

.PHONY: fpu-normalize-check
fpu-normalize-check: ## Prove FPU mantissa normalization and exponent adjustment
	$(PYTHON) scripts/fpu_normalize_check.py --output "$(BUILD_DIR)/fpu-normalize"

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
ACT4_SAIL_FLAGS := --rv32
ACT4_VFLAGS :=
ifeq ($(ISA),rv64)
  ACT4_CONFIG  := $(ACT4_DIR)/raptor-rv64gc/test_config.yaml
  ACT4_SAIL_FLAGS :=
  ACT4_VFLAGS := -DRAPT_RV64
endif
ACT4_ELF_DIR    = $(ACT4_WORKDIR)/raptor-rv32gc/elfs
ifeq ($(ISA),rv64)
  ACT4_ELF_DIR  = $(ACT4_WORKDIR)/raptor-rv64gc/elfs
endif
# Only generate tests for implemented extensions (positive filter).
# Using EXTENSIONS instead of EXCLUDE_EXTENSIONS avoids generating tests for
# unsupported extensions such as Zfh/V, which bloat tests/ and waste Sail time.
ifeq ($(ISA),rv64)
  ACT4_EXTENSIONS ?= I,M,F,D,Zca,Zcd,Zicsr,Zicntr,Zifencei,Zaamo,Zalrsc,Zba,Zbb,Zbc,Zbs
else
  ACT4_EXTENSIONS ?= I,M,F,D,Zca,Zcf,Zcd,Zicsr,Zicntr,Zifencei,Zaamo,Zalrsc,Zba,Zbb,Zbc,Zbs
endif
ACT4_BUILD_PROFILE ?= $(RAPT_CONFIG)-act4-$(ISA)
# ACT4 FP self-checking ELFs exceed the generic 10-second unit-test budget.
# Preserve explicit legacy TIMEOUT overrides; otherwise match run_act4.py.
ACT4_TIMEOUT ?= $(if $(filter command line environment override,$(origin TIMEOUT)),$(TIMEOUT),60)
ACT4_NPC_BIN ?= $(NSIM_HOME)/build/$(ACT4_BUILD_PROFILE)/riscv$(if $(filter rv64,$(ISA)),64,32)-npc-sim
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
	@PATH="$(ACT4_PATH)" sail_riscv_sim $(ACT4_SAIL_FLAGS) --config-override \
		"$(dir $(ACT4_CONFIG))sail.json" --validate-config >/dev/null
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

riscof-build-npc: ## Build the selected XLEN NPC for ACT4 self-checking ELFs
	@# ACT4 binaries report their own result and run without a NEMU -d argument.
	@# The simulator supports this even when CONFIG_DIFFTEST is enabled.
	@if [ ! -f $(NSIM_HOME)/.config ]; then \
		$(MAKE) -C $(NSIM_HOME) o2_defconfig; \
	fi
	@$(MAKE) -C $(NSIM_HOME) $(SUBMAKE_JOBS) RAPT_CONFIG=$(RAPT_CONFIG) \
		BUILD_PROFILE=$(ACT4_BUILD_PROFILE) VFLAGS="$(ACT4_VFLAGS)"
	@test -f $(ACT4_NPC_BIN) || { echo "[act4] ERROR: NPC build failed: $(ACT4_NPC_BIN)"; exit 1; }

riscof-run: riscof-build-npc $(MROM_IMG) ## Run ACT4 ELFs on Raptor NPC
	@test -d "$(ACT4_ELF_DIR)" || { echo "[act4] ERROR: ELF directory not found: $(ACT4_ELF_DIR)"; \
		echo "  Run 'make riscof-gen' first to generate self-checking ELFs."; exit 1; }
	@echo "================================================================"
	@echo "[act4] Running ACT4 tests on Raptor NPC"
	@echo "  NPC:    $(ACT4_NPC_BIN)"
	@echo "  ELFs:   $(ACT4_ELF_DIR)"
	@echo "  Logs:   $(ACT4_WORKDIR)/logs"
	@echo "================================================================"
	python3 $(VERIFY_HOME)/scripts/run_act4.py \
		--npc-bin "$(ACT4_NPC_BIN)" \
		--objcopy "$(OBJCOPY)" \
		--mrom-img "$(MROM_IMG)" \
		--mem-random-delay $(MEM_RANDOM_DELAY) \
		--mem-random-seed $(MEM_RANDOM_SEED) \
		--jobs $(JOBS) \
		--log-dir "$(ACT4_WORKDIR)/logs" \
		--timeout $(ACT4_TIMEOUT) \
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
# Large classic F/D vectors can take minutes in an RTL simulator.  Do not
# inherit the generic 10-second smoke-test budget unless explicitly requested.
RISCOF_CLASSIC_TIMEOUT ?= $(if $(filter command line environment override,$(origin TIMEOUT)),$(TIMEOUT),600)
RISCOF_CLASSIC_SHARD_INDEX ?= 0
RISCOF_CLASSIC_SHARD_COUNT ?= 1
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
			NSIM_HOME="$(NSIM_HOME)" RAPT_TIMEOUT="$(RISCOF_CLASSIC_TIMEOUT)" \
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
			--shard-index="$(RISCOF_CLASSIC_SHARD_INDEX)" \
			--shard-count="$(RISCOF_CLASSIC_SHARD_COUNT)" \
			--drop-legacy-ad && \
		export NPC_BIN="$(RISCOF_NPC_BIN_32)" MROM_IMG="$(MROM_IMG)" \
			NSIM_HOME="$(NSIM_HOME)" RAPT_TIMEOUT="$(RISCOF_CLASSIC_TIMEOUT)" \
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
	@test -s "$(RISCOF_CLASSIC_WORKDIR)/report.html" || { \
		echo "[riscof-classic] ERROR: missing report.html; run did not complete."; exit 1; }
	@if ! grep -q 'class="col-result">Failed' "$(RISCOF_CLASSIC_WORKDIR)/report.html"; then \
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
RISCOF_CLASSIC_NEMU_WORKDIR := $(BUILD_DIR)/riscof-classic-nemu-$(ISA)
RISCOF_CLASSIC_NEMU_TESTLIST := $(RISCOF_CLASSIC_NEMU_WORKDIR)/test_list.yaml
RISCOF_CLASSIC_NEMU_FILTERED_TESTLIST := $(RISCOF_CLASSIC_NEMU_WORKDIR)/nemu-test_list.yaml
RISCOF_CLASSIC_NEMU_CONFIG := $(if $(filter rv64,$(ISA)),config-rv64.ini,config.ini)
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
	@test "$(ISA)" = rv32 -o "$(ISA)" = rv64 || { echo "Unsupported ISA: $(ISA)"; exit 1; }
	+$(MAKE) -C $(NEMU_HOME) riscv$(patsubst rv%,%,$(ISA))_riscof_defconfig
	+$(MAKE) -C $(NEMU_HOME) $(SUBMAKE_JOBS)
	@test -f $(NEMU_BIN) || { echo "[riscof-classic-nemu] ERROR: NEMU build failed: $(NEMU_BIN)"; exit 1; }

riscof-classic-nemu: riscof-classic-nemu-run ## Run classic RISCOF flow against NEMU

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

riscof-classic-nemu-run: riscof-classic-nemu-setup ## Execute classic RISCOF flow with NEMU as DUT
	@test -d "$(RISCOF_CLASSIC_NEMU_SUITE)" || { echo "[riscof-classic-nemu] ERROR: suite not found. Run 'make riscof-classic-setup' first."; exit 1; }
	@# Same FileExistsError guard as riscof-classic-run: wipe stale work-dir.
	rm -rf "$(RISCOF_CLASSIC_NEMU_WORKDIR)"
	@mkdir -p "$(RISCOF_CLASSIC_NEMU_WORKDIR)"
	@mkdir -p "$(RISCOF_CLASSIC_NEMU_WORKDIR)/tmp"
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
			RAPT_TIMEOUT="$(or $(strip $(TIMEOUT)),10)" RAPT_JOBS="$(JOBS)" \
			RAPT_RISCV_PREFIX="$(CROSS_COMPILE)" TMPDIR="$(RISCOF_CLASSIC_NEMU_WORKDIR)/tmp"; \
		RISCOF_BIN="$(if $(wildcard $(RISCOF_CLASSIC_BIN)),$(RISCOF_CLASSIC_BIN),riscof)"; \
		"$$RISCOF_BIN" testlist \
			--config=$(RISCOF_CLASSIC_NEMU_CONFIG) \
			--suite=$(RISCOF_CLASSIC_NEMU_SUITE)/riscv-test-suite/ \
			--env=$(RISCOF_CLASSIC_NEMU_SUITE)/riscv-test-suite/env \
			--work-dir="$(RISCOF_CLASSIC_NEMU_WORKDIR)" && \
		$(if $(wildcard $(RISCOF_CLASSIC_PYTHON)),$(RISCOF_CLASSIC_PYTHON),$(PYTHON)) "$(VERIFY_HOME)/scripts/filter_riscof_testlist.py" \
			--input="$(RISCOF_CLASSIC_NEMU_TESTLIST)" \
			--output="$(RISCOF_CLASSIC_NEMU_FILTERED_TESTLIST)" \
			--target=nemu --ad-policy=keep && \
		"$$RISCOF_BIN" run \
			--config=$(RISCOF_CLASSIC_NEMU_CONFIG) \
			--suite=$(RISCOF_CLASSIC_NEMU_SUITE)/riscv-test-suite/ \
			--env=$(RISCOF_CLASSIC_NEMU_SUITE)/riscv-test-suite/env \
			--testfile="$(RISCOF_CLASSIC_NEMU_FILTERED_TESTLIST)" \
			--work-dir="$(RISCOF_CLASSIC_NEMU_WORKDIR)" \
			--no-browser
	$(PYTHON) "$(VERIFY_HOME)/scripts/check_riscof_report.py" \
		--report "$(RISCOF_CLASSIC_NEMU_WORKDIR)/report.html" \
		--testlist "$(RISCOF_CLASSIC_NEMU_FILTERED_TESTLIST)"
	@echo "[riscof-classic-nemu] PASS"

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

# Require the expected profile/XLEN binary before running a coverage workload.
# BUILD_PROFILE must match coverage-build so the run retains instrumentation.
.PHONY: check-coverage-bin
check-coverage-bin:
	@if [ ! -x "$(COV_NPC_BIN)" ]; then \
		echo "[coverage] ERROR: simulator $(COV_NPC_BIN) not found."; \
		echo "[coverage]        Run 'make -C verify coverage-build' first"; \
		echo "[coverage]        (check BUILD_PROFILE, XLEN, and the coverage-build configuration)."; \
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
	"$(RAPTOR_HOME)/hdl/common/rapt_issue_select.sv" \
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
	"$(RAPTOR_HOME)/hdl/memory/rapt_cache_fill_select.sv" \
	"$(RAPTOR_HOME)/hdl/memory/rapt_cache_plru.sv" \
	"$(RAPTOR_HOME)/hdl/rapt_pkg.sv" \
	"$(RAPTOR_HOME)/hdl/memory/rapt_sram_1rw.sv" \
	"$(RAPTOR_HOME)/hdl/memory/rapt_l1d_data.sv" \
	"$(RAPTOR_HOME)/hdl/memory/rapt_l1d_tags.sv" \
	"$(RAPTOR_HOME)/hdl/memory/rapt_l1d_access.sv" \
	"$(RAPTOR_HOME)/hdl/memory/rapt_plru.sv" \
	"$(RAPTOR_HOME)/hdl/memory/rapt_pmp.sv" \
	"$(RAPTOR_HOME)/hdl/memory/rapt_tlb.sv" \
	"$(RAPTOR_HOME)/hdl/memory/rapt_ptw.sv" \
	"$(RAPTOR_HOME)/hdl/memory/rapt_l1d.sv"

XSIM_L1I_SOURCES := \
	"$(RAPTOR_HOME)/hdl/memory/rapt_ifetch_word.sv" \
	"$(RAPTOR_HOME)/hdl/memory/rapt_ifetch_translate.sv" \
	"$(RAPTOR_HOME)/hdl/memory/rapt_l1i_access.sv" \
	"$(RAPTOR_HOME)/hdl/memory/rapt_cache_fill_select.sv" \
	"$(RAPTOR_HOME)/hdl/memory/rapt_cache_plru.sv" \
	"$(RAPTOR_HOME)/hdl/memory/rapt_l1i_data.sv" \
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
	"$(RAPTOR_HOME)/hdl/frontend/rapt_decode_slot.sv" \
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
	"$(RAPTOR_HOME)/hdl/backend/lsu/rapt_ioq_store_check.sv" \
	"$(RAPTOR_HOME)/hdl/rapt_pkg.sv" \
	"$(RAPTOR_HOME)/hdl/memory/rapt_pmp.sv" \
	"$(RAPTOR_HOME)/hdl/backend/lsu/rapt_lsu_ioq.sv"

XSIM_LSU_SOURCES := \
	"$(RAPTOR_HOME)/hdl/backend/lsu/rapt_store_beats.sv" \
	"$(RAPTOR_HOME)/hdl/backend/lsu/rapt_sq_forward.sv" \
	"$(RAPTOR_HOME)/hdl/rapt_pkg.sv" \
	"$(RAPTOR_HOME)/hdl/memory/rapt_pmp.sv" \
	"$(RAPTOR_HOME)/hdl/backend/lsu/rapt_lsu_sq.sv"

XSIM_ROU_SOURCES := \
	"$(RAPTOR_HOME)/hdl/rapt_pkg.sv" \
	"$(RAPTOR_HOME)/hdl/backend/rapt_rob_age_mask.sv" \
	"$(RAPTOR_HOME)/hdl/backend/rapt_completion_guard.sv" \
	"$(RAPTOR_HOME)/hdl/backend/rapt_recovery_pending.sv" \
	"$(RAPTOR_HOME)/hdl/backend/rapt_dispatch_admit.sv" \
	"$(RAPTOR_HOME)/hdl/backend/rapt_rob_dispatch_select.sv" \
	"$(RAPTOR_HOME)/hdl/common/rapt_stream_queue.sv" \
	"$(RAPTOR_HOME)/hdl/common/rapt_rank_select.sv" \
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

define SHARED_TB_SOURCE
$(if $(filter tb_idu_%,$(1)),tb_idu_contract.sv,$(if $(filter tb_router_%,$(1)),tb_router_all_contract.sv,$(if $(filter tb_ptw_%,$(1)),tb_ptw_all_contract.sv,$(if $(filter tb_sq_%,$(1)),tb_sq_all_contract.sv,$(if $(filter tb_l1d_%,$(1)),tb_l1d_all_contract.sv,$(if $(filter tb_ioq_%,$(1)),tb_ioq_all_contract.sv,$(if $(filter tb_lsu_%,$(1)),tb_lsu_all_contract.sv,$(if $(filter tb_csr_%,$(1)),tb_csr_all_contract.sv,$(if $(filter tb_csr_pmp_%,$(1)),tb_csr_pmp_contract.sv,$(if $(filter tb_predict_history%,$(1)),tb_predict_history_contract.sv,$(if $(filter tb_lsu_atomic_%,$(1)),tb_lsu_atomic_contract.sv,$(if $(filter tb_ioq_atomic_%,$(1)),tb_ioq_atomic_contract.sv,$(if $(filter tb_issue_select%,$(1)),tb_issue_select_contract.sv,$(if $(filter tb_l1d_load_%,$(1)),tb_l1d_load_contract.sv,$(if $(filter tb_l1d_store_%,$(1)),tb_l1d_store_contract.sv,$(if $(filter tb_ioq_store_%,$(1)),tb_ioq_store_contract.sv,$(if $(filter tb_rename_checkpoint%,$(1)),tb_rename_checkpoint_contract.sv,$(if $(filter tb_lsu_lr_%,$(1)),tb_lsu_lr_contract.sv,$(1).sv))))))))))))))))))
endef

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
		"$(XSIM_DIR)/$(call SHARED_TB_SOURCE,$(2))"; \
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
INTEGER_PORT_BUILD_DIR := $(BUILD_DIR)/integer-issue-ports
VERILATOR_DIRECTED_FLAGS ?= --binary --timing --assert -Wno-fatal -j 1
VERILATOR_DIRECTED_DELAY ?= 63## Random response-delay maximum for module checks
VERILATOR_DIRECTED_SEED ?= 1## Reproducible seed for randomized module checks

VERILATOR_DIRECTED_TARGETS := \
	verilator-l1d-replacement \
	verilator-l1i-width-window-4way \
	verilator-l1i-width-window-8way \
	verilator-cache-replacement \
	verilator-sq-forward-ports \
	verilator-sq-forward-ports-rv64 \
	verilator-l1d-data \
	verilator-l1d-tags \
	verilator-alu-zbb-strlen \
	verilator-l2 \
	verilator-l1d-byte-rom \
	verilator-l1d-store-coherence \
	verilator-l1d-flush-ordered \
	verilator-l1d-cmo-permissions \
	verilator-l1i-sret-priv-epoch \
	verilator-ptw-kill-drain \
	verilator-ptw-profile-negative \
	verilator-ptw-global-rv32 \
	verilator-ptw-global-rv64 \
	verilator-idu-illegal-stval \
	verilator-idu-zfhmin \
	verilator-idu-cmo \
	verilator-idu-privileged-rv32 \
	verilator-idu-privileged-rv64 \
	verilator-tlb-flush-asid \
	verilator-bus-axi \
	verilator-bus-read-ownership \
	verilator-csr-sret-roundtrip-rv32 \
	verilator-csr-sret-roundtrip-rv64 \
	verilator-csr-architectural-rv32 \
	verilator-csr-architectural-rv64 \
	verilator-addr-classification \
	verilator-pmp-endpoint \
	verilator-pmp-reset-napot-rv32 \
	verilator-pmp-reset-napot-rv64 \
	verilator-lsu-lr-sq-forward \
	verilator-lsu-cbo-zero \
	verilator-lsu-sq-random \
	verilator-ioq \
	verilator-clint \
	verilator-plic-gateway \
	verilator-muldiv-flush-reuse \
	verilator-muldiv-word-rv64 \
	verilator-rou-dual-commit \
	verilator-backend-extensibility \
	verilator-iq-type-family \
	verilator-superscalar-widths \
	verilator-stream-queue \
	verilator-rename-checkpoint \
	verilator-rename-checkpoint-pipeline \
	verilator-rename-width-recovery \
	verilator-l1i-width-window \
	verilator-ifu-stream-events \
	verilator-frontend-recovery \
	verilator-rename-random \
	verilator-issue-select \
	verilator-dispatch-admit \
	verilator-rob-dispatch-select \
	verilator-dispatch-compact \
	verilator-recovery-pending \
	verilator-completion-guard \
	verilator-iq-reclaim-random \
	verilator-ras \
	verilator-ras-pipeline \
	verilator-predict-history \
	verilator-predict-history-pipeline

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
		$(3) "$(XSIM_DIR)/$(call SHARED_TB_SOURCE,$(2))" \
		--Mdir "$(VERILATOR_DIRECTED_BUILD_DIR)/$(1)/obj" -o $(2) \
		>"$(VERILATOR_DIRECTED_BUILD_DIR)/$(1)/build.log" 2>&1; \
	"$(VERILATOR_DIRECTED_BUILD_DIR)/$(1)/obj/$(2)" $(5) \
		2>&1 | tee "$(VERILATOR_DIRECTED_BUILD_DIR)/$(1)/run.log"; \
	grep -q "PASS:" "$(VERILATOR_DIRECTED_BUILD_DIR)/$(1)/run.log" || { \
		echo "[verilator-directed] ERROR: $(2) did not report PASS"; exit 1; }; \
	echo "[verilator-directed] PASS $(1)"
endef

.PHONY: verilator-directed verilator-directed-clean $(VERILATOR_DIRECTED_TARGETS)

verilator-directed: superscalar-structure-check $(VERILATOR_DIRECTED_TARGETS) ## Run all module checks with portable Verilator
	@echo "[verilator-directed] all $(words $(VERILATOR_DIRECTED_TARGETS)) checks passed"

.PHONY: superscalar-structure-check
.PHONY: rtl-synthesis-check
.PHONY: rtl-synthesis-audit-test
rtl-synthesis-audit-test: ## Test fail-closed synthesis evidence handling
	$(PYTHON) "$(VERIFY_HOME)/scripts/test_rtl_synthesis_check.py"
	$(PYTHON) "$(VERIFY_HOME)/scripts/test_native_synthesis_policy.py"

rtl-synthesis-check: ## Elaborate core/config matrix at native limits; reject invalid RTL contracts
	$(PYTHON) "$(VERIFY_HOME)/scripts/rtl_synthesis_check.py"

superscalar-structure-check: ## Reject fixed A/B lane APIs in the active scalable pipeline
	$(PYTHON) "$(VERIFY_HOME)/scripts/superscalar_structure_check.py"

.PHONY: verilator-dpifree-middle-smoke
verilator-dpifree-middle-smoke: ## Exercise the parameterized commit monitor in the DPI-free whole-chip harness
	$(MAKE) -C "$(RAPTOR_HOME)/sim/tb" verilator-middle-smoke

# Whole-core elaboration checks keep physical execution resources independent
# from the ordered Decode/Rename/Dispatch/Commit widths.  Use separate build
# profiles so parallel invocations cannot invalidate one another's signatures.
.PHONY: verilator-execution-port-matrix verilator-execution-port-1 \
	verilator-execution-port-2 verilator-execution-port-3 \
	verilator-execution-port-relocated-system
verilator-execution-port-matrix: verilator-execution-port-1 verilator-execution-port-2 verilator-execution-port-3 verilator-execution-port-relocated-system ## Lint whole core with 1/2/3 integer ports and relocated system capability
	$(PYTHON) "$(VERIFY_HOME)/scripts/integer_issue_ports_check.py" \
		--output "$(INTEGER_PORT_BUILD_DIR)" --ports 1 2 3 3 --system-ports 0 0 0 1
	@echo "[verilator-port-matrix] 1/2/3-port and relocated-system whole-core elaboration passed"

verilator-execution-port-1 verilator-execution-port-2 verilator-execution-port-3:
	+@set -e; port=$(lastword $(subst -, ,$@)); \
		mkdir -p "$(INTEGER_PORT_BUILD_DIR)"; \
		log="$(INTEGER_PORT_BUILD_DIR)/lint-port-$$port.log"; \
		if ! $(MAKE) -C $(NSIM_HOME) lint RAPT_CONFIG=default \
			BUILD_PROFILE=integer-ports-lint-$$port LINT_EXTRA=-Wno-fatal \
			VFLAGS="-DRAPT_INTEGER_ISSUE_PORTS=$$port" >"$$log" 2>&1; then \
			tail -80 "$$log"; exit 1; \
		fi; \
		warnings=$$(grep -c '^%Warning-' "$$log" || true); \
		report=$$(grep 'Built from' "$$log" | tail -1); \
		echo "[verilator-port-matrix] port=$$port warnings=$$warnings $${report#*- Verilator: }"

verilator-execution-port-relocated-system:
	+@set -e; \
		mkdir -p "$(INTEGER_PORT_BUILD_DIR)"; \
		log="$(INTEGER_PORT_BUILD_DIR)/lint-port-3-system-1.log"; \
		if ! $(MAKE) -C $(NSIM_HOME) lint RAPT_CONFIG=default \
			BUILD_PROFILE=integer-ports-lint-3-system-1 LINT_EXTRA=-Wno-fatal \
			VFLAGS="-DRAPT_INTEGER_ISSUE_PORTS=3 -DRAPT_INTEGER_SYSTEM_PORT=1" >"$$log" 2>&1; then \
			tail -80 "$$log"; exit 1; \
		fi; \
		warnings=$$(grep -c '^%Warning-' "$$log" || true); \
		report=$$(grep 'Built from' "$$log" | tail -1); \
		echo "[verilator-port-matrix] port=3 system=1 warnings=$$warnings $${report#*- Verilator: }"

INTEGER_PORT2_BIN ?= $(NSIM_HOME)/build/integer-ports-2-current/riscv32-npc-sim## Current default two-port simulator
INTEGER_PORT3_BIN ?= $(NSIM_HOME)/build/integer-ports-3/riscv32-npc-sim## Current default three-port simulator
INTEGER_PORT_COREMARK_IMG ?= $(AM_KERNELS)/benchmarks/coremark_eembc/build/coremark-riscv32-npc.bin## Prebuilt CoreMark comparison image
INTEGER_PORT_MICROBENCH_IMG ?= $(AM_KERNELS)/benchmarks/microbench/build/microbench-riscv32-npc.bin## Prebuilt MicroBench image
INTEGER_PORT_WORKLOAD_TIMEOUT ?= 600## Per long-workload simulator timeout
INTEGER_SYSTEM_PORT_BIN ?= $(NSIM_HOME)/build/integer-ports-3-system-1/riscv32-npc-sim## Three-port simulator with system capability at port 1
INTEGER_SYSTEM_PORT_FP_DIR := $(BUILD_DIR)/integer-system-port-fp
ROB_DISPATCH_BASELINE_BIN ?= $(NSIM_HOME)/build/dispatch-coupled-n2/riscv32-npc-sim## Coupled allocation/endpoint baseline
ROB_DISPATCH_CANDIDATE_BIN ?= $(NSIM_HOME)/build/rob-dispatch-hierarchical-n2/riscv32-npc-sim## Buffered fall-through plus hierarchical selector
ROB_DISPATCH_SCAN4_BIN ?= $(NSIM_HOME)/build/rob-dispatch-scan4-n2/riscv32-npc-sim## Explicit W2/K4 simulator for steering sweep
ROB_DISPATCH_SCAN8_BIN ?= $(NSIM_HOME)/build/rob-dispatch-scan8-n2/riscv32-npc-sim## Explicit W2/K8 simulator for steering sweep
DISPATCH_STEER_PPA_PDK ?= nangate45## Standard-cell library for steering PPA comparison
DISPATCH_STEER_PPA_CONFIG ?= default## Core configuration used for W/ROB dimensions
DISPATCH_STEER_PPA_ROOT ?= $(BUILD_DIR)/dispatch-timing/$(DISPATCH_STEER_PPA_PDK)## Isolated PPA artifacts
DISPATCH_STEER_PPA_COMMON = PDK=$(DISPATCH_STEER_PPA_PDK) \
	RAPT_CONFIG=$(DISPATCH_STEER_PPA_CONFIG) CLK_FREQ_MHZ=100 IO_DELAY_FRAC=0 \
	OUTPUT_LOAD_FF=5.0 SRAM_MODE=flops GENERATE_PROFILE_SUMMARY=0
DISPATCH_STEER_PPA_CASE_TARGETS := dispatch-steer-ppa-dpu-k4 \
	dispatch-steer-ppa-dpu-k8 dispatch-steer-ppa-select-k4 \
	dispatch-steer-ppa-select-k8 dispatch-steer-ppa-steer-k4 \
	dispatch-steer-ppa-steer-k8
.PHONY: integer-issue-port-evaluate integer-issue-port-workloads \
	execution-port-workload-parser-test integer-system-port-fp-test \
	rob-dispatch-evaluate rob-dispatch-workloads rob-dispatch-report \
	rob-dispatch-scan-build rob-dispatch-scan-evaluate \
	rob-dispatch-scan-workloads rob-dispatch-scan-report \
	dispatch-steer-ppa dispatch-steer-ppa-build dispatch-steer-ppa-report \
	dispatch-steer-ppa-parser-test $(DISPATCH_STEER_PPA_CASE_TARGETS)
integer-issue-port-evaluate: ## Compare two/three-port simulators over all RV32 cpu-tests
	@test -x "$(INTEGER_PORT2_BIN)" || { echo "missing $(INTEGER_PORT2_BIN)"; exit 1; }
	@test -x "$(INTEGER_PORT3_BIN)" || { echo "missing $(INTEGER_PORT3_BIN)"; exit 1; }
	$(PYTHON) "$(VERIFY_HOME)/scripts/width_evaluate.py" --all-cases \
		--profile ports2="$(INTEGER_PORT2_BIN)" \
		--profile ports3="$(INTEGER_PORT3_BIN)" \
		--output "$(BUILD_DIR)/integer-ports-2-vs-3-current"

integer-issue-port-workloads: ## Compare two/three-port simulators on CoreMark and MicroBench
	@test -x "$(INTEGER_PORT2_BIN)" || { echo "missing $(INTEGER_PORT2_BIN)"; exit 1; }
	@test -x "$(INTEGER_PORT3_BIN)" || { echo "missing $(INTEGER_PORT3_BIN)"; exit 1; }
	@test -f "$(INTEGER_PORT_COREMARK_IMG)" || { echo "missing $(INTEGER_PORT_COREMARK_IMG)"; exit 1; }
	@test -f "$(INTEGER_PORT_MICROBENCH_IMG)" || { echo "missing $(INTEGER_PORT_MICROBENCH_IMG)"; exit 1; }
	$(PYTHON) "$(VERIFY_HOME)/scripts/execution_port_workloads.py" \
		--profile ports2="$(INTEGER_PORT2_BIN)" \
		--profile ports3="$(INTEGER_PORT3_BIN)" \
		--workload coremark="$(INTEGER_PORT_COREMARK_IMG)" \
		--workload microbench="$(INTEGER_PORT_MICROBENCH_IMG)" \
		--timeout "$(INTEGER_PORT_WORKLOAD_TIMEOUT)" \
		--output "$(BUILD_DIR)/integer-port-workloads"

execution-port-workload-parser-test:
	$(PYTHON) "$(VERIFY_HOME)/scripts/test_execution_port_workloads.py"
	$(PYTHON) "$(VERIFY_HOME)/scripts/test_execution_port_report.py"

.PHONY: integer-issue-port-report
integer-issue-port-report: ## Summarize dispatch-domain bottlenecks in the latest long-workload result
	$(PYTHON) "$(VERIFY_HOME)/scripts/execution_port_report.py" \
		"$(BUILD_DIR)/integer-port-workloads/results.json"

rob-dispatch-evaluate: ## Compare coupled and decoupled ROB dispatch over all RV32 cpu-tests
	@test -x "$(ROB_DISPATCH_BASELINE_BIN)" || { echo "missing $(ROB_DISPATCH_BASELINE_BIN)"; exit 1; }
	@test -x "$(ROB_DISPATCH_CANDIDATE_BIN)" || { echo "missing $(ROB_DISPATCH_CANDIDATE_BIN)"; exit 1; }
	$(PYTHON) "$(VERIFY_HOME)/scripts/width_evaluate.py" --all-cases \
		--profile coupled="$(ROB_DISPATCH_BASELINE_BIN)" \
		--profile fallthrough="$(ROB_DISPATCH_CANDIDATE_BIN)" \
		--output "$(BUILD_DIR)/rob-dispatch-evaluation"

rob-dispatch-workloads: ## Compare coupled and decoupled ROB dispatch on long workloads
	@test -x "$(ROB_DISPATCH_BASELINE_BIN)" || { echo "missing $(ROB_DISPATCH_BASELINE_BIN)"; exit 1; }
	@test -x "$(ROB_DISPATCH_CANDIDATE_BIN)" || { echo "missing $(ROB_DISPATCH_CANDIDATE_BIN)"; exit 1; }
	@test -f "$(INTEGER_PORT_COREMARK_IMG)" || { echo "missing $(INTEGER_PORT_COREMARK_IMG)"; exit 1; }
	@test -f "$(INTEGER_PORT_MICROBENCH_IMG)" || { echo "missing $(INTEGER_PORT_MICROBENCH_IMG)"; exit 1; }
	$(PYTHON) "$(VERIFY_HOME)/scripts/execution_port_workloads.py" \
		--profile coupled="$(ROB_DISPATCH_BASELINE_BIN)" \
		--profile fallthrough="$(ROB_DISPATCH_CANDIDATE_BIN)" \
		--workload coremark="$(INTEGER_PORT_COREMARK_IMG)" \
		--workload microbench="$(INTEGER_PORT_MICROBENCH_IMG)" \
		--timeout "$(INTEGER_PORT_WORKLOAD_TIMEOUT)" \
		--output "$(BUILD_DIR)/rob-dispatch-workloads"

rob-dispatch-report: ## Report allocation and endpoint pressure for ROB dispatch profiles
	$(PYTHON) "$(VERIFY_HOME)/scripts/execution_port_report.py" \
		"$(BUILD_DIR)/rob-dispatch-workloads/results.json"

rob-dispatch-scan-build: ## Build explicit coupled, W2/K4 and W2/K8 simulator profiles
	$(MAKE) -C $(NSIM_HOME) all RAPT_CONFIG=default BUILD_PROFILE=dispatch-coupled-n2 \
		VFLAGS="-DRAPT_ROB_DISPATCH_BUFFERED=0 -DRAPT_STEER_SCAN_ENTRIES=2" \
		VERILATOR_EXTRA="-Wno-UNOPTFLAT"
	$(MAKE) -C $(NSIM_HOME) all RAPT_CONFIG=default BUILD_PROFILE=rob-dispatch-scan4-n2 \
		VFLAGS="-DRAPT_STEER_SCAN_ENTRIES=4"
	$(MAKE) -C $(NSIM_HOME) all RAPT_CONFIG=default BUILD_PROFILE=rob-dispatch-scan8-n2 \
		VFLAGS="-DRAPT_STEER_SCAN_ENTRIES=8"

rob-dispatch-scan-evaluate: ## Compare coupled, W2/K4 and W2/K8 over all RV32 cpu-tests
	@test -x "$(ROB_DISPATCH_BASELINE_BIN)" || { echo "missing $(ROB_DISPATCH_BASELINE_BIN)"; exit 1; }
	@test -x "$(ROB_DISPATCH_SCAN4_BIN)" || { echo "missing $(ROB_DISPATCH_SCAN4_BIN)"; exit 1; }
	@test -x "$(ROB_DISPATCH_SCAN8_BIN)" || { echo "missing $(ROB_DISPATCH_SCAN8_BIN)"; exit 1; }
	$(PYTHON) "$(VERIFY_HOME)/scripts/width_evaluate.py" --all-cases \
		--profile coupled="$(ROB_DISPATCH_BASELINE_BIN)" \
		--profile scan4="$(ROB_DISPATCH_SCAN4_BIN)" \
		--profile scan8="$(ROB_DISPATCH_SCAN8_BIN)" \
		--output "$(BUILD_DIR)/rob-dispatch-scan-sweep-cpu"

rob-dispatch-scan-workloads: ## Compare coupled, W2/K4 and W2/K8 on long workloads
	@test -x "$(ROB_DISPATCH_BASELINE_BIN)" || { echo "missing $(ROB_DISPATCH_BASELINE_BIN)"; exit 1; }
	@test -x "$(ROB_DISPATCH_SCAN4_BIN)" || { echo "missing $(ROB_DISPATCH_SCAN4_BIN)"; exit 1; }
	@test -x "$(ROB_DISPATCH_SCAN8_BIN)" || { echo "missing $(ROB_DISPATCH_SCAN8_BIN)"; exit 1; }
	@test -f "$(INTEGER_PORT_COREMARK_IMG)" || { echo "missing $(INTEGER_PORT_COREMARK_IMG)"; exit 1; }
	@test -f "$(INTEGER_PORT_MICROBENCH_IMG)" || { echo "missing $(INTEGER_PORT_MICROBENCH_IMG)"; exit 1; }
	$(PYTHON) "$(VERIFY_HOME)/scripts/execution_port_workloads.py" \
		--profile coupled="$(ROB_DISPATCH_BASELINE_BIN)" \
		--profile scan4="$(ROB_DISPATCH_SCAN4_BIN)" \
		--profile scan8="$(ROB_DISPATCH_SCAN8_BIN)" \
		--workload coremark="$(INTEGER_PORT_COREMARK_IMG)" \
		--workload microbench="$(INTEGER_PORT_MICROBENCH_IMG)" \
		--timeout "$(INTEGER_PORT_WORKLOAD_TIMEOUT)" \
		--output "$(BUILD_DIR)/rob-dispatch-scan-sweep-workloads"

rob-dispatch-scan-report: ## Report endpoint pressure for the K=4/K=8 steering sweep
	$(PYTHON) "$(VERIFY_HOME)/scripts/execution_port_report.py" \
		"$(BUILD_DIR)/rob-dispatch-scan-sweep-workloads/results.json"

dispatch-steer-ppa: dispatch-steer-ppa-report ## Map and compare K4/K8 steering cones

dispatch-steer-ppa-build: ## Build six zero-I/O-delay technology-mapped steering cases
	+$(MAKE) --no-print-directory --output-sync=target $(SUBMAKE_JOBS) \
		$(DISPATCH_STEER_PPA_CASE_TARGETS)

dispatch-steer-ppa-dpu-k4:
	+$(MAKE) -C "$(RAPTOR_HOME)/lspd/syn" ppa MODULE=dpu \
		$(DISPATCH_STEER_PPA_COMMON) EXTRA_DEFINES=-DRAPT_STEER_SCAN_ENTRIES=4 \
		BUILD_DIR="$(DISPATCH_STEER_PPA_ROOT)/dpu-k4-io0"

dispatch-steer-ppa-dpu-k8:
	+$(MAKE) -C "$(RAPTOR_HOME)/lspd/syn" ppa MODULE=dpu \
		$(DISPATCH_STEER_PPA_COMMON) EXTRA_DEFINES=-DRAPT_STEER_SCAN_ENTRIES=8 \
		BUILD_DIR="$(DISPATCH_STEER_PPA_ROOT)/dpu-k8-io0"

dispatch-steer-ppa-select-k4:
	+$(MAKE) -C "$(RAPTOR_HOME)/lspd/syn" ppa MODULE=dispatch_select \
		$(DISPATCH_STEER_PPA_COMMON) EXTRA_DEFINES=-DRAPT_STEER_SCAN_ENTRIES=4 \
		BUILD_DIR="$(DISPATCH_STEER_PPA_ROOT)/select-k4-io0"

dispatch-steer-ppa-select-k8:
	+$(MAKE) -C "$(RAPTOR_HOME)/lspd/syn" ppa MODULE=dispatch_select \
		$(DISPATCH_STEER_PPA_COMMON) EXTRA_DEFINES=-DRAPT_STEER_SCAN_ENTRIES=8 \
		BUILD_DIR="$(DISPATCH_STEER_PPA_ROOT)/select-k8-io0"

dispatch-steer-ppa-steer-k4:
	+$(MAKE) -C "$(RAPTOR_HOME)/lspd/syn" ppa MODULE=dispatch_steer \
		$(DISPATCH_STEER_PPA_COMMON) EXTRA_DEFINES=-DRAPT_STEER_SCAN_ENTRIES=4 \
		BUILD_DIR="$(DISPATCH_STEER_PPA_ROOT)/steer-k4-io0"

dispatch-steer-ppa-steer-k8:
	+$(MAKE) -C "$(RAPTOR_HOME)/lspd/syn" ppa MODULE=dispatch_steer \
		$(DISPATCH_STEER_PPA_COMMON) EXTRA_DEFINES=-DRAPT_STEER_SCAN_ENTRIES=8 \
		BUILD_DIR="$(DISPATCH_STEER_PPA_ROOT)/steer-k8-io0"

dispatch-steer-ppa-report: dispatch-steer-ppa-build ## Validate provenance and emit JSON/Markdown K4/K8 PPA comparison
	$(PYTHON) "$(VERIFY_HOME)/scripts/dispatch_steer_ppa.py" \
		--root "$(DISPATCH_STEER_PPA_ROOT)" \
		--output "$(BUILD_DIR)/dispatch-timing/report"

dispatch-steer-ppa-parser-test: ## Unit-test steering PPA parser and provenance rejection
	$(PYTHON) "$(VERIFY_HOME)/scripts/test_dispatch_steer_ppa.py"

ROU_STATE_PPA_BASELINE ?= $(BUILD_DIR)/rou-array-state-ppa
ROU_STATE_PPA_CANDIDATE ?= $(BUILD_DIR)/rou-local-state-ppa
.PHONY: rou-state-ppa-report rou-state-ppa-parser-test
rou-state-ppa-report: ## Compare existing full-ROU runs; does not launch synthesis
	$(PYTHON) "$(VERIFY_HOME)/scripts/rou_state_evaluate.py" \
		--baseline "$(ROU_STATE_PPA_BASELINE)" --candidate "$(ROU_STATE_PPA_CANDIDATE)" \
		--output "$(BUILD_DIR)/rou-state-evaluation"
rou-state-ppa-parser-test: ## Test full-ROU comparison and provenance rejection
	$(PYTHON) "$(VERIFY_HOME)/scripts/test_rou_state_evaluate.py"

ORDERED_HEAD_FP_BIN ?= $(NPC_BIN_32)
ORDERED_HEAD_FP_DIR := $(BUILD_DIR)/ordered-head-fp-rv32
.PHONY: ordered-head-fp-rv32
ordered-head-fp-rv32: ## Mixed load/S/D arithmetic self-check on an already-built RV32 simulator
	@test -x "$(ORDERED_HEAD_FP_BIN)" && test -f "$(NEMU_SO_32)" && test -f "$(MROM_IMG)"
	@mkdir -p "$(ORDERED_HEAD_FP_DIR)"
	$(CC) -march=rv32imafdc_zicsr -mabi=ilp32 -nostdlib -nostartfiles \
		-T "$(VERIFY_HOME)/scripts/fuzz_link.ld" -o "$(ORDERED_HEAD_FP_DIR)/test.elf" \
		"$(RAPTOR_HOME)/app/tests/baremetal/ordered_head_fp.S"
	$(OBJCOPY) -O binary "$(ORDERED_HEAD_FP_DIR)/test.elf" "$(ORDERED_HEAD_FP_DIR)/test.bin"
	@set -e; cd "$(NSIM_HOME)"; \
		"$(ORDERED_HEAD_FP_BIN)" -b -n --no-lightsss -t 120 \
		-d "$(NEMU_SO_32)" -r "$(MROM_IMG)" "$(ORDERED_HEAD_FP_DIR)/test.bin" \
		>"$(ORDERED_HEAD_FP_DIR)/run.log" 2>&1
	@grep -q "HIT GOOD TRAP" "$(ORDERED_HEAD_FP_DIR)/run.log"
	@! grep -qiE "HIT BAD TRAP|mismatch|\\[ERROR\\]" "$(ORDERED_HEAD_FP_DIR)/run.log"
	@echo "PASS: ordered-head FP RV32 mixed load/S/D arithmetic"

FP_PRODUCT_STREAM_BIN ?= $(NPC_BIN_$(FP_PRODUCT_STREAM_XLEN))
FP_PRODUCT_STREAM_REF ?= $(NEMU_SO_$(FP_PRODUCT_STREAM_XLEN))
FP_PRODUCT_STREAM_DIR = $(BUILD_DIR)/fp-product-stream-rv$(FP_PRODUCT_STREAM_XLEN)
.PHONY: fp-product-stream-rv32 fp-product-stream-rv64
fp-product-stream-rv32: FP_PRODUCT_STREAM_XLEN = 32
fp-product-stream-rv64: FP_PRODUCT_STREAM_XLEN = 64
fp-product-stream-rv32 fp-product-stream-rv64: ## MUL/FMA handoff and flags on an already-built simulator; supply matching MROM_IMG
	@test -x "$(FP_PRODUCT_STREAM_BIN)" && test -f "$(FP_PRODUCT_STREAM_REF)" && test -f "$(MROM_IMG)"
	@mkdir -p "$(FP_PRODUCT_STREAM_DIR)"
	$(CC) -march=rv$(FP_PRODUCT_STREAM_XLEN)imafdc_zicsr \
		-mabi=$(if $(filter 64,$(FP_PRODUCT_STREAM_XLEN)),lp64,ilp32) -nostdlib -nostartfiles \
		-T "$(VERIFY_HOME)/scripts/fuzz_link.ld" -o "$(FP_PRODUCT_STREAM_DIR)/test.elf" \
		"$(RAPTOR_HOME)/app/tests/baremetal/fp_product_stream.S"
	$(OBJCOPY) -O binary "$(FP_PRODUCT_STREAM_DIR)/test.elf" "$(FP_PRODUCT_STREAM_DIR)/test.bin"
	@sha256sum "$(FP_PRODUCT_STREAM_BIN)" "$(FP_PRODUCT_STREAM_REF)" "$(MROM_IMG)" \
		"$(FP_PRODUCT_STREAM_DIR)/test.bin" > "$(FP_PRODUCT_STREAM_DIR)/inputs.sha256"
	@set -e; cd "$(NSIM_HOME)"; \
		"$(FP_PRODUCT_STREAM_BIN)" -b -n --no-lightsss -t 120 \
		-d "$(FP_PRODUCT_STREAM_REF)" -r "$(MROM_IMG)" "$(FP_PRODUCT_STREAM_DIR)/test.bin" \
		>"$(FP_PRODUCT_STREAM_DIR)/run.log" 2>&1
	@grep -q "HIT GOOD TRAP" "$(FP_PRODUCT_STREAM_DIR)/run.log"
	@! grep -qiE 'HIT BAD TRAP|mismatch|\[ERROR\]' "$(FP_PRODUCT_STREAM_DIR)/run.log"
	@echo "PASS: FP product stream RV$(FP_PRODUCT_STREAM_XLEN)"

integer-system-port-fp-test: ## Check FP/system shared completion with system capability at port 1
	@test -x "$(INTEGER_SYSTEM_PORT_BIN)" || { echo "missing $(INTEGER_SYSTEM_PORT_BIN)"; exit 1; }
	@mkdir -p "$(INTEGER_SYSTEM_PORT_FP_DIR)"
	$(CC) -march=rv32imafdc_zicsr -mabi=ilp32 -nostdlib -nostartfiles \
		-T "$(VERIFY_HOME)/scripts/fuzz_link.ld" \
		-o "$(INTEGER_SYSTEM_PORT_FP_DIR)/test.elf" \
		"$(RAPTOR_HOME)/app/tests/baremetal/integer_system_port_fp.S"
	$(OBJCOPY) -O binary "$(INTEGER_SYSTEM_PORT_FP_DIR)/test.elf" \
		"$(INTEGER_SYSTEM_PORT_FP_DIR)/test.bin"
	@if ! (cd "$(NSIM_HOME)"; \
		"$(INTEGER_SYSTEM_PORT_BIN)" -b -n --no-lightsss -t 120 \
		-d "$(NEMU_SO_32)" -r "$(MROM_IMG)" \
		"$(INTEGER_SYSTEM_PORT_FP_DIR)/test.bin" \
		>"$(INTEGER_SYSTEM_PORT_FP_DIR)/run.log" 2>&1); then \
		tail -80 "$(INTEGER_SYSTEM_PORT_FP_DIR)/run.log"; exit 1; \
	fi
	@grep -q "HIT GOOD TRAP" "$(INTEGER_SYSTEM_PORT_FP_DIR)/run.log" || { \
		tail -80 "$(INTEGER_SYSTEM_PORT_FP_DIR)/run.log"; exit 1; }
	@! grep -qiE "HIT BAD TRAP|mismatch|ERROR" "$(INTEGER_SYSTEM_PORT_FP_DIR)/run.log" || { \
		tail -80 "$(INTEGER_SYSTEM_PORT_FP_DIR)/run.log"; exit 1; }
	@echo "[integer-system-port] FP result, fflags CSR, NEMU difftest: PASS"

verilator-alu-zbb-strlen:
	$(call VERILATOR_DIRECTED_RUN,alu_zbb_strlen,tb_alu_zbb_strlen,$(XSIM_ALU_SOURCES),-d RAPT_RV64,)
.PHONY: verilator-alu-cpop
verilator-alu-cpop: VERILATOR_DIRECTED_FLAGS = --binary --timing --assert -j 2
verilator-alu-cpop:
	$(call VERILATOR_DIRECTED_RUN,alu_cpop,tb_alu_cpop,$(XSIM_ALU_SOURCES),,)
verilator-l2:
	$(call VERILATOR_DIRECTED_RUN,l2,tb_l2_ordered_mmio,$(XSIM_L2_SOURCES),-d RAPT_L2_EN,)
verilator-l1d-data verilator-l1d-tags: VERILATOR_DIRECTED_FLAGS = --binary --timing --assert -j 1
verilator-cache-replacement verilator-sq-forward-ports verilator-sq-forward-ports-rv64: VERILATOR_DIRECTED_FLAGS = --binary --timing --assert -j 1
verilator-cache-replacement:
	$(call VERILATOR_DIRECTED_RUN,cache_replacement,tb_cache_replacement,"$(RAPTOR_HOME)/hdl/memory/rapt_cache_plru.sv" "$(RAPTOR_HOME)/hdl/memory/rapt_cache_fill_select.sv",,)
verilator-l1d-replacement: VERILATOR_DIRECTED_FLAGS = --binary --timing --assert -j 1
verilator-l1d-replacement:
	$(call VERILATOR_DIRECTED_RUN,l1d_replacement,tb_l1d_replacement,"$(RAPTOR_HOME)/hdl/memory/rapt_cache_plru.sv" "$(RAPTOR_HOME)/hdl/memory/rapt_cache_fill_select.sv" "$(RAPTOR_HOME)/hdl/memory/rapt_l1d_tags.sv",,)
verilator-l1i-width-window-4way: VERILATOR_DIRECTED_FLAGS += -GWays=4
verilator-l1i-width-window-4way:
	$(call VERILATOR_DIRECTED_RUN,l1i_width_window_4way,tb_l1i_width_window,$(XSIM_L1I_SOURCES),-d RAPT_ASSERT_EN,)
verilator-l1i-width-window-8way: VERILATOR_DIRECTED_FLAGS += -GWays=8
verilator-l1i-width-window-8way:
	$(call VERILATOR_DIRECTED_RUN,l1i_width_window_8way,tb_l1i_width_window,$(XSIM_L1I_SOURCES),-d RAPT_ASSERT_EN,)
verilator-sq-forward-ports:
	$(call VERILATOR_DIRECTED_RUN,sq_forward_ports,tb_sq_forward_ports,"$(RAPTOR_HOME)/hdl/backend/lsu/rapt_sq_forward.sv",,)
verilator-sq-forward-ports-rv64:
	$(call VERILATOR_DIRECTED_RUN,sq_forward_ports_rv64,tb_sq_forward_ports,"$(RAPTOR_HOME)/hdl/backend/lsu/rapt_sq_forward.sv",-d RAPT_RV64,)
verilator-l1d-data:
	$(call VERILATOR_DIRECTED_RUN,l1d_data,tb_l1d_data,"$(RAPTOR_HOME)/hdl/memory/rapt_sram_1rw.sv" "$(RAPTOR_HOME)/hdl/memory/rapt_l1d_data.sv",,)
verilator-l1d-tags:
	$(call VERILATOR_DIRECTED_RUN,l1d_tags,tb_l1d_tags,"$(RAPTOR_HOME)/hdl/memory/rapt_cache_plru.sv" "$(RAPTOR_HOME)/hdl/memory/rapt_cache_fill_select.sv" "$(RAPTOR_HOME)/hdl/memory/rapt_l1d_tags.sv",,)
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

.PHONY: verilator-l1i-zero-va
verilator-l1i-zero-va:
	$(call VERILATOR_DIRECTED_RUN,l1i_zero_va,tb_l1i_sret_priv_epoch,$(XSIM_L1I_SOURCES),-d RAPT_ASSERT_EN -d RAPT_TEST_ZERO_PC,)
.PHONY: verilator-l1i-zero-va-rv64 verilator-l1i-sret-priv-epoch-rv64
verilator-l1i-zero-va-rv64:
	$(call VERILATOR_DIRECTED_RUN,l1i_zero_va_rv64,tb_l1i_sret_priv_epoch,$(XSIM_L1I_SOURCES),-d RAPT_ASSERT_EN -d RAPT_TEST_ZERO_PC -d RAPT_RV64,)
verilator-l1i-sret-priv-epoch-rv64:
	$(call VERILATOR_DIRECTED_RUN,l1i_sret_priv_epoch_rv64,tb_l1i_sret_priv_epoch,$(XSIM_L1I_SOURCES),-d RAPT_ASSERT_EN -d RAPT_RV64,)
verilator-ptw-kill-drain:
	$(call VERILATOR_DIRECTED_RUN,ptw_kill_drain,tb_ptw_kill_drain,$(XSIM_PTW_SOURCES),-d RAPT_ASSERT_EN,)
verilator-ptw-profile-negative:
	$(call VERILATOR_DIRECTED_RUN,ptw_profile_negative,tb_ptw_profile_negative,$(XSIM_PTW_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,)
verilator-ptw-global-rv32:
	$(call VERILATOR_DIRECTED_RUN,ptw_global_rv32,tb_ptw_global,$(XSIM_PTW_SOURCES),-d RAPT_ASSERT_EN,)
verilator-ptw-global-rv64:
	$(call VERILATOR_DIRECTED_RUN,ptw_global_rv64,tb_ptw_global,$(XSIM_PTW_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,)
.PHONY: verilator-ptw-pbmt
verilator-ptw-pbmt:
	$(call VERILATOR_DIRECTED_RUN,ptw_pbmt,tb_ptw_pbmt,$(XSIM_PTW_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,)
verilator-idu-illegal-stval:
	$(call VERILATOR_DIRECTED_RUN,idu_illegal_stval,tb_idu_illegal_stval,$(XSIM_IDU_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,)
verilator-idu-zfhmin:
	$(call VERILATOR_DIRECTED_RUN,idu_zfhmin,tb_idu_zfhmin,$(XSIM_IDU_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,)
verilator-idu-cmo:
	$(call VERILATOR_DIRECTED_RUN,idu_cmo,tb_idu_cmo,$(XSIM_IDU_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,)
verilator-idu-privileged-rv32:
	$(call VERILATOR_DIRECTED_RUN,idu_privileged_rv32,tb_idu_privileged,$(XSIM_IDU_SOURCES),-d RAPT_ASSERT_EN,)

.PHONY: verilator-idu-zkt-rv32 verilator-idu-zkt-rv64
verilator-idu-zkt-rv32 verilator-idu-zkt-rv64:
	$(PYTHON) "$(VERIFY_HOME)/scripts/zkt_decode_vectors.py" --xlen $(if $(findstring rv64,$@),64,32) --output "$(BUILD_DIR)/$@-vectors"
	$(call VERILATOR_DIRECTED_RUN,$(subst -,_,$@),tb_idu_zkt,$(XSIM_IDU_SOURCES),$(if $(findstring rv64,$@),-d RAPT_RV64),+vectors=$(abspath $(BUILD_DIR)/$@-vectors/vectors.txt))

.PHONY: rva22s64-zkt-core-timing-run
rva22s64-zkt-core-timing-run: $(MROM_IMG)
	$(PYTHON) "$(VERIFY_HOME)/scripts/zkt_core_timing.py" --xlen $(RVA22S64_XLEN) \
		--npc "$(RVA22S64_NPC)" --reference "$(NEMU_SO_$(RVA22S64_XLEN))" \
		--output "$(BUILD_DIR)/zkt-core-timing"
verilator-idu-privileged-rv64:
	$(call VERILATOR_DIRECTED_RUN,idu_privileged_rv64,tb_idu_privileged,$(XSIM_IDU_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,)

# End-to-end supervisor test: caller supplies freshly built RV64 DUT/reference.
# Separate build/run targets keep shared simulator configuration mutations
# explicit and allow repeated memory timing runs with the exact same binaries.
RVA22S64_XLEN ?= 64
RVA22S64_CORE_PROFILE ?= rva22s64-rv$(RVA22S64_XLEN)
RVA22S64_PRIV_DIR := $(BUILD_DIR)/rva22s64-privileged-rv$(RVA22S64_XLEN)
RVA22S64_NPC ?= $(NSIM_HOME)/build/$(RVA22S64_CORE_PROFILE)/riscv$(RVA22S64_XLEN)-npc-sim
.PHONY: rva22s64-privileged-build rva22s64-privileged-run rva22s64-privileged-run-rv32 rva22s64-privileged-run-rv64
rva22s64-privileged-run-rv32:
	$(MAKE) rva22s64-privileged-run RVA22S64_XLEN=32
rva22s64-privileged-run-rv64:
	$(MAKE) rva22s64-privileged-run RVA22S64_XLEN=64
rva22s64-privileged-build:
	$(MAKE) -C "$(RAPTOR_HOME)" verilog
	$(MAKE) -C "$(RAPTOR_HOME)" config-nemu$(RVA22S64_XLEN)-ref
	$(MAKE) -C "$(NSIM_HOME)" RAPT_CONFIG=default BUILD_PROFILE="$(RVA22S64_CORE_PROFILE)" VFLAGS="$(if $(filter 64,$(RVA22S64_XLEN)),-DRAPT_RV64,)"
rva22s64-privileged-run: $(MROM_IMG)
	@mkdir -p "$(RVA22S64_PRIV_DIR)"
	$(CC) -march=rv$(RVA22S64_XLEN)imac_zicsr_zifencei -mabi=$(if $(filter 64,$(RVA22S64_XLEN)),lp64,ilp32) -nostdlib -nostartfiles -static \
		-Wl,--no-relax -T "$(FUZZ_LINKER)" "$(RAPTOR_HOME)/app/tests/baremetal/rva22s64_privileged.S" \
		-o "$(RVA22S64_PRIV_DIR)/privileged.elf"
	$(OBJCOPY) -O binary "$(RVA22S64_PRIV_DIR)/privileged.elf" "$(RVA22S64_PRIV_DIR)/privileged.bin"
	$(PYTHON) "$(VERIFY_HOME)/scripts/rva22s64_privileged.py" \
		--npc "$(RVA22S64_NPC)" --reference "$(NEMU_SO_$(RVA22S64_XLEN))" --mrom "$(MROM_IMG)" \
		--image "$(RVA22S64_PRIV_DIR)/privileged.bin" --output "$(RVA22S64_PRIV_DIR)/runs"
.PHONY: verilator-tlb-flush-asid-rv64
verilator-tlb-flush-asid-rv64:
	$(call VERILATOR_DIRECTED_RUN,tlb_flush_asid_rv64,tb_tlb_flush_asid,$(XSIM_TLB_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,)
verilator-tlb-flush-asid:
	$(call VERILATOR_DIRECTED_RUN,tlb_flush_asid,tb_tlb_flush_asid,$(XSIM_TLB_SOURCES),-d RAPT_ASSERT_EN,)

.PHONY: rva22s64-compressed-zero-immediate-run rva22s64-compressed-register-legality-run rva22s64-zexth-xlen-run rva22s64-bit-xlen-legality-run rva22s64-m-privileged-edges-run rva22s64-clint-subword-run rva22s64-clint-subword-write-run rva22s64-clint-subword-time-run rva22s64-clint-subword-msip-run rva22s64-plic-contract-run rva22s64-plic-completion-id-run rva22s64-plic-completion-context-run rva22s64-load-pmp-float-run rva22s64-load-pmp-translated-float-run rva22s64-clint-mtime-shared-run rva22s64-clint-mtime-write-run rva22s64-clint-word-irq-run rva22s64-clint-width-run rva22s64-load-pmp-translated-run rva22s64-load-pmp-footprint-run rva22s64-load-overlap-widths-run rva22s64-store-overlap-widths-run rva22s64-store-overlap-run rva22s64-branch-sq-forward-run rva22s64-bare-mode-switch-run rva22s64-ifetch-superpage-replace-run rva22s64-ifetch-asid-recycle-run rva22s64-ifetch-mapping-replace-run rva22s64-fence-i-self-modify-run rva22s64-svpbmt-wrong-ifetch-run rva22s64-svpbmt-wrong-path-run rva22s64-svpbmt-enabled-run rva22s64-bus-write-error-run rva22s64-bus-read-error-run rva22s64-platform-memory-map-run rva22s64-data-span-run rva22s64-readonly-pma-run rva22s64-lrsc-reservation-run rva22s64-lrsc-exact-extent-run rva22s64-lrsc-misaligned-run rva22s64-atomic-pma-run rva22s64-zero-pma-run rva22s64-sram-pma-run rva22s64-ifetch-pma-run rva22s64-ptw-pma-run rva22s64-ifetch-cross-page-run rva22s64-ptw-pmp-span-run rva22s64-amo-access-fault-run rva22s64-amo-page-fault-run rva22s64-amo-minmax-run rva22s64-svinval-page-retry-run rva22s64-fp-page-nested-irq-run rva22s64-fp-page-retry-run rva22s64-hpm-permissions-run rva22s64-fp-context-run rva22s64-fp-privilege-run rva22s64-pmp-address-span-run rva22s64-csr-architectural-run rva22s64-store-cross-page-run rva22s64-split-page-fault-run
# Shared guest sources keep separate named scenarios and output directories.
RVA22S64_TEST_SOURCE ?= $(subst -,_,$(patsubst rva22s64-%-run,%,$@))
rva22s64-readonly-pma-run: RVA22S64_TEST_SOURCE = zero_pma
rva22s64-readonly-pma-run: RVA22S64_CASE_CPPFLAGS = -DPMA_READONLY=1
RVA22S64_TEST_MARCH ?= rv$(RVA22S64_XLEN)imac_zicsr_zifencei
.PHONY: rva22s64-svpbmt-axi-check
.PHONY: rva22s64-svpbmt-cross-page-check
rva22s64-svpbmt-cross-page-check: RVA22S64_XLEN = 64
rva22s64-svpbmt-cross-page-check: $(MROM_IMG)
	$(PYTHON) "$(VERIFY_HOME)/scripts/svpbmt_cross_page.py" \
		--npc "$(RVA22S64_NPC)" --reference "$(NEMU_SO_64)" --mrom "$(MROM_IMG)" \
		--output "$(BUILD_DIR)/svpbmt-cross-page"
# Supply an RV64 DUT built with VFLAGS="-DRAPT_RV64 -DRAPT_AXI_OBSERVE".
rva22s64-svpbmt-axi-check: rva22s64-svpbmt-enabled-run
	$(PYTHON) "$(VERIFY_HOME)/scripts/svpbmt_axi_check.py" \
		--summary "$(BUILD_DIR)/svpbmt-enabled/runs/summary.json" \
		--elf "$(BUILD_DIR)/svpbmt-enabled/test.elf" \
		--output "$(BUILD_DIR)/svpbmt-enabled/axi-summary.json"
.PHONY: rva22s64-svpbmt-wrong-ifetch-check
rva22s64-svpbmt-wrong-ifetch-run: RVA22S64_XLEN = 64
rva22s64-svpbmt-wrong-ifetch-check: rva22s64-svpbmt-wrong-ifetch-run
	$(PYTHON) "$(VERIFY_HOME)/scripts/svpbmt_wrong_ifetch_check.py" \
		--summary "$(BUILD_DIR)/svpbmt-wrong-ifetch/runs/summary.json" \
		--elf "$(BUILD_DIR)/svpbmt-wrong-ifetch/test.elf" \
		--output "$(BUILD_DIR)/svpbmt-wrong-ifetch/ifetch-summary.json"
.PHONY: rva22s64-svpbmt-wrong-path-check
# Also requires RAPT_SPEC_OBSERVE for queue/recovery/commit coverage.
rva22s64-svpbmt-wrong-path-run: RVA22S64_XLEN = 64
rva22s64-svpbmt-wrong-path-check: rva22s64-svpbmt-wrong-path-run
	$(PYTHON) "$(VERIFY_HOME)/scripts/svpbmt_wrong_path_check.py" \
		--summary "$(BUILD_DIR)/svpbmt-wrong-path/runs/summary.json" \
		--elf "$(BUILD_DIR)/svpbmt-wrong-path/test.elf" \
		--output "$(BUILD_DIR)/svpbmt-wrong-path/spec-summary.json"
rva22s64-svinval-page-retry-run rva22s64-fp-page-nested-irq-run rva22s64-fp-page-retry-run rva22s64-hpm-permissions-run rva22s64-fp-context-run rva22s64-fp-privilege-run: RVA22S64_TEST_MARCH = rv$(RVA22S64_XLEN)imafdc_zicsr_zifencei_zfhmin
rva22s64-svinval-page-retry-run rva22s64-fp-page-nested-irq-run rva22s64-fp-page-retry-run: RVA22S64_XLEN = 64
rva22s64-svinval-page-retry-run: RVA22S64_TEST_MARCH = rv64imafdc_zicsr_zifencei_zfhmin_svinval
# The exhaustive HPM permission matrix executes thousands of traps. Delayed
# bus runs need a larger wall-clock budget than the smaller directed programs.
rva22s64-hpm-permissions-run: RVA22S64_RUN_TIMEOUT = 180
rva22s64-svpbmt-enabled-run: RVA22S64_XLEN = 64
rva22s64-svpbmt-enabled-run: RVA22S64_TEST_MARCH = rv64imac_zicsr_zifencei_zicbom
rva22s64-bus-read-error-run rva22s64-data-span-run rva22s64-store-cross-page-run rva22s64-split-page-fault-run rva22s64-split-page-permissions-run: RVA22S64_TEST_MARCH = rv$(RVA22S64_XLEN)imafdc_zicsr_zifencei
rva22s64-compressed-zero-immediate-run rva22s64-compressed-register-legality-run rva22s64-zexth-xlen-run rva22s64-bit-xlen-legality-run rva22s64-m-privileged-edges-run rva22s64-clint-subword-run rva22s64-clint-subword-write-run rva22s64-clint-subword-time-run rva22s64-clint-subword-msip-run rva22s64-plic-contract-run rva22s64-plic-completion-id-run rva22s64-plic-completion-context-run rva22s64-load-pmp-float-run rva22s64-load-pmp-translated-float-run rva22s64-clint-mtime-shared-run rva22s64-clint-mtime-write-run rva22s64-clint-word-irq-run rva22s64-clint-width-run rva22s64-load-pmp-translated-run rva22s64-load-pmp-footprint-run rva22s64-load-overlap-widths-run rva22s64-store-overlap-widths-run rva22s64-store-overlap-run rva22s64-branch-sq-forward-run rva22s64-bare-mode-switch-run rva22s64-ifetch-superpage-replace-run rva22s64-ifetch-asid-recycle-run rva22s64-ifetch-mapping-replace-run rva22s64-fence-i-self-modify-run rva22s64-svpbmt-wrong-ifetch-run rva22s64-svpbmt-wrong-path-run rva22s64-svpbmt-enabled-run rva22s64-bus-write-error-run rva22s64-bus-read-error-run rva22s64-platform-memory-map-run rva22s64-data-span-run rva22s64-readonly-pma-run rva22s64-lrsc-reservation-run rva22s64-lrsc-exact-extent-run rva22s64-lrsc-misaligned-run rva22s64-atomic-pma-run rva22s64-zero-pma-run rva22s64-sram-pma-run rva22s64-ifetch-pma-run rva22s64-ptw-pma-run rva22s64-ifetch-cross-page-run rva22s64-ptw-pmp-span-run rva22s64-amo-access-fault-run rva22s64-amo-page-fault-run rva22s64-amo-minmax-run rva22s64-svinval-page-retry-run rva22s64-fp-page-nested-irq-run rva22s64-fp-page-retry-run rva22s64-hpm-permissions-run rva22s64-fp-context-run rva22s64-fp-privilege-run rva22s64-pmp-address-span-run rva22s64-csr-architectural-run rva22s64-store-cross-page-run rva22s64-split-page-fault-run rva22s64-split-page-permissions-run: $(MROM_IMG)
	@mkdir -p "$(BUILD_DIR)/$(patsubst rva22s64-%-run,%,$@)"
	$(CC) $(RVA22S64_TEST_CPPFLAGS) $(RVA22S64_CASE_CPPFLAGS) -march=$(RVA22S64_TEST_MARCH) -mabi=$(if $(filter 64,$(RVA22S64_XLEN)),lp64,ilp32) -nostdlib -nostartfiles -static \
		-Wl,--no-relax -T "$(FUZZ_LINKER)" "$(RAPTOR_HOME)/app/tests/baremetal/$(RVA22S64_TEST_SOURCE).S" \
		-o "$(BUILD_DIR)/$(patsubst rva22s64-%-run,%,$@)/test.elf"
	$(OBJCOPY) -O binary "$(BUILD_DIR)/$(patsubst rva22s64-%-run,%,$@)/test.elf" "$(BUILD_DIR)/$(patsubst rva22s64-%-run,%,$@)/test.bin"
	$(PYTHON) "$(VERIFY_HOME)/scripts/rva22s64_privileged.py" --name "$(patsubst rva22s64-%-run,%,$@)" \
		--timeout "$(or $(RVA22S64_RUN_TIMEOUT),60)" \
		--npc "$(RVA22S64_NPC)" --reference "$(NEMU_SO_$(RVA22S64_XLEN))" --mrom "$(MROM_IMG)" \
		--image "$(BUILD_DIR)/$(patsubst rva22s64-%-run,%,$@)/test.bin" --output "$(BUILD_DIR)/$(patsubst rva22s64-%-run,%,$@)/runs"
verilator-bus-axi:
	$(call VERILATOR_DIRECTED_RUN,bus_axi,tb_bus_l1d_rlast,$(XSIM_BUS_SOURCES),,)
verilator-bus-read-ownership:
	$(call VERILATOR_DIRECTED_RUN,bus_read_ownership,tb_bus_read_ownership,$(XSIM_BUS_SOURCES),,)
verilator-csr-sret-roundtrip-rv32:
	$(call VERILATOR_DIRECTED_RUN,csr_sret_roundtrip_rv32,tb_csr_sret_roundtrip,$(XSIM_CSR_SOURCES),,)
verilator-csr-sret-roundtrip-rv64:
	$(call VERILATOR_DIRECTED_RUN,csr_sret_roundtrip_rv64,tb_csr_sret_roundtrip,$(XSIM_CSR_SOURCES),-d RAPT_RV64,)

.PHONY: verilator-csr-trap-payload-rv32 verilator-csr-trap-payload-rv64
verilator-csr-trap-payload-rv32 verilator-csr-trap-payload-rv64:
	$(call VERILATOR_DIRECTED_RUN,$(subst -,_,$@),tb_csr_trap_payload,$(XSIM_CSR_SOURCES),$(if $(findstring rv64,$@),-d RAPT_RV64),)
verilator-csr-architectural-rv32:
	$(call VERILATOR_DIRECTED_RUN,csr_architectural_rv32,tb_csr_architectural,$(XSIM_CSR_SOURCES) "$(RAPTOR_HOME)/hdl/backend/ieu/rapt_ieu_alu.sv" "$(RAPTOR_HOME)/hdl/backend/ieu/rapt_ieu_pipe_alu_csr.sv",,)
verilator-csr-architectural-rv64:
	$(call VERILATOR_DIRECTED_RUN,csr_architectural_rv64,tb_csr_architectural,$(XSIM_CSR_SOURCES) "$(RAPTOR_HOME)/hdl/backend/ieu/rapt_ieu_alu.sv" "$(RAPTOR_HOME)/hdl/backend/ieu/rapt_ieu_pipe_alu_csr.sv",-d RAPT_RV64,)
.PHONY: verilator-addr-classification-rv32
verilator-addr-classification verilator-addr-classification-rv32: VERILATOR_DIRECTED_FLAGS = --binary --timing --assert -j 1
verilator-addr-classification-rv32:
	$(call VERILATOR_DIRECTED_RUN,addr_classification_rv32,tb_addr_classification,"$(RAPTOR_HOME)/hdl/rapt_pkg.sv",,)
verilator-addr-classification:
	$(call VERILATOR_DIRECTED_RUN,addr_classification,tb_addr_classification,"$(RAPTOR_HOME)/hdl/rapt_pkg.sv",-d RAPT_RV64,)
verilator-pmp-endpoint:
	$(call VERILATOR_DIRECTED_RUN,pmp_endpoint,tb_pmp_endpoint,"$(RAPTOR_HOME)/hdl/rapt_pkg.sv" "$(RAPTOR_HOME)/hdl/memory/rapt_pmp.sv",,)
.PHONY: verilator-l1d-page-permissions-rv32 verilator-l1d-page-permissions-rv64
verilator-l1d-page-permissions-rv32:
	$(call VERILATOR_DIRECTED_RUN,l1d_page_permissions_rv32,tb_l1d_page_permissions,"$(RAPTOR_HOME)/hdl/rapt_pkg.sv" "$(RAPTOR_HOME)/hdl/memory/rapt_pmp.sv" "$(RAPTOR_HOME)/hdl/memory/rapt_l1d_access.sv",,)
verilator-l1d-page-permissions-rv64:
	$(call VERILATOR_DIRECTED_RUN,l1d_page_permissions_rv64,tb_l1d_page_permissions,"$(RAPTOR_HOME)/hdl/rapt_pkg.sv" "$(RAPTOR_HOME)/hdl/memory/rapt_pmp.sv" "$(RAPTOR_HOME)/hdl/memory/rapt_l1d_access.sv",-d RAPT_RV64,)
.PHONY: verilator-pmp-reset-napot-rv32 verilator-pmp-reset-napot-rv64
verilator-pmp-reset-napot-rv32 verilator-pmp-reset-napot-rv64: VERILATOR_DIRECTED_FLAGS = --binary --timing --assert -j 1
verilator-pmp-reset-napot-rv32:
	$(call VERILATOR_DIRECTED_RUN,pmp_reset_napot_rv32,tb_pmp_reset_napot,"$(VERIFY_HOME)/formal/pmp_formal_if.sv" "$(RAPTOR_HOME)/hdl/memory/rapt_pmp.sv",,)
verilator-pmp-reset-napot-rv64:
	$(call VERILATOR_DIRECTED_RUN,pmp_reset_napot_rv64,tb_pmp_reset_napot,"$(VERIFY_HOME)/formal/pmp_formal_if.sv" "$(RAPTOR_HOME)/hdl/memory/rapt_pmp.sv",-d RAPT_RV64,)
verilator-lsu-lr-sq-forward:
	$(call VERILATOR_DIRECTED_RUN,lsu_lr_sq_forward,tb_lsu_lr_sq_forward,$(XSIM_LSU_SOURCES),-d RAPT_ASSERT_EN,)
verilator-lsu-cbo-zero:
	$(call VERILATOR_DIRECTED_RUN,lsu_cbo_zero,tb_lsu_cbo_zero,$(XSIM_LSU_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,)
verilator-lsu-sq-random:
	$(call VERILATOR_DIRECTED_RUN,lsu_sq_random,tb_lsu_sq_random,$(XSIM_LSU_SOURCES),-d RAPT_ASSERT_EN,+SEED=$(VERILATOR_DIRECTED_SEED))
verilator-ioq:
	$(call VERILATOR_DIRECTED_RUN,ioq,tb_ioq_pending_lock,$(XSIM_IOQ_SOURCES),,)
.PHONY: verilator-ioq-store-pbmt-rv32 verilator-ioq-store-pbmt-rv64
verilator-ioq-store-pbmt-rv32:
	$(call VERILATOR_DIRECTED_RUN,ioq_store_pbmt_rv32,tb_ioq_store_pbmt,$(XSIM_IOQ_SOURCES),-d RAPT_ASSERT_EN,)
verilator-ioq-store-pbmt-rv64:
	$(call VERILATOR_DIRECTED_RUN,ioq_store_pbmt_rv64,tb_ioq_store_pbmt,$(XSIM_IOQ_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,)
.PHONY: verilator-sq-store-pbmt-rv32 verilator-sq-store-pbmt-rv64
verilator-sq-store-pbmt-rv32:
	$(call VERILATOR_DIRECTED_RUN,sq_store_pbmt_rv32,tb_sq_store_pbmt,$(XSIM_LSU_SOURCES),-d RAPT_ASSERT_EN,)
verilator-sq-store-pbmt-rv64:
	$(call VERILATOR_DIRECTED_RUN,sq_store_pbmt_rv64,tb_sq_store_pbmt,$(XSIM_LSU_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,)
.PHONY: verilator-l1d-store-pbmt-rv32 verilator-l1d-store-pbmt-rv64
verilator-l1d-store-pbmt-rv32:
	$(call VERILATOR_DIRECTED_RUN,l1d_store_pbmt_rv32,tb_l1d_store_pbmt,$(XSIM_L1D_SOURCES),-d RAPT_ASSERT_EN,)
verilator-l1d-store-pbmt-rv64:
	$(call VERILATOR_DIRECTED_RUN,l1d_store_pbmt_rv64,tb_l1d_store_pbmt,$(XSIM_L1D_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,)
verilator-clint:
	$(call VERILATOR_DIRECTED_RUN,clint,tb_clint,"$(RAPTOR_HOME)/hdl/perip/rapt_clint.sv",,)

.PHONY: verilator-clint-strobe-rv32 verilator-clint-strobe-rv64
verilator-clint-strobe-rv32 verilator-clint-strobe-rv64: VERILATOR_DIRECTED_FLAGS = --binary --timing --assert -j 2
verilator-clint-strobe-rv32:
	$(call VERILATOR_DIRECTED_RUN,clint_strobe_rv32,tb_clint_strobe,"$(RAPTOR_HOME)/hdl/perip/rapt_clint.sv",,)
verilator-clint-strobe-rv64:
	$(call VERILATOR_DIRECTED_RUN,clint_strobe_rv64,tb_clint_strobe,"$(RAPTOR_HOME)/hdl/perip/rapt_clint.sv",-d RAPT_RV64,)

.PHONY: verilator-router-clint-strobe-rv32 verilator-router-clint-strobe-rv64
verilator-router-clint-strobe-rv32 verilator-router-clint-strobe-rv64: VERILATOR_DIRECTED_FLAGS = --binary --timing --assert -j 2
verilator-router-clint-strobe-rv32:
	$(call VERILATOR_DIRECTED_RUN,router_clint_strobe_rv32,tb_router_clint_strobe,"$(RAPTOR_HOME)/hdl/rapt_router.sv" "$(RAPTOR_HOME)/hdl/perip/rapt_clint.sv",-d RAPT_ASSERT_EN,)
verilator-router-clint-strobe-rv64:
	$(call VERILATOR_DIRECTED_RUN,router_clint_strobe_rv64,tb_router_clint_strobe,"$(RAPTOR_HOME)/hdl/rapt_router.sv" "$(RAPTOR_HOME)/hdl/perip/rapt_clint.sv",-d RAPT_RV64 -d RAPT_ASSERT_EN,)
verilator-plic-gateway:
	$(call VERILATOR_DIRECTED_RUN,plic_gateway,tb_plic_gateway,"$(RAPTOR_HOME)/hdl/perip/rapt_plic.sv",,)

define VERILATOR_PLIC_CONTRACT_RUN
	$(call VERILATOR_DIRECTED_RUN,router_plic_contract_rv$(1),tb_router_plic_contract,"$(RAPTOR_HOME)/hdl/rapt_router.sv" "$(RAPTOR_HOME)/hdl/perip/rapt_plic.sv",$(if $(filter 64,$(1)),-d RAPT_RV64,),)
	@set -e; for case_id in 1 2 3 4 5 6; do \
		"$(VERILATOR_DIRECTED_BUILD_DIR)/router_plic_contract_rv$(1)/obj/tb_router_plic_contract" +CASE=$$case_id \
		> "$(VERILATOR_DIRECTED_BUILD_DIR)/router_plic_contract_rv$(1)/case$$case_id.log" 2>&1; \
		grep 'PASS:' "$(VERILATOR_DIRECTED_BUILD_DIR)/router_plic_contract_rv$(1)/case$$case_id.log"; \
	done
endef
.PHONY: verilator-router-plic-contract-rv32 verilator-router-plic-contract-rv64
verilator-router-plic-contract-rv32 verilator-router-plic-contract-rv64: VERILATOR_DIRECTED_FLAGS = --binary --timing --assert -j 1
verilator-router-plic-contract-rv32:
	$(call VERILATOR_PLIC_CONTRACT_RUN,32)
verilator-router-plic-contract-rv64:
	$(call VERILATOR_PLIC_CONTRACT_RUN,64)
verilator-muldiv-flush-reuse:
	$(call VERILATOR_DIRECTED_RUN,muldiv_flush_reuse,tb_muldiv_flush_reuse,$(XSIM_MULDIV_SOURCES),-d RAPT_ASSERT_EN,)
verilator-muldiv-word-rv64:
	$(call VERILATOR_DIRECTED_RUN,muldiv_word_rv64,tb_muldiv_flush_reuse,$(XSIM_MULDIV_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,)
.PHONY: verilator-div-iterations verilator-div-iterations-rv64
.PHONY: verilator-mdq-zkt-rv32 verilator-mdq-zkt-rv64
verilator-mdq-zkt-rv32 verilator-mdq-zkt-rv64: VERILATOR_DIRECTED_FLAGS = --binary --timing --assert -j 1 -CFLAGS -O0
verilator-mdq-zkt-rv32 verilator-mdq-zkt-rv64:
	$(call VERILATOR_DIRECTED_RUN,$(subst -,_,$@),tb_muldiv_flush_reuse,$(XSIM_MULDIV_SOURCES),-d RAPT_ASSERT_EN -GCheckOperandIndependence=1 $(if $(findstring rv64,$@),-d RAPT_RV64),)

.PHONY: verilator-muldiv-stream verilator-muldiv-stream-rv64
verilator-muldiv-stream verilator-muldiv-stream-rv64:
	$(call VERILATOR_DIRECTED_RUN,$(subst -,_,$@),tb_muldiv_stream,"$(RAPTOR_HOME)/hdl/backend/ieu/rapt_ieu_mul.sv",$(if $(findstring rv64,$@),-d RAPT_RV64),)
verilator-div-iterations verilator-div-iterations-rv64:
	$(call VERILATOR_DIRECTED_RUN,$(subst -,_,$@),tb_div_word_iterations,"$(RAPTOR_HOME)/hdl/backend/ieu/rapt_ieu_mul.sv",$(if $(findstring rv64,$@),-d RAPT_RV64),)
verilator-rou-dual-commit:
	$(call VERILATOR_DIRECTED_RUN,rou_dual_commit,tb_rou_dual_commit,$(XSIM_ROU_SOURCES),-d RAPT_ASSERT_EN,)

.PHONY: verilator-rou-exception-rd-rv32 verilator-rou-exception-rd-rv64
verilator-rou-exception-rd-rv32 verilator-rou-exception-rd-rv64:
	$(call VERILATOR_DIRECTED_RUN,$(subst -,_,$@),tb_rou_dual_commit,$(XSIM_ROU_SOURCES),-d RAPT_ASSERT_EN -d RAPT_TEST_EXCEPTION_RD $(if $(findstring rv64,$@),-d RAPT_RV64),)

.PHONY: verilator-rou-zkt-rv32 verilator-rou-zkt-rv64
verilator-rou-zkt-rv32 verilator-rou-zkt-rv64: VERILATOR_DIRECTED_FLAGS = --binary --timing --assert -Wno-fatal -j 1 -CFLAGS -O0
verilator-rou-zkt-rv32 verilator-rou-zkt-rv64:
	$(call VERILATOR_DIRECTED_RUN,$(subst -,_,$@),tb_rou_dual_commit,$(XSIM_ROU_SOURCES),-d RAPT_ASSERT_EN -GCheckOperandIndependence=1 $(if $(findstring rv64,$@),-d RAPT_RV64),)

.PHONY: verilator-rou-dual-commit-rv64
verilator-rou-dual-commit-rv64:
	$(call VERILATOR_DIRECTED_RUN,rou_dual_commit_rv64,tb_rou_dual_commit,$(XSIM_ROU_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,)

.PHONY: verilator-rou-rvfi verilator-rou-rvfi-rv64 \
	verilator-lsu-store-observation verilator-lsu-store-observation-rv64
verilator-rou-rvfi:
	$(call VERILATOR_DIRECTED_RUN,rou_rvfi,tb_rou_dual_commit,$(XSIM_ROU_SOURCES),-d RAPT_RVFI -d RAPT_ASSERT_EN,)
verilator-rou-rvfi-rv64:
	$(call VERILATOR_DIRECTED_RUN,rou_rvfi_rv64,tb_rou_dual_commit,$(XSIM_ROU_SOURCES),-d RAPT_RVFI -d RAPT_RV64 -d RAPT_ASSERT_EN,)
verilator-lsu-store-observation:
	$(call VERILATOR_DIRECTED_RUN,lsu_store_observation,tb_lsu_store_observation,$(XSIM_LSU_SOURCES),-d RAPT_ASSERT_EN,)
verilator-lsu-store-observation-rv64:
	$(call VERILATOR_DIRECTED_RUN,lsu_store_observation_rv64,tb_lsu_store_observation,$(XSIM_LSU_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,)

.PHONY: verilator-backend-extensibility
.PHONY: verilator-backend-recovery verilator-backend-recovery-rv64
verilator-backend-recovery: VERILATOR_DIRECTED_FLAGS += -GRecoveryExercise=1
verilator-backend-recovery-rv64: VERILATOR_DIRECTED_FLAGS += -GRecoveryExercise=1 -DRAPT_RV64
XSIM_BACKEND_EXT_SOURCES = $(XSIM_ROU_SOURCES) \
	  "$(RAPTOR_HOME)/hdl/frontend/rapt_rename_admit.sv" "$(RAPTOR_HOME)/hdl/frontend/rapt_rnu.sv" \
	  "$(RAPTOR_HOME)/hdl/frontend/rapt_rename_checkpoint.sv" \
	  "$(RAPTOR_HOME)/hdl/frontend/rapt_rnu_maptable.sv" \
	  "$(RAPTOR_HOME)/hdl/frontend/rapt_rnu_freelist.sv" \
	  "$(RAPTOR_HOME)/hdl/backend/rapt_prf.sv" \
	  "$(RAPTOR_HOME)/hdl/common/rapt_issue_select.sv" \
	  "$(RAPTOR_HOME)/hdl/backend/rapt_iq.sv" \
	  "$(RAPTOR_HOME)/hdl/backend/rapt_dpu.sv" \
	  "$(RAPTOR_HOME)/hdl/backend/rapt_dispatch_iq_adapter.sv"
verilator-backend-extensibility:
	$(call VERILATOR_DIRECTED_RUN,backend_extensibility,tb_backend_extensibility,$(XSIM_BACKEND_EXT_SOURCES),-d RAPT_ASSERT_EN,)
verilator-backend-recovery:
	$(call VERILATOR_DIRECTED_RUN,backend_recovery,tb_backend_extensibility,$(XSIM_BACKEND_EXT_SOURCES),-d RAPT_ASSERT_EN,)
verilator-backend-recovery-rv64:
	$(call VERILATOR_DIRECTED_RUN,backend_recovery_rv64,tb_backend_extensibility,$(XSIM_BACKEND_EXT_SOURCES),-d RAPT_ASSERT_EN,)

.PHONY: verilator-iq-type-family
verilator-iq-type-family:
	$(call VERILATOR_DIRECTED_RUN,iq_type_family,tb_iq_type_family,"$(RAPTOR_HOME)/hdl/rapt_pkg.sv" \
	  "$(RAPTOR_HOME)/hdl/common/rapt_issue_select.sv" \
	  "$(RAPTOR_HOME)/hdl/backend/rapt_iq.sv",-d RAPT_ASSERT_EN,)

WIDTH_BACKEND_SOURCES = $(XSIM_ROU_SOURCES) \
  "$(RAPTOR_HOME)/hdl/frontend/rapt_rename_admit.sv" "$(RAPTOR_HOME)/hdl/frontend/rapt_rnu.sv" \
  "$(RAPTOR_HOME)/hdl/frontend/rapt_rename_checkpoint.sv" \
  "$(RAPTOR_HOME)/hdl/backend/rapt_prf.sv" \
  "$(RAPTOR_HOME)/hdl/common/rapt_issue_select.sv" \
  "$(RAPTOR_HOME)/hdl/backend/rapt_iq.sv" \
  "$(RAPTOR_HOME)/hdl/backend/rapt_dpu.sv" \
  "$(RAPTOR_HOME)/hdl/backend/rapt_dispatch_iq_adapter.sv"

.PHONY: verilator-width-1 verilator-width-2 verilator-width-3 verilator-width-4 verilator-width-mixed
verilator-superscalar-widths: verilator-width-1 verilator-width-2 verilator-width-3 verilator-width-4 verilator-width-mixed verilator-width-contract verilator-width-odd
verilator-width-1 verilator-width-2 verilator-width-3 verilator-width-4:
	$(call VERILATOR_DIRECTED_RUN,width_$(lastword $(subst -, ,$@)),tb_superscalar_widths,$(WIDTH_BACKEND_SOURCES),-d RAPT_ASSERT_EN -d RAPT_DECODE_WIDTH=$(lastword $(subst -, ,$@)) -d RAPT_RENAME_WIDTH=$(lastword $(subst -, ,$@)) -d RAPT_DISPATCH_WIDTH=$(lastword $(subst -, ,$@)) -d RAPT_COMMIT_WIDTH=$(lastword $(subst -, ,$@)),)
verilator-width-mixed:
	$(call VERILATOR_DIRECTED_RUN,width_mixed,tb_superscalar_widths,$(WIDTH_BACKEND_SOURCES),-d RAPT_ASSERT_EN -d RAPT_DECODE_WIDTH=3 -d RAPT_RENAME_WIDTH=4 -d RAPT_DISPATCH_WIDTH=3 -d RAPT_COMMIT_WIDTH=4,)
.PHONY: verilator-width-mixed-rv64
verilator-width-mixed-rv64:
	$(call VERILATOR_DIRECTED_RUN,width_mixed_rv64,tb_superscalar_widths,$(WIDTH_BACKEND_SOURCES),-d RAPT_ASSERT_EN -d RAPT_RV64 -d RAPT_DECODE_WIDTH=3 -d RAPT_RENAME_WIDTH=4 -d RAPT_DISPATCH_WIDTH=3 -d RAPT_COMMIT_WIDTH=4,)
.PHONY: verilator-width-contract verilator-width-odd
verilator-width-contract:
	$(call VERILATOR_DIRECTED_RUN,width_contract,tb_superscalar_widths,$(WIDTH_BACKEND_SOURCES),-d RAPT_ASSERT_EN -d RAPT_DECODE_WIDTH=4 -d RAPT_RENAME_WIDTH=1 -d RAPT_DISPATCH_WIDTH=2 -d RAPT_COMMIT_WIDTH=3,)
verilator-width-odd:
	$(call VERILATOR_DIRECTED_RUN,width_odd,tb_superscalar_widths,$(WIDTH_BACKEND_SOURCES),-d RAPT_ASSERT_EN -d RAPT_TEST_ODD_DEPTHS -d RAPT_DECODE_WIDTH=4 -d RAPT_RENAME_WIDTH=3 -d RAPT_DISPATCH_WIDTH=1 -d RAPT_COMMIT_WIDTH=2,)
verilator-stream-queue:
	$(call VERILATOR_DIRECTED_RUN,stream_queue,tb_stream_queue,"$(RAPTOR_HOME)/hdl/rapt_pkg.sv" "$(RAPTOR_HOME)/hdl/common/rapt_stream_queue.sv",-d RAPT_ASSERT_EN,)
.PHONY: verilator-stream-queue-sweep
verilator-stream-queue-sweep:
	$(call VERILATOR_DIRECTED_RUN,stream_queue_sweep,tb_stream_queue,"$(RAPTOR_HOME)/hdl/rapt_pkg.sv" "$(RAPTOR_HOME)/hdl/common/rapt_stream_queue.sv",-d RAPT_ASSERT_EN -GSweepDepth=5,)
verilator-rename-checkpoint:
	$(call VERILATOR_DIRECTED_RUN,rename_checkpoint,tb_rename_checkpoint,"$(RAPTOR_HOME)/hdl/rapt_pkg.sv" "$(RAPTOR_HOME)/hdl/frontend/rapt_rename_checkpoint.sv",-d RAPT_ASSERT_EN,)
verilator-rename-checkpoint-pipeline:
	$(call VERILATOR_DIRECTED_RUN,rename_checkpoint_pipeline,tb_rename_checkpoint_pipeline,"$(RAPTOR_HOME)/hdl/rapt_pkg.sv" "$(RAPTOR_HOME)/hdl/common/rapt_stream_queue.sv" "$(RAPTOR_HOME)/hdl/common/rapt_rank_select.sv" "$(RAPTOR_HOME)/hdl/frontend/rapt_rename_checkpoint.sv" "$(RAPTOR_HOME)/hdl/frontend/rapt_rename_admit.sv" "$(RAPTOR_HOME)/hdl/frontend/rapt_rnu.sv",-d RAPT_ASSERT_EN -d RAPT_DECODE_WIDTH=2 -d RAPT_RENAME_WIDTH=2 -d RAPT_COMMIT_WIDTH=2 -d RAPT_BRANCH_CHECKPOINTS=2,)
.PHONY: verilator-rename-checkpoint-pipeline-rv64
verilator-rename-checkpoint-pipeline-rv64:
	$(call VERILATOR_DIRECTED_RUN,rename_checkpoint_pipeline_rv64,tb_rename_checkpoint_pipeline,$(RENAME_RANDOM_SOURCES),-d RAPT_ASSERT_EN -d RAPT_RV64 -d RAPT_DECODE_WIDTH=2 -d RAPT_RENAME_WIDTH=2 -d RAPT_COMMIT_WIDTH=2 -d RAPT_BRANCH_CHECKPOINTS=2,)
verilator-rename-width-recovery:
	$(call VERILATOR_DIRECTED_RUN,rename_width_recovery,tb_rename_width_recovery,"$(RAPTOR_HOME)/hdl/rapt_pkg.sv" "$(RAPTOR_HOME)/hdl/common/rapt_stream_queue.sv" "$(RAPTOR_HOME)/hdl/common/rapt_rank_select.sv" "$(RAPTOR_HOME)/hdl/frontend/rapt_rename_checkpoint.sv" "$(RAPTOR_HOME)/hdl/frontend/rapt_rename_admit.sv" "$(RAPTOR_HOME)/hdl/frontend/rapt_rnu.sv",-d RAPT_ASSERT_EN -d RAPT_DECODE_WIDTH=4 -d RAPT_RENAME_WIDTH=4 -d RAPT_COMMIT_WIDTH=4,)
verilator-l1i-width-window:
	$(call VERILATOR_DIRECTED_RUN,l1i_width_window,tb_l1i_width_window,$(XSIM_L1I_SOURCES),-d RAPT_ASSERT_EN,)
verilator-ifu-stream-events:
	$(call VERILATOR_DIRECTED_RUN,ifu_stream_events,tb_ifu_stream_events,"$(RAPTOR_HOME)/hdl/rapt_pkg.sv" "$(RAPTOR_HOME)/hdl/frontend/rapt_ifu.sv" "$(RAPTOR_HOME)/hdl/generated/rapt_idu_decoder_c.sv",-d RAPT_ASSERT_EN -d RAPT_DECODE_WIDTH=4,)
.PHONY: verilator-ifu-stream-events-rv32 verilator-ifu-stream-events-rv64
verilator-ifu-stream-events-rv32: verilator-ifu-stream-events
verilator-ifu-stream-events-rv64:
	$(call VERILATOR_DIRECTED_RUN,ifu_stream_events_rv64,tb_ifu_stream_events,"$(RAPTOR_HOME)/hdl/rapt_pkg.sv" "$(RAPTOR_HOME)/hdl/frontend/rapt_ifu.sv" "$(RAPTOR_HOME)/hdl/generated/rapt_idu_decoder_c.sv",-d RAPT_ASSERT_EN -d RAPT_DECODE_WIDTH=4 -d RAPT_RV64,)
verilator-frontend-recovery:
	$(call VERILATOR_DIRECTED_RUN,frontend_recovery,tb_frontend_recovery,"$(RAPTOR_HOME)/hdl/rapt_pkg.sv" "$(RAPTOR_HOME)/hdl/common/rapt_stream_queue.sv" "$(RAPTOR_HOME)/hdl/frontend/rapt_ifu.sv" "$(RAPTOR_HOME)/hdl/frontend/rapt_fqu.sv" "$(RAPTOR_HOME)/hdl/frontend/rapt_decode_slot.sv" "$(RAPTOR_HOME)/hdl/frontend/rapt_idu.sv" "$(RAPTOR_HOME)/hdl/generated/rapt_idu_decoder.sv" "$(RAPTOR_HOME)/hdl/generated/rapt_idu_decoder_c.sv",-d RAPT_ASSERT_EN -d RAPT_DECODE_WIDTH=4,)
verilator-rename-random:
	$(call VERILATOR_DIRECTED_RUN,rename_random,tb_rename_random,$(RENAME_RANDOM_SOURCES),-d RAPT_ASSERT_EN -d RAPT_DECODE_WIDTH=4 -d RAPT_RENAME_WIDTH=3 -d RAPT_COMMIT_WIDTH=4,+SEED=$(VERILATOR_DIRECTED_SEED))
RENAME_RANDOM_SOURCES = "$(RAPTOR_HOME)/hdl/rapt_pkg.sv" "$(RAPTOR_HOME)/hdl/common/rapt_stream_queue.sv" "$(RAPTOR_HOME)/hdl/common/rapt_rank_select.sv" "$(RAPTOR_HOME)/hdl/frontend/rapt_rename_checkpoint.sv" "$(RAPTOR_HOME)/hdl/frontend/rapt_rename_admit.sv" "$(RAPTOR_HOME)/hdl/frontend/rapt_rnu.sv"
.PHONY: rename-admit-prove
.PHONY: rename-admit-native
.PHONY: rename-admit-lint
rename-admit-lint:
	@mkdir -p "$(BUILD_DIR)/rename-admit"
	@set -e; for width in 1 3 16 128; do \
		verilator --lint-only --top-module rapt_rename_admit -GWidth=$$width "$(RAPTOR_HOME)/hdl/frontend/rapt_rename_admit.sv" > "$(BUILD_DIR)/rename-admit/lint-$$width.log" 2>&1; \
	done

rename-admit-native:
	@mkdir -p "$(BUILD_DIR)/rename-admit"
	@set -e; for width in 1 3 16 64 128; do \
		timeout 60s yosys -Q -T -m slang -p "read_slang --single-unit -DSYNTHESIS --top rapt_rename_admit -GWidth=$$width $(RAPTOR_HOME)/hdl/frontend/rapt_rename_admit.sv; select -assert-none t:\$$check t:\$$assert t:\$$assume t:\$$cover; prep -top rapt_rename_admit -flatten; check -assert; select -assert-none t:\$$*latch* t:\$$*ff*" > "$(BUILD_DIR)/rename-admit/native-$$width.log" 2>&1; \
	done
	@if yosys -Q -T -m slang -p 'read_slang --single-unit --top rapt_rename_admit -GWidth=0 $(RAPTOR_HOME)/hdl/frontend/rapt_rename_admit.sv' > "$(BUILD_DIR)/rename-admit/native-invalid.log" 2>&1; then exit 1; fi
	@rg -q 'error: \$$error encountered: Invalid rapt_rename_admit configuration' "$(BUILD_DIR)/rename-admit/native-invalid.log"

rename-admit-prove:
	@mkdir -p "$(BUILD_DIR)/rename-admit"
	@set -e; for width in 1 3 4 8 16; do \
		timeout 60s yosys -Q -T -m slang -p "read_slang --single-unit --top formal_rename_admit -GWidth=$$width $(RAPTOR_HOME)/hdl/frontend/rapt_rename_admit.sv $(RAPTOR_HOME)/verify/formal/formal_rename_admit.sv; select -assert-none t:\$$check t:\$$assert t:\$$assume t:\$$cover; prep -top formal_rename_admit -flatten; opt; sat -verify -prove correct 1 -set-def-inputs" > "$(BUILD_DIR)/rename-admit/prove-$$width.log" 2>&1; \
	done
.PHONY: verilator-rename-random-rv64 verilator-rename-random-expand
verilator-rename-random-rv64:
	$(call VERILATOR_DIRECTED_RUN,rename_random_rv64,tb_rename_random,$(RENAME_RANDOM_SOURCES),-d RAPT_ASSERT_EN -d RAPT_RV64 -d RAPT_DECODE_WIDTH=4 -d RAPT_RENAME_WIDTH=3 -d RAPT_COMMIT_WIDTH=4,+SEED=$(VERILATOR_DIRECTED_SEED))
verilator-rename-random-expand:
	$(call VERILATOR_DIRECTED_RUN,rename_random_expand,tb_rename_random,$(RENAME_RANDOM_SOURCES),-d RAPT_ASSERT_EN -d RAPT_DECODE_WIDTH=2 -d RAPT_RENAME_WIDTH=4 -d RAPT_COMMIT_WIDTH=2,+SEED=$(VERILATOR_DIRECTED_SEED))
.PHONY: rank-select-prove rank-select-evaluate
rank-select-prove:
	python3 "$(RAPTOR_HOME)/verify/scripts/rank_select_check.py" --mode prove
rank-select-evaluate:
	python3 "$(RAPTOR_HOME)/verify/scripts/rank_select_check.py" --mode all

# These standalone selectors must compile with warnings fatal, including
# scheduling cycles; do not inherit the broad directed-suite warning policy.
verilator-issue-select verilator-issue-select-large: VERILATOR_DIRECTED_FLAGS = --binary --timing --assert -j 1
verilator-issue-select:
	$(call VERILATOR_DIRECTED_RUN,issue_select,tb_issue_select,"$(RAPTOR_HOME)/hdl/common/rapt_issue_select.sv" "$(RAPTOR_HOME)/verify/formal/formal_issue_select.sv",,+SEED=$(VERILATOR_DIRECTED_SEED))
.PHONY: verilator-issue-select-large
verilator-issue-select-large:
	$(call VERILATOR_DIRECTED_RUN,issue_select_large,tb_issue_select_large,"$(RAPTOR_HOME)/hdl/common/rapt_issue_select.sv",,)
.PHONY: issue-select-prove issue-select-evaluate issue-select-scaling issue-select-audit-test
issue-select-prove:
	python3 "$(RAPTOR_HOME)/verify/scripts/issue_select_check.py" --mode prove
issue-select-evaluate:
	python3 "$(RAPTOR_HOME)/verify/scripts/issue_select_check.py" --mode all
issue-select-scaling:
	python3 "$(RAPTOR_HOME)/verify/scripts/issue_select_check.py" --mode synth --matrix port-scaling --output "$(BUILD_DIR)/issue-port-scaling"
issue-select-audit-test:
	python3 "$(RAPTOR_HOME)/verify/scripts/test_issue_select_check.py"
verilator-dispatch-admit:
	$(call VERILATOR_DIRECTED_RUN,dispatch_admit,tb_dispatch_admit,"$(RAPTOR_HOME)/hdl/rapt_pkg.sv" "$(RAPTOR_HOME)/hdl/backend/rapt_dispatch_admit.sv" "$(RAPTOR_HOME)/verify/formal/formal_dispatch_admit.sv",,+SEED=$(VERILATOR_DIRECTED_SEED))

verilator-rob-dispatch-select:
	$(call VERILATOR_DIRECTED_RUN,rob_dispatch_select,tb_rob_dispatch_select,"$(RAPTOR_HOME)/hdl/rapt_pkg.sv" "$(RAPTOR_HOME)/hdl/common/rapt_rank_select.sv" "$(RAPTOR_HOME)/hdl/backend/rapt_rob_dispatch_select.sv",,+SEED=$(VERILATOR_DIRECTED_SEED))
.PHONY: verilator-dispatch-compact
verilator-dispatch-compact:
	$(call VERILATOR_DIRECTED_RUN,dispatch_compact,tb_dispatch_compact,"$(RAPTOR_HOME)/hdl/rapt_pkg.sv" "$(RAPTOR_HOME)/hdl/common/rapt_rank_select.sv" "$(RAPTOR_HOME)/hdl/backend/rapt_dpu.sv",-d RAPT_ASSERT_EN,+SEED=$(VERILATOR_DIRECTED_SEED))
.PHONY: rob-dispatch-select-prove rob-dispatch-select-evaluate dispatch-compact-evaluate
rob-dispatch-select-prove:
	python3 "$(RAPTOR_HOME)/verify/scripts/rob_dispatch_select_check.py" --mode prove \
		--output "$(BUILD_DIR)/rob-dispatch-select-proof"
rob-dispatch-select-evaluate:
	python3 "$(RAPTOR_HOME)/verify/scripts/rob_dispatch_select_check.py" --mode all
dispatch-compact-evaluate:
	python3 "$(RAPTOR_HOME)/verify/scripts/dispatch_compact_evaluate.py"
.PHONY: dispatch-admit-prove
dispatch-admit-prove:
	python3 "$(RAPTOR_HOME)/verify/scripts/dispatch_admit_check.py"

verilator-recovery-pending:
	$(call VERILATOR_DIRECTED_RUN,recovery_pending,tb_recovery_pending,"$(RAPTOR_HOME)/hdl/backend/rapt_recovery_pending.sv" "$(RAPTOR_HOME)/verify/formal/formal_recovery_pending.sv",-d RAPT_ASSERT_EN,+SEED=$(VERILATOR_DIRECTED_SEED))
.PHONY: recovery-pending-check
recovery-pending-check:
	python3 "$(RAPTOR_HOME)/verify/scripts/recovery_pending_check.py"

.PHONY: rob-age-mask-check
rob-age-mask-check: ## Prove the circular recovery mask and compare generic mapped cones
	python3 "$(RAPTOR_HOME)/verify/scripts/rob_age_mask_check.py"

.PHONY: synthesis-driver-check
synthesis-driver-check: ## Exercise valid/missing-driver tops through the actual synthesis flow
	python3 "$(RAPTOR_HOME)/verify/scripts/synthesis_driver_check.py" --output "$(BUILD_DIR)/synthesis-driver-check"

.PHONY: sta-constraint-check
sta-constraint-check: ## Reject unconstrained clocks and invalidate stale STA success
	python3 "$(RAPTOR_HOME)/verify/scripts/sta_constraint_check.py" --output "$(BUILD_DIR)/sta-constraint-check"

.PHONY: rename-checkpoint-check rename-checkpoint-prove
rename-checkpoint-check:
	python3 "$(RAPTOR_HOME)/verify/scripts/rename_checkpoint_check.py"
rename-checkpoint-prove:
	python3 "$(RAPTOR_HOME)/verify/scripts/rename_checkpoint_check.py" --mode prove

verilator-completion-guard:
	$(call VERILATOR_DIRECTED_RUN,completion_guard,tb_completion_guard,"$(RAPTOR_HOME)/hdl/backend/rapt_completion_guard.sv",,+SEED=$(VERILATOR_DIRECTED_SEED))
.PHONY: completion-guard-check
completion-guard-check:
	python3 "$(RAPTOR_HOME)/verify/scripts/completion_guard_check.py"

verilator-iq-reclaim-random:
	$(call VERILATOR_DIRECTED_RUN,iq_reclaim_random,tb_iq_reclaim_random,"$(RAPTOR_HOME)/hdl/rapt_pkg.sv" "$(RAPTOR_HOME)/hdl/common/rapt_issue_select.sv" "$(RAPTOR_HOME)/hdl/backend/rapt_iq.sv",-d RAPT_ASSERT_EN -d RAPT_DISPATCH_WIDTH=3,+SEED=$(VERILATOR_DIRECTED_SEED))

.PHONY: verilator-iq-recovery-window
.PHONY: verilator-iq-recovery-window-rv64
IQ_RECOVERY_MATRIX_TARGETS := verilator-iq-recovery-width3 verilator-iq-recovery-width3-rv64 \
                              verilator-iq-recovery-width4 verilator-iq-recovery-width4-rv64
.PHONY: $(IQ_RECOVERY_MATRIX_TARGETS)
$(IQ_RECOVERY_MATRIX_TARGETS): VERILATOR_DIRECTED_FLAGS = --binary --timing --assert -j 1 -CFLAGS -O0
$(IQ_RECOVERY_MATRIX_TARGETS):
	$(call VERILATOR_DIRECTED_RUN,$(subst -,_,$@),tb_iq_recovery_window,"$(RAPTOR_HOME)/hdl/rapt_pkg.sv" "$(RAPTOR_HOME)/hdl/common/rapt_issue_select.sv" "$(RAPTOR_HOME)/hdl/backend/rapt_iq.sv",-d RAPT_ASSERT_EN -d RAPT_DISPATCH_WIDTH=$(if $(findstring width3,$@),3,4) $(if $(findstring rv64,$@),-d RAPT_RV64),)
verilator-iq-recovery-window verilator-iq-recovery-window-rv64: VERILATOR_DIRECTED_FLAGS = --binary --timing --assert -j 1 -CFLAGS -O0
verilator-iq-recovery-window-rv64:
	$(call VERILATOR_DIRECTED_RUN,iq_recovery_window_rv64,tb_iq_recovery_window,"$(RAPTOR_HOME)/hdl/rapt_pkg.sv" "$(RAPTOR_HOME)/hdl/common/rapt_issue_select.sv" "$(RAPTOR_HOME)/hdl/backend/rapt_iq.sv",-d RAPT_ASSERT_EN -d RAPT_RV64,)
verilator-iq-recovery-window: ## Measure resident wrong-path issue before precise flush
	$(call VERILATOR_DIRECTED_RUN,iq_recovery_window,tb_iq_recovery_window,"$(RAPTOR_HOME)/hdl/rapt_pkg.sv" "$(RAPTOR_HOME)/hdl/common/rapt_issue_select.sv" "$(RAPTOR_HOME)/hdl/backend/rapt_iq.sv",-d RAPT_ASSERT_EN,)
.PHONY: verilator-iq-reclaim-random-rv64
verilator-iq-reclaim-random verilator-iq-reclaim-random-rv64 verilator-iq-type-family: VERILATOR_DIRECTED_FLAGS = --binary --timing --assert -j 1
verilator-iq-reclaim-random-rv64:
	$(call VERILATOR_DIRECTED_RUN,iq_reclaim_random_rv64,tb_iq_reclaim_random,"$(RAPTOR_HOME)/hdl/rapt_pkg.sv" "$(RAPTOR_HOME)/hdl/common/rapt_issue_select.sv" "$(RAPTOR_HOME)/hdl/backend/rapt_iq.sv",-d RAPT_ASSERT_EN -d RAPT_RV64 -d RAPT_DISPATCH_WIDTH=3,+SEED=$(VERILATOR_DIRECTED_SEED))
.PHONY: verilator-iq-reclaim-single verilator-iq-reclaim-three verilator-iq-reclaim-six-rv64 iq-reclaim-width-matrix
IQ_RECLAIM_WIDTH_TARGETS := verilator-iq-reclaim-single verilator-iq-reclaim-three verilator-iq-reclaim-six-rv64
$(IQ_RECLAIM_WIDTH_TARGETS): VERILATOR_DIRECTED_FLAGS = --binary --timing --assert -j 1
IQ_RECLAIM_SOURCES = "$(RAPTOR_HOME)/hdl/rapt_pkg.sv" "$(RAPTOR_HOME)/hdl/common/rapt_issue_select.sv" "$(RAPTOR_HOME)/hdl/backend/rapt_iq.sv"
.PHONY: verilator-iq-zkt-dependencies-rv32 verilator-iq-zkt-dependencies-rv64
verilator-iq-zkt-dependencies-rv32 verilator-iq-zkt-dependencies-rv64: VERILATOR_DIRECTED_FLAGS = --binary --timing --assert -j 1 -CFLAGS -O0
verilator-iq-zkt-dependencies-rv32 verilator-iq-zkt-dependencies-rv64:
	$(call VERILATOR_DIRECTED_RUN,$(subst -,_,$@),tb_iq_recovery_window,$(IQ_RECLAIM_SOURCES),-d RAPT_ASSERT_EN -GCheckOperandIndependence=1 -GCheckDependencyCases=1 $(if $(findstring rv64,$@),-d RAPT_RV64),)

.PHONY: verilator-iq-zkt-recovery-rv32 verilator-iq-zkt-recovery-rv64
verilator-iq-zkt-recovery-rv32 verilator-iq-zkt-recovery-rv64:
	$(call VERILATOR_DIRECTED_RUN,$(subst -,_,$@),tb_iq_recovery_window,$(IQ_RECLAIM_SOURCES),-d RAPT_ASSERT_EN -GCheckOperandIndependence=1 $(if $(findstring rv64,$@),-d RAPT_RV64),)

.PHONY: verilator-iq-zkt-rv32 verilator-iq-zkt-rv64
verilator-iq-zkt-rv32 verilator-iq-zkt-rv64:
	$(call VERILATOR_DIRECTED_RUN,$(subst -,_,$@),tb_iq_reclaim_random,$(IQ_RECLAIM_SOURCES),-d RAPT_ASSERT_EN -GCheckOperandIndependence=1 -GEntries=8 $(if $(findstring rv64,$@),-d RAPT_RV64),+SEED=$(VERILATOR_DIRECTED_SEED))
verilator-iq-reclaim-single:
	$(call VERILATOR_DIRECTED_RUN,iq_reclaim_single,tb_iq_reclaim_random,$(IQ_RECLAIM_SOURCES),-d RAPT_ASSERT_EN -d RAPT_INTEGER_ISSUE_PORTS=1 -d RAPT_DISPATCH_WIDTH=1 -GEntries=1,+SEED=$(VERILATOR_DIRECTED_SEED))
verilator-iq-reclaim-three:
	$(call VERILATOR_DIRECTED_RUN,iq_reclaim_three,tb_iq_reclaim_random,$(IQ_RECLAIM_SOURCES),-d RAPT_ASSERT_EN -d RAPT_INTEGER_ISSUE_PORTS=3 -d RAPT_DISPATCH_WIDTH=4 -GEntries=7,+SEED=$(VERILATOR_DIRECTED_SEED))
verilator-iq-reclaim-six-rv64:
	$(call VERILATOR_DIRECTED_RUN,iq_reclaim_six_rv64,tb_iq_reclaim_random,$(IQ_RECLAIM_SOURCES),-d RAPT_ASSERT_EN -d RAPT_RV64 -d RAPT_INTEGER_ISSUE_PORTS=6 -d RAPT_DISPATCH_WIDTH=4 -GEntries=11,+SEED=$(VERILATOR_DIRECTED_SEED))
iq-reclaim-width-matrix: verilator-iq-reclaim-random verilator-iq-reclaim-random-rv64 $(IQ_RECLAIM_WIDTH_TARGETS)

.PHONY: verilator-iq-ordered-head verilator-iq-ordered-head-rv64
verilator-iq-ordered-head verilator-iq-ordered-head-rv64: VERILATOR_DIRECTED_FLAGS = --binary --timing --assert -j 1
verilator-iq-ordered-head verilator-iq-ordered-head-rv64:
	$(call VERILATOR_DIRECTED_RUN,$(subst -,_,$@),tb_iq_reclaim_random,$(IQ_RECLAIM_SOURCES),-d RAPT_ASSERT_EN -GInOrder=1 -GPorts=1 -GEntries=7 $(if $(findstring rv64,$@),-d RAPT_RV64),+SEED=$(VERILATOR_DIRECTED_SEED))

.PHONY: verilator-iq-repair-three verilator-iq-repair-six-rv64 iq-repair-lifecycle-matrix
verilator-iq-repair-three verilator-iq-repair-six-rv64: VERILATOR_DIRECTED_FLAGS = --binary --timing --assert -j 1
verilator-iq-repair-three:
	$(call VERILATOR_DIRECTED_RUN,iq_repair_three,tb_iq_reclaim_random,$(IQ_RECLAIM_SOURCES),-d RAPT_ASSERT_EN -d RAPT_INTEGER_ISSUE_PORTS=3 -d RAPT_DISPATCH_WIDTH=4 -GEntries=7 -GRebalance=1,+SEED=$(VERILATOR_DIRECTED_SEED))
verilator-iq-repair-six-rv64:
	$(call VERILATOR_DIRECTED_RUN,iq_repair_six_rv64,tb_iq_reclaim_random,$(IQ_RECLAIM_SOURCES),-d RAPT_ASSERT_EN -d RAPT_RV64 -d RAPT_INTEGER_ISSUE_PORTS=6 -d RAPT_DISPATCH_WIDTH=4 -GEntries=11 -GRebalance=1,+SEED=$(VERILATOR_DIRECTED_SEED))
iq-repair-lifecycle-matrix: verilator-iq-repair-three verilator-iq-repair-six-rv64

.PHONY: sim-build-flags-test width-evaluate-parser-test
.PHONY: verilator-prf-state verilator-prf-state-rv64
.PHONY: verilator-prf-state-arch16
verilator-prf-state-arch16:
	$(call VERILATOR_DIRECTED_RUN,prf_state_arch16,tb_prf_state,"$(RAPTOR_HOME)/hdl/rapt_pkg.sv" "$(RAPTOR_HOME)/hdl/backend/rapt_prf.sv",-d RAPT_RVFI -GArchRegs=16,+SEED=$(VERILATOR_DIRECTED_SEED))

.PHONY: prf-equivalence-audit-test
.PHONY: rnu-equivalence-audit-test
rnu-equivalence-audit-test:
	python3 "$(RAPTOR_HOME)/verify/scripts/test_rnu_equivalence.py"
.PHONY: rnu-equivalence
RNU_EQ_DECODE_WIDTH ?= 4
RNU_EQ_RENAME_WIDTH ?= 3
RNU_EQ_COMMIT_WIDTH ?= 4
rnu-equivalence:
	@test -n "$(BASELINE_RNU)" || { echo 'Set BASELINE_RNU to the preserved pre-change rapt_rnu.sv'; exit 2; }
	python3 "$(RAPTOR_HOME)/verify/scripts/rnu_equivalence.py" --baseline-rnu "$(BASELINE_RNU)" --output "$(BUILD_DIR)/rnu-equivalence" \
	  --decode-width "$(RNU_EQ_DECODE_WIDTH)" --rename-width "$(RNU_EQ_RENAME_WIDTH)" --commit-width "$(RNU_EQ_COMMIT_WIDTH)"

.PHONY: prf-contract-check
prf-contract-check:
	python3 "$(RAPTOR_HOME)/verify/scripts/prf_contract_check.py"

prf-equivalence-audit-test:
	python3 "$(RAPTOR_HOME)/verify/scripts/test_prf_equivalence.py"

verilator-prf-state:
	$(call VERILATOR_DIRECTED_RUN,prf_state,tb_prf_state,"$(RAPTOR_HOME)/hdl/rapt_pkg.sv" "$(RAPTOR_HOME)/hdl/backend/rapt_prf.sv",-d RAPT_RVFI,+SEED=$(VERILATOR_DIRECTED_SEED))
verilator-prf-state-rv64:
	$(call VERILATOR_DIRECTED_RUN,prf_state_rv64,tb_prf_state,"$(RAPTOR_HOME)/hdl/rapt_pkg.sv" "$(RAPTOR_HOME)/hdl/backend/rapt_prf.sv",-d RAPT_RVFI -d RAPT_RV64,+SEED=$(VERILATOR_DIRECTED_SEED))

sim-build-flags-test: ## Check assertion compiler flags in an isolated simulator fixture
	python3 "$(RAPTOR_HOME)/verify/scripts/test_sim_build_flags.py"

.PHONY: sta-entrypoints-test
sta-entrypoints-test: ## Check offline STA preflight and dependency failure diagnostics
	python3 "$(RAPTOR_HOME)/verify/scripts/test_sta_entrypoints.py"

width-evaluate-parser-test:
	python3 "$(RAPTOR_HOME)/verify/scripts/test_width_evaluate.py"
	python3 "$(RAPTOR_HOME)/verify/scripts/test_width_evaluate_evidence.py"
verilator-ras:
	$(call VERILATOR_DIRECTED_RUN,ras,tb_ras,"$(RAPTOR_HOME)/hdl/rapt_pkg.sv" "$(RAPTOR_HOME)/hdl/frontend/branch_predictor/rapt_ras.sv",-d RAPT_ASSERT_EN,+SEED=$(VERILATOR_DIRECTED_SEED))
verilator-ras-pipeline:
	$(call VERILATOR_DIRECTED_RUN,ras_pipeline,tb_ras_pipeline,$(XSIM_IDU_SOURCES) "$(RAPTOR_HOME)/hdl/backend/rapt_cmu.sv" $(wildcard $(RAPTOR_HOME)/hdl/frontend/branch_predictor/*.sv),-d RAPT_ASSERT_EN,)
	$(call VERILATOR_DIRECTED_RUN,ras_pipeline4,tb_ras_pipeline,$(XSIM_IDU_SOURCES) "$(RAPTOR_HOME)/hdl/backend/rapt_cmu.sv" $(wildcard $(RAPTOR_HOME)/hdl/frontend/branch_predictor/*.sv),-d RAPT_ASSERT_EN -d RAPT_DECODE_WIDTH=4 -d RAPT_COMMIT_WIDTH=4,)
.PHONY: ras-check
ras-check:
	python3 "$(RAPTOR_HOME)/verify/scripts/ras_check.py"
verilator-predict-history:
	$(call VERILATOR_DIRECTED_RUN,predict_history,tb_predict_history,"$(RAPTOR_HOME)/hdl/frontend/branch_predictor/rapt_predict_history.sv" "$(RAPTOR_HOME)/verify/formal/formal_predict_history.sv",,+SEED=$(VERILATOR_DIRECTED_SEED))
verilator-predict-history-pipeline:
	$(call VERILATOR_DIRECTED_RUN,predict_history_pipeline,tb_predict_history_pipeline,$(XSIM_IDU_SOURCES) "$(RAPTOR_HOME)/hdl/backend/rapt_cmu.sv" "$(RAPTOR_HOME)/hdl/backend/ieu/rapt_ieu_pipe_branch.sv" $(wildcard $(RAPTOR_HOME)/hdl/frontend/branch_predictor/*.sv),-d RAPT_ASSERT_EN -d RAPT_DECODE_WIDTH=4 -d RAPT_COMMIT_WIDTH=4,)
	$(call VERILATOR_DIRECTED_RUN,predict_history_pipeline_rv64,tb_predict_history_pipeline,$(XSIM_IDU_SOURCES) "$(RAPTOR_HOME)/hdl/backend/rapt_cmu.sv" "$(RAPTOR_HOME)/hdl/backend/ieu/rapt_ieu_pipe_branch.sv" $(wildcard $(RAPTOR_HOME)/hdl/frontend/branch_predictor/*.sv),-d RAPT_ASSERT_EN -d RAPT_RV64 -d RAPT_DECODE_WIDTH=4 -d RAPT_COMMIT_WIDTH=2,)
.PHONY: predict-history-prove
predict-history-prove:
	python3 "$(RAPTOR_HOME)/verify/scripts/predict_history_check.py"
.PHONY: recovery-metrics-test
recovery-metrics-test:
	@mkdir -p "$(BUILD_DIR)/recovery-metrics"
	$(CXX) -std=c++17 -Wall -Wextra -Werror -I"$(RAPTOR_HOME)/sim/include" \
		"$(RAPTOR_HOME)/app/tests/host/recovery_metrics_test.cc" -o "$(BUILD_DIR)/recovery-metrics/test"
	"$(BUILD_DIR)/recovery-metrics/test"

verilator-directed-clean: ## Clean portable Verilator directed-check artifacts
	rm -rf $(VERILATOR_DIRECTED_BUILD_DIR)


# ============================================================================
# All-in-one
# ============================================================================
.PHONY: all clean

all: fuzz sigtest ## Run all lightweight verification

clean: fuzz-clean riscof-clean coverage-clean sigtest-clean formal-clean jtag-clean uvm-clean xsim-clean verilator-directed-clean ## Clean all verify artifacts
	rm -rf $(BUILD_DIR)

.PHONY: verilator-lsu-split-fault-rv32 verilator-lsu-split-fault-rv64
verilator-lsu-split-fault-rv32:
	$(call VERILATOR_DIRECTED_RUN,lsu_split_fault_rv32,tb_lsu_split_fault,$(XSIM_LSU_SOURCES),-d RAPT_ASSERT_EN,)
verilator-lsu-split-fault-rv64:
	$(call VERILATOR_DIRECTED_RUN,lsu_split_fault_rv64,tb_lsu_split_fault,$(XSIM_LSU_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,)

.PHONY: rva22s64-split-page-permissions-run

.PHONY: verilator-l1d-load-pbmt
verilator-l1d-load-pbmt:
	$(call VERILATOR_DIRECTED_RUN,l1d_load_pbmt,tb_l1d_load_pbmt,$(XSIM_L1D_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,)

.PHONY: verilator-ioq-pbmt-order verilator-sq-pbmt-order
verilator-ioq-pbmt-order:
	$(call VERILATOR_DIRECTED_RUN,ioq_pbmt_order,tb_ioq_pbmt_order,$(XSIM_IOQ_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,)
verilator-sq-pbmt-order:
	$(call VERILATOR_DIRECTED_RUN,sq_pbmt_order,tb_sq_pbmt_order,$(XSIM_LSU_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,)

.PHONY: verilator-ioq-store-stage-rv32 verilator-ioq-store-stage-rv64
verilator-ioq-store-stage-rv32:
	$(call VERILATOR_DIRECTED_RUN,ioq_store_stage_rv32,tb_ioq_store_stage,$(XSIM_IOQ_SOURCES),-d RAPT_ASSERT_EN,)
verilator-ioq-store-stage-rv64:
	$(call VERILATOR_DIRECTED_RUN,ioq_store_stage_rv64,tb_ioq_store_stage,$(XSIM_IOQ_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,)
.PHONY: verilator-ioq-readonly-pma-rv32 verilator-ioq-readonly-pma-rv64
verilator-ioq-readonly-pma-rv32:
	$(call VERILATOR_DIRECTED_RUN,ioq_readonly_pma_rv32,tb_ioq_readonly_pma,$(XSIM_IOQ_SOURCES),-d RAPT_ASSERT_EN,)
verilator-ioq-readonly-pma-rv64:
	$(call VERILATOR_DIRECTED_RUN,ioq_readonly_pma_rv64,tb_ioq_readonly_pma,$(XSIM_IOQ_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,)

.PHONY: verilator-ioq-amo-fault-rv32 verilator-ioq-amo-fault-rv64
verilator-ioq-amo-fault-rv32:
	$(call VERILATOR_DIRECTED_RUN,ioq_amo_fault_rv32,tb_ioq_amo_fault,$(XSIM_IOQ_SOURCES),-d RAPT_ASSERT_EN,)
verilator-ioq-amo-fault-rv64:
	$(call VERILATOR_DIRECTED_RUN,ioq_amo_fault_rv64,tb_ioq_amo_fault,$(XSIM_IOQ_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,)

.PHONY: verilator-l1d-io-size
verilator-l1d-io-size:
	$(call VERILATOR_DIRECTED_RUN,l1d_io_size,tb_l1d_io_size,$(XSIM_L1D_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,)

.PHONY: verilator-lsu-l1d-io-split
verilator-lsu-l1d-io-split:
	$(call VERILATOR_DIRECTED_RUN,lsu_l1d_io_split,tb_lsu_l1d_io_split,$(sort $(XSIM_L1D_SOURCES) $(XSIM_LSU_SOURCES)),-d RAPT_RV64 -d RAPT_ASSERT_EN,)

.PHONY: verilator-bus-pbmt-rv32 verilator-bus-pbmt-rv64
verilator-bus-pbmt-rv32:
	$(call VERILATOR_DIRECTED_RUN,bus_pbmt_rv32,tb_bus_pbmt,$(XSIM_BUS_SOURCES),-d RAPT_ASSERT_EN,)
verilator-bus-pbmt-rv64:
	$(call VERILATOR_DIRECTED_RUN,bus_pbmt_rv64,tb_bus_pbmt,$(XSIM_BUS_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,)

.PHONY: verilator-l2-pbmt
verilator-l2-pbmt:
	$(call VERILATOR_DIRECTED_RUN,l2_pbmt,tb_l2_pbmt,$(XSIM_L2_SOURCES),-d RAPT_L2_EN,)

.PHONY: verilator-l2-pbmt-rv64
verilator-l2-pbmt-rv64:
	$(call VERILATOR_DIRECTED_RUN,l2_pbmt_rv64,tb_l2_pbmt,$(XSIM_L2_SOURCES),-d RAPT_RV64 -d RAPT_L2_EN,)

.PHONY: verilator-l1d-ptw-pma-rv32 verilator-l1d-ptw-pma-rv64
verilator-l1d-ptw-pma-rv32:
	$(call VERILATOR_DIRECTED_RUN,l1d_ptw_pma_rv32,tb_l1d_ptw_pma,$(XSIM_L1D_SOURCES),-d RAPT_ASSERT_EN,)
verilator-l1d-ptw-pma-rv64:
	$(call VERILATOR_DIRECTED_RUN,l1d_ptw_pma_rv64,tb_l1d_ptw_pma,$(XSIM_L1D_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,)

.PHONY: verilator-ifetch-word-rv32 verilator-ifetch-word-rv64
verilator-ifetch-word-rv32:
	$(call VERILATOR_DIRECTED_RUN,ifetch_word_rv32,tb_ifetch_word,"$(RAPTOR_HOME)/hdl/memory/rapt_ifetch_word.sv",,)
verilator-ifetch-word-rv64:
	$(call VERILATOR_DIRECTED_RUN,ifetch_word_rv64,tb_ifetch_word,"$(RAPTOR_HOME)/hdl/memory/rapt_ifetch_word.sv",-d RAPT_RV64,)

.PHONY: verilator-ifetch-translate-rv32 verilator-ifetch-translate-rv64
verilator-ifetch-translate-rv32:
	$(call VERILATOR_DIRECTED_RUN,ifetch_translate_rv32,tb_ifetch_translate,"$(RAPTOR_HOME)/hdl/rapt_pkg.sv" "$(RAPTOR_HOME)/hdl/memory/rapt_ifetch_translate.sv" "$(RAPTOR_HOME)/hdl/memory/rapt_ptw.sv" "$(RAPTOR_HOME)/hdl/memory/rapt_pmp.sv",,)
verilator-ifetch-translate-rv64:
	$(call VERILATOR_DIRECTED_RUN,ifetch_translate_rv64,tb_ifetch_translate,"$(RAPTOR_HOME)/hdl/rapt_pkg.sv" "$(RAPTOR_HOME)/hdl/memory/rapt_ifetch_translate.sv" "$(RAPTOR_HOME)/hdl/memory/rapt_ptw.sv" "$(RAPTOR_HOME)/hdl/memory/rapt_pmp.sv",-d RAPT_RV64,)

XSIM_DATA_PAGE_PERMISSION_SOURCES := "$(RAPTOR_HOME)/hdl/rapt_pkg.sv" "$(RAPTOR_HOME)/hdl/memory/rapt_l1d_access.sv" "$(RAPTOR_HOME)/hdl/memory/rapt_pmp.sv"
.PHONY: verilator-data-page-permissions-rv32 verilator-data-page-permissions-rv64
verilator-data-page-permissions-rv32:
	$(call VERILATOR_DIRECTED_RUN,data_page_permissions_rv32,tb_data_page_permissions,$(XSIM_DATA_PAGE_PERMISSION_SOURCES),,)
verilator-data-page-permissions-rv64:
	$(call VERILATOR_DIRECTED_RUN,data_page_permissions_rv64,tb_data_page_permissions,$(XSIM_DATA_PAGE_PERMISSION_SOURCES),-d RAPT_RV64,)

XSIM_PTW_PMP_SPAN_SOURCES := "$(RAPTOR_HOME)/hdl/rapt_pkg.sv" \
    "$(RAPTOR_HOME)/hdl/memory/rapt_l1i_access.sv" \
    "$(RAPTOR_HOME)/hdl/memory/rapt_l1d_access.sv" \
    "$(RAPTOR_HOME)/hdl/memory/rapt_pmp.sv"
.PHONY: verilator-ptw-pmp-span-rv32 verilator-ptw-pmp-span-rv64
verilator-ptw-pmp-span-rv32:
	$(call VERILATOR_DIRECTED_RUN,ptw_pmp_span_rv32,tb_ptw_pmp_span,$(XSIM_PTW_PMP_SPAN_SOURCES),,)
verilator-ptw-pmp-span-rv64:
	$(call VERILATOR_DIRECTED_RUN,ptw_pmp_span_rv64,tb_ptw_pmp_span,$(XSIM_PTW_PMP_SPAN_SOURCES),-d RAPT_RV64,)

.PHONY: verilator-l1i-word-path-rv32 verilator-l1i-word-path-rv64
verilator-l1i-word-path-rv32:
	$(call VERILATOR_DIRECTED_RUN,l1i_word_path_rv32,tb_l1i_word_path,$(XSIM_L1I_SOURCES),-d RAPT_ASSERT_EN,)
verilator-l1i-word-path-rv64:
	$(call VERILATOR_DIRECTED_RUN,l1i_word_path_rv64,tb_l1i_word_path,$(XSIM_L1I_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,)

.PHONY: verilator-ifetch-io-guard-rv32 verilator-ifetch-io-guard-rv64
verilator-ifetch-io-guard-rv32:
	$(call VERILATOR_DIRECTED_RUN,ifetch_io_guard_rv32,tb_ifetch_io_guard,"$(RAPTOR_HOME)/hdl/frontend/rapt_ifetch_io_guard.sv",-d RAPT_ASSERT_EN,)
verilator-ifetch-io-guard-rv64:
	$(call VERILATOR_DIRECTED_RUN,ifetch_io_guard_rv64,tb_ifetch_io_guard,"$(RAPTOR_HOME)/hdl/frontend/rapt_ifetch_io_guard.sv",-d RAPT_RV64 -d RAPT_ASSERT_EN,)

.PHONY: verilator-l1i-io-guard-rv64
verilator-l1i-io-guard-rv64: VERILATOR_DIRECTED_FLAGS += -GUseGuard=1
verilator-l1i-io-guard-rv64:
	$(call VERILATOR_DIRECTED_RUN,l1i_io_guard_rv64,tb_l1i_word_path,$(XSIM_L1I_SOURCES) "$(RAPTOR_HOME)/hdl/frontend/rapt_ifetch_io_guard.sv",-d RAPT_RV64 -d RAPT_ASSERT_EN,)

.PHONY: verilator-ioq-atomic-pma-rv32 verilator-ioq-atomic-pma-rv64
verilator-ioq-atomic-pma-rv32:
	$(call VERILATOR_DIRECTED_RUN,ioq_atomic_pma_rv32,tb_ioq_atomic_pma,$(XSIM_IOQ_SOURCES),-d RAPT_ASSERT_EN,)
verilator-ioq-atomic-pma-rv64:
	$(call VERILATOR_DIRECTED_RUN,ioq_atomic_pma_rv64,tb_ioq_atomic_pma,$(XSIM_IOQ_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,)

.PHONY: verilator-l1d-lr-pma-rv32 verilator-l1d-lr-pma-rv64
verilator-l1d-lr-pma-rv32:
	$(call VERILATOR_DIRECTED_RUN,l1d_lr_pma_rv32,tb_l1d_pma,$(XSIM_L1D_SOURCES),-d RAPT_ASSERT_EN,)
verilator-l1d-lr-pma-rv64:
	$(call VERILATOR_DIRECTED_RUN,l1d_lr_pma_rv64,tb_l1d_pma,$(XSIM_L1D_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,)

.PHONY: verilator-ioq-zero-pma-rv32 verilator-ioq-zero-pma-rv64
verilator-ioq-zero-pma-rv32:
	$(call VERILATOR_DIRECTED_RUN,ioq_zero_pma_rv32,tb_ioq_zero_pma,$(XSIM_IOQ_SOURCES),-d RAPT_ASSERT_EN,)
verilator-ioq-zero-pma-rv64:
	$(call VERILATOR_DIRECTED_RUN,ioq_zero_pma_rv64,tb_ioq_zero_pma,$(XSIM_IOQ_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,)

.PHONY: verilator-l1d-sram-pma-rv32 verilator-l1d-sram-pma-rv64
verilator-l1d-sram-pma-rv32:
	$(call VERILATOR_DIRECTED_RUN,l1d_sram_pma_rv32,tb_l1d_pma,$(XSIM_L1D_SOURCES),-d RAPT_ASSERT_EN,+SRAM)
verilator-l1d-sram-pma-rv64:
	$(call VERILATOR_DIRECTED_RUN,l1d_sram_pma_rv64,tb_l1d_pma,$(XSIM_L1D_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,+SRAM)

.PHONY: verilator-ioq-data-span-rv32 verilator-ioq-data-span-rv64
verilator-ioq-data-span-rv32:
	$(call VERILATOR_DIRECTED_RUN,ioq_data_span_rv32,tb_ioq_data_span,$(XSIM_IOQ_SOURCES),-d RAPT_ASSERT_EN,)
verilator-ioq-data-span-rv64:
	$(call VERILATOR_DIRECTED_RUN,ioq_data_span_rv64,tb_ioq_data_span,$(XSIM_IOQ_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,)

.PHONY: nemu-memory-map-check
nemu-memory-map-check:
	$(PYTHON) "$(VERIFY_HOME)/scripts/nemu_memory_map_check.py"

.PHONY: verilator-l1d-read-error-rv32 verilator-l1d-read-error-rv64
verilator-l1d-read-error-rv32:
	$(call VERILATOR_DIRECTED_RUN,l1d_read_error_rv32,tb_l1d_read_error,$(XSIM_L1D_SOURCES),-d RAPT_ASSERT_EN,)
verilator-l1d-read-error-rv64:
	$(call VERILATOR_DIRECTED_RUN,l1d_read_error_rv64,tb_l1d_read_error,$(XSIM_L1D_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,)

.PHONY: verilator-l1d-ptw-error-rv32 verilator-l1d-ptw-error-rv64
verilator-l1d-ptw-error-rv32:
	$(call VERILATOR_DIRECTED_RUN,l1d_ptw_error_rv32,tb_l1d_ptw_error,$(XSIM_L1D_SOURCES),-d RAPT_ASSERT_EN,)
verilator-l1d-ptw-error-rv64:
	$(call VERILATOR_DIRECTED_RUN,l1d_ptw_error_rv64,tb_l1d_ptw_error,$(XSIM_L1D_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,)

.PHONY: verilator-l1d-ptw-axi-error-rv32 verilator-l1d-ptw-axi-error-rv64
verilator-l1d-ptw-axi-error-rv32:
	$(call VERILATOR_DIRECTED_RUN,l1d_ptw_axi_error_rv32,tb_l1d_ptw_axi_error,$(XSIM_L1D_SOURCES) "$(RAPTOR_HOME)/hdl/memory/rapt_bus.sv" "$(RAPTOR_HOME)/hdl/memory/rapt_axi_master.sv",-d RAPT_ASSERT_EN,)
verilator-l1d-ptw-axi-error-rv64:
	$(call VERILATOR_DIRECTED_RUN,l1d_ptw_axi_error_rv64,tb_l1d_ptw_axi_error,$(XSIM_L1D_SOURCES) "$(RAPTOR_HOME)/hdl/memory/rapt_bus.sv" "$(RAPTOR_HOME)/hdl/memory/rapt_axi_master.sv",-d RAPT_RV64 -d RAPT_ASSERT_EN,)

.PHONY: verilator-l1d-write-error-rv32 verilator-l1d-write-error-rv64 verilator-sq-write-error-rv32 verilator-sq-write-error-rv64
verilator-l1d-write-error-rv32:
	$(call VERILATOR_DIRECTED_RUN,l1d_write_error_rv32,tb_l1d_write_error,$(XSIM_L1D_SOURCES),-d RAPT_ASSERT_EN,)
verilator-l1d-write-error-rv64:
	$(call VERILATOR_DIRECTED_RUN,l1d_write_error_rv64,tb_l1d_write_error,$(XSIM_L1D_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,)
verilator-sq-write-error-rv32:
	$(call VERILATOR_DIRECTED_RUN,sq_write_error_rv32,tb_sq_write_error,$(XSIM_LSU_SOURCES),-d RAPT_ASSERT_EN,)
verilator-sq-write-error-rv64:
	$(call VERILATOR_DIRECTED_RUN,sq_write_error_rv64,tb_sq_write_error,$(XSIM_LSU_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,)

.PHONY: verilator-csr-bus-error-rv32 verilator-csr-bus-error-rv64
verilator-csr-bus-error-rv32:
	$(call VERILATOR_DIRECTED_RUN,csr_bus_error_rv32,tb_csr_bus_error,$(XSIM_CSR_SOURCES) "$(RAPTOR_HOME)/hdl/backend/ieu/rapt_ieu_alu.sv" "$(RAPTOR_HOME)/hdl/backend/ieu/rapt_ieu_pipe_alu_csr.sv",-d RAPT_ASSERT_EN,)
verilator-csr-bus-error-rv64:
	$(call VERILATOR_DIRECTED_RUN,csr_bus_error_rv64,tb_csr_bus_error,$(XSIM_CSR_SOURCES) "$(RAPTOR_HOME)/hdl/backend/ieu/rapt_ieu_alu.sv" "$(RAPTOR_HOME)/hdl/backend/ieu/rapt_ieu_pipe_alu_csr.sv",-d RAPT_RV64 -d RAPT_ASSERT_EN,)

# Architectural snapshot persistence for posted-write diagnostics. The caller
# supplies a freshly built DUT/reference; output must be fresh (no stale saves).
.PHONY: rva22s64-bus-error-checkpoint-run
RVA22S64_CHECKPOINT_DIR = $(BUILD_DIR)/bus-error-checkpoint-rv$(RVA22S64_XLEN)
rva22s64-bus-error-checkpoint-run: $(MROM_IMG)
	@mkdir -p "$(RVA22S64_CHECKPOINT_DIR)"
	$(CC) -DRAPT_CKPT_ERROR -march=rv$(RVA22S64_XLEN)imac_zicsr_zifencei -mabi=$(if $(filter 64,$(RVA22S64_XLEN)),lp64,ilp32) -nostdlib -nostartfiles -static \
		-Wl,--no-relax -T "$(VERIFY_HOME)/scripts/fuzz_link.ld" "$(RAPTOR_HOME)/app/tests/baremetal/bus_write_error.S" -o "$(RVA22S64_CHECKPOINT_DIR)/test.elf"
	$(OBJCOPY) -O binary "$(RVA22S64_CHECKPOINT_DIR)/test.elf" "$(RVA22S64_CHECKPOINT_DIR)/test.bin"
	$(PYTHON) "$(VERIFY_HOME)/scripts/bus_error_checkpoint.py" \
		--npc "$(RVA22S64_NPC)" --reference "$(NEMU_SO_$(RVA22S64_XLEN))" --mrom "$(MROM_IMG)" \
		--elf "$(RVA22S64_CHECKPOINT_DIR)/test.elf" --image "$(RVA22S64_CHECKPOINT_DIR)/test.bin" --output "$(RVA22S64_CHECKPOINT_DIR)/runs"

SQ_CHECKPOINT_BIN ?= $(NPC_BIN_$(SQ_CHECKPOINT_XLEN))
SQ_CHECKPOINT_KIND ?= word
SQ_CHECKPOINT_DIR = $(BUILD_DIR)/sq-checkpoint-rv$(SQ_CHECKPOINT_XLEN)-$(SQ_CHECKPOINT_KIND)
.PHONY: sq-checkpoint-rv32 sq-checkpoint-rv64
sq-checkpoint-rv32: SQ_CHECKPOINT_XLEN = 32
sq-checkpoint-rv64: SQ_CHECKPOINT_XLEN = 64
sq-checkpoint-rv32 sq-checkpoint-rv64: ## Pending retired stores survive save/load; supply matching simulator and MROM_IMG
	@test -x "$(SQ_CHECKPOINT_BIN)" && test -f "$(NEMU_SO_$(SQ_CHECKPOINT_XLEN))" && test -f "$(MROM_IMG)"
	@mkdir -p "$(SQ_CHECKPOINT_DIR)"
	$(CC) $(if $(filter fp64,$(SQ_CHECKPOINT_KIND)),-DCHECKPOINT_FP64) $(if $(filter unaligned,$(SQ_CHECKPOINT_KIND)),-DCHECKPOINT_UNALIGNED) \
		-march=rv$(SQ_CHECKPOINT_XLEN)imafdc_zicsr_zifencei -mabi=$(if $(filter 64,$(SQ_CHECKPOINT_XLEN)),lp64,ilp32) -nostdlib -nostartfiles \
		-Wl,--no-relax -T "$(VERIFY_HOME)/scripts/fuzz_link.ld" "$(RAPTOR_HOME)/app/tests/baremetal/sq_checkpoint.S" -o "$(SQ_CHECKPOINT_DIR)/test.elf"
	$(OBJCOPY) -O binary "$(SQ_CHECKPOINT_DIR)/test.elf" "$(SQ_CHECKPOINT_DIR)/test.bin"
	$(PYTHON) "$(VERIFY_HOME)/scripts/sq_checkpoint.py" --xlen "$(SQ_CHECKPOINT_XLEN)" --kind "$(SQ_CHECKPOINT_KIND)" --nm "$(CROSS_COMPILE)nm" \
		--npc "$(SQ_CHECKPOINT_BIN)" --reference "$(NEMU_SO_$(SQ_CHECKPOINT_XLEN))" --mrom "$(MROM_IMG)" \
		--elf "$(SQ_CHECKPOINT_DIR)/test.elf" --image "$(SQ_CHECKPOINT_DIR)/test.bin" --output "$(SQ_CHECKPOINT_DIR)/runs"

# Shared CLINT/CSR time across actual save/exit/load, including legacy metadata.
.PHONY: rva22s64-clint-time-checkpoint-run
RVA22S64_TIME_CHECKPOINT_DIR = $(BUILD_DIR)/clint-time-checkpoint-rv$(RVA22S64_XLEN)
RVA22S64_TIME_CHECKPOINT_CPPFLAGS ?= -DCHECKPOINT_SSTC
rva22s64-clint-time-checkpoint-run: $(MROM_IMG)
	@mkdir -p "$(RVA22S64_TIME_CHECKPOINT_DIR)"
	$(CC) $(RVA22S64_TIME_CHECKPOINT_CPPFLAGS) -march=rv$(RVA22S64_XLEN)imac_zicsr_zifencei -mabi=$(if $(filter 64,$(RVA22S64_XLEN)),lp64,ilp32) -nostdlib -nostartfiles -static \
		-Wl,--no-relax -T "$(VERIFY_HOME)/scripts/fuzz_link.ld" "$(RAPTOR_HOME)/app/tests/baremetal/clint_time_checkpoint.S" -o "$(RVA22S64_TIME_CHECKPOINT_DIR)/test.elf"
	$(OBJCOPY) -O binary "$(RVA22S64_TIME_CHECKPOINT_DIR)/test.elf" "$(RVA22S64_TIME_CHECKPOINT_DIR)/test.bin"
	$(PYTHON) "$(VERIFY_HOME)/scripts/clint_time_checkpoint.py" --xlen "$(RVA22S64_XLEN)" \
		--npc "$(RVA22S64_NPC)" --reference "$(NEMU_SO_$(RVA22S64_XLEN))" --mrom "$(MROM_IMG)" \
		--elf "$(RVA22S64_TIME_CHECKPOINT_DIR)/test.elf" --image "$(RVA22S64_TIME_CHECKPOINT_DIR)/test.bin" --output "$(RVA22S64_TIME_CHECKPOINT_DIR)/runs"

.PHONY: nemu-svpbmt-check
nemu-svpbmt-check:
	$(PYTHON) "$(VERIFY_HOME)/scripts/nemu_svpbmt_check.py"

.PHONY: nemu-svpbmt-access-check
nemu-svpbmt-access-check:
	$(PYTHON) "$(VERIFY_HOME)/scripts/nemu_svpbmt_check.py" --access

.PHONY: nemu-svpbmt-decode-check
HOST_CXX ?= c++
.PHONY: mmio-alignment-check
mmio-alignment-check: $(MROM_IMG)
	$(PYTHON) "$(VERIFY_HOME)/scripts/mmio_alignment_check.py" \
		--npc "$(RVA22S64_NPC)" --reference "$(NEMU_SO_$(RVA22S64_XLEN))" \
		--mrom "$(MROM_IMG)" --xlen "$(RVA22S64_XLEN)" \
		--output "$(BUILD_DIR)/mmio-alignment-rv$(RVA22S64_XLEN)"
.PHONY: mmio-transaction-check mmio-virtio-mask-check mmio-uart-read-check
.PHONY: mmio-spi-read-mask-check
mmio-spi-read-mask-check:
	@mkdir -p "$(BUILD_DIR)"
	$(HOST_CXX) -std=c++17 -O2 -ffunction-sections -Wl,--gc-sections -I"$(NSIM_HOME)/include" "$(RAPTOR_HOME)/app/tests/host/mmio_spi_read_mask.cc" -o "$(BUILD_DIR)/mmio-spi-read32"
	"$(BUILD_DIR)/mmio-spi-read32"
	$(HOST_CXX) -std=c++17 -O2 -ffunction-sections -Wl,--gc-sections -DCONFIG_ISA64 -I"$(NSIM_HOME)/include" "$(RAPTOR_HOME)/app/tests/host/mmio_spi_read_mask.cc" -o "$(BUILD_DIR)/mmio-spi-read64"
	"$(BUILD_DIR)/mmio-spi-read64"
mmio-uart-read-check: $(MROM_IMG)
	$(PYTHON) "$(VERIFY_HOME)/scripts/mmio_transaction_check.py" --uart-read \
		--npc "$(RVA22S64_NPC)" --reference "$(NEMU_SO_$(RVA22S64_XLEN))" \
		--mrom "$(MROM_IMG)" --xlen "$(RVA22S64_XLEN)" \
		--output "$(BUILD_DIR)/mmio-uart-read-rv$(RVA22S64_XLEN)"
mmio-transaction-check: $(MROM_IMG)
	$(PYTHON) "$(VERIFY_HOME)/scripts/mmio_transaction_check.py" \
		--npc "$(RVA22S64_NPC)" --reference "$(NEMU_SO_$(RVA22S64_XLEN))" \
		--mrom "$(MROM_IMG)" --xlen "$(RVA22S64_XLEN)" \
		--output "$(BUILD_DIR)/mmio-transactions-rv$(RVA22S64_XLEN)"
mmio-virtio-mask-check:
	@mkdir -p "$(BUILD_DIR)"
	$(HOST_CXX) -std=c++17 -O2 -I"$(NSIM_HOME)/include" "$(RAPTOR_HOME)/app/tests/host/mmio_virtio_mask.cc" -o "$(BUILD_DIR)/mmio-virtio-mask32"
	"$(BUILD_DIR)/mmio-virtio-mask32"
	$(HOST_CXX) -std=c++17 -O2 -DCONFIG_ISA64 -I"$(NSIM_HOME)/include" "$(RAPTOR_HOME)/app/tests/host/mmio_virtio_mask.cc" -o "$(BUILD_DIR)/mmio-virtio-mask64"
	"$(BUILD_DIR)/mmio-virtio-mask64"
nemu-svpbmt-decode-check:
	@mkdir -p "$(BUILD_DIR)"
	$(HOST_CXX) -std=c++17 -DCONFIG_ISA64 -I"$(NSIM_HOME)/include" "$(RAPTOR_HOME)/app/tests/host/nemu_svpbmt_decode.cc" -ldl -o "$(BUILD_DIR)/nemu-svpbmt-decode"
	"$(BUILD_DIR)/nemu-svpbmt-decode" "$(NEMU_SO_64)" 1
	"$(BUILD_DIR)/nemu-svpbmt-decode" "$(NEMU_SO_64)" 2

.PHONY: verilator-lsu-hum-pmp-rv32 verilator-lsu-hum-pmp-rv64
verilator-lsu-hum-pmp-rv32:
	$(call VERILATOR_DIRECTED_RUN,lsu_hum_pmp_rv32,tb_lsu_hum_pmp,$(XSIM_LSU_SOURCES),-d RAPT_ASSERT_EN,)
verilator-lsu-hum-pmp-rv64:
	$(call VERILATOR_DIRECTED_RUN,lsu_hum_pmp_rv64,tb_lsu_hum_pmp,$(XSIM_LSU_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,)

.PHONY: verilator-pmp-endpoint-rv64
verilator-pmp-endpoint-rv64:
	$(call VERILATOR_DIRECTED_RUN,pmp_endpoint_rv64,tb_pmp_endpoint,"$(RAPTOR_HOME)/hdl/rapt_pkg.sv" "$(RAPTOR_HOME)/hdl/memory/rapt_pmp.sv",-d RAPT_RV64,)

.PHONY: verilator-fpu-product-share
verilator-fpu-product-share:
	$(call VERILATOR_DIRECTED_RUN,fpu_product_share,tb_fpu_product_share,"$(RAPTOR_HOME)/hdl/backend/feu/fpu/rapt_fpu_mul.sv" "$(RAPTOR_HOME)/hdl/backend/feu/fpu/rapt_fpu_fma.sv" "$(RAPTOR_HOME)/hdl/backend/feu/fpu/rapt_fpu_mul_fma.sv",-d RAPT_ASSERT_EN,)

.PHONY: verilator-csr-pmp-warl-rv32 verilator-csr-pmp-warl-rv64
verilator-csr-pmp-warl-rv32:
	$(call VERILATOR_DIRECTED_RUN,csr_pmp_warl_rv32,tb_csr_pmp_warl,$(XSIM_CSR_SOURCES) "$(RAPTOR_HOME)/hdl/backend/ieu/rapt_ieu_alu.sv" "$(RAPTOR_HOME)/hdl/backend/ieu/rapt_ieu_pipe_alu_csr.sv",,)
verilator-csr-pmp-warl-rv64:
	$(call VERILATOR_DIRECTED_RUN,csr_pmp_warl_rv64,tb_csr_pmp_warl,$(XSIM_CSR_SOURCES) "$(RAPTOR_HOME)/hdl/backend/ieu/rapt_ieu_alu.sv" "$(RAPTOR_HOME)/hdl/backend/ieu/rapt_ieu_pipe_alu_csr.sv",-d RAPT_RV64,)

.PHONY: verilator-csr-pmp-address-rv64
verilator-csr-pmp-address-rv64:
	$(call VERILATOR_DIRECTED_RUN,csr_pmp_address_rv64,tb_csr_pmp_address,$(XSIM_CSR_SOURCES) "$(RAPTOR_HOME)/hdl/backend/ieu/rapt_ieu_alu.sv" "$(RAPTOR_HOME)/hdl/backend/ieu/rapt_ieu_pipe_alu_csr.sv",-d RAPT_RV64,)

.PHONY: npc-event-bridge-check
npc-event-bridge-check: ## Check NPC half-cycle external-write notification ordering
	mkdir -p "$(BUILD_DIR)/npc-event-bridge"
	$(HOST_CXX) -std=c++17 -Wall -Wextra -Werror -I"$(NSIM_HOME)/include" "$(RAPTOR_HOME)/app/tests/host/npc_eval_events.cc" -o "$(BUILD_DIR)/npc-event-bridge/test"
	"$(BUILD_DIR)/npc-event-bridge/test"

.PHONY: verilator-l1d-reservation-external-rv32 verilator-l1d-reservation-external-rv64
verilator-l1d-reservation-external-rv32:
	$(call VERILATOR_DIRECTED_RUN,l1d_reservation_external_rv32,tb_l1d_reservation_external,$(XSIM_L1D_SOURCES),-d RAPT_ASSERT_EN,)
verilator-l1d-reservation-external-rv64:
	$(call VERILATOR_DIRECTED_RUN,l1d_reservation_external_rv64,tb_l1d_reservation_external,$(XSIM_L1D_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,)

.PHONY: verilator-ioq-sc-external-rv32 verilator-ioq-sc-external-rv64
verilator-ioq-sc-external-rv32:
	$(call VERILATOR_DIRECTED_RUN,ioq_sc_external_rv32,tb_ioq_sc_external,$(XSIM_IOQ_SOURCES) "$(RAPTOR_HOME)/hdl/backend/rapt_completion_guard.sv",-d RAPT_ASSERT_EN,)
verilator-ioq-sc-external-rv64:
	$(call VERILATOR_DIRECTED_RUN,ioq_sc_external_rv64,tb_ioq_sc_external,$(XSIM_IOQ_SOURCES) "$(RAPTOR_HOME)/hdl/backend/rapt_completion_guard.sv",-d RAPT_RV64 -d RAPT_ASSERT_EN,)

.PHONY: rva22s64-lrsc-sv39-alias-run
rva22s64-lrsc-sv39-alias-run: RVA22S64_XLEN = 64
rva22s64-lrsc-sv39-alias-run: $(MROM_IMG)
	@mkdir -p "$(BUILD_DIR)/lrsc-sv39-alias"
	$(CC) -march=rv64imac_zicsr_zifencei -mabi=lp64 -nostdlib -nostartfiles -static -Wl,--no-relax -T "$(FUZZ_LINKER)" "$(RAPTOR_HOME)/app/tests/baremetal/lrsc_sv39_alias.S" -o "$(BUILD_DIR)/lrsc-sv39-alias/test.elf"
	$(OBJCOPY) -O binary "$(BUILD_DIR)/lrsc-sv39-alias/test.elf" "$(BUILD_DIR)/lrsc-sv39-alias/test.bin"
	$(PYTHON) "$(VERIFY_HOME)/scripts/rva22s64_privileged.py" --name lrsc-sv39-alias --npc "$(RVA22S64_NPC)" --reference "$(NEMU_SO_64)" --mrom "$(MROM_IMG)" --image "$(BUILD_DIR)/lrsc-sv39-alias/test.bin" --output "$(BUILD_DIR)/lrsc-sv39-alias/runs"

.PHONY: verilator-ioq-reservation-extent-rv32 verilator-ioq-reservation-extent-rv64
verilator-ioq-reservation-extent-rv32:
	$(call VERILATOR_DIRECTED_RUN,ioq_reservation_extent_rv32,tb_ioq_reservation_extent,$(XSIM_IOQ_SOURCES),-d RAPT_ASSERT_EN,)
verilator-ioq-reservation-extent-rv64:
	$(call VERILATOR_DIRECTED_RUN,ioq_reservation_extent_rv64,tb_ioq_reservation_extent,$(XSIM_IOQ_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,)

.PHONY: verilator-lsu-lr-alignment-rv32 verilator-lsu-lr-alignment-rv64
verilator-lsu-lr-alignment-rv32:
	$(call VERILATOR_DIRECTED_RUN,lsu_lr_alignment_rv32,tb_lsu_lr_alignment,$(XSIM_LSU_SOURCES),-d RAPT_ASSERT_EN,)
verilator-lsu-lr-alignment-rv64:
	$(call VERILATOR_DIRECTED_RUN,lsu_lr_alignment_rv64,tb_lsu_lr_alignment,$(XSIM_LSU_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,)

rva22s64-lrsc-misaligned-run: RVA22S64_RUN_TIMEOUT = 180

.PHONY: verilator-ioq-acquire-publish-rv32 verilator-ioq-acquire-publish-rv64
verilator-ioq-acquire-publish-rv32:
	$(call VERILATOR_DIRECTED_RUN,ioq_acquire_publish_rv32,tb_ioq_acquire_publish,$(XSIM_IOQ_SOURCES),-d RAPT_ASSERT_EN,$(IOQ_ACQUIRE_PLUSARGS))
verilator-ioq-acquire-publish-rv64:
	$(call VERILATOR_DIRECTED_RUN,ioq_acquire_publish_rv64,tb_ioq_acquire_publish,$(XSIM_IOQ_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,$(IOQ_ACQUIRE_PLUSARGS))

.PHONY: verilator-lsu-atomic-release-rv32 verilator-lsu-atomic-release-rv64
verilator-lsu-atomic-release-rv32:
	$(call VERILATOR_DIRECTED_RUN,lsu_atomic_release_rv32,tb_lsu_atomic_release,$(XSIM_LSU_SOURCES),-d RAPT_ASSERT_EN,)
verilator-lsu-atomic-release-rv64:
	$(call VERILATOR_DIRECTED_RUN,lsu_atomic_release_rv64,tb_lsu_atomic_release,$(XSIM_LSU_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,)

.PHONY: verilator-ioq-atomic-release-rv32 verilator-ioq-atomic-release-rv64
verilator-ioq-atomic-release-rv32:
	$(call VERILATOR_DIRECTED_RUN,ioq_atomic_release_rv32,tb_ioq_atomic_release,$(XSIM_IOQ_SOURCES),-d RAPT_ASSERT_EN,)
verilator-ioq-atomic-release-rv64:
	$(call VERILATOR_DIRECTED_RUN,ioq_atomic_release_rv64,tb_ioq_atomic_release,$(XSIM_IOQ_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,)

.PHONY: verilator-ioq-amo-acquire-publish-rv32 verilator-ioq-amo-acquire-publish-rv64
verilator-ioq-amo-acquire-publish-rv32:
	$(call VERILATOR_DIRECTED_RUN,ioq_amo_acquire_publish_rv32,tb_ioq_acquire_publish,$(XSIM_IOQ_SOURCES),-d RAPT_ASSERT_EN,+AMO $(IOQ_ACQUIRE_PLUSARGS))
verilator-ioq-amo-acquire-publish-rv64:
	$(call VERILATOR_DIRECTED_RUN,ioq_amo_acquire_publish_rv64,tb_ioq_acquire_publish,$(XSIM_IOQ_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,+AMO $(IOQ_ACQUIRE_PLUSARGS))

.PHONY: verilator-atomic-replay-rv32 verilator-atomic-replay-rv64
verilator-atomic-replay-rv32:
	$(call VERILATOR_DIRECTED_RUN,atomic_replay_rv32,tb_rou_dual_commit,$(XSIM_ROU_SOURCES) $(filter-out $(XSIM_ROU_SOURCES),$(XSIM_LSU_SOURCES)),-d RAPT_ASSERT_EN -d RAPT_TEST_ATOMIC_REPLAY,)
verilator-atomic-replay-rv64:
	$(call VERILATOR_DIRECTED_RUN,atomic_replay_rv64,tb_rou_dual_commit,$(XSIM_ROU_SOURCES) $(filter-out $(XSIM_ROU_SOURCES),$(XSIM_LSU_SOURCES)),-d RAPT_RV64 -d RAPT_ASSERT_EN -d RAPT_TEST_ATOMIC_REPLAY,)

.PHONY: verilator-lsu-atomic-acquire-rv32 verilator-lsu-atomic-acquire-rv64
verilator-lsu-atomic-acquire-rv32:
	$(call VERILATOR_DIRECTED_RUN,lsu_atomic_acquire_rv32,tb_lsu_atomic_acquire,$(XSIM_LSU_SOURCES),-d RAPT_ASSERT_EN,)
verilator-lsu-atomic-acquire-rv64:
	$(call VERILATOR_DIRECTED_RUN,lsu_atomic_acquire_rv64,tb_lsu_atomic_acquire,$(XSIM_LSU_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,)

.PHONY: verilator-fence-replay-rv32 verilator-fence-replay-rv64
verilator-fence-replay-rv32:
	$(call VERILATOR_DIRECTED_RUN,fence_replay_rv32,tb_rou_dual_commit,$(XSIM_ROU_SOURCES) $(filter-out $(XSIM_ROU_SOURCES),$(XSIM_LSU_SOURCES)),-d RAPT_ASSERT_EN -d RAPT_TEST_ATOMIC_REPLAY -d RAPT_TEST_FENCE_REPLAY,)
verilator-fence-replay-rv64:
	$(call VERILATOR_DIRECTED_RUN,fence_replay_rv64,tb_rou_dual_commit,$(XSIM_ROU_SOURCES) $(filter-out $(XSIM_ROU_SOURCES),$(XSIM_LSU_SOURCES)),-d RAPT_RV64 -d RAPT_ASSERT_EN -d RAPT_TEST_ATOMIC_REPLAY -d RAPT_TEST_FENCE_REPLAY,)

.PHONY: verilator-lsu-axi-io-order-rv32 verilator-lsu-axi-io-order-rv64
verilator-lsu-axi-io-order-rv32:
	$(call VERILATOR_DIRECTED_RUN,lsu_axi_io_order_rv32,tb_lsu_axi_io_order,$(sort $(XSIM_L1D_SOURCES) $(XSIM_LSU_SOURCES) $(XSIM_BUS_SOURCES)),-d RAPT_ASSERT_EN,)
verilator-lsu-axi-io-order-rv64:
	$(call VERILATOR_DIRECTED_RUN,lsu_axi_io_order_rv64,tb_lsu_axi_io_order,$(sort $(XSIM_L1D_SOURCES) $(XSIM_LSU_SOURCES) $(XSIM_BUS_SOURCES)),-d RAPT_RV64 -d RAPT_ASSERT_EN,)

.PHONY: verilator-l1i-invalidate-pending-rv32 verilator-l1i-invalidate-pending-rv64
verilator-l1i-invalidate-pending-rv32:
	$(call VERILATOR_DIRECTED_RUN,l1i_invalidate_pending_rv32,tb_l1i_invalidate_pending,$(XSIM_L1I_SOURCES),-d RAPT_ASSERT_EN,)
verilator-l1i-invalidate-pending-rv64:
	$(call VERILATOR_DIRECTED_RUN,l1i_invalidate_pending_rv64,tb_l1i_invalidate_pending,$(XSIM_L1I_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,)

.PHONY: verilator-l1i-response-error-rv32 verilator-l1i-response-error-rv64
verilator-l1i-response-error-rv32:
	$(call VERILATOR_DIRECTED_RUN,l1i_response_error_rv32,tb_l1i_response_error,$(XSIM_L1I_SOURCES),-d RAPT_ASSERT_EN,$(L1I_ERROR_PLUSARGS))
verilator-l1i-response-error-rv64:
	$(call VERILATOR_DIRECTED_RUN,l1i_response_error_rv64,tb_l1i_response_error,$(XSIM_L1I_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,$(L1I_ERROR_PLUSARGS))

rva22s64-ifetch-mapping-replace-run: RVA22S64_TEST_MARCH = rv$(RVA22S64_XLEN)imafdc_zicsr_zifencei_svinval

rva22s64-ifetch-asid-recycle-run: RVA22S64_TEST_MARCH = rv$(RVA22S64_XLEN)imafdc_zicsr_zifencei_svinval

.PHONY: verilator-ptw-kill-drain-rv64
verilator-ptw-kill-drain-rv64:
	$(call VERILATOR_DIRECTED_RUN,ptw_kill_drain_rv64,tb_ptw_kill_drain,$(XSIM_PTW_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,)

.PHONY: verilator-l1i-mapping-epoch-rv32 verilator-l1i-mapping-epoch-rv64
verilator-l1i-mapping-epoch-rv32:
	$(call VERILATOR_DIRECTED_RUN,l1i_mapping_epoch_rv32,tb_l1i_mapping_epoch,$(XSIM_L1I_SOURCES),-d RAPT_ASSERT_EN,)
verilator-l1i-mapping-epoch-rv64:
	$(call VERILATOR_DIRECTED_RUN,l1i_mapping_epoch_rv64,tb_l1i_mapping_epoch,$(XSIM_L1I_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,)

.PHONY: verilator-ptw-kill-drain-rv32
verilator-ptw-kill-drain-rv32: verilator-ptw-kill-drain

rva22s64-ifetch-superpage-replace-run: RVA22S64_TEST_MARCH = rv64imafdc_zicsr_zifencei_svinval

.PHONY: nemu-sv39-superpage-check
.PHONY: nemu-satp-warl-check
.PHONY: nemu-pmp-priority-check
nemu-pmp-priority-check:
	$(PYTHON) "$(VERIFY_HOME)/scripts/nemu_pmp_priority_check.py"

nemu-satp-warl-check:
	$(PYTHON) "$(VERIFY_HOME)/scripts/nemu_satp_warl_check.py" \
		--reference "$(NEMU_SO_64)" --output "$(BUILD_DIR)/nemu-satp-warl.json"

nemu-sv39-superpage-check:
	$(PYTHON) "$(VERIFY_HOME)/scripts/nemu_sv39_superpage_check.py" \
		--reference "$(NEMU_SO_64)" --output "$(BUILD_DIR)/nemu-sv39-superpage" \
		--cc "$(CC)" --objcopy "$(OBJCOPY)"

.PHONY: verilator-idu-hints-rv32 verilator-idu-hints-rv64
verilator-idu-hints-rv32:
	$(call VERILATOR_DIRECTED_RUN,idu_hints_rv32,tb_idu_hints,$(XSIM_IDU_SOURCES),,)
verilator-idu-hints-rv64:
	$(call VERILATOR_DIRECTED_RUN,idu_hints_rv64,tb_idu_hints,$(XSIM_IDU_SOURCES),-d RAPT_RV64,)

.PHONY: verilator-sq-context-rv32 verilator-sq-context-rv64
verilator-sq-context-rv32 verilator-sq-context-rv64: VERILATOR_DIRECTED_FLAGS = --binary --timing --assert -j 1
verilator-sq-context-rv32:
	$(call VERILATOR_DIRECTED_RUN,sq_context_rv32,tb_sq_context,$(XSIM_LSU_SOURCES),-d RAPT_ASSERT_EN,)
verilator-sq-context-rv64:
	$(call VERILATOR_DIRECTED_RUN,sq_context_rv64,tb_sq_context,$(XSIM_LSU_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,)

.PHONY: verilator-sq-branch-context-rv32 verilator-sq-branch-context-rv64
verilator-sq-branch-context-rv32 verilator-sq-branch-context-rv64: VERILATOR_DIRECTED_FLAGS = --binary --timing --assert -j 1
verilator-sq-branch-context-rv32:
	$(call VERILATOR_DIRECTED_RUN,sq_branch_context_rv32,tb_sq_branch_context,$(XSIM_LSU_SOURCES) "$(RAPTOR_HOME)/hdl/backend/rapt_cmu.sv",-d RAPT_ASSERT_EN -d RAPT_LSU_TB_CMU,)
verilator-sq-branch-context-rv64:
	$(call VERILATOR_DIRECTED_RUN,sq_branch_context_rv64,tb_sq_branch_context,$(XSIM_LSU_SOURCES) "$(RAPTOR_HOME)/hdl/backend/rapt_cmu.sv",-d RAPT_RV64 -d RAPT_ASSERT_EN -d RAPT_LSU_TB_CMU,)

.PHONY: verilator-sq-atomic-context-rv32 verilator-sq-atomic-context-rv64
verilator-sq-atomic-context-rv32 verilator-sq-atomic-context-rv64: VERILATOR_DIRECTED_FLAGS = --binary --timing --assert -j 1
verilator-sq-atomic-context-rv32:
	$(call VERILATOR_DIRECTED_RUN,sq_atomic_context_rv32,tb_sq_atomic_context,$(XSIM_LSU_SOURCES) "$(RAPTOR_HOME)/hdl/backend/rapt_cmu.sv",-d RAPT_ASSERT_EN -d RAPT_LSU_TB_CMU,)
verilator-sq-atomic-context-rv64:
	$(call VERILATOR_DIRECTED_RUN,sq_atomic_context_rv64,tb_sq_atomic_context,$(XSIM_LSU_SOURCES) "$(RAPTOR_HOME)/hdl/backend/rapt_cmu.sv",-d RAPT_RV64 -d RAPT_ASSERT_EN -d RAPT_LSU_TB_CMU,)

.PHONY: verilator-ioq-overlap-rv32 verilator-ioq-overlap-rv64
verilator-ioq-overlap-rv32 verilator-ioq-overlap-rv64: VERILATOR_DIRECTED_FLAGS = --binary --timing --assert -j 1
verilator-ioq-overlap-rv32:
	$(call VERILATOR_DIRECTED_RUN,ioq_overlap_rv32,tb_ioq_overlap,$(XSIM_IOQ_SOURCES),-d RAPT_ASSERT_EN,)
verilator-ioq-overlap-rv64:
	$(call VERILATOR_DIRECTED_RUN,ioq_overlap_rv64,tb_ioq_overlap,$(XSIM_IOQ_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,)

rva22s64-load-overlap-widths-run rva22s64-store-overlap-widths-run: RVA22S64_TEST_MARCH = rv$(RVA22S64_XLEN)imafdc_zicsr_zifencei

.PHONY: verilator-lsu-load-footprint-rv32 verilator-lsu-load-footprint-rv64
verilator-lsu-load-footprint-rv32 verilator-lsu-load-footprint-rv64: VERILATOR_DIRECTED_FLAGS = --binary --timing --assert -j 1
verilator-lsu-load-footprint-rv32:
	$(call VERILATOR_DIRECTED_RUN,lsu_load_footprint_rv32,tb_lsu_load_footprint,$(XSIM_LSU_SOURCES),-d RAPT_ASSERT_EN,)
verilator-lsu-load-footprint-rv64:
	$(call VERILATOR_DIRECTED_RUN,lsu_load_footprint_rv64,tb_lsu_load_footprint,$(XSIM_LSU_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,)

.PHONY: verilator-l1d-load-footprint-rv32 verilator-l1d-load-footprint-rv64
.PHONY: verilator-l1d-plic-width-rv32 verilator-l1d-plic-width-rv64
verilator-l1d-plic-width-rv32 verilator-l1d-plic-width-rv64: VERILATOR_DIRECTED_FLAGS = --binary --timing --assert -j 1
verilator-l1d-plic-width-rv32:
	$(call VERILATOR_DIRECTED_RUN,l1d_plic_width_rv32,tb_l1d_plic_width,$(XSIM_L1D_SOURCES),-d RAPT_ASSERT_EN,)
verilator-l1d-plic-width-rv64:
	$(call VERILATOR_DIRECTED_RUN,l1d_plic_width_rv64,tb_l1d_plic_width,$(XSIM_L1D_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,)

verilator-l1d-load-footprint-rv32 verilator-l1d-load-footprint-rv64: VERILATOR_DIRECTED_FLAGS = --binary --timing --assert -j 1
verilator-l1d-load-footprint-rv32:
	$(call VERILATOR_DIRECTED_RUN,l1d_load_footprint_rv32,tb_l1d_load_footprint,$(XSIM_L1D_SOURCES),-d RAPT_ASSERT_EN,)
verilator-l1d-load-footprint-rv64:
	$(call VERILATOR_DIRECTED_RUN,l1d_load_footprint_rv64,tb_l1d_load_footprint,$(XSIM_L1D_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,)

rva22s64-load-pmp-float-run rva22s64-load-pmp-translated-float-run: RVA22S64_TEST_MARCH = rv$(RVA22S64_XLEN)imafdc_zicsr_zifencei

.PHONY: verilator-router-clint-width-rv32 verilator-router-clint-width-rv64
verilator-router-clint-width-rv32:
	$(call VERILATOR_DIRECTED_RUN,router_clint_width_rv32,tb_router_clint_width,"$(RAPTOR_HOME)/hdl/rapt_router.sv" "$(RAPTOR_HOME)/hdl/perip/rapt_clint.sv",,)
verilator-router-clint-width-rv64:
	$(call VERILATOR_DIRECTED_RUN,router_clint_width_rv64,tb_router_clint_width,"$(RAPTOR_HOME)/hdl/rapt_router.sv" "$(RAPTOR_HOME)/hdl/perip/rapt_clint.sv",-d RAPT_RV64,)

.PHONY: verilator-clint-csr-time-rv32 verilator-clint-csr-time-rv64
verilator-clint-csr-time-rv32:
	$(call VERILATOR_DIRECTED_RUN,clint_csr_time_rv32,tb_clint_csr_time,$(XSIM_CSR_SOURCES) "$(RAPTOR_HOME)/hdl/perip/rapt_clint.sv",,)
verilator-clint-csr-time-rv64:
	$(call VERILATOR_DIRECTED_RUN,clint_csr_time_rv64,tb_clint_csr_time,$(XSIM_CSR_SOURCES) "$(RAPTOR_HOME)/hdl/perip/rapt_clint.sv",-d RAPT_RV64,)

.PHONY: verilator-ioq-plic-width-rv32 verilator-ioq-plic-width-rv64
verilator-ioq-plic-width-rv32 verilator-ioq-plic-width-rv64: VERILATOR_DIRECTED_FLAGS = --binary --timing --assert -j 1
verilator-ioq-plic-width-rv32:
	$(call VERILATOR_DIRECTED_RUN,ioq_plic_width_rv32,tb_ioq_plic_width,$(XSIM_IOQ_SOURCES),-d RAPT_ASSERT_EN,)
verilator-ioq-plic-width-rv64:
	$(call VERILATOR_DIRECTED_RUN,ioq_plic_width_rv64,tb_ioq_plic_width,$(XSIM_IOQ_SOURCES),-d RAPT_RV64 -d RAPT_ASSERT_EN,)

.PHONY: verilator-router-clint-subword-rv32 verilator-router-clint-subword-rv64
verilator-router-clint-subword-rv32 verilator-router-clint-subword-rv64: VERILATOR_DIRECTED_FLAGS = --binary --timing --assert -j 1
verilator-router-clint-subword-rv32:
	$(call VERILATOR_DIRECTED_RUN,router_clint_subword_rv32,tb_router_clint_subword,"$(RAPTOR_HOME)/hdl/rapt_router.sv" "$(RAPTOR_HOME)/hdl/perip/rapt_clint.sv",-d RAPT_ASSERT_EN,)
verilator-router-clint-subword-rv64:
	$(call VERILATOR_DIRECTED_RUN,router_clint_subword_rv64,tb_router_clint_subword,"$(RAPTOR_HOME)/hdl/rapt_router.sv" "$(RAPTOR_HOME)/hdl/perip/rapt_clint.sv",-d RAPT_RV64 -d RAPT_ASSERT_EN,)

.PHONY: verilator-idu-m-encodings-rv32 verilator-idu-m-encodings-rv64
verilator-idu-m-encodings-rv32 verilator-idu-m-encodings-rv64:
	$(call VERILATOR_DIRECTED_RUN,$(subst -,_,$@),tb_idu_m_encodings,$(XSIM_IDU_SOURCES),$(if $(findstring rv64,$@),-d RAPT_RV64),)

.PHONY: verilator-idu-bit-immediates-rv32 verilator-idu-bit-immediates-rv64
verilator-idu-bit-immediates-rv32 verilator-idu-bit-immediates-rv64:
	$(call VERILATOR_DIRECTED_RUN,$(subst -,_,$@),tb_idu_bit_immediates,$(XSIM_IDU_SOURCES),$(if $(findstring rv64,$@),-d RAPT_RV64),)

rva22s64-bit-xlen-legality-run: RVA22S64_TEST_MARCH = rv$(RVA22S64_XLEN)imac_zicsr_zifencei_zba_zbb_zbs

.PHONY: verilator-bit-decode-alu-rv32 verilator-bit-decode-alu-rv64
verilator-bit-decode-alu-rv32 verilator-bit-decode-alu-rv64:
	$(PYTHON) "$(VERIFY_HOME)/scripts/bit_alu_vectors.py" --xlen $(if $(findstring rv64,$@),64,32) --output "$(BUILD_DIR)/$@-vectors"
	$(call VERILATOR_DIRECTED_RUN,$(subst -,_,$@),tb_bit_decode_alu,$(XSIM_IDU_SOURCES) "$(RAPTOR_HOME)/hdl/backend/ieu/rapt_ieu_alu.sv",$(if $(findstring rv64,$@),-d RAPT_RV64),+vectors=$(abspath $(BUILD_DIR)/$@-vectors/vectors.txt))

.PHONY: verilator-zexth-decode-alu-rv32 verilator-zexth-decode-alu-rv64
verilator-zexth-decode-alu-rv32 verilator-zexth-decode-alu-rv64:
	$(call VERILATOR_DIRECTED_RUN,$(subst -,_,$@),tb_zexth_decode_alu,$(XSIM_IDU_SOURCES) "$(RAPTOR_HOME)/hdl/backend/ieu/rapt_ieu_alu.sv",$(if $(findstring rv64,$@),-d RAPT_RV64),)

rva22s64-zexth-xlen-run: RVA22S64_TEST_MARCH = rv$(RVA22S64_XLEN)imac_zicsr_zifencei_zba_zbb_zbs

.PHONY: verilator-compressed-register-legality-rv32 verilator-compressed-register-legality-rv64
verilator-compressed-register-legality-rv32 verilator-compressed-register-legality-rv64:
	$(call VERILATOR_DIRECTED_RUN,$(subst -,_,$@),tb_compressed_register_legality,$(XSIM_IDU_SOURCES),$(if $(findstring rv64,$@),-d RAPT_RV64),)

.PHONY: verilator-compressed-zero-immediate-rv32 verilator-compressed-zero-immediate-rv64
verilator-compressed-zero-immediate-rv32 verilator-compressed-zero-immediate-rv64:
	$(call VERILATOR_DIRECTED_RUN,$(subst -,_,$@),tb_compressed_zero_immediate,$(XSIM_IDU_SOURCES),$(if $(findstring rv64,$@),-d RAPT_RV64),)

.PHONY: verilator-compressed-expansion-rv32 verilator-compressed-expansion-rv64
verilator-compressed-expansion-rv32 verilator-compressed-expansion-rv64:
	$(PYTHON) "$(VERIFY_HOME)/scripts/compressed_vectors.py" --xlen $(if $(findstring rv64,$@),64,32) --output "$(BUILD_DIR)/$@-vectors"
	$(call VERILATOR_DIRECTED_RUN,$(subst -,_,$@),tb_compressed_expansion,$(XSIM_IDU_SOURCES),$(if $(findstring rv64,$@),-d RAPT_RV64),+vectors=$(abspath $(BUILD_DIR)/$@-vectors/vectors.txt))

.PHONY: verilator-csr-write-intent-rv32 verilator-csr-write-intent-rv64
verilator-csr-write-intent-rv32 verilator-csr-write-intent-rv64:
	$(call VERILATOR_DIRECTED_RUN,$(subst -,_,$@),tb_csr_write_intent,$(XSIM_IDU_SOURCES) "$(RAPTOR_HOME)/hdl/backend/ieu/rapt_ieu_alu.sv" "$(RAPTOR_HOME)/hdl/backend/ieu/rapt_ieu_pipe_alu_csr.sv",$(if $(findstring rv64,$@),-d RAPT_RV64),)

.PHONY: verilator-rou-retire-count-rv32 verilator-rou-retire-count-rv64
.PHONY: verilator-half-store-visibility-rv32 verilator-half-store-visibility-rv64
.PHONY: verilator-half-axi-write-rv32 verilator-half-axi-write-rv64
verilator-half-axi-write-rv32 verilator-half-axi-write-rv64:
	$(call VERILATOR_DIRECTED_RUN,$(subst -,_,$@),tb_half_axi_write,$(XSIM_BUS_SOURCES),-d RAPT_ASSERT_EN $(if $(findstring rv64,$@),-d RAPT_RV64),)

verilator-half-store-visibility-rv32 verilator-half-store-visibility-rv64:
	$(call VERILATOR_DIRECTED_RUN,$(subst -,_,$@),tb_half_store_visibility,$(XSIM_LSU_SOURCES) $(filter-out $(XSIM_LSU_SOURCES),$(XSIM_L1D_SOURCES)),-d RAPT_ASSERT_EN $(if $(findstring rv64,$@),-d RAPT_RV64),)

.PHONY: verilator-rou-fp-irq-boundary-rv32 verilator-rou-fp-irq-boundary-rv64
.PHONY: verilator-rou-fp-irq-compose-rv32 verilator-rou-fp-irq-compose-rv64
XSIM_FP_IRQ_COMPOSE_SOURCES = $(XSIM_ROU_SOURCES) \
	"$(RAPTOR_HOME)/hdl/backend/rapt_iq.sv" \
	"$(RAPTOR_HOME)/hdl/common/rapt_issue_select.sv" \
	"$(RAPTOR_HOME)/hdl/backend/rapt_fpr.sv" \
	"$(RAPTOR_HOME)/hdl/backend/feu/rapt_feu.sv" \
	$(wildcard $(RAPTOR_HOME)/hdl/backend/feu/fpu/*.sv)
verilator-rou-fp-irq-compose-rv32 verilator-rou-fp-irq-compose-rv64:
	$(call VERILATOR_DIRECTED_RUN,$(subst -,_,$@),tb_rou_dual_commit,$(XSIM_FP_IRQ_COMPOSE_SOURCES),-d RAPT_ASSERT_EN -d RAPT_TEST_FP_IRQ_BOUNDARY -d RAPT_TEST_FP_IRQ_COMPOSE $(if $(findstring rv64,$@),-d RAPT_RV64),)

verilator-rou-fp-irq-boundary-rv32 verilator-rou-fp-irq-boundary-rv64:
	$(call VERILATOR_DIRECTED_RUN,$(subst -,_,$@),tb_rou_dual_commit,$(XSIM_ROU_SOURCES),-d RAPT_ASSERT_EN -d RAPT_TEST_FP_IRQ_BOUNDARY $(if $(findstring rv64,$@),-d RAPT_RV64),)

verilator-rou-retire-count-rv32 verilator-rou-retire-count-rv64:
	$(call VERILATOR_DIRECTED_RUN,$(subst -,_,$@),tb_rou_dual_commit,$(XSIM_ROU_SOURCES),-d RAPT_ASSERT_EN -d RAPT_TEST_RETIRE_COUNT $(if $(findstring rv64,$@),-d RAPT_RV64),)

.PHONY: verilator-csr-counter-priority-rv32 verilator-csr-counter-priority-rv64
verilator-csr-counter-priority-rv32 verilator-csr-counter-priority-rv64:
	$(call VERILATOR_DIRECTED_RUN,$(subst -,_,$@),tb_csr_counter_priority,$(XSIM_CSR_SOURCES),$(if $(findstring rv64,$@),-d RAPT_RV64),)

.PHONY: verilator-counter-permissions-rv32 verilator-counter-permissions-rv64
verilator-counter-permissions-rv32 verilator-counter-permissions-rv64:
	$(call VERILATOR_DIRECTED_RUN,$(subst -,_,$@),tb_counter_permissions,$(XSIM_IDU_SOURCES),$(if $(findstring rv64,$@),-d RAPT_RV64),)

.PHONY: verilator-l1i-width-window-rv64
verilator-l1i-width-window-rv64:
	$(call VERILATOR_DIRECTED_RUN,l1i_width_window_rv64,tb_l1i_width_window,$(XSIM_L1I_SOURCES),-d RAPT_RV64,)

.PHONY: verilator-svinval-decode-rv32 verilator-svinval-decode-rv64
verilator-svinval-decode-rv32 verilator-svinval-decode-rv64:
	$(call VERILATOR_DIRECTED_RUN,$(subst -,_,$@),tb_svinval_decode,$(XSIM_IDU_SOURCES),$(if $(findstring rv64,$@),-d RAPT_RV64),)

.PHONY: verilator-l1i-data-integrity
L1I_DATA_SEED ?= 1
verilator-l1i-data-integrity:
	$(call VERILATOR_DIRECTED_RUN,l1i_data_integrity,tb_l1i_data_integrity,"$(RAPTOR_HOME)/hdl/memory/rapt_sram_1rw.sv" "$(RAPTOR_HOME)/hdl/memory/rapt_l1i_data.sv",,+SEED=$(L1I_DATA_SEED))

.PHONY: verilator-l1d-permission-stage-rv32 verilator-l1d-permission-stage-rv64
.PHONY: verilator-l1d-trap-owner-rv32 verilator-l1d-trap-owner-rv64
verilator-l1d-trap-owner-rv32 verilator-l1d-trap-owner-rv64:
	$(call VERILATOR_DIRECTED_RUN,$(subst -,_,$@),tb_l1d_trap_owner,$(XSIM_L1D_SOURCES),-d RAPT_ASSERT_EN $(if $(findstring rv64,$@),-d RAPT_RV64),)

verilator-l1d-permission-stage-rv32 verilator-l1d-permission-stage-rv64:
	$(call VERILATOR_DIRECTED_RUN,$(subst -,_,$@),tb_l1d_permission_stage,$(XSIM_L1D_SOURCES),-d RAPT_ASSERT_EN $(if $(findstring rv64,$@),-d RAPT_RV64),)

.PHONY: verilator-idu-fence-i-fields-rv32 verilator-idu-fence-i-fields-rv64
verilator-idu-fence-i-fields-rv32 verilator-idu-fence-i-fields-rv64:
	$(call VERILATOR_DIRECTED_RUN,$(subst -,_,$@),tb_idu_fence_i_fields,$(XSIM_IDU_SOURCES),$(if $(findstring rv64,$@),-d RAPT_RV64),)

.PHONY: verilator-csr-satp-warl-rv32 verilator-csr-satp-warl-rv64
verilator-csr-satp-warl-rv32 verilator-csr-satp-warl-rv64:
	$(call VERILATOR_DIRECTED_RUN,$(subst -,_,$@),tb_csr_contract,$(XSIM_CSR_SOURCES) "$(RAPTOR_HOME)/hdl/backend/ieu/rapt_ieu_alu.sv" "$(RAPTOR_HOME)/hdl/backend/ieu/rapt_ieu_pipe_alu_csr.sv",$(if $(findstring rv64,$@),-d RAPT_RV64),+CASE=satp_warl)

.PHONY: verilator-csr-envcfg-warl-rv32 verilator-csr-envcfg-warl-rv64
verilator-csr-envcfg-warl-rv32 verilator-csr-envcfg-warl-rv64:
	$(call VERILATOR_DIRECTED_RUN,$(subst -,_,$@),tb_csr_envcfg_warl,$(XSIM_CSR_SOURCES) "$(RAPTOR_HOME)/hdl/backend/ieu/rapt_ieu_alu.sv" "$(RAPTOR_HOME)/hdl/backend/ieu/rapt_ieu_pipe_alu_csr.sv",$(if $(findstring rv64,$@),-d RAPT_RV64),)

.PHONY: verilator-ifu-l1i-stream-rv32 verilator-ifu-l1i-stream-rv64
verilator-ifu-l1i-stream-rv32 verilator-ifu-l1i-stream-rv64:
	$(call VERILATOR_DIRECTED_RUN,$(subst -,_,$@),tb_ifu_l1i_stream,$(XSIM_L1I_SOURCES) "$(RAPTOR_HOME)/hdl/frontend/rapt_ifu.sv" "$(RAPTOR_HOME)/hdl/generated/rapt_idu_decoder_c.sv",-d RAPT_ASSERT_EN -d RAPT_DECODE_WIDTH=4 $(if $(findstring rv64,$@),-d RAPT_RV64),)

.PHONY: verilator-csr-pmp-lock-rv32 verilator-csr-pmp-lock-rv64
verilator-csr-pmp-lock-rv32 verilator-csr-pmp-lock-rv64:
	$(call VERILATOR_DIRECTED_RUN,$(subst -,_,$@),tb_csr_pmp_lock,$(XSIM_CSR_SOURCES) "$(RAPTOR_HOME)/hdl/backend/ieu/rapt_ieu_alu.sv" "$(RAPTOR_HOME)/hdl/backend/ieu/rapt_ieu_pipe_alu_csr.sv",$(if $(findstring rv64,$@),-d RAPT_RV64),)

.PHONY: verilator-idu-csr-addresses-rv32 verilator-idu-csr-addresses-rv64
verilator-idu-csr-addresses-rv32 verilator-idu-csr-addresses-rv64:
	$(call VERILATOR_DIRECTED_RUN,$(subst -,_,$@),tb_idu_csr_addresses,$(XSIM_IDU_SOURCES),$(if $(findstring rv64,$@),-d RAPT_RV64),)

.PHONY: verilator-csr-trap-storage-rv32 verilator-csr-trap-storage-rv64
verilator-csr-trap-storage-rv32 verilator-csr-trap-storage-rv64:
	$(call VERILATOR_DIRECTED_RUN,$(subst -,_,$@),tb_csr_contract,$(XSIM_CSR_SOURCES) "$(RAPTOR_HOME)/hdl/backend/ieu/rapt_ieu_alu.sv" "$(RAPTOR_HOME)/hdl/backend/ieu/rapt_ieu_pipe_alu_csr.sv",$(if $(findstring rv64,$@),-d RAPT_RV64),+CASE=trap_storage)

.PHONY: verilator-csr-status-fields-rv32 verilator-csr-status-fields-rv64
verilator-csr-status-fields-rv32 verilator-csr-status-fields-rv64:
	$(call VERILATOR_DIRECTED_RUN,$(subst -,_,$@),tb_csr_contract,$(XSIM_CSR_SOURCES) "$(RAPTOR_HOME)/hdl/backend/ieu/rapt_ieu_alu.sv" "$(RAPTOR_HOME)/hdl/backend/ieu/rapt_ieu_pipe_alu_csr.sv",$(if $(findstring rv64,$@),-d RAPT_RV64),+CASE=status_fields)

.PHONY: verilator-csr-fp-aliases-rv32 verilator-csr-fp-aliases-rv64
verilator-csr-fp-aliases-rv32 verilator-csr-fp-aliases-rv64:
	$(call VERILATOR_DIRECTED_RUN,$(subst -,_,$@),tb_csr_contract,$(XSIM_CSR_SOURCES) "$(RAPTOR_HOME)/hdl/backend/ieu/rapt_ieu_alu.sv" "$(RAPTOR_HOME)/hdl/backend/ieu/rapt_ieu_pipe_alu_csr.sv",$(if $(findstring rv64,$@),-d RAPT_RV64),+CASE=fp_aliases)

.PHONY: verilator-csr-stimecmp-rv32 verilator-csr-stimecmp-rv64
verilator-csr-stimecmp-rv32 verilator-csr-stimecmp-rv64:
	$(call VERILATOR_DIRECTED_RUN,$(subst -,_,$@),tb_csr_contract,$(XSIM_CSR_SOURCES) "$(RAPTOR_HOME)/hdl/backend/ieu/rapt_ieu_alu.sv" "$(RAPTOR_HOME)/hdl/backend/ieu/rapt_ieu_pipe_alu_csr.sv",$(if $(findstring rv64,$@),-d RAPT_RV64),+CASE=stimecmp)

.PHONY: verilator-csr-identity-time-rv32 verilator-csr-identity-time-rv64
verilator-csr-identity-time-rv32 verilator-csr-identity-time-rv64:
	$(call VERILATOR_DIRECTED_RUN,$(subst -,_,$@),tb_csr_contract,$(XSIM_CSR_SOURCES) "$(RAPTOR_HOME)/hdl/backend/ieu/rapt_ieu_alu.sv" "$(RAPTOR_HOME)/hdl/backend/ieu/rapt_ieu_pipe_alu_csr.sv",$(if $(findstring rv64,$@),-d RAPT_RV64),+CASE=identity_time)

.PHONY: verilator-csr-tvec-routes-rv32 verilator-csr-tvec-routes-rv64
verilator-csr-tvec-routes-rv32 verilator-csr-tvec-routes-rv64:
	$(call VERILATOR_DIRECTED_RUN,$(subst -,_,$@),tb_csr_contract,$(XSIM_CSR_SOURCES) "$(RAPTOR_HOME)/hdl/backend/ieu/rapt_ieu_alu.sv" "$(RAPTOR_HOME)/hdl/backend/ieu/rapt_ieu_pipe_alu_csr.sv",$(if $(findstring rv64,$@),-d RAPT_RV64),+CASE=tvec_routes)
