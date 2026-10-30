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

.PHONY: make-targets-test
make-targets-test: ## Check consolidated Make entry points, formatting scopes and benchmark rebuilds
	python3 scripts/test_make_targets.py

.PHONY: sta-flow-check
sta-flow-check: ## Check isolated SRAM/DFF STA runner contracts (no PDK/tool installation)
	python3 scripts/test_sta.py DffFlowTest

.PHONY: sim-build-isolation-check
sim-build-isolation-check: ## Check build-local Kconfig and non-destructive model cache selection
	python3 "$(VERIFY_HOME)/scripts/test_sim_build_isolation.py"

# Tool-free unit tests for helper scripts that have no dedicated check target.
SCRIPT_UNITTESTS := test_config_macro_check test_paddr_config test_fp_test_makefile \
	test_closeout_config_check test_litex_sdcard_linux_override \
	test_lrsc_trace_check test_run_act4 \
	test_sta.SummaryStatusTest test_subsystem_build_cache \
	test_external_drivers $(addprefix test_formal_drivers.,SnapshotOutputTests \
	AbcCompatibilityTest StateAbstractionAudit QualificationEvidenceTests WitnessTests \
	ToolTimeoutTest)

.PHONY: script-unittests
script-unittests: config-macro-check ## Run helper-script unit tests that need no EDA tools
	cd scripts && PYTHONDONTWRITEBYTECODE=1 python3 -m unittest $(SCRIPT_UNITTESTS)

.PHONY: config-macro-check
config-macro-check: ## Check preset macro uses, declarations and direction-predictor selection
	$(PYTHON) "$(VERIFY_HOME)/scripts/config_macro_check.py"

.PHONY: bpu-config-check
bpu-config-check: ## Check all BPU selections and reject missing selections in RV32/RV64
	$(PYTHON) "$(VERIFY_HOME)/scripts/bpu_config_check.py" --output "$(BUILD_DIR)/bpu-config-check"

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
# Guest programs take platform addresses from the generated contract header.
GUEST_INCLUDE := $(RAPTOR_HOME)/app/lib
GUEST_CPPFLAGS := -I"$(GUEST_INCLUDE)"
# Script runners compile guests themselves; CPATH reaches their gcc subprocesses.
export CPATH := $(GUEST_INCLUDE)$(if $(CPATH),:$(CPATH))
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
# sim scopes outputs per RAPT_CONFIG (rtl/configs/<name>/). Keep this in
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
NEMU_SO_32  := $(NEMU_HOME)/build/ref/riscv32_ref_defconfig/riscv32-nemu-interpreter-so
NEMU_REF_PMPADDR_BITS ?= $(shell $(PYTHON) "$(RAPTOR_HOME)/sim/scripts/paddr_config.py" \
  --pmp-only --config "$(RAPTOR_HOME)/rtl/configs/$(or $(strip $(RAPT_CONFIG)),default)" \
  --hdl "$(RAPTOR_HOME)/rtl" -- -DRAPT_RV64 $(VFLAGS))
NEMU_SO_64  := $(NEMU_HOME)/build/ref/riscv64_ref_defconfig$(if $(filter 30,$(NEMU_REF_PMPADDR_BITS)),,-pmp$(NEMU_REF_PMPADDR_BITS))/riscv64-nemu-interpreter-so
MROM_IMG    = $(BUILD_DIR)/mrom-rv$(ISA_XLEN)/mrom-data.bin
# RVA22S64 and SQ checkpoint flows follow their own XLEN variable, independent of ISA.
RVA22S64_XLEN ?= 64
RVA22S64_MROM = $(BUILD_DIR)/mrom-rv$(RVA22S64_XLEN)/mrom-data.bin
rva22s64-%: MROM_IMG = $(RVA22S64_MROM)
sq-checkpoint-rv%: MROM_IMG = $(BUILD_DIR)/mrom-rv$(SQ_CHECKPOINT_XLEN)/mrom-data.bin

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
RISCV_DV_OUT        ?= $(BUILD_DIR)/riscv-dv/$(ISA)## XLEN-isolated generated programs and logs
RISCV_DV_TEST       ?= raptor_privileged_smoke## Test name from riscv-dv-target/testlist.yaml
RISCV_DV_ITERATIONS ?= 1## Override generated program count
RISCV_DV_SEED       ?= 1## Reproducible first random seed
RISCV_DV_TIMEOUT    ?= 120## NPC timeout per delay/seed case
RISCV_DV_MEM_DELAYS ?= 0 7 31 63 233## AXI random-delay maxima (0..N cycles per beat)
RISCV_DV_MEM_SEEDS  ?= 1## Reproducible AXI delay seeds

RISCV_DV_ENV = PATH="$(RISCV_DV_VENV)/bin:$$PATH" \
	PYTHONPATH="$(RISCV_DV_TARGET):$$PYTHONPATH" \
	RISCV_GCC="$(CC)" RISCV_OBJCOPY="$(OBJCOPY)"
RISCV_DV_TARGET_NAME = raptor_rv$(ISA_XLEN)imac
RISCV_DV_ABI = $(if $(filter rv64,$(ISA)),lp64,ilp32)
RISCV_DV_RUN = cd $(RISCV_DV_DIR) && $(RISCV_DV_ENV) \
	$(RISCV_DV_VENV)/bin/python ./run.py --simulator pyflow \
	--target $(RISCV_DV_TARGET_NAME) --custom_target $(RISCV_DV_TARGET) \
	--isa $(ISA)imac_zicsr_zifencei --mabi $(RISCV_DV_ABI)

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
.PHONY: verify-npc-build
verify-npc-build:
	@echo "[verify] Checking the current NPC simulator build..."
	+$(MAKE) -C $(RAPTOR_HOME) configure-rv$(ISA_XLEN) \
		RAPT_CONFIG=$(RAPT_CONFIG) BUILD_PROFILE=$(SIM_BUILD_PROFILE)
	+$(MAKE) -C $(NSIM_HOME) $(SUBMAKE_JOBS) all RAPT_CONFIG=$(RAPT_CONFIG) \
		BUILD_PROFILE=$(SIM_BUILD_PROFILE) VFLAGS="$(VFLAGS)"

$(NEMU_SO):
	@echo "[verify] Building NEMU reference SO..."
ifeq ($(ISA),rv64)
	$(MAKE) -C $(RAPTOR_HOME) build-nemu64-ref
else
	$(MAKE) -C $(RAPTOR_HOME) build-nemu32-ref
endif

# NEMU ISS checks: nemu-*-check targets.
include $(VERIFY_HOME)/nemu/nemu.mk

# One MROM per XLEN; the directory name selects it, so XLEN-specific flows
# (e.g. RVA22S64_XLEN) cannot pick up the other XLEN's boot ROM.
$(BUILD_DIR)/mrom-rv%/mrom-data.bin:
	$(MAKE) -C $(NSIM_HOME)/csrc/mem/mrom-data \
		BUILD_DIR=$(abspath $(dir $@)) ISA64=$(if $(filter 64,$*),1,0)

.PHONY: check-prereqs
check-prereqs: verify-npc-build $(NEMU_SO) $(MROM_IMG) ## Verify all prerequisites are current
	@echo "[verify] Checking prerequisites..."
	@test -f "$(NPC_BIN)" || { echo "ERROR: NPC binary not found: $(NPC_BIN)"; exit 1; }
	@test -f "$(NEMU_SO)" || { echo "ERROR: NEMU SO not found: $(NEMU_SO)"; exit 1; }
	@echo "[verify] All prerequisites OK."

# ============================================================================
include $(VERIFY_HOME)/external-verification.mk

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
		if ! $(CC) $(GUEST_CPPFLAGS) -march=$(MARCH) -mabi=$(MABI) -nostdlib -nostartfiles \
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
	$(CC) $(GUEST_CPPFLAGS) -march=$(MARCH) -mabi=$(MABI) -nostdlib -nostartfiles \
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
	@$(MAKE) -C $(NSIM_HOME) o2_defconfig RAPT_CONFIG=$(RAPT_CONFIG) \
		BUILD_PROFILE=$(ACT4_BUILD_PROFILE) VFLAGS="$(ACT4_VFLAGS)"
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
# Classic needs the full-access PMP precheck in our pinned Sail 0.16 build.
# ACT4 retains its independent SAIL_VERSION requirement above.
RISCOF_CLASSIC_SAIL_VERSION ?= 0.16
RISCOF_CLASSIC_SAIL_PREFIX ?= $(BUILD_DIR)/sail-riscv
RISCOF_CLASSIC_PATH := $(RISCOF_CLASSIC_SAIL_PREFIX)/bin:$(PATH)
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

.PHONY: riscof-classic-sail
riscof-classic-sail: ## Build the pinned classic Sail reference with Raptor's physical access policy
	JOBS="$(JOBS)" bash "$(VERIFY_HOME)/scripts/build_sail_reference.sh" \
		"$(BUILD_DIR)/sail-reference" "$(RISCOF_CLASSIC_SAIL_PREFIX)"

riscof-classic: riscof-classic-setup ## Run classic RISCOF compliance flow
	+$(MAKE) --no-print-directory riscof-classic-run

riscof-classic-build-npc: ## (Re)build NPC simulator without difftest for RISCOF
	@# RISCOF's DUT plugin invokes sim without `--diff`, so the simulator
	@# must be built with the plain (non-difftest) config; otherwise
	@# init_difftest aborts with `ref_so_file != NULL`.
	@$(MAKE) -C $(NSIM_HOME) o2_defconfig RAPT_CONFIG=$(RAPT_CONFIG) \
		BUILD_PROFILE=$(RISCOF_BUILD_PROFILE) VFLAGS=""
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
	@SAIL_FOUND_VERSION=$$(PATH="$(RISCOF_CLASSIC_PATH)" sail_riscv_sim --version 2>/dev/null) \
		&& [ "$$SAIL_FOUND_VERSION" = "$(RISCOF_CLASSIC_SAIL_VERSION)" ] \
		|| { echo "[riscof-classic] ERROR: Sail $(RISCOF_CLASSIC_SAIL_VERSION)" \
			"is required (found '$$SAIL_FOUND_VERSION')."; exit 1; }
	@PATH="$(RISCOF_CLASSIC_PATH)" sail_riscv_sim --rv32 --validate-config \
		--config-override "$(RISCOF_CLASSIC_DIR)/plugins/sail_cSim/raptor.json" >/dev/null
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
		export PATH="$(RISCOF_CLASSIC_PATH)" \
			NPC_BIN="$(RISCOF_NPC_BIN_32)" MROM_IMG="$(MROM_IMG)" \
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
	$(MAKE) -C $(RAPTOR_HOME) build-nemu32

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
	@SAIL_FOUND_VERSION=$$(PATH="$(RISCOF_CLASSIC_PATH)" sail_riscv_sim --version 2>/dev/null) \
		&& [ "$$SAIL_FOUND_VERSION" = "$(RISCOF_CLASSIC_SAIL_VERSION)" ] \
		|| { echo "[riscof-classic-nemu] ERROR: Sail $(RISCOF_CLASSIC_SAIL_VERSION)" \
			"is required (found '$$SAIL_FOUND_VERSION')."; exit 1; }
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
		export PATH="$(RISCOF_CLASSIC_PATH)" NEMU_BIN="$(NEMU_BIN)" NEMU_HOME="$(NEMU_HOME)" \
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
		mkdir -p "$(COV_DIR)/raw"; \
		raw_dir=$$(mktemp -d "$(COV_DIR)/raw/$(1).XXXXXX") || exit 1; status=0; \
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
	$(MAKE) -C $(NSIM_HOME) o2_difftest_defconfig RAPT_CONFIG=$(RAPT_CONFIG) \
		BUILD_PROFILE=$(COV_BUILD_PROFILE) VFLAGS="$(VFLAGS)"
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
		echo "[coverage]        Run 'make -C verification coverage-build' first"; \
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
		if ! $(CC) $(GUEST_CPPFLAGS) -march=$(MARCH) -mabi=$(MABI) -nostdlib -nostartfiles \
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
	formal-pmp formal-pmp-monolithic formal-zkt formal-plru formal-clint \
	formal-plic formal-dtm formal-divsqrt formal-rvfi formal-rvfi-gen formal-rvfi-check formal-rvfi-clean formal-clean

formal-setup: ## Install oss-cad-suite (yosys, sby, solvers)
	$(MAKE) -C $(FORMAL_DIR) setup

formal-bus: ## Formal: verify AXI bus properties
	$(MAKE) -C $(FORMAL_DIR) formal_bus

FORMAL_MEMORY_PROGRESS_TIMEOUT ?= 600
.PHONY: formal-memory-progress formal-memory-progress-negative
formal-memory-progress: ## Formal: bounded L1D/bus progress and collision/escape witnesses
	$(PYTHON) scripts/memory_progress_formal.py --output "$(BUILD_DIR)/memory-progress/bounded" --timeout $(FORMAL_MEMORY_PROGRESS_TIMEOUT)
	$(PYTHON) scripts/memory_progress_formal.py --mode cover --output "$(BUILD_DIR)/memory-progress/cover" --timeout $(FORMAL_MEMORY_PROGRESS_TIMEOUT)

formal-memory-progress-negative: ## Require the isolated old refill gate to fail a progress assertion
	$(PYTHON) scripts/memory_progress_formal.py --mode bmc --negative-control --output "$(BUILD_DIR)/memory-progress/negative" --timeout $(FORMAL_MEMORY_PROGRESS_TIMEOUT)

formal-ieu-mul: ## Formal: verify IEU multiplier
	$(MAKE) -C $(FORMAL_DIR) formal_ieu_mul

.PHONY: formal-ieu-div formal-ieu-muldiv
formal-ieu-div: ## Prove RV32/RV64 DIV/REM values, W forms, ownership and completion
	$(MAKE) -C $(FORMAL_DIR) formal_ieu_div

formal-ieu-muldiv: ## Prove mixed RV32/RV64 MUL/DIV values, arbitration and cancellation
	$(MAKE) -C $(FORMAL_DIR) formal_ieu_muldiv

.PHONY: formal-rvfi-metadata formal-rvfi-platform formal-rou-rvfi formal-rou-rvfi-composed
.PHONY: formal-cache-nru
formal-cache-nru: ## Prove NRU replacement priority, epoch renewal and invalidation
	$(MAKE) -C $(FORMAL_DIR) formal_cache_nru

.PHONY: formal-recovery-pending formal-stream-queue
formal-recovery-pending: ## Prove masked recovery selection and stale-owner cancellation
	$(MAKE) -C $(FORMAL_DIR) formal_recovery_pending

formal-stream-queue: ## Prove banked/BRAM stream queue transport against flop reference
	$(MAKE) -C $(FORMAL_DIR) formal_stream_queue

.PHONY: formal-rou-retire
formal-rou-retire: ## Prove actual retirement banks and serialized immediate transport
	$(MAKE) -C $(FORMAL_DIR) formal_rou_retire

.PHONY: formal-l1d-data
formal-l1d-data: ## Prove diagonal L1D data mapping for every production geometry
	$(MAKE) -C $(FORMAL_DIR) formal_l1d_data

.PHONY: formal-prf formal-prf-zero
formal-prf: ## Check PRF x0, physical data/state history and late-read forwarding
	$(MAKE) -C $(FORMAL_DIR) formal_prf

formal-prf-zero: ## Prove the PRF architectural/debug x0 reset contract
	$(MAKE) -C $(FORMAL_DIR) formal_prf_zero

formal-rvfi-metadata: ## Prove RVFI fault effects, order numbering and compressed HINT metadata
	$(MAKE) -C $(FORMAL_DIR) formal_rvfi_metadata

formal-rvfi-platform: ## Qualify the default/formal Bare physical PMA reference
	$(MAKE) -C $(FORMAL_DIR) formal_rvfi_platform

formal-rou-rvfi: ## Prove actual ROU/RVFI memory transport and retirement prefix
	$(MAKE) -C $(FORMAL_DIR) formal_rou_rvfi

formal-rou-rvfi-composed: ## Prove ROU/RVFI transport with audited cuts and uncut activation
	$(MAKE) -C $(FORMAL_DIR) formal_rou_rvfi_composed

FORMAL_SCOPE_OUTPUT ?= $(or $(TMPDIR),/tmp)/raptor-formal/scope
FORMAL_RECEIPTS ?=
FORMAL_CONTRACT_REVIEW ?=
.PHONY: formal-scope formal-signoff formal-vpu-memory-response formal-sram
formal-scope: ## Inventory all RTL units, interfaces and supported configuration profiles
	$(PYTHON) scripts/formal_scope.py scope --output "$(FORMAL_SCOPE_OUTPUT)"

formal-signoff: ## Fail unless reviewed contracts and current whole-RTL proof evidence close
	$(PYTHON) scripts/formal_scope.py scope --output "$(FORMAL_SCOPE_OUTPUT)" --signoff \
	  $(if $(FORMAL_CONTRACT_REVIEW),--contract-review "$(FORMAL_CONTRACT_REVIEW)",) \
	  --receipts $(foreach receipt,$(FORMAL_RECEIPTS),"$(receipt)")

formal-vpu-memory-response: ## Prove RV32/RV64 stale vector-memory response payload isolation
	$(MAKE) -C vpu memory-response-formal

formal-sram: ## Prove all registered 1RW SRAM shapes, masks, read latency and output hold
	$(MAKE) -C $(FORMAL_DIR) formal_sram

formal-ieu-alu: ## Formal: verify RV32/RV64 IEU ALU and bit-manipulation operations
	$(MAKE) -C $(FORMAL_DIR) formal_ieu_alu

.PHONY: formal-ioq-owner
formal-ioq-owner: ## Formal: prove IOQ dispatch/response provenance and single completion
	$(MAKE) -C $(FORMAL_DIR) formal_ioq_owner

.PHONY: formal-ioq-store
formal-ioq-store: ## Formal: prove owned store operands, AMO bytes and sampled SC decisions
	$(MAKE) -C $(FORMAL_DIR) formal_ioq_store

formal-pmp: ## Formal: prove RV32/RV64 PMP per entry, then compose priority/permissions
	$(MAKE) -C $(FORMAL_DIR) formal_pmp_composed

formal-pmp-monolithic: ## Formal: single-model PMP proof (RV32 ~12 min, RV64 much longer)
	$(MAKE) -C $(FORMAL_DIR) formal_pmp

formal-zkt: ## Formal: Zkt operand-independent MUL, MUL/DIV port, ALU and CDB timing
	$(MAKE) -C $(FORMAL_DIR) zkt-mul zkt-muldiv zkt-alu-ports zkt-cdb

formal-plru: ## Formal: verify 2/4/8-way PLRU replacement
	$(MAKE) -C $(FORMAL_DIR) formal_plru

formal-clint: ## Formal: verify CLINT timer and software-interrupt semantics
	$(MAKE) -C $(FORMAL_DIR) formal_clint

formal-plic: ## Formal: verify PLIC arbitration and gateway lifecycle
	$(MAKE) -C $(FORMAL_DIR) formal_plic

formal-dtm: ## Formal: verify the single-clock JTAG TAP and DMI transport
	$(MAKE) -C $(FORMAL_DIR) formal_dtm

formal-divsqrt: ## Formal: verify FPU divide/square-root control contract
	$(MAKE) -C $(FORMAL_DIR) formal_divsqrt

formal: formal-ieu-alu formal-ieu-muldiv formal-pmp formal-zkt formal-plru \
	formal-memory-progress \
	formal-clint formal-plic formal-dtm formal-bus formal-divsqrt formal-sram \
	formal-vpu-memory-response formal-rvfi-metadata formal-rvfi-platform formal-cache-nru \
	formal-recovery-pending formal-stream-queue formal-rou-retire \
	formal-l1d-data formal-prf ## Run standalone checks

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
# See verification/jtag/README.md for the full coverage matrix and gap list.
JTAG_DIR := $(VERIFY_HOME)/jtag

.PHONY: jtag jtag-selftest jtag-debug-tests-setup jtag-debug-tests jtag-clean

jtag: jtag-selftest ## Run the JTAG default verification (= jtag-selftest)

jtag-selftest: ## JTAG: 23-point DTM/DM compliance probe (no NEMU needed)
	$(MAKE) -C $(JTAG_DIR) selftest

jtag-debug-tests-setup: ## JTAG: clone upstream riscv-tests/debug suite
	$(MAKE) -C $(JTAG_DIR) debug-tests-setup

jtag-debug-tests: ## JTAG: run upstream debug suite (BLOCKED, see verification/jtag/README.md)
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
	-i "$(RAPTOR_HOME)/rtl/configs/$(UVM_RAPT_CONFIG)" \
	-i "$(RAPTOR_HOME)/rtl/include" \
	-i "$(RAPTOR_HOME)/rtl/include/dpic_mock" \
	-i "$(RAPTOR_HOME)/rtl/include/npc"

UVM_IQ_SOURCES := \
	"$(RAPTOR_HOME)/rtl/rapt_pkg.sv" \
	"$(RAPTOR_HOME)/rtl/common/rapt_issue_select.sv" \
	"$(UVM_DIR)/iq/rapt_iq_uvm_if.sv" \
	"$(UVM_DIR)/iq/rapt_iq_uvm_pkg.sv" \
	"$(RAPTOR_HOME)/rtl/backend/rapt_iq.sv" \
	"$(UVM_DIR)/iq/tb_rapt_iq_uvm.sv"

UVM_CSR_SOURCES := \
	"$(RAPTOR_HOME)/rtl/rapt_pkg.sv" \
	"$(UVM_DIR)/csr/rapt_csr_uvm_if.sv" \
	"$(UVM_DIR)/csr/rapt_csr_uvm_pkg.sv" \
	"$(RAPTOR_HOME)/rtl/frontend/rapt_csr.sv" \
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

.PHONY: uvm-chip uvm-chip-rv32 uvm-chip-rv64 uvm-chip-rnp uvm-chip-regress
uvm-chip: ## UVM: run complete-chip scenarios (AXI, CLINT/PLIC, debug, faults)
	$(MAKE) -C "$(UVM_DIR)" chip RAPT_CONFIG=$(UVM_RAPT_CONFIG)
uvm-chip-rv32: ## UVM: run complete-chip RV32 scenarios
	$(MAKE) -C "$(UVM_DIR)" chip-rv32 RAPT_CONFIG=$(UVM_RAPT_CONFIG)
uvm-chip-rv64: ## UVM: run complete-chip RV64 scenarios
	$(MAKE) -C "$(UVM_DIR)" chip-rv64 RAPT_CONFIG=$(UVM_RAPT_CONFIG)
uvm-chip-rnp: ## UVM: run RV32 RNP package-pin verification
	$(MAKE) -C "$(UVM_DIR)" chip-rnp RAPT_CONFIG=$(UVM_RAPT_CONFIG)
uvm-chip-regress: ## UVM: run preset/XLEN/RNP matrix and checker negative tests
	$(MAKE) -C "$(UVM_DIR)" chip-regress

uvm-clean: ## UVM: clean module-level UVM artifacts
	rm -rf $(UVM_BUILD_DIR)

# ============================================================================
# Vivado xsim Directed Checks
# ============================================================================
XSIM_DIR := $(VERIFY_HOME)/xsim
XSIM_BUILD_DIR := $(BUILD_DIR)/xsim
XSIM_RAPT_CONFIG ?= default
VIVADO_SETTINGS ?= /opt/Xilinx/2025.2/Vivado/settings64.sh

# RTL is resolved by module name, so adding, splitting or renaming files under
# rtl/ never edits test rules. rapt_pkg.sv compiles first; Verilator reads every
# other RTL file as a library and elaborates only modules the testbench
# reaches. Testbench stubs take precedence over library modules. Rules list
# only non-RTL helpers (testbench models, sim/ wrappers).
XSIM_RTL_PKG := $(RAPTOR_HOME)/rtl/rapt_pkg.sv
XSIM_RTL_FILES := $(sort $(filter-out $(XSIM_RTL_PKG),$(shell find "$(RAPTOR_HOME)/rtl" \
	-path "$(RAPTOR_HOME)/tools/decodegen" -prune -o -name '*.sv' -print)))
XSIM_RTL_LIBRARY := "$(XSIM_RTL_PKG)" $(addprefix -v ,$(XSIM_RTL_FILES)) -Wno-MODDUP
# xvlog has no library search: compile all RTL; xelab keeps the top's hierarchy.
XSIM_RTL_ALL := "$(XSIM_RTL_PKG)" $(XSIM_RTL_FILES)

XSIM_COMMON_INCLUDES := \
	-i "$(RAPTOR_HOME)/rtl/configs/$(XSIM_RAPT_CONFIG)" \
	-i "$(RAPTOR_HOME)/rtl/include" \
	-i "$(RAPTOR_HOME)/rtl/include/dpic_mock" \
	-i "$(RAPTOR_HOME)/rtl/include/npc" \
	-i "$(XSIM_DIR)"

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
	xsim-lsu-lr-sq-forward \
	xsim-lsu-cbo-zero \
	xsim-lsu-sq-random \
	xsim-ioq \
	xsim-clint \
	xsim-plic-gateway \
	xsim-alu-zbb-strlen \
	xsim-muldiv-flush-reuse \
	xsim-rou-dual-commit

# Scenario tops stored in a shared source, as <top pattern>:<file>. The first
# match wins; other tops, and those in SHARED_TB_STANDALONE, use <top>.sv.
SHARED_TB_SOURCES := \
	tb_sfence_selective_walk:tb_sfence_all_contract.sv \
	tb_sfence_selective_tlb:tb_sfence_all_contract.sv \
	tb_sfence_selective_l2:tb_sfence_all_contract.sv \
	tb_sfence_selective_operands:tb_sfence_all_contract.sv \
	tb_sfence_data_remap:tb_sfence_all_contract.sv \
	tb_completion_packets:tb_uop_all_contract.sv \
	tb_uop_instruction_metadata:tb_uop_all_contract.sv \
	tb_uop_payload:tb_uop_all_contract.sv \
	tb_cache_lru:tb_replacement_all_contract.sv \
	tb_tlb_lru:tb_replacement_all_contract.sv \
	tb_pmp_shared_equiv:tb_pmp_permissions.sv \
	tb_targeted_coherence:tb_l1d_all_contract.sv \
	tb_dirty_line_select:tb_l1d_all_contract.sv \
	tb_cbo_refill_order:tb_l1d_all_contract.sv \
	tb_bus_buffered_writeback:tb_bus_all_contract.sv \
	tb_bus_read_ownership:tb_bus_all_contract.sv \
	tb_idu_%:tb_idu_contract.sv \
	tb_router_%:tb_router_all_contract.sv \
	tb_ptw_%:tb_ptw_all_contract.sv \
	tb_sq_%:tb_sq_all_contract.sv \
	tb_l1d_%:tb_l1d_all_contract.sv \
	tb_ioq_%:tb_ioq_all_contract.sv \
	tb_lsu_%:tb_lsu_all_contract.sv \
	tb_csr_%:tb_csr_all_contract.sv \
	tb_predict_history%:tb_predict_history_contract.sv \
	tb_issue_select%:tb_issue_select_contract.sv \
	tb_rename_checkpoint%:tb_rename_checkpoint_contract.sv \
	tb_fetch_%:tb_fetch_contract.sv
SHARED_TB_STANDALONE := \
	tb_l1d_16k tb_l1d_pmp_shared tb_l1d_ptw_permission_stage \
	tb_ioq_forward_nonalias tb_ioq_dispatch_stable tb_ioq_fp_ooo

# $(call shared_tb_match,<pattern>:<file>,<top>) gives <file> if <top> matches.
shared_tb_pattern = $(firstword $(subst :, ,$(1)))
shared_tb_file = $(lastword $(subst :, ,$(1)))
shared_tb_match = $(if $(filter $(call shared_tb_pattern,$(1)),$(2)),$(call shared_tb_file,$(1)))
shared_tb_matches = $(foreach entry,$(SHARED_TB_SOURCES),$(call shared_tb_match,$(entry),$(1)))
shared_tb_first = $(firstword $(call shared_tb_matches,$(1)))
shared_tb_lookup = $(if $(filter $(SHARED_TB_STANDALONE),$(1)),,$(call shared_tb_first,$(1)))

define SHARED_TB_SOURCE
$(or $(call shared_tb_lookup,$(1)),$(1).sv)
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
		$(XSIM_RTL_ALL) $(3) \
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
	$(call XSIM_RUN,alu_zbb_strlen,tb_alu_zbb_strlen,,-d RAPT_RV64)

xsim-l2: ## xsim: verify L2 ordering, cache fills, and posted write streams
	$(call XSIM_RUN,l2,tb_l2_ordered_mmio,,-d RAPT_L2_EN)

xsim-l2-ordered-mmio xsim-l2-write-stream: xsim-l2

xsim-l1d-byte-rom: ## xsim: verify L1D ROM byte reads across cache fills/hits
	$(call XSIM_RUN,l1d_byte_rom,tb_l1d_byte_rom,,)

xsim-l1d-store-coherence: ## xsim: verify L1D load-after-store coherence
	$(call XSIM_RUN,l1d_store_coherence,tb_l1d_store_coherence,,)

xsim-l1d-flush-ordered: ## xsim: verify L1D flush drain and non-cacheable ordering
	$(call XSIM_RUN,l1d_flush_ordered,tb_l1d_flush_ordered,,-d RAPT_ASSERT_EN)

xsim-l1d-cmo-permissions: ## xsim: verify Zicbom R-or-W/A-only PTE checks and store faults
	$(call XSIM_RUN,l1d_cmo_permissions,tb_l1d_cmo_permissions,,-d RAPT_RV64 -d RAPT_ASSERT_EN)

xsim-l1i-sret-priv-epoch: ## xsim: verify SRET target privilege and stale PTW response kill
	$(call XSIM_RUN,l1i_sret_priv_epoch,tb_l1i_sret_priv_epoch,,-d RAPT_ASSERT_EN)

xsim-ptw-kill-drain: ## xsim: verify PTW cancel-before-accept and drain-after-accept
	$(call XSIM_RUN,ptw_kill_drain,tb_ptw_kill_drain,,-d RAPT_ASSERT_EN)

xsim-ptw-profile-negative: ## xsim: verify RVA20S64 Svade and Sv39 canonical faults
	$(call XSIM_RUN,ptw_profile_negative,tb_ptw_profile_negative,,-d RAPT_RV64 -d RAPT_ASSERT_EN)

xsim-idu-illegal-stval: ## xsim: verify Sstvala reports raw illegal C instruction bits
	$(call XSIM_RUN,idu_illegal_stval,tb_idu_illegal_stval,,-d RAPT_RV64 -d RAPT_ASSERT_EN)

xsim-idu-zfhmin: ## xsim: verify all mandatory Zfhmin instructions decode and use halfword LSU widths
	$(call XSIM_RUN,idu_zfhmin,tb_idu_zfhmin,,-d RAPT_RV64 -d RAPT_ASSERT_EN)

xsim-idu-cmo: ## xsim: verify RVA22 CMO decode and xenvcfg privilege gating
	$(call XSIM_RUN,idu_cmo,tb_idu_cmo,,-d RAPT_RV64 -d RAPT_ASSERT_EN)

xsim-tlb-flush-asid: ## xsim: verify TLB ASID matching and flush priority
	$(call XSIM_RUN,tlb_flush_asid,tb_tlb_flush_asid,,-d RAPT_ASSERT_EN)

xsim-bus-axi: ## xsim: verify bus AXI reads and independent AW/W handshakes
	$(call XSIM_RUN,bus_axi,tb_bus_l1d_rlast,,)

xsim-bus-l1d-rlast xsim-bus-write-aw-before-w: xsim-bus-axi

xsim-bus-read-ownership: ## xsim: verify read response ID ownership and interleaving
	$(call XSIM_RUN,bus_read_ownership,tb_bus_read_ownership,,)

xsim-csr-sret-roundtrip: ## xsim: verify CSR reset and U-ecall/SRET round trip
	$(call XSIM_RUN,csr_sret_roundtrip_$(ISA),tb_csr_sret_roundtrip,,$(if $(filter rv64,$(ISA)),-d RAPT_RV64,))

xsim-addr-classification: ## xsim: reject malformed RV64 physical-address upper bits
	$(call XSIM_RUN,addr_classification,tb_addr_classification,,-d RAPT_RV64)

xsim-pmp-endpoint: ## xsim: verify variable-size PMP endpoint boundary checks
	$(call XSIM_RUN,pmp_endpoint,tb_pmp_endpoint,,)

xsim-lsu-lr-sq-forward: ## xsim: verify LR waits for SQ drain instead of forwarding
	$(call XSIM_RUN,lsu_lr_sq_forward,tb_lsu_lr_sq_forward,,-d RAPT_ASSERT_EN)

xsim-lsu-cbo-zero: ## xsim: verify Zicboz emits eight aligned zero dword stores
	$(call XSIM_RUN,lsu_cbo_zero,tb_lsu_cbo_zero,,-d RAPT_RV64 -d RAPT_ASSERT_EN)

LSU_SQ_RANDOM_SEED ?= 1370169382
xsim-lsu-sq-random: ## xsim: constrained-random SQ ordering, alias, wrap, flush, and backpressure
	$(call XSIM_RUN,lsu_sq_random,tb_lsu_sq_random,,-d RAPT_ASSERT_EN,-testplusarg SEED=$(LSU_SQ_RANDOM_SEED))

xsim-ioq: ## xsim: verify IOQ LR/SC reservations, pending loads, and flush kills
	$(call XSIM_RUN,ioq,tb_ioq_pending_lock,,)

xsim-ioq-lrsc-reservation xsim-ioq-pending-lock: xsim-ioq

xsim-clint: ## xsim: verify CLINT divider, compare, and software interrupt semantics
	$(call XSIM_RUN,clint,tb_clint,,)

xsim-plic-gateway: ## xsim: verify PLIC gateway and claim/complete semantics
	$(call XSIM_RUN,plic_gateway,tb_plic_gateway,,)

xsim-muldiv-flush-reuse: ## xsim: verify flush kills DIV completion before MDQ slot reuse
	$(call XSIM_RUN,muldiv_flush_reuse,tb_muldiv_flush_reuse,,-d RAPT_ASSERT_EN)

xsim-rou-dual-commit: ## xsim: verify ROU dual commit and slot1 flush serialization
	$(call XSIM_RUN,rou_dual_commit,tb_rou_dual_commit,,-d RAPT_ASSERT_EN)

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
	verilator-zfhmin-decode-slot-rv32 \
	verilator-zfhmin-decode-slot-rv64 \
	verilator-l1i-response-error-rv32 \
	verilator-l1i-response-error-rv64 \
	verilator-compressed-expansion-rv32 \
	verilator-compressed-expansion-rv64 \
	verilator-l1d-replacement \
	verilator-l1i-width-window-4way \
	verilator-l1i-width-window-8way \
	verilator-cache-replacement \
	verilator-sq-forward-ports \
	verilator-sq-forward-ports-rv64 \
	verilator-sq-forward-ring-rv32 \
	verilator-sq-forward-ring-rv64 \
	verilator-l1d-data \
	verilator-l1d-writeback \
	verilator-l1d-config-slices \
	verilator-l1d-tags \
	verilator-alu-zbb-strlen \
	verilator-l2 \
	verilator-axi-r-buffer-rv32 \
	verilator-axi-r-buffer-rv64 \
	verilator-l2-data-array \
	verilator-l2-directory \
	verilator-l2-directory-oneway \
	verilator-l2-release-buffer-rv32 \
	verilator-l2-release-buffer-rv64 \
	verilator-l1d-byte-rom \
	verilator-l1d-store-coherence \
	verilator-memory-coherence-progress-rv32 \
	verilator-memory-coherence-progress-rv64 \
	verilator-l1d-writeback-rv32 \
	verilator-l1d-writeback-rv64 \
	verilator-l1d-writeback-line-rv32 \
	verilator-l1d-writeback-line-rv64 \
	verilator-l1d-writeback-bscan-rv64 \
	verilator-l1d-flush-ordered \
	verilator-l1d-cmo-permissions \
	verilator-l1d-pmp-shared-rv32 \
	verilator-l1d-pmp-shared-rv64 \
	verilator-l1d-permission-stage-rv32 \
	verilator-l1d-permission-stage-rv64 \
	verilator-l1i-sret-priv-epoch \
	verilator-l1i-access-sizes-rv32 \
	verilator-l1i-access-sizes-rv64 \
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
	verilator-l2tlb-rv32 \
	verilator-l2tlb-rv64 \
	verilator-cached-ptw-rv32 \
	verilator-cached-ptw-rv64 \
	verilator-l2tlb-l1i-epoch-rv32 \
	verilator-l2tlb-l1i-epoch-rv64 \
	verilator-l2tlb-l1i-sret-rv32 \
	verilator-l2tlb-l1i-sret-rv64 \
	verilator-l2tlb-cbo-rv32 \
	verilator-l2tlb-cbo-rv64 \
	verilator-bus-axi \
	verilator-axi-write-lanes-rv32 \
	verilator-axi-write-lanes-rv64 \
	verilator-bus-read-ownership \
	verilator-csr-sret-roundtrip-rv32 \
	verilator-csr-sret-roundtrip-rv64 \
	verilator-csr-architectural-rv32 \
	verilator-csr-architectural-rv64 \
	verilator-addr-classification \
	verilator-pmp-endpoint \
	verilator-pmp-reset-napot-rv32 \
	verilator-pmp-reset-napot-rv64 \
	verilator-pmp-window-uniform-rv32 \
	verilator-pmp-window-uniform-rv64 \
	verilator-lsu-lr-sq-forward \
	verilator-lsu-cbo-zero \
	verilator-lsu-sq-random \
	verilator-ioq \
	verilator-ioq-forward-nonalias-rv32 \
	verilator-ioq-forward-nonalias-rv64 \
	verilator-ioq-dispatch-stable-rv32 \
	verilator-ioq-dispatch-stable-rv64 \
	verilator-ioq-b-wake-alias-rv32 \
	verilator-ioq-b-wake-alias-rv64 \
	verilator-ioq-completion-kill-rv32 \
	verilator-ioq-completion-kill-rv64 \
	verilator-mshr-fill-selection-rv32 \
	verilator-mshr-fill-selection-rv64 \
	verilator-mshr-cache-rv32 \
	verilator-mshr-cache-rv64 \
	verilator-mshr-ioq-rv32 \
	verilator-mshr-ioq-rv64 \
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
	verilator-port-priority \
	verilator-iq-cdb-wake-rv32 \
	verilator-iq-cdb-wake-rv64 \
	verilator-iq-port-priority-rv32 \
	verilator-iq-port-priority-rv64 \
	verilator-dispatch-admit \
	verilator-rob-dispatch-select \
	verilator-operand-spill \
	verilator-operand-value-spill \
	verilator-dispatch-compact \
	verilator-recovery-pending \
	verilator-completion-guard \
	verilator-ioq-response-stage-rv32 \
	verilator-ioq-response-stage-rv64 \
	verilator-completion-stage-rv32 \
	verilator-completion-stage-rv64 \
	verilator-fmax-boundaries-rv32 \
	verilator-fmax-boundaries-rv64 \
	verilator-cdb-streaming-rv32 \
	verilator-cdb-streaming-rv64 \
	verilator-iq-reclaim-random \
	verilator-ras \
	verilator-ras-pipeline \
	verilator-btb-storage-rv32 \
	verilator-btb-storage-rv64 \
	verilator-predict-history \
	verilator-predict-history-pipeline \
	verilator-cache-stream-wb-rv32 \
	verilator-cache-stream-wb-rv64 \
	verilator-cache-stream-wb-l2-rv32 \
	verilator-cache-stream-wb-l2-rv64 \
	verilator-cache-default-rv32 \
	verilator-cache-default-rv64 \
	verilator-wb-ptw-rv32 \
	verilator-wb-ptw-rv64

# $(1)=build/log stem, $(2)=top/testbench, $(3)=DUT sources,
# $(4)=XSim-style defines (`-d NAME`, translated to `-DNAME`),
# $(5)=runtime plusargs; $(6)=optional follow-up commands using $$model_dir.
_verify_quote = '$(subst ','"'"',$(1))'
define VERILATOR_DIRECTED_RUN
	+@set -e -o pipefail; \
	command -v $(VERILATOR) >/dev/null 2>&1 || { \
		echo "[verilator-directed] ERROR: $(VERILATOR) not found"; exit 1; }; \
	mkdir -p "$(VERILATOR_DIRECTED_BUILD_DIR)/$(1)"; \
	build_key=$$(python3 "$(VERIFY_HOME)/../sim/scripts/build_cache.py" fingerprint --config /dev/null -- \
		$(call _verify_quote,$(VERILATOR) $(VERILATOR_DIRECTED_FLAGS)) \
		$(call _verify_quote,$(2) $(XSIM_RTL_LIBRARY) $(3) $(4) $(XSIM_COMMON_INCLUDES))); \
	model_dir="$(VERILATOR_DIRECTED_BUILD_DIR)/$(1)/obj-$$build_key"; \
	$(VERILATOR) $(VERILATOR_DIRECTED_FLAGS) \
		--timescale 1ns/1ps --top-module $(2) \
		$(subst -d ,-D,$(4)) \
		$(addprefix -I,$(patsubst -i%,%,$(XSIM_COMMON_INCLUDES))) \
		$(XSIM_RTL_LIBRARY) $(3) "$(XSIM_DIR)/$(call SHARED_TB_SOURCE,$(2))" \
		--Mdir "$$model_dir" -o $(2) \
		>"$(VERILATOR_DIRECTED_BUILD_DIR)/$(1)/build.log" 2>&1; \
	"$$model_dir/$(2)" $(5) \
		2>&1 | tee "$(VERILATOR_DIRECTED_BUILD_DIR)/$(1)/run.log"; \
	grep -q "PASS:" "$(VERILATOR_DIRECTED_BUILD_DIR)/$(1)/run.log" || { \
		echo "[verilator-directed] ERROR: $(2) did not report PASS"; exit 1; }; \
	echo "[verilator-directed] PASS $(1)"$(if $(strip $(6)),; $(6))
endef

# Paired -rv32/-rv64 form: the target name selects XLEN and the build stem
# (verilator-foo-rv64 -> foo_rv64, with -d RAPT_RV64 prepended to the defines).
# $(1)=top/testbench, $(2)=DUT sources, $(3)=defines, $(4)=plusargs, $(5)=follow-up.
VERILATOR_DIRECTED_XLEN_RUN = $(call VERILATOR_DIRECTED_RUN,$(subst -,_,$(patsubst verilator-%,%,$@)),$(1),$(2),$(strip $(if $(filter %-rv64,$@),-d RAPT_RV64) $(3)),$(4),$(5))

.PHONY: verilator-directed verilator-directed-clean $(VERILATOR_DIRECTED_TARGETS)

verilator-directed: superscalar-structure-check verilator-directed-registry-check $(VERILATOR_DIRECTED_TARGETS) ## Run the fast module-check gate with portable Verilator
	@echo "[verilator-directed] all $(words $(VERILATOR_DIRECTED_TARGETS)) checks passed"

# verilator-* rules that are aggregates or helpers rather than checks. Every
# other verilator-* rule is a directed check and runs in verilator-directed-all.
VERILATOR_DIRECTED_NONTEST := verilator-directed verilator-directed-all \
	verilator-directed-clean verilator-directed-registry-check verilator-execution-port-matrix

.PHONY: verilator-directed-all verilator-directed-registry-check _directed-registry-db
verilator-directed-all: superscalar-structure-check verilator-directed-registry-check ## Run every defined directed module check
	+@checks="$$($(PYTHON) "$(VERIFY_HOME)/scripts/directed_registry.py" list)"; \
	$(MAKE) --no-print-directory $$checks && \
	echo "[verilator-directed-all] all $$(echo $$checks | wc -w) checks passed"

verilator-directed-registry-check: ## Reject gate entries without a rule; count ungated checks
	@$(PYTHON) "$(VERIFY_HOME)/scripts/directed_registry.py" check

_directed-registry-db:
	@:

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
ROB_DISPATCH_SCAN6_BIN ?= $(NSIM_HOME)/build/rob-dispatch-scan6-n2/riscv32-npc-sim## W2 window with six lanes
ROB_DISPATCH_SCAN8_BIN ?= $(NSIM_HOME)/build/rob-dispatch-scan8-n2/riscv32-npc-sim## W2 window with eight lanes
ROB_DISPATCH_SCAN12_BIN ?= $(NSIM_HOME)/build/rob-dispatch-scan12-n2/riscv32-npc-sim## W2 window with twelve lanes
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

.PHONY: integer-issue-port-report
integer-issue-port-report: ## Summarize dispatch-domain bottlenecks in the latest long-workload result
	$(PYTHON) "$(VERIFY_HOME)/scripts/execution_port_report.py" \
		"$(BUILD_DIR)/integer-port-workloads/results.json"

rob-dispatch-scan-build: ## Build W2 dispatch-window profiles with 6, 8 and 12 lanes
	$(MAKE) -C $(NSIM_HOME) all RAPT_CONFIG=default BUILD_PROFILE=rob-dispatch-scan6-n2 \
		VFLAGS="-DRAPT_STEER_SCAN_ENTRIES=6"
	$(MAKE) -C $(NSIM_HOME) all RAPT_CONFIG=default BUILD_PROFILE=rob-dispatch-scan8-n2 \
		VFLAGS="-DRAPT_STEER_SCAN_ENTRIES=8"
	$(MAKE) -C $(NSIM_HOME) all RAPT_CONFIG=default BUILD_PROFILE=rob-dispatch-scan12-n2 \
		VFLAGS="-DRAPT_STEER_SCAN_ENTRIES=12"

rob-dispatch-scan-evaluate: ## Compare W2 dispatch windows with 6, 8 and 12 lanes over all RV32 cpu-tests
	@test -x "$(ROB_DISPATCH_SCAN6_BIN)" || { echo "missing $(ROB_DISPATCH_SCAN6_BIN)"; exit 1; }
	@test -x "$(ROB_DISPATCH_SCAN8_BIN)" || { echo "missing $(ROB_DISPATCH_SCAN8_BIN)"; exit 1; }
	@test -x "$(ROB_DISPATCH_SCAN12_BIN)" || { echo "missing $(ROB_DISPATCH_SCAN12_BIN)"; exit 1; }
	$(PYTHON) "$(VERIFY_HOME)/scripts/width_evaluate.py" --all-cases \
		--profile scan6="$(ROB_DISPATCH_SCAN6_BIN)" \
		--profile scan8="$(ROB_DISPATCH_SCAN8_BIN)" \
		--profile scan12="$(ROB_DISPATCH_SCAN12_BIN)" \
		--output "$(BUILD_DIR)/rob-dispatch-scan-sweep-cpu"

rob-dispatch-scan-workloads: ## Compare W2 dispatch windows with 6, 8 and 12 lanes on long workloads
	@test -x "$(ROB_DISPATCH_SCAN6_BIN)" || { echo "missing $(ROB_DISPATCH_SCAN6_BIN)"; exit 1; }
	@test -x "$(ROB_DISPATCH_SCAN8_BIN)" || { echo "missing $(ROB_DISPATCH_SCAN8_BIN)"; exit 1; }
	@test -x "$(ROB_DISPATCH_SCAN12_BIN)" || { echo "missing $(ROB_DISPATCH_SCAN12_BIN)"; exit 1; }
	@test -f "$(INTEGER_PORT_COREMARK_IMG)" || { echo "missing $(INTEGER_PORT_COREMARK_IMG)"; exit 1; }
	@test -f "$(INTEGER_PORT_MICROBENCH_IMG)" || { echo "missing $(INTEGER_PORT_MICROBENCH_IMG)"; exit 1; }
	$(PYTHON) "$(VERIFY_HOME)/scripts/execution_port_workloads.py" \
		--profile scan6="$(ROB_DISPATCH_SCAN6_BIN)" \
		--profile scan8="$(ROB_DISPATCH_SCAN8_BIN)" \
		--profile scan12="$(ROB_DISPATCH_SCAN12_BIN)" \
		--workload coremark="$(INTEGER_PORT_COREMARK_IMG)" \
		--workload microbench="$(INTEGER_PORT_MICROBENCH_IMG)" \
		--timeout "$(INTEGER_PORT_WORKLOAD_TIMEOUT)" \
		--output "$(BUILD_DIR)/rob-dispatch-scan-sweep-workloads"

rob-dispatch-scan-report: ## Report endpoint pressure for the dispatch-window sweep
	$(PYTHON) "$(VERIFY_HOME)/scripts/execution_port_report.py" \
		"$(BUILD_DIR)/rob-dispatch-scan-sweep-workloads/results.json"

dispatch-steer-ppa: dispatch-steer-ppa-report ## Map and compare K4/K8 steering cones

dispatch-steer-ppa-build: ## Build six zero-I/O-delay technology-mapped steering cases
	+$(MAKE) --no-print-directory --output-sync=target $(SUBMAKE_JOBS) \
		$(DISPATCH_STEER_PPA_CASE_TARGETS)

dispatch-steer-ppa-dpu-k4:
	+$(MAKE) -C "$(RAPTOR_HOME)/synth/yosys" ppa MODULE=dpu \
		$(DISPATCH_STEER_PPA_COMMON) EXTRA_DEFINES=-DRAPT_STEER_SCAN_ENTRIES=4 \
		BUILD_DIR="$(DISPATCH_STEER_PPA_ROOT)/dpu-k4-io0"

dispatch-steer-ppa-dpu-k8:
	+$(MAKE) -C "$(RAPTOR_HOME)/synth/yosys" ppa MODULE=dpu \
		$(DISPATCH_STEER_PPA_COMMON) EXTRA_DEFINES=-DRAPT_STEER_SCAN_ENTRIES=8 \
		BUILD_DIR="$(DISPATCH_STEER_PPA_ROOT)/dpu-k8-io0"

dispatch-steer-ppa-select-k4:
	+$(MAKE) -C "$(RAPTOR_HOME)/synth/yosys" ppa MODULE=dispatch_select \
		$(DISPATCH_STEER_PPA_COMMON) EXTRA_DEFINES=-DRAPT_STEER_SCAN_ENTRIES=4 \
		BUILD_DIR="$(DISPATCH_STEER_PPA_ROOT)/select-k4-io0"

dispatch-steer-ppa-select-k8:
	+$(MAKE) -C "$(RAPTOR_HOME)/synth/yosys" ppa MODULE=dispatch_select \
		$(DISPATCH_STEER_PPA_COMMON) EXTRA_DEFINES=-DRAPT_STEER_SCAN_ENTRIES=8 \
		BUILD_DIR="$(DISPATCH_STEER_PPA_ROOT)/select-k8-io0"

dispatch-steer-ppa-steer-k4:
	+$(MAKE) -C "$(RAPTOR_HOME)/synth/yosys" ppa MODULE=dispatch_steer \
		$(DISPATCH_STEER_PPA_COMMON) EXTRA_DEFINES=-DRAPT_STEER_SCAN_ENTRIES=4 \
		BUILD_DIR="$(DISPATCH_STEER_PPA_ROOT)/steer-k4-io0"

dispatch-steer-ppa-steer-k8:
	+$(MAKE) -C "$(RAPTOR_HOME)/synth/yosys" ppa MODULE=dispatch_steer \
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
	$(CC) $(GUEST_CPPFLAGS) -march=rv32imafdc_zicsr -mabi=ilp32 -nostdlib -nostartfiles \
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
	$(CC) $(GUEST_CPPFLAGS) -march=rv$(FP_PRODUCT_STREAM_XLEN)imafdc_zicsr \
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
	$(CC) $(GUEST_CPPFLAGS) -march=rv32imafdc_zicsr -mabi=ilp32 -nostdlib -nostartfiles \
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

verilator-l1i-width-window-4way: VERILATOR_DIRECTED_FLAGS += -GWays=4
verilator-l1i-width-window-8way: VERILATOR_DIRECTED_FLAGS += -GWays=8
.PHONY: yosys-sq-span-equivalence
yosys-sq-span-equivalence:
	python3 "$(VERIFY_HOME)/scripts/check_sq_span_equivalence.py" --rtl "$(RAPTOR_HOME)/rtl/backend/lsu/rapt_sq_forward.sv" --build-dir "$(BUILD_DIR)/sq-span-equivalence"

WB_LINE_REFILL ?= 0
verilator-l1d-writeback-rv32 verilator-l1d-writeback-rv64: VERILATOR_DIRECTED_FLAGS += -GWriteBack=1 -GLineRefill=$(WB_LINE_REFILL)
verilator-l1d-writeback-line-rv32 verilator-l1d-writeback-line-rv64 \
verilator-l1d-refill-store-rv32 verilator-l1d-refill-store-rv64: VERILATOR_DIRECTED_FLAGS += -GWriteBack=1 -GLineRefill=1
L1D_BSCAN_TRACE ?= 0
verilator-l1d-writeback-bscan-rv64: VERILATOR_DIRECTED_FLAGS += -GWriteBack=1 -GLineRefill=1 --trace

.PHONY: verilator-l1d-config-slices
verilator-l1d-config-slices: ## Lint all L1D geometries and full w4/w8 core slices in RV32/RV64
	python3 "$(VERIFY_HOME)/scripts/check_l1d_config_slices.py"

.PHONY: verilator-idu-zkt-rv32 verilator-idu-zkt-rv64
verilator-idu-zkt-rv32 verilator-idu-zkt-rv64:
	$(PYTHON) "$(VERIFY_HOME)/scripts/zkt_decode_vectors.py" --xlen $(if $(findstring rv64,$@),64,32) --output "$(BUILD_DIR)/$@-vectors"
	$(call VERILATOR_DIRECTED_RUN,$(subst -,_,$@),tb_idu_zkt,,$(if $(findstring rv64,$@),-d RAPT_RV64),+vectors=$(abspath $(BUILD_DIR)/$@-vectors/vectors.txt))

.PHONY: rva22s64-zkt-core-timing-run
rva22s64-zkt-core-timing-run: $(RVA22S64_MROM)
	$(PYTHON) "$(VERIFY_HOME)/scripts/zkt_core_timing.py" --xlen $(RVA22S64_XLEN) \
		--npc "$(RVA22S64_NPC)" --reference "$(NEMU_SO_$(RVA22S64_XLEN))" \
		--output "$(BUILD_DIR)/zkt-core-timing"

# End-to-end supervisor test: caller supplies freshly built RV64 DUT/reference.
# Separate build/run targets keep shared simulator configuration mutations
# explicit and allow repeated memory timing runs with the exact same binaries.
RVA22S64_CORE_PROFILE ?= rva22s64-rv$(RVA22S64_XLEN)
RVA22S64_VFLAGS = $(if $(filter 64,$(RVA22S64_XLEN)),-DRAPT_RV64,) $(VFLAGS)
RVA22S64_PRIV_DIR := $(BUILD_DIR)/rva22s64-privileged-rv$(RVA22S64_XLEN)
RVA22S64_NPC ?= $(NSIM_HOME)/build/$(RVA22S64_CORE_PROFILE)/riscv$(RVA22S64_XLEN)-npc-sim
.PHONY: rva22s64-privileged-build rva22s64-privileged-run rva22s64-privileged-run-rv32 rva22s64-privileged-run-rv64
rva22s64-privileged-run-rv32:
	$(MAKE) rva22s64-privileged-run RVA22S64_XLEN=32
rva22s64-privileged-run-rv64:
	$(MAKE) rva22s64-privileged-run RVA22S64_XLEN=64
rva22s64-privileged-build:
	$(MAKE) -C "$(RAPTOR_HOME)" verilog
	$(MAKE) -C "$(NSIM_HOME)" RAPT_CONFIG=default BUILD_PROFILE="$(RVA22S64_CORE_PROFILE)" VFLAGS="$(RVA22S64_VFLAGS)" nemu-reference all
rva22s64-privileged-run: $(RVA22S64_MROM)
	@mkdir -p "$(RVA22S64_PRIV_DIR)"
	$(CC) $(GUEST_CPPFLAGS) -march=rv$(RVA22S64_XLEN)imac_zicsr_zifencei -mabi=$(if $(filter 64,$(RVA22S64_XLEN)),lp64,ilp32) -nostdlib -nostartfiles -static \
		-Wl,--no-relax -T "$(FUZZ_LINKER)" "$(RAPTOR_HOME)/app/tests/baremetal/rva22s64_privileged.S" \
		-o "$(RVA22S64_PRIV_DIR)/privileged.elf"
	$(OBJCOPY) -O binary "$(RVA22S64_PRIV_DIR)/privileged.elf" "$(RVA22S64_PRIV_DIR)/privileged.bin"
	$(PYTHON) "$(VERIFY_HOME)/scripts/rva22s64_privileged.py" \
		--npc "$(RVA22S64_NPC)" --reference "$(NEMU_SO_$(RVA22S64_XLEN))" --mrom "$(MROM_IMG)" \
		--image "$(RVA22S64_PRIV_DIR)/privileged.bin" --output "$(RVA22S64_PRIV_DIR)/runs"

# Directed guest programs, one name each: app/tests/baremetal/<name with _>.S
# unless a per-case RVA22S64_TEST_SOURCE override below says otherwise.
RVA22S64_CASES := \
	amo-access-fault amo-minmax amo-page-fault atomic-pma bare-mode-switch bare-pa-alias bit-xlen-legality \
	branch-sq-forward btb-amo-slot-reuse btb-exception-slot-reuse \
	bus-read-error bus-write-error cycle-counter clint-mtime-shared clint-mtime-write \
	clint-subword clint-subword-msip clint-subword-time clint-subword-write clint-width \
	clint-word-irq compressed-register-legality compressed-zero-immediate csr-architectural \
	data-span fence-i-self-modify fp-ooo fp-context fp-page-nested-irq fp-page-retry fp-privilege \
	hpm-permissions ifetch-asid-recycle ifetch-cross-page ifetch-mapping-replace ifetch-pma \
	ifetch-superpage-replace load-overlap-widths load-pmp-float load-pmp-footprint \
	load-pmp-translated load-pmp-translated-float lrsc-exact-extent lrsc-misaligned \
	lrsc-reservation m-privileged-edges platform-memory-map plic-completion-context \
	plic-completion-id plic-contract pmp-address-span ptw-pma ptw-pmp-span readonly-pma \
	split-page-fault split-page-permissions sram-pma store-cross-page store-overlap \
	store-overlap-widths svinval-page-retry svpbmt-enabled svpbmt-wrong-ifetch svpbmt-wrong-path \
	zero-pma zexth-xlen
# Cases whose sources #error on RV32 (Sv39, high PMP or mode-switch scope).
RVA22S64_RV64_CASES := \
	bare-mode-switch bare-pa-alias fp-page-nested-irq fp-page-retry ifetch-superpage-replace pmp-address-span \
	svinval-page-retry svpbmt-enabled svpbmt-wrong-ifetch svpbmt-wrong-path
RVA22S64_CASE_TARGETS := $(RVA22S64_CASES:%=rva22s64-%-run)
.PHONY: $(RVA22S64_CASE_TARGETS) rva22s64-directed
rva22s64-directed: ## Run every directed RVA22S64 case for RVA22S64_XLEN (skips RV64-only on RV32)
	@$(MAKE) --no-print-directory -k $(if $(filter 32,$(RVA22S64_XLEN)),$(filter-out $(RVA22S64_RV64_CASES:%=rva22s64-%-run),$(RVA22S64_CASE_TARGETS)),$(RVA22S64_CASE_TARGETS))
# Shared guest sources keep separate named scenarios and output directories.
RVA22S64_TEST_DIR ?= $(RAPTOR_HOME)/app/tests/baremetal
RVA22S64_TEST_SOURCE ?= $(subst -,_,$(patsubst rva22s64-%-run,%,$@))
rva22s64-clint-mtime-shared-run: RVA22S64_TEST_SOURCE = clint_mtime_write
rva22s64-clint-mtime-shared-run: RVA22S64_CASE_CPPFLAGS = -DCHECK_CSR_TIME=1
rva22s64-fp-page-nested-irq-run: RVA22S64_TEST_SOURCE = fp_page_retry
rva22s64-fp-page-nested-irq-run: RVA22S64_CASE_CPPFLAGS = -DFP_PAGE_NESTED_IRQ=1
rva22s64-svinval-page-retry-run: RVA22S64_TEST_SOURCE = fp_page_retry
rva22s64-svinval-page-retry-run: RVA22S64_CASE_CPPFLAGS = -DFP_PAGE_SINVAL=1
rva22s64-load-pmp-float-run: RVA22S64_TEST_SOURCE = load_pmp_footprint
rva22s64-load-pmp-float-run: RVA22S64_CASE_CPPFLAGS = -DPMP_TEST_FP=1
rva22s64-load-pmp-translated-float-run: RVA22S64_TEST_SOURCE = load_pmp_translated
rva22s64-load-pmp-translated-float-run: RVA22S64_CASE_CPPFLAGS = -DPMP_TEST_FP=1
rva22s64-lrsc-exact-extent-run: RVA22S64_TEST_SOURCE = lrsc_reservation
rva22s64-lrsc-exact-extent-run: RVA22S64_CASE_CPPFLAGS = -DREQUIRE_EXACT_LR_EXTENT=1
rva22s64-ptw-pma-run: RVA22S64_TEST_SOURCE = ptw_pmp_span
rva22s64-ptw-pma-run: RVA22S64_CASE_CPPFLAGS = -DPTW_PMA_TEST=1
rva22s64-split-page-permissions-run: RVA22S64_TEST_SOURCE = split_page_fault
rva22s64-split-page-permissions-run: RVA22S64_CASE_CPPFLAGS = -DSPLIT_EXEC_ONLY=1
rva22s64-store-cross-page-run: RVA22S64_TEST_SOURCE = split_page_fault
rva22s64-store-cross-page-run: RVA22S64_CASE_CPPFLAGS = -DCROSS_PAGE_ONLY=1
rva22s64-readonly-pma-run: RVA22S64_TEST_SOURCE = zero_pma
rva22s64-readonly-pma-run: RVA22S64_CASE_CPPFLAGS = -DPMA_READONLY=1
rva22s64-plic-completion-context-run rva22s64-plic-completion-id-run: RVA22S64_TEST_SOURCE = plic_contract
rva22s64-plic-completion-context-run: RVA22S64_CASE_CPPFLAGS = -DPLIC_CASE=2
rva22s64-plic-completion-id-run: RVA22S64_CASE_CPPFLAGS = -DPLIC_CASE=1
rva22s64-clint-subword-write-run rva22s64-clint-subword-time-run rva22s64-clint-subword-msip-run: RVA22S64_TEST_SOURCE = clint_subword
rva22s64-clint-subword-write-run: RVA22S64_CASE_CPPFLAGS = -DCLINT_SUBWORD_CASE=1
rva22s64-clint-subword-time-run: RVA22S64_CASE_CPPFLAGS = -DCLINT_SUBWORD_CASE=2
rva22s64-clint-subword-msip-run: RVA22S64_CASE_CPPFLAGS = -DCLINT_SUBWORD_CASE=3
RVA22S64_TEST_MARCH ?= rv$(RVA22S64_XLEN)imac_zicsr_zifencei
.PHONY: rva22s64-svpbmt-axi-check
.PHONY: rva22s64-svpbmt-cross-page-check
rva22s64-svpbmt-cross-page-check: RVA22S64_XLEN = 64
rva22s64-svpbmt-cross-page-check: $(RVA22S64_MROM)
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
rva22s64-fp-ooo-run rva22s64-svinval-page-retry-run rva22s64-fp-page-nested-irq-run rva22s64-fp-page-retry-run rva22s64-hpm-permissions-run rva22s64-fp-context-run rva22s64-fp-privilege-run: RVA22S64_TEST_MARCH = rv$(RVA22S64_XLEN)imafdc_zicsr_zifencei_zfhmin
rva22s64-svinval-page-retry-run rva22s64-fp-page-nested-irq-run rva22s64-fp-page-retry-run: RVA22S64_XLEN = 64
rva22s64-svinval-page-retry-run: RVA22S64_TEST_MARCH = rv64imafdc_zicsr_zifencei_zfhmin_svinval
# The exhaustive HPM permission matrix executes thousands of traps. Delayed
# bus runs need a larger wall-clock budget than the smaller directed programs.
rva22s64-hpm-permissions-run: RVA22S64_RUN_TIMEOUT = 900
rva22s64-svpbmt-enabled-run: RVA22S64_XLEN = 64
rva22s64-svpbmt-enabled-run: RVA22S64_TEST_MARCH = rv64imac_zicsr_zifencei_zicbom
rva22s64-bus-read-error-run rva22s64-data-span-run rva22s64-store-cross-page-run rva22s64-split-page-fault-run rva22s64-split-page-permissions-run: RVA22S64_TEST_MARCH = rv$(RVA22S64_XLEN)imafdc_zicsr_zifencei
$(RVA22S64_CASE_TARGETS): $(RVA22S64_MROM)
	@mkdir -p "$(BUILD_DIR)/$(patsubst rva22s64-%-run,%,$@)"
	$(CC) $(GUEST_CPPFLAGS) $(RVA22S64_TEST_CPPFLAGS) $(RVA22S64_CASE_CPPFLAGS) -march=$(RVA22S64_TEST_MARCH) -mabi=$(if $(filter 64,$(RVA22S64_XLEN)),lp64,ilp32) -nostdlib -nostartfiles -static \
		-Wl,--no-relax -T "$(FUZZ_LINKER)" "$(RVA22S64_TEST_DIR)/$(RVA22S64_TEST_SOURCE).S" \
		-o "$(BUILD_DIR)/$(patsubst rva22s64-%-run,%,$@)/test.elf"
	$(OBJCOPY) -O binary "$(BUILD_DIR)/$(patsubst rva22s64-%-run,%,$@)/test.elf" "$(BUILD_DIR)/$(patsubst rva22s64-%-run,%,$@)/test.bin"
	$(PYTHON) "$(VERIFY_HOME)/scripts/rva22s64_privileged.py" --name "$(patsubst rva22s64-%-run,%,$@)" \
		--timeout "$(or $(RVA22S64_RUN_TIMEOUT),60)" \
		--npc "$(RVA22S64_NPC)" --reference "$(NEMU_SO_$(RVA22S64_XLEN))" --mrom "$(MROM_IMG)" \
		--image "$(BUILD_DIR)/$(patsubst rva22s64-%-run,%,$@)/test.bin" --output "$(BUILD_DIR)/$(patsubst rva22s64-%-run,%,$@)/runs"

define VERILATOR_PLIC_CONTRACT_RUN
	$(call VERILATOR_DIRECTED_RUN,router_plic_contract_rv$(1),tb_router_plic_contract,,$(if $(filter 64,$(1)),-d RAPT_RV64,),,for case_id in 1 2 3 4 5 6; do \
		"$$model_dir/tb_router_plic_contract" +CASE=$$case_id \
		> "$(VERILATOR_DIRECTED_BUILD_DIR)/router_plic_contract_rv$(1)/case$$case_id.log" 2>&1; \
		grep 'PASS:' "$(VERILATOR_DIRECTED_BUILD_DIR)/router_plic_contract_rv$(1)/case$$case_id.log"; \
	done)
endef
.PHONY: verilator-router-plic-contract-rv32 verilator-router-plic-contract-rv64
verilator-router-plic-contract-rv32:
	$(call VERILATOR_PLIC_CONTRACT_RUN,32)
verilator-router-plic-contract-rv64:
	$(call VERILATOR_PLIC_CONTRACT_RUN,64)

.PHONY: verilator-plic-network-rv32 verilator-plic-network-rv64
verilator-plic-network-rv32 verilator-plic-network-rv64:
	$(call VERILATOR_DIRECTED_XLEN_RUN,tb_plic_network,,-d RAPT_ASSERT_EN,,for case_id in 1 2 3 4 5; do \
		"$$model_dir/tb_plic_network" +CASE=$$case_id \
		> "$(VERILATOR_DIRECTED_BUILD_DIR)/$(subst -,_,$(patsubst verilator-%,%,$@))/case$$case_id.log" 2>&1; \
		grep 'PASS:' "$(VERILATOR_DIRECTED_BUILD_DIR)/$(subst -,_,$(patsubst verilator-%,%,$@))/case$$case_id.log"; \
	done)
verilator-mdq-zkt-rv32 verilator-mdq-zkt-rv64: VERILATOR_DIRECTED_FLAGS += -CFLAGS -O0

.PHONY: ioq-overlap-check
ioq-overlap-check:
	$(PYTHON) scripts/formal_contract.py ioq-overlap --output "$(BUILD_DIR)/ioq-overlap"

verilator-rou-zkt-rv32 verilator-rou-zkt-rv64: VERILATOR_DIRECTED_FLAGS += -CFLAGS -O0

verilator-backend-recovery: VERILATOR_DIRECTED_FLAGS += -GRecoveryExercise=1
verilator-backend-recovery-rv64: VERILATOR_DIRECTED_FLAGS += -GRecoveryExercise=1 -DRAPT_RV64

verilator-superscalar-widths: verilator-width-1 verilator-width-2 verilator-width-3 verilator-width-4 verilator-width-mixed verilator-width-contract verilator-width-odd
.PHONY: verilator-ifu-stream-events-rv32
verilator-ifu-stream-events-rv32: verilator-ifu-stream-events
.PHONY: rename-admit-prove
.PHONY: rename-admit-native
.PHONY: rename-admit-lint
rename-admit-lint:
	@mkdir -p "$(BUILD_DIR)/rename-admit"
	@set -e; for width in 1 3 16 128; do \
		verilator --lint-only --top-module rapt_rename_admit -GWidth=$$width "$(RAPTOR_HOME)/rtl/frontend/rapt_rename_admit.sv" > "$(BUILD_DIR)/rename-admit/lint-$$width.log" 2>&1; \
	done

rename-admit-native:
	@mkdir -p "$(BUILD_DIR)/rename-admit"
	@set -e; for width in 1 3 16 64 128; do \
		timeout 60s yosys -Q -T -m slang -p "read_slang --single-unit -DSYNTHESIS --top rapt_rename_admit -GWidth=$$width $(RAPTOR_HOME)/rtl/frontend/rapt_rename_admit.sv; select -assert-none t:\$$check t:\$$assert t:\$$assume t:\$$cover; prep -top rapt_rename_admit -flatten; check -assert; select -assert-none t:\$$*latch* t:\$$*ff*" > "$(BUILD_DIR)/rename-admit/native-$$width.log" 2>&1; \
	done
	@if yosys -Q -T -m slang -p 'read_slang --single-unit --top rapt_rename_admit -GWidth=0 $(RAPTOR_HOME)/rtl/frontend/rapt_rename_admit.sv' > "$(BUILD_DIR)/rename-admit/native-invalid.log" 2>&1; then exit 1; fi
	@rg -q 'error: \$$error encountered: Invalid rapt_rename_admit configuration' "$(BUILD_DIR)/rename-admit/native-invalid.log"

rename-admit-prove:
	@mkdir -p "$(BUILD_DIR)/rename-admit"
	@set -e; for width in 1 3 4 8 16; do \
		timeout 60s yosys -Q -T -m slang -p "read_slang --single-unit --top formal_rename_admit -GWidth=$$width $(RAPTOR_HOME)/rtl/frontend/rapt_rename_admit.sv $(RAPTOR_HOME)/verification/formal/formal_rename_admit.sv; select -assert-none t:\$$check t:\$$assert t:\$$assume t:\$$cover; prep -top formal_rename_admit -flatten; opt; sat -verify -prove correct 1 -set-def-inputs" > "$(BUILD_DIR)/rename-admit/prove-$$width.log" 2>&1; \
	done
.PHONY: rank-select-prove rank-select-evaluate
rank-select-prove:
	python3 "$(RAPTOR_HOME)/verification/scripts/logic_check.py" rank-select --mode prove
rank-select-evaluate:
	python3 "$(RAPTOR_HOME)/verification/scripts/logic_check.py" rank-select --mode all

# These standalone selectors must compile with warnings fatal, including
# scheduling cycles; do not inherit the broad directed-suite warning policy.
.PHONY: issue-select-prove issue-select-evaluate issue-select-scaling issue-select-audit-test
.PHONY: issue-select-uniform-prove
issue-select-prove:
	python3 "$(RAPTOR_HOME)/verification/scripts/logic_check.py" issue-select --mode prove
issue-select-uniform-prove:
	python3 "$(RAPTOR_HOME)/verification/scripts/logic_check.py" issue-select --mode prove --matrix uniform --output "$(BUILD_DIR)/issue-select-uniform"
issue-select-evaluate:
	python3 "$(RAPTOR_HOME)/verification/scripts/logic_check.py" issue-select --mode all
issue-select-scaling:
	python3 "$(RAPTOR_HOME)/verification/scripts/logic_check.py" issue-select --mode synth --matrix port-scaling --output "$(BUILD_DIR)/issue-port-scaling"
issue-select-audit-test:
	python3 "$(RAPTOR_HOME)/verification/scripts/test_logic_check.py"

.PHONY: rob-dispatch-select-prove rob-dispatch-select-evaluate dispatch-compact-evaluate
rob-dispatch-select-prove:
	python3 "$(RAPTOR_HOME)/verification/scripts/logic_check.py" rob-dispatch-select --mode prove \
		--output "$(BUILD_DIR)/rob-dispatch-select-proof"
rob-dispatch-select-evaluate:
	python3 "$(RAPTOR_HOME)/verification/scripts/logic_check.py" rob-dispatch-select --mode all
dispatch-compact-evaluate:
	python3 "$(RAPTOR_HOME)/verification/scripts/dispatch_compact_evaluate.py"
.PHONY: dispatch-admit-prove
dispatch-admit-prove:
	python3 "$(RAPTOR_HOME)/verification/scripts/logic_check.py" dispatch-admit

.PHONY: recovery-pending-check
recovery-pending-check:
	python3 "$(RAPTOR_HOME)/verification/scripts/recovery_pending_check.py"

.PHONY: rob-age-mask-check
rob-age-mask-check: ## Prove the circular recovery mask and compare generic mapped cones
	python3 "$(RAPTOR_HOME)/verification/scripts/logic_check.py" rob-age-mask

.PHONY: synthesis-driver-check
synthesis-driver-check: ## Exercise valid/missing-driver tops through the actual synthesis flow
	python3 "$(RAPTOR_HOME)/verification/scripts/synthesis_driver_check.py" --output "$(BUILD_DIR)/synthesis-driver-check"

.PHONY: sta-constraint-check
sta-constraint-check: ## Reject unconstrained clocks and invalidate stale STA success
	python3 "$(RAPTOR_HOME)/verification/scripts/sta_constraint_check.py" --output "$(BUILD_DIR)/sta-constraint-check"

.PHONY: rename-checkpoint-check rename-checkpoint-prove
rename-checkpoint-check:
	python3 "$(RAPTOR_HOME)/verification/scripts/rename_checkpoint_check.py"
rename-checkpoint-prove:
	python3 "$(RAPTOR_HOME)/verification/scripts/rename_checkpoint_check.py" --mode prove

.PHONY: completion-guard-check
completion-guard-check:
	python3 "$(RAPTOR_HOME)/verification/scripts/completion_guard_check.py"

IQ_RECOVERY_MATRIX_TARGETS := verilator-iq-recovery-width3 verilator-iq-recovery-width3-rv64 \
                              verilator-iq-recovery-width4 verilator-iq-recovery-width4-rv64
.PHONY: $(IQ_RECOVERY_MATRIX_TARGETS)
$(IQ_RECOVERY_MATRIX_TARGETS): VERILATOR_DIRECTED_FLAGS += -CFLAGS -O0
$(IQ_RECOVERY_MATRIX_TARGETS):
	$(call VERILATOR_DIRECTED_RUN,$(subst -,_,$@),tb_iq_recovery_window,,-d RAPT_ASSERT_EN -d RAPT_DISPATCH_WIDTH=$(if $(findstring width3,$@),3,4) $(if $(findstring rv64,$@),-d RAPT_RV64),)
verilator-iq-recovery-window verilator-iq-recovery-window-rv64: VERILATOR_DIRECTED_FLAGS += -CFLAGS -O0
.PHONY: iq-reclaim-width-matrix
IQ_RECLAIM_WIDTH_TARGETS := verilator-iq-reclaim-single verilator-iq-reclaim-three verilator-iq-reclaim-six-rv64
verilator-iq-zkt-dependencies-rv32 verilator-iq-zkt-dependencies-rv64: VERILATOR_DIRECTED_FLAGS += -CFLAGS -O0

iq-reclaim-width-matrix: verilator-iq-reclaim-random verilator-iq-reclaim-random-rv64 $(IQ_RECLAIM_WIDTH_TARGETS)

.PHONY: iq-repair-lifecycle-matrix
iq-repair-lifecycle-matrix: verilator-iq-repair-three verilator-iq-repair-six-rv64

.PHONY: sim-build-flags-test width-evaluate-parser-test

.PHONY: prf-equivalence-audit-test
.PHONY: rnu-equivalence-audit-test
rnu-equivalence-audit-test:
	python3 "$(RAPTOR_HOME)/verification/scripts/test_rnu_equivalence.py"
.PHONY: rnu-equivalence
RNU_EQ_DECODE_WIDTH ?= 4
RNU_EQ_RENAME_WIDTH ?= 3
RNU_EQ_COMMIT_WIDTH ?= 4
rnu-equivalence:
	@test -n "$(BASELINE_RNU)" || { echo 'Set BASELINE_RNU to the preserved pre-change rapt_rnu.sv'; exit 2; }
	python3 "$(RAPTOR_HOME)/verification/scripts/rnu_equivalence.py" --baseline-rnu "$(BASELINE_RNU)" --output "$(BUILD_DIR)/rnu-equivalence" \
	  --decode-width "$(RNU_EQ_DECODE_WIDTH)" --rename-width "$(RNU_EQ_RENAME_WIDTH)" --commit-width "$(RNU_EQ_COMMIT_WIDTH)"

.PHONY: prf-contract-check
prf-contract-check:
	python3 "$(RAPTOR_HOME)/verification/scripts/prf_contract_check.py"

prf-equivalence-audit-test:
	python3 "$(RAPTOR_HOME)/verification/scripts/test_prf_equivalence.py"

sim-build-flags-test: ## Check assertion compiler flags in an isolated simulator fixture
	python3 "$(RAPTOR_HOME)/verification/scripts/test_sim_build_flags.py"

.PHONY: sta-entrypoints-test
sta-entrypoints-test: ## Check offline STA preflight and dependency failure diagnostics
	python3 "$(RAPTOR_HOME)/verification/scripts/test_sta.py" StaEntrypointsTest

width-evaluate-parser-test:
	python3 "$(RAPTOR_HOME)/verification/scripts/test_width_evaluate.py"

verilator-ras-pipeline:
	$(call VERILATOR_DIRECTED_RUN,ras_pipeline,tb_ras_pipeline, $(wildcard $(RAPTOR_HOME)/rtl/frontend/branch_predictor/*.sv),-d RAPT_ASSERT_EN,)
	$(call VERILATOR_DIRECTED_RUN,ras_pipeline4,tb_ras_pipeline, $(wildcard $(RAPTOR_HOME)/rtl/frontend/branch_predictor/*.sv),-d RAPT_ASSERT_EN -d RAPT_DECODE_WIDTH=4 -d RAPT_COMMIT_WIDTH=4,)
.PHONY: ras-check
ras-check:
	python3 "$(RAPTOR_HOME)/verification/scripts/logic_check.py" ras
verilator-predict-history-pipeline:
	$(call VERILATOR_DIRECTED_RUN,predict_history_pipeline,tb_predict_history_pipeline, $(wildcard $(RAPTOR_HOME)/rtl/frontend/branch_predictor/*.sv),-d RAPT_ASSERT_EN -d RAPT_DECODE_WIDTH=4 -d RAPT_COMMIT_WIDTH=4,)
	$(call VERILATOR_DIRECTED_RUN,predict_history_pipeline_rv64,tb_predict_history_pipeline, $(wildcard $(RAPTOR_HOME)/rtl/frontend/branch_predictor/*.sv),-d RAPT_ASSERT_EN -d RAPT_RV64 -d RAPT_DECODE_WIDTH=4 -d RAPT_COMMIT_WIDTH=2,)
.PHONY: predict-history-prove
predict-history-prove:
	python3 "$(RAPTOR_HOME)/verification/scripts/logic_check.py" predict-history
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
.PHONY: light clean

light: fuzz sigtest ## Run all lightweight verification

clean: fuzz-clean riscof-clean coverage-clean sigtest-clean formal-clean jtag-clean uvm-clean xsim-clean verilator-directed-clean ## Clean all verify artifacts
	rm -rf $(BUILD_DIR)

.PHONY: rva22s64-split-page-permissions-run

verilator-l1i-io-guard-rv64: VERILATOR_DIRECTED_FLAGS += -GUseGuard=1

# Architectural snapshot persistence for posted-write diagnostics. The caller
# supplies a freshly built DUT/reference; output must be fresh (no stale saves).
.PHONY: rva22s64-bus-error-checkpoint-run
RVA22S64_CHECKPOINT_DIR = $(BUILD_DIR)/bus-error-checkpoint-rv$(RVA22S64_XLEN)
rva22s64-bus-error-checkpoint-run: $(RVA22S64_MROM)
	@mkdir -p "$(RVA22S64_CHECKPOINT_DIR)"
	$(CC) $(GUEST_CPPFLAGS) -DRAPT_CKPT_ERROR -march=rv$(RVA22S64_XLEN)imac_zicsr_zifencei -mabi=$(if $(filter 64,$(RVA22S64_XLEN)),lp64,ilp32) -nostdlib -nostartfiles -static \
		-Wl,--no-relax -T "$(VERIFY_HOME)/scripts/fuzz_link.ld" "$(RAPTOR_HOME)/app/tests/baremetal/bus_write_error.S" -o "$(RVA22S64_CHECKPOINT_DIR)/test.elf"
	$(OBJCOPY) -O binary "$(RVA22S64_CHECKPOINT_DIR)/test.elf" "$(RVA22S64_CHECKPOINT_DIR)/test.bin"
	$(PYTHON) "$(VERIFY_HOME)/scripts/checkpoint_milestones.py" bus-error \
		--npc "$(RVA22S64_NPC)" --reference "$(NEMU_SO_$(RVA22S64_XLEN))" --mrom "$(MROM_IMG)" \
		--elf "$(RVA22S64_CHECKPOINT_DIR)/test.elf" --image "$(RVA22S64_CHECKPOINT_DIR)/test.bin" --output "$(RVA22S64_CHECKPOINT_DIR)/runs"

SQ_CHECKPOINT_BIN ?= $(NPC_BIN_$(SQ_CHECKPOINT_XLEN))
SQ_CHECKPOINT_KIND ?= word
SQ_CHECKPOINT_REQUIRE_L2 ?= 0
SQ_CHECKPOINT_DIR = $(BUILD_DIR)/sq-checkpoint-rv$(SQ_CHECKPOINT_XLEN)-$(SQ_CHECKPOINT_KIND)
.PHONY: sq-checkpoint-rv32 sq-checkpoint-rv64
sq-checkpoint-rv32: SQ_CHECKPOINT_XLEN = 32
sq-checkpoint-rv64: SQ_CHECKPOINT_XLEN = 64
sq-checkpoint-rv32: $(BUILD_DIR)/mrom-rv32/mrom-data.bin
sq-checkpoint-rv64: $(BUILD_DIR)/mrom-rv64/mrom-data.bin
sq-checkpoint-rv32 sq-checkpoint-rv64: ## Pending retired stores survive save/load; supply the matching simulator
	@test -x "$(SQ_CHECKPOINT_BIN)" && test -f "$(NEMU_SO_$(SQ_CHECKPOINT_XLEN))" && test -f "$(MROM_IMG)"
	@mkdir -p "$(SQ_CHECKPOINT_DIR)"
	$(CC) $(GUEST_CPPFLAGS) $(if $(filter fp64,$(SQ_CHECKPOINT_KIND)),-DCHECKPOINT_FP64) $(if $(filter unaligned,$(SQ_CHECKPOINT_KIND)),-DCHECKPOINT_UNALIGNED) \
		-march=rv$(SQ_CHECKPOINT_XLEN)imafdc_zicsr_zifencei -mabi=$(if $(filter 64,$(SQ_CHECKPOINT_XLEN)),lp64,ilp32) -nostdlib -nostartfiles \
		-Wl,--no-relax -T "$(VERIFY_HOME)/scripts/fuzz_link.ld" "$(RAPTOR_HOME)/app/tests/baremetal/$(if $(filter cache,$(SQ_CHECKPOINT_KIND)),cache_checkpoint,sq_checkpoint).S" -o "$(SQ_CHECKPOINT_DIR)/test.elf"
	$(OBJCOPY) -O binary "$(SQ_CHECKPOINT_DIR)/test.elf" "$(SQ_CHECKPOINT_DIR)/test.bin"
	$(PYTHON) "$(VERIFY_HOME)/scripts/sq_checkpoint.py" --xlen "$(SQ_CHECKPOINT_XLEN)" --kind "$(SQ_CHECKPOINT_KIND)" --nm "$(CROSS_COMPILE)nm" $(if $(filter 1,$(SQ_CHECKPOINT_REQUIRE_L2)),--require-l2) \
		--npc "$(SQ_CHECKPOINT_BIN)" --reference "$(NEMU_SO_$(SQ_CHECKPOINT_XLEN))" --mrom "$(MROM_IMG)" \
		--elf "$(SQ_CHECKPOINT_DIR)/test.elf" --image "$(SQ_CHECKPOINT_DIR)/test.bin" --output "$(SQ_CHECKPOINT_DIR)/runs"

# Shared CLINT/CSR time across actual save/exit/load, including legacy metadata.
.PHONY: rva22s64-clint-time-checkpoint-run
RVA22S64_TIME_CHECKPOINT_DIR = $(BUILD_DIR)/clint-time-checkpoint-rv$(RVA22S64_XLEN)
RVA22S64_TIME_CHECKPOINT_CPPFLAGS ?= -DCHECKPOINT_SSTC
rva22s64-clint-time-checkpoint-run: $(RVA22S64_MROM)
	@mkdir -p "$(RVA22S64_TIME_CHECKPOINT_DIR)"
	$(CC) $(GUEST_CPPFLAGS) $(RVA22S64_TIME_CHECKPOINT_CPPFLAGS) -march=rv$(RVA22S64_XLEN)imac_zicsr_zifencei -mabi=$(if $(filter 64,$(RVA22S64_XLEN)),lp64,ilp32) -nostdlib -nostartfiles -static \
		-Wl,--no-relax -T "$(VERIFY_HOME)/scripts/fuzz_link.ld" "$(RAPTOR_HOME)/app/tests/baremetal/clint_time_checkpoint.S" -o "$(RVA22S64_TIME_CHECKPOINT_DIR)/test.elf"
	$(OBJCOPY) -O binary "$(RVA22S64_TIME_CHECKPOINT_DIR)/test.elf" "$(RVA22S64_TIME_CHECKPOINT_DIR)/test.bin"
	$(PYTHON) "$(VERIFY_HOME)/scripts/clint_time_checkpoint.py" --xlen "$(RVA22S64_XLEN)" \
		--npc "$(RVA22S64_NPC)" --reference "$(NEMU_SO_$(RVA22S64_XLEN))" --mrom "$(MROM_IMG)" \
		--elf "$(RVA22S64_TIME_CHECKPOINT_DIR)/test.elf" --image "$(RVA22S64_TIME_CHECKPOINT_DIR)/test.bin" --output "$(RVA22S64_TIME_CHECKPOINT_DIR)/runs"

HOST_CXX ?= c++
.PHONY: mmio-alignment-check
mmio-alignment-check: $(MROM_IMG)
	$(PYTHON) "$(VERIFY_HOME)/scripts/mmio_alignment_check.py" \
		--npc "$(RVA22S64_NPC)" --reference "$(NEMU_SO_$(RVA22S64_XLEN))" \
		--mrom "$(MROM_IMG)" --xlen "$(RVA22S64_XLEN)" \
		--output "$(BUILD_DIR)/mmio-alignment-rv$(RVA22S64_XLEN)"
.PHONY: mmio-transaction-check mmio-virtio-mask-check mmio-uart-read-check
.PHONY: sim-assert-check
sim-assert-check: ## Check host Assert semantics and real Capstone startup in RV32/RV64
	$(PYTHON) "$(VERIFY_HOME)/scripts/test_sim_assert.py"

.PHONY: uart-platform-check mmio-uart-irq-check
uart-platform-check:
	$(PYTHON) "$(VERIFY_HOME)/scripts/test_uart_platform.py"

mmio-uart-irq-check: $(MROM_IMG)
	$(PYTHON) "$(VERIFY_HOME)/scripts/mmio_transaction_check.py" --uart-irq \
		--npc "$(RVA22S64_NPC)" --no-difftest \
		--mrom "$(MROM_IMG)" --xlen "$(RVA22S64_XLEN)" \
		--output "$(BUILD_DIR)/mmio-uart-irq-rv$(RVA22S64_XLEN)"

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
.PHONY: npc-event-bridge-check
npc-event-bridge-check: ## Check NPC half-cycle external-write notification ordering
	mkdir -p "$(BUILD_DIR)/npc-event-bridge"
	$(HOST_CXX) -std=c++17 -Wall -Wextra -Werror -I"$(NSIM_HOME)/include" "$(RAPTOR_HOME)/app/tests/host/npc_eval_events.cc" -o "$(BUILD_DIR)/npc-event-bridge/test"
	"$(BUILD_DIR)/npc-event-bridge/test"

.PHONY: rva22s64-lrsc-sv39-alias-run
rva22s64-lrsc-sv39-alias-run: RVA22S64_XLEN = 64
rva22s64-lrsc-sv39-alias-run: $(RVA22S64_MROM)
	@mkdir -p "$(BUILD_DIR)/lrsc-sv39-alias"
	$(CC) $(GUEST_CPPFLAGS) -march=rv64imac_zicsr_zifencei -mabi=lp64 -nostdlib -nostartfiles -static -Wl,--no-relax -T "$(FUZZ_LINKER)" "$(RAPTOR_HOME)/app/tests/baremetal/lrsc_sv39_alias.S" -o "$(BUILD_DIR)/lrsc-sv39-alias/test.elf"
	$(OBJCOPY) -O binary "$(BUILD_DIR)/lrsc-sv39-alias/test.elf" "$(BUILD_DIR)/lrsc-sv39-alias/test.bin"
	$(PYTHON) "$(VERIFY_HOME)/scripts/rva22s64_privileged.py" --name lrsc-sv39-alias --npc "$(RVA22S64_NPC)" --reference "$(NEMU_SO_64)" --mrom "$(MROM_IMG)" --image "$(BUILD_DIR)/lrsc-sv39-alias/test.bin" --output "$(BUILD_DIR)/lrsc-sv39-alias/runs"

rva22s64-lrsc-misaligned-run: RVA22S64_RUN_TIMEOUT = 180

rva22s64-ifetch-mapping-replace-run: RVA22S64_TEST_MARCH = rv$(RVA22S64_XLEN)imafdc_zicsr_zifencei_svinval

rva22s64-ifetch-asid-recycle-run: RVA22S64_TEST_MARCH = rv$(RVA22S64_XLEN)imafdc_zicsr_zifencei_svinval

.PHONY: verilator-ptw-kill-drain-rv32
verilator-ptw-kill-drain-rv32: verilator-ptw-kill-drain

rva22s64-ifetch-superpage-replace-run: RVA22S64_TEST_MARCH = rv64imafdc_zicsr_zifencei_svinval

.PHONY: pmp-capacity-check
pmp-capacity-check: nemu-pmp-capacity-check \
	verilator-csr-pmp-warl-rv32 verilator-csr-pmp-warl-rv64 \
	verilator-csr-pmp-lock-rv32 verilator-csr-pmp-lock-rv64 \
	verilator-pmp-permissions-rv32 verilator-pmp-permissions-rv64 \
	verilator-pmp-reset-napot-rv32 verilator-pmp-reset-napot-rv64 \
	verilator-idu-csr-addresses-rv32 verilator-idu-csr-addresses-rv64 \
	verilator-l1d-pmp-shared-rv32 verilator-l1d-pmp-shared-rv64

rva22s64-load-overlap-widths-run rva22s64-store-overlap-widths-run: RVA22S64_TEST_MARCH = rv$(RVA22S64_XLEN)imafdc_zicsr_zifencei

rva22s64-load-pmp-float-run rva22s64-load-pmp-translated-float-run: RVA22S64_TEST_MARCH = rv$(RVA22S64_XLEN)imafdc_zicsr_zifencei

rva22s64-bit-xlen-legality-run: RVA22S64_TEST_MARCH = rv$(RVA22S64_XLEN)imac_zicsr_zifencei_zba_zbb_zbs

.PHONY: verilator-bit-decode-alu-rv32 verilator-bit-decode-alu-rv64
verilator-bit-decode-alu-rv32 verilator-bit-decode-alu-rv64:
	$(PYTHON) "$(VERIFY_HOME)/scripts/bit_alu_vectors.py" --xlen $(if $(findstring rv64,$@),64,32) --output "$(BUILD_DIR)/$@-vectors"
	$(call VERILATOR_DIRECTED_RUN,$(subst -,_,$@),tb_bit_decode_alu,,$(if $(findstring rv64,$@),-d RAPT_RV64),+vectors=$(abspath $(BUILD_DIR)/$@-vectors/vectors.txt))

rva22s64-zexth-xlen-run: RVA22S64_TEST_MARCH = rv$(RVA22S64_XLEN)imac_zicsr_zifencei_zba_zbb_zbs

# One decoder build per XLEN covers both exhaustive legality matrices.
.PHONY: verilator-compressed-register-legality-rv32 verilator-compressed-register-legality-rv64 verilator-compressed-zero-immediate-rv32 verilator-compressed-zero-immediate-rv64
verilator-compressed-register-legality-rv32 verilator-compressed-zero-immediate-rv32: verilator-compressed-legality-rv32
verilator-compressed-register-legality-rv64 verilator-compressed-zero-immediate-rv64: verilator-compressed-legality-rv64

.PHONY: compressed-assembler-rv32 compressed-assembler-rv64
compressed-assembler-rv32 compressed-assembler-rv64:
	$(PYTHON) "$(VERIFY_HOME)/scripts/compressed_assembler_check.py" \
		--xlen $(if $(filter %-rv64,$@),64,32) --output "$(BUILD_DIR)/$@"

.PHONY: compressed-breakpoint-rv32 compressed-breakpoint-rv64
compressed-breakpoint-rv32: $(NPC_BIN_32) $(BUILD_DIR)/mrom-rv32/mrom-data.bin
compressed-breakpoint-rv64: $(NPC_BIN_64) $(BUILD_DIR)/mrom-rv64/mrom-data.bin
compressed-breakpoint-rv32 compressed-breakpoint-rv64:
	$(PYTHON) "$(VERIFY_HOME)/scripts/compressed_breakpoint_check.py" \
		--xlen $(if $(filter %-rv64,$@),64,32) \
		--npc "$(if $(filter %-rv64,$@),$(NPC_BIN_64),$(NPC_BIN_32))" \
		--mrom "$(BUILD_DIR)/mrom-rv$(if $(filter %-rv64,$@),64,32)/mrom-data.bin" \
		--gcc "$(CC)" --objcopy "$(CROSS_COMPILE)objcopy" --output "$(BUILD_DIR)/$@"

.PHONY: verilator-compressed-expansion-rv32 verilator-compressed-expansion-rv64
verilator-compressed-expansion-rv32 verilator-compressed-expansion-rv64:
	$(PYTHON) "$(VERIFY_HOME)/scripts/compressed_vectors.py" --xlen $(if $(findstring rv64,$@),64,32) --output "$(BUILD_DIR)/$@-vectors"
	$(call VERILATOR_DIRECTED_RUN,$(subst -,_,$@),tb_compressed_expansion,,$(if $(findstring rv64,$@),-d RAPT_RV64),+vectors=$(abspath $(BUILD_DIR)/$@-vectors/vectors.txt))

L1I_DATA_SEED ?= 1

# Follow the preset policy without a WriteBack parameter override.
verilator-wb-ptw-rv32 verilator-wb-ptw-rv64: VERILATOR_DIRECTED_FLAGS += -GWriteBack=1

# Full-capacity checks follow the configured default L1 geometry (sets/ways/line).

verilator-cache-stream-wb-rv32 verilator-cache-stream-wb-rv64 verilator-cache-stream-wb-l2-rv32 verilator-cache-stream-wb-l2-rv64: VERILATOR_DIRECTED_FLAGS += -GWriteBack=1
verilator-cache-stream-rv32 verilator-cache-stream-rv64 verilator-cache-stream-l2-rv32 verilator-cache-stream-l2-rv64 verilator-cache-stream-rnp-rv32: VERILATOR_DIRECTED_FLAGS += -GWriteBack=0

# Both XLEN modes use the production default-w4 preset and independent directed benches.
.PHONY: w4-scaling
w4-scaling:
	python3 "$(VERIFY_HOME)/scripts/test_w4_scaling.py" --build-dir "$(BUILD_DIR)/w4-scaling"

verilator-l2tlb-l1i-epoch-rv32 verilator-l2tlb-l1i-epoch-rv64: override VERILATOR_DIRECTED_FLAGS += -GL2Tlb=1
verilator-l2tlb-l1i-sret-rv32 verilator-l2tlb-l1i-sret-rv64: override VERILATOR_DIRECTED_FLAGS += -GL2Tlb=1
verilator-l2tlb-cbo-rv32 verilator-l2tlb-cbo-rv64: override VERILATOR_DIRECTED_FLAGS += -GL2Tlb=1

verilator-wb-mshr-l2-rv32 verilator-wb-mshr-l2-rv64: override XSIM_COMMON_INCLUDES := $(subst /configs/$(XSIM_RAPT_CONFIG),/configs/default-l2,$(XSIM_COMMON_INCLUDES))

# Public-port checks for FPGA committed-register RAM and deferred PA publication.
FP_ARCH_BANK_LUTRAM ?= 1

include $(VERIFY_HOME)/directed-tests.mk

# M: compare the shared checker with independent legacy permission checkers.
$(eval $(call XLEN_TEST,pmp-shared-equiv,tb_pmp_shared_equiv,,-d RAPT_ASSERT_EN))
$(eval $(call XLEN_TEST,l2tlb-1024,tb_l2tlb,,-d RAPT_ASSERT_EN -GEntries=1024))
$(eval $(call XLEN_TEST,l2tlb-2048,tb_l2tlb,,-d RAPT_ASSERT_EN -GEntries=2048))
$(eval $(call XLEN_TEST,l2tlb-4096,tb_l2tlb,,-d RAPT_ASSERT_EN -GEntries=4096))
# end M

# Job D: target-neutral L1D replacement checks.
.PHONY: verilator-l1d-nru
verilator-l1d-nru:
	$(call VERILATOR_DIRECTED_RUN,l1d_nru,tb_l1d_nru,,-d RAPT_ASSERT_EN,)
# End Job D.

# Job D: compare consumed shared tag reads against independent ports.
.PHONY: verilator-l1d-shared-tags
verilator-l1d-shared-tags:
	$(call VERILATOR_DIRECTED_RUN,l1d_shared_tags,tb_l1d_shared_tags,,-d RAPT_ASSERT_EN,)
# End Job D.

# Job D: preserve held-load data and response cycles across a probe writeback.
.PHONY: verilator-l1d-wb-resume-rv32 verilator-l1d-wb-resume-rv64
verilator-l1d-wb-resume-rv32 verilator-l1d-wb-resume-rv64: VERILATOR_DIRECTED_FLAGS += -GWriteBack=1
verilator-l1d-wb-resume-rv32:
	$(call VERILATOR_DIRECTED_RUN,l1d_wb_resume_rv32,tb_l1d_store_coherence,,\
		-d RAPT_ASSERT_EN,+MIN_WB_RESUME +BUS_DELAY_MAX=0)
verilator-l1d-wb-resume-rv64:
	$(call VERILATOR_DIRECTED_RUN,l1d_wb_resume_rv64,tb_l1d_store_coherence,,\
		-d RAPT_RV64 -d RAPT_ASSERT_EN,+MIN_WB_RESUME +BUS_DELAY_MAX=0)
# End Job D.
