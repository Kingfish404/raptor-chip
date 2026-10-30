# ============================================================================
# Raptor Chip: Formal Verification Makefile
# ============================================================================
# Uses SymbiYosys (sby) from oss-cad-suite for formal verification.
# Run `make setup` to download oss-cad-suite if not already present.
# ============================================================================

SHELL := /bin/bash

# --- Paths ---
RAPTOR_HOME    ?= $(abspath ../..)
OSS_CAD_DIR  := $(RAPTOR_HOME)/third_party/oss-cad-suite
OSS_CAD_BIN  := $(OSS_CAD_DIR)/bin

# oss-cad-suite release to download when running `make setup`
OSS_CAD_VERSION ?= 2025-07-30
OSS_CAD_REPO    := https://github.com/YosysHQ/oss-cad-suite-build/releases/download
UNAME_S := $(shell uname -s)
UNAME_M := $(shell uname -m)
ifeq ($(UNAME_S),Darwin)
  ifeq ($(UNAME_M),arm64)
    OSS_CAD_PLATFORM := darwin-arm64
  else
    OSS_CAD_PLATFORM := darwin-x64
  endif
else ifeq ($(UNAME_S),Linux)
  ifeq ($(UNAME_M),aarch64)
    OSS_CAD_PLATFORM := linux-arm64
  else
    OSS_CAD_PLATFORM := linux-x64
  endif
endif
OSS_CAD_DATE    := $(subst -,,$(OSS_CAD_VERSION))
OSS_CAD_TARBALL := oss-cad-suite-$(OSS_CAD_PLATFORM)-$(OSS_CAD_DATE).tgz
OSS_CAD_URL     := $(OSS_CAD_REPO)/$(OSS_CAD_VERSION)/$(OSS_CAD_TARBALL)

# Resolve Yosys before prepending the bundled solver tools. Otherwise an older
# bundled slang frontend silently shadows a compatible system installation.
# RAPTOR_YOSYS_REAL also overrides the executable used by the SBY wrapper.
ifeq ($(strip $(RAPTOR_YOSYS_REAL)),)
RAPTOR_YOSYS_REAL := $(or $(shell command -v yosys 2>/dev/null),$(OSS_CAD_BIN)/yosys)
endif
export RAPTOR_YOSYS_REAL

# Prepend oss-cad-suite/bin to PATH for all recipes
export PATH := $(OSS_CAD_BIN):$(PATH)
NPROC ?= $(shell nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
FORMAL_JOBS ?= 4
FORMAL_SBY := $(OSS_CAD_BIN)/sby
FORMAL_YOSYS := $(RAPTOR_HOME)/verification/formal/yosys-rvfi-compat.sh
SBY_RUN := $(FORMAL_SBY) --yosys "$(FORMAL_YOSYS)"
FORMAL_BUS_PACK := build/formal_bus_pack.sv
FORMAL_RESULTS_DIR ?= $(or $(TMPDIR),/tmp)/raptor-formal

.PHONY: zkt-mul
zkt-mul: ## Prove default RV32/RV64 multiply operand-independent completion timing
	$(SBY_RUN) -f zkt_mul.sby

.PHONY: zkt-muldiv
zkt-muldiv: ## Prove shared multiply/divide port timing under independent operand streams
	$(SBY_RUN) -f zkt_muldiv.sby

.PHONY: zkt-alu-ports
zkt-alu-ports: ## Check both actual integer ALU ports for operand-independent control
	$(SBY_RUN) -f zkt_alu_ports.sby

.PHONY: zkt-cdb
zkt-cdb: ## Check shared ALU/FP endpoint control independently of result values
	$(SBY_RUN) -f zkt_cdb.sby

# ============================================================================
# Help
# ============================================================================
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
	@echo "Variables:"
	@echo "  OSS_CAD_VERSION=YYYY-MM-DD  oss-cad-suite release (default: $(OSS_CAD_VERSION))"
	@echo "  RAPTOR_YOSYS_REAL=/path/to/yosys  RVFI frontend (default: $(RAPTOR_YOSYS_REAL))"

# ============================================================================
# Setup / Init
# ============================================================================
.PHONY: setup check-tools

setup: ## Download and install oss-cad-suite (sby, yosys, solvers)
	@if [ -x "$(OSS_CAD_BIN)/sby" ]; then \
		echo "[formal] oss-cad-suite already installed at $(OSS_CAD_DIR)"; \
		echo "  sby:   $$($(OSS_CAD_BIN)/sby --version 2>/dev/null || echo unknown)"; \
		echo "  yosys: $$($(OSS_CAD_BIN)/yosys --version 2>/dev/null | head -1 || echo unknown)"; \
	else \
		echo "[formal] Downloading oss-cad-suite $(OSS_CAD_VERSION) for $(OSS_CAD_PLATFORM)..."; \
		echo "  URL: $(OSS_CAD_URL)"; \
		mkdir -p "$(RAPTOR_HOME)/third_party"; \
		curl -L --fail --progress-bar -o "/tmp/$(OSS_CAD_TARBALL)" "$(OSS_CAD_URL)"; \
		echo "[formal] Extracting to $(RAPTOR_HOME)/third_party/ ..."; \
		tar -xzf "/tmp/$(OSS_CAD_TARBALL)" -C "$(RAPTOR_HOME)/third_party/"; \
		rm -f "/tmp/$(OSS_CAD_TARBALL)"; \
		if [ "$(UNAME_S)" = "Darwin" ]; then \
			echo "[formal] Removing macOS quarantine flags (may require sudo)..."; \
			sudo xattr -rd com.apple.quarantine "$(OSS_CAD_DIR)" 2>/dev/null || true; \
		fi; \
		echo "[formal] Done. Installed:"; \
		echo "  sby:   $$($(OSS_CAD_BIN)/sby --version 2>/dev/null || echo unknown)"; \
		echo "  yosys: $$($(OSS_CAD_BIN)/yosys --version 2>/dev/null | head -1 || echo unknown)"; \
	fi

check-tools: ## Verify sby and the selected Yosys/Slang frontend are available
	@command -v sby >/dev/null 2>&1 || \
		{ echo "ERROR: sby not found in PATH."; \
		  echo "  Run: make setup"; \
		  echo "  Or:  source $(OSS_CAD_DIR)/environment"; \
		  exit 1; }
	@command -v "$(RAPTOR_YOSYS_REAL)" >/dev/null 2>&1 || \
		{ echo "ERROR: yosys not found in PATH."; \
		  echo "  Run: make setup"; exit 1; }
	@"$(RAPTOR_YOSYS_REAL)" -Q -T -m slang -p 'help read_slang' >/dev/null || \
		{ echo "ERROR: selected Yosys cannot load the Slang frontend."; \
		  echo "  Set RAPTOR_YOSYS_REAL=/path/to/compatible/yosys"; exit 1; }
	@echo "[formal] Tools OK: sby=$$(which sby), yosys=$(RAPTOR_YOSYS_REAL)"

# ============================================================================
# Formal Verification Targets
# ============================================================================
all: ## Run standalone formal checks (excludes whole-core RVFI/ISA)
all: formal_ieu_alu formal_ieu_muldiv formal_pmp formal_plru formal_clint formal_plic \
	formal_dtm formal_bus formal_divsqrt formal_memory_progress formal_sram \
	formal_rvfi_metadata formal_rvfi_platform formal_rou_rvfi formal_cache_nru \
	formal_recovery_pending formal_stream_queue formal_rou_retire formal_l1d_data formal_prf \
	formal_ioq_owner formal_ioq_store

.PHONY: formal_memory_progress
formal_memory_progress: ## Check reduced L1D/bus bounded progress and cover collision recovery
	$(MAKE) -C .. formal-memory-progress

FORMAL_BUS_SRCS := \
		$(RAPTOR_HOME)/rtl/rapt_pkg.sv \
		$(RAPTOR_HOME)/rtl/memory/rapt_bus.sv \
		$(RAPTOR_HOME)/rtl/memory/rapt_axi_master.sv
# Preprocessing consumes these headers too. Keep them as dependencies, not
# standalone Verilator inputs, so header/config edits invalidate cached packs.
FORMAL_COMMON_HEADERS := $(wildcard $(RAPTOR_HOME)/rtl/include/*.svh)
FORMAL_BUS_HEADERS := $(FORMAL_COMMON_HEADERS) \
	$(wildcard $(RAPTOR_HOME)/rtl/configs/formal/*.svh) \
	$(wildcard $(RAPTOR_HOME)/rtl/include/npc/*.svh) \
	$(wildcard $(RAPTOR_HOME)/rtl/include/dpic_mock/*.svh)

$(FORMAL_BUS_PACK): $(FORMAL_BUS_SRCS) $(FORMAL_BUS_HEADERS)
	@mkdir -p $(@D)
	verilator -E -P \
		-I$(RAPTOR_HOME)/rtl/configs/formal \
		-I$(RAPTOR_HOME)/rtl/include \
		-I$(RAPTOR_HOME)/rtl/include/npc \
		-I$(RAPTOR_HOME)/rtl/include/dpic_mock \
		$(FORMAL_BUS_SRCS) > $@

formal_bus: check-tools $(FORMAL_BUS_PACK) ## Verify AXI bus
	$(SBY_RUN) -f bus.sby

formal_ieu_mul: check-tools ## Compose exhaustive multiply arithmetic and unbounded transport
	python3 "$(RAPTOR_HOME)/verification/scripts/muldiv_contract.py" multiply \
	  --output "$(FORMAL_RESULTS_DIR)/mul"

.PHONY: formal_ieu_div
formal_ieu_div: check-tools ## Compose Euclidean lemmas and unbounded DIV/REM RTL refinement
	python3 "$(RAPTOR_HOME)/verification/scripts/muldiv_contract.py" divide \
	  --output "$(FORMAL_RESULTS_DIR)/div"

.PHONY: formal_ieu_muldiv
formal_ieu_muldiv: formal_ieu_mul formal_ieu_div ## Prove mixed MUL/DIV values and arbitration
	python3 "$(RAPTOR_HOME)/verification/scripts/muldiv_contract.py" mixed \
	  --multiply-evidence "$(FORMAL_RESULTS_DIR)/mul/results.json" \
	  --divide-evidence "$(FORMAL_RESULTS_DIR)/div/results.json" \
	  --output "$(FORMAL_RESULTS_DIR)/muldiv"

.PHONY: formal_ieu_mul_monolithic
formal_ieu_mul_monolithic: check-tools ## Run the optional monolithic multiply BMC reference
	$(SBY_RUN) -f ieu_mul.sby

.PHONY: formal_sram
formal_sram: check-tools ## Prove all registered 1RW SRAM shapes against functional contracts
	python3 "$(RAPTOR_HOME)/verification/scripts/unit_contracts.py" sram \
	  --output "$(FORMAL_RESULTS_DIR)/sram" --jobs "$(FORMAL_JOBS)"

.PHONY: formal_cache_nru
formal_cache_nru: check-tools ## Prove NRU priority, epoch renewal and invalidation for every set
	python3 "$(RAPTOR_HOME)/verification/scripts/unit_contracts.py" nru \
	  --output "$(FORMAL_RESULTS_DIR)/cache-nru" --jobs "$(FORMAL_JOBS)"

.PHONY: formal_recovery_pending formal_stream_queue
formal_recovery_pending: check-tools ## Prove masked recovery selection and stale-owner cancellation
	python3 "$(RAPTOR_HOME)/verification/scripts/unit_contracts.py" recovery \
	  --output "$(FORMAL_RESULTS_DIR)/recovery-pending" --jobs "$(FORMAL_JOBS)"

formal_stream_queue: check-tools ## Prove banked/BRAM stream queue transport against flop reference
	python3 "$(RAPTOR_HOME)/verification/scripts/unit_contracts.py" stream-queue \
	  --output "$(FORMAL_RESULTS_DIR)/stream-queue" --jobs "$(FORMAL_JOBS)"

FORMAL_ROU_RETIRE_PRESETS ?= formal
.PHONY: formal_rou_retire
formal_rou_retire: check-tools ## Prove actual retirement banks and serialized immediate transport
	python3 "$(RAPTOR_HOME)/verification/scripts/rou_contract.py" retire \
	  --output "$(FORMAL_RESULTS_DIR)/rou-retire" --presets $(FORMAL_ROU_RETIRE_PRESETS) \
	  --jobs "$(FORMAL_JOBS)"

FORMAL_L1D_DATA_PRESETS ?=
FORMAL_L1D_DATA_ARGS = $(if $(strip $(FORMAL_L1D_DATA_PRESETS)),--presets $(FORMAL_L1D_DATA_PRESETS))
.PHONY: formal_l1d_data
formal_l1d_data: check-tools ## Prove diagonal L1D data mapping for every production geometry
	python3 "$(RAPTOR_HOME)/verification/scripts/unit_contracts.py" l1d-data \
	  --output "$(FORMAL_RESULTS_DIR)/l1d-data" --jobs "$(FORMAL_JOBS)" $(FORMAL_L1D_DATA_ARGS)

FORMAL_PRF_PRESETS ?=
FORMAL_PRF_ARGS = $(if $(strip $(FORMAL_PRF_PRESETS)),--presets $(FORMAL_PRF_PRESETS))
FORMAL_PRF_TIMEOUT ?= 300
FORMAL_PRF_PROOF_STYLE ?= composed
.PHONY: formal_prf formal_prf_zero
formal_prf: check-tools ## Check PRF x0, physical data/state history and late-read forwarding
	python3 "$(RAPTOR_HOME)/verification/scripts/prf_formal.py" prove \
	  --output "$(FORMAL_RESULTS_DIR)/prf" --jobs "$(FORMAL_JOBS)" \
	  --timeout "$(FORMAL_PRF_TIMEOUT)" --proof-style "$(FORMAL_PRF_PROOF_STYLE)" \
	  $(FORMAL_PRF_ARGS)

formal_prf_zero: check-tools ## Prove the PRF architectural/debug x0 reset contract
	python3 "$(RAPTOR_HOME)/verification/scripts/prf_formal.py" prove \
	  --output "$(FORMAL_RESULTS_DIR)/prf-zero" --jobs "$(FORMAL_JOBS)" --checks zero \
	  --timeout "$(FORMAL_PRF_TIMEOUT)" $(FORMAL_PRF_ARGS)

.PHONY: formal_rvfi_metadata
formal_rvfi_metadata: check-tools ## Prove RVFI fault effects, numbering and RVC HINT metadata
	python3 "$(RAPTOR_HOME)/verification/scripts/rvfi_contract.py" --contract effects \
	  --output "$(FORMAL_RESULTS_DIR)/rvfi-effects"
	python3 "$(RAPTOR_HOME)/verification/scripts/rvfi_contract.py" --contract hints \
	  --output "$(FORMAL_RESULTS_DIR)/rvfi-hints"

.PHONY: formal_rvfi_platform
formal_rvfi_platform: check-tools ## Qualify the independent Bare platform PMA reference
	python3 "$(RAPTOR_HOME)/verification/scripts/rvfi_contract.py" --contract platform \
	  --output "$(FORMAL_RESULTS_DIR)/rvfi-platform"

FORMAL_ROU_RVFI_PRESETS ?= formal
.PHONY: formal_rou_rvfi
formal_rou_rvfi: check-tools ## Prove actual ROU/RVFI memory transport and retirement prefix
	python3 "$(RAPTOR_HOME)/verification/scripts/rou_contract.py" rvfi \
	  --output "$(FORMAL_RESULTS_DIR)/rou-rvfi" --jobs "$(FORMAL_JOBS)" \
	  --presets $(FORMAL_ROU_RVFI_PRESETS)

.PHONY: formal_rou_rvfi_composed
formal_rou_rvfi_composed: check-tools ## Prove both ROU completion bindings with audited state cuts
	python3 "$(RAPTOR_HOME)/verification/scripts/rou_contract.py" composed \
	  --output "$(FORMAL_RESULTS_DIR)/rou-rvfi-composed" --jobs "$(FORMAL_JOBS)" \
	  --presets $(FORMAL_ROU_RVFI_PRESETS)

FORMAL_ALU_PRESETS ?=
FORMAL_ALU_ARGS = $(if $(strip $(FORMAL_ALU_PRESETS)),--presets $(FORMAL_ALU_PRESETS))
FORMAL_ALU_TIMEOUT ?= 300
formal_ieu_alu: check-tools ## Prove unrestricted ALU values, opcode activation and rare-port policy
	python3 "$(RAPTOR_HOME)/verification/scripts/alu_contract.py" prove \
	  --output "$(FORMAL_RESULTS_DIR)/alu" --jobs "$(FORMAL_JOBS)" \
	  --timeout "$(FORMAL_ALU_TIMEOUT)" $(FORMAL_ALU_ARGS)
	python3 "$(RAPTOR_HOME)/verification/scripts/alu_contract.py" receipts \
	  --evidence "$(FORMAL_RESULTS_DIR)/alu"

FORMAL_IOQ_OWNER_PRESETS ?=
FORMAL_IOQ_OWNER_ARGS = $(if $(strip $(FORMAL_IOQ_OWNER_PRESETS)),--presets $(FORMAL_IOQ_OWNER_PRESETS))
FORMAL_IOQ_OWNER_TIMEOUT ?= 1800
FORMAL_IOQ_OWNER_DEPTH ?= 4
FORMAL_IOQ_OWNER_SOLVER ?= auto
.PHONY: formal_ioq_owner
formal_ioq_owner: check-tools ## Prove production IOQ allocation and request/response provenance
	python3 "$(RAPTOR_HOME)/verification/scripts/ioq_contract.py" prove \
	  --output "$(FORMAL_RESULTS_DIR)/ioq-owner" --jobs "$(FORMAL_JOBS)" \
	  --timeout "$(FORMAL_IOQ_OWNER_TIMEOUT)" --depth "$(FORMAL_IOQ_OWNER_DEPTH)" \
	  --solver "$(FORMAL_IOQ_OWNER_SOLVER)" $(FORMAL_IOQ_OWNER_ARGS)
	python3 "$(RAPTOR_HOME)/verification/scripts/ioq_contract.py" activate \
	  --evidence "$(FORMAL_RESULTS_DIR)/ioq-owner" --jobs "$(FORMAL_JOBS)" \
	  --timeout "$(FORMAL_IOQ_OWNER_TIMEOUT)"

FORMAL_IOQ_STORE_PRESETS ?=
FORMAL_IOQ_STORE_ARGS = $(if $(strip $(FORMAL_IOQ_STORE_PRESETS)),--presets $(FORMAL_IOQ_STORE_PRESETS))
FORMAL_IOQ_STORE_TIMEOUT ?= 1800
FORMAL_IOQ_STORE_SOLVER ?= bitwuzla
.PHONY: formal_ioq_store
formal_ioq_store: check-tools ## Prove IOQ store operands, AMO payload bytes and sampled SC decisions
	python3 "$(RAPTOR_HOME)/verification/scripts/ioq_contract.py" prove --contract store \
	  --output "$(FORMAL_RESULTS_DIR)/ioq-store" --jobs "$(FORMAL_JOBS)" \
	  --timeout "$(FORMAL_IOQ_STORE_TIMEOUT)" --solver "$(FORMAL_IOQ_STORE_SOLVER)" \
	  $(FORMAL_IOQ_STORE_ARGS)

formal_pmp: check-tools ## Prove RV32/RV64 PMP matching, priority and permissions
	$(SBY_RUN) -f pmp.sby

# Range tasks follow the implemented entry count; pmp_ranges.sby defines 16.
PMP_ENTRIES := $(shell sed -n 's/^`define RAPT_PMP_NUM \([0-9]*\).*/\1/p' $(RAPTOR_HOME)/rtl/include/rapt.svh)

.PHONY: formal_pmp_composed
formal_pmp_composed: check-tools ## Prove every PMP range, then compose with priority/permissions
	@test -n "$(PMP_ENTRIES)" || { echo "cannot read RAPT_PMP_NUM"; exit 1; }
	@set -e; for bits in 32 64; do \
	  for ((base = 0; base < $(PMP_ENTRIES); base += 4)); do \
	    tasks=(); for ((i = base; i < base + 4 && i < $(PMP_ENTRIES); i++)); do \
	      tasks+=("range$${bits}_$$i"); done; \
	    $(SBY_RUN) -j 8 -f pmp_ranges.sby "$${tasks[@]}"; \
	  done; \
	done
	$(SBY_RUN) -f pmp_composed.sby selector32 selector64

formal_plru: check-tools ## Prove 2/4/8-way PLRU selection and state updates
	$(SBY_RUN) -f plru.sby

formal_clint: check-tools ## Prove CLINT timer, compare, register and interrupt behavior
	$(SBY_RUN) -f clint.sby

formal_plic: check-tools ## Prove RV32/RV64 PLIC arbitration, contexts and gateway lifecycle
	$(SBY_RUN) -f plic.sby

formal_dtm: check-tools ## Prove single-clock JTAG TAP and DMI transport behavior
	$(SBY_RUN) -f dtm.sby

DIVSQRT_PACK := build/divsqrt_pack.sv
$(DIVSQRT_PACK): \
		$(RAPTOR_HOME)/rtl/backend/feu/fpu/rapt_fpu_divsqrt.sv \
		$(FORMAL_COMMON_HEADERS) \
		$(wildcard $(RAPTOR_HOME)/rtl/configs/small/*.svh)
	@mkdir -p $(@D)
	verilator -E -P \
		-I$(RAPTOR_HOME)/rtl/configs/small -I$(RAPTOR_HOME)/rtl/include \
		$< > $@

formal_divsqrt: check-tools $(DIVSQRT_PACK) ## Check div/sqrt control by BMC, induction and covers
	$(SBY_RUN) -f divsqrt.sby bmc prove cover

formal_divsqrt_prove: check-tools $(DIVSQRT_PACK) ## Prove FPU divider/sqrt safety properties (k-induction)
	$(SBY_RUN) -f divsqrt.sby prove

formal_gui: check-tools ## Open sby GUI
	sby-gui

# ============================================================================
# riscv-formal (RVFI) Verification
# ============================================================================
# riscv-formal is an external repository; cloned automatically when needed.
# Raptor-specific files (wrapper.sv, checks.cfg) live in rvfi/ (project-owned).

RISCV_FORMAL_REPO   := https://github.com/YosysHQ/riscv-formal.git
RISCV_FORMAL_COMMIT := 2aa7b49
RISCV_FORMAL_DIR    := riscv-formal

RVFI_SRC_DIR  := rvfi
RVFI_CORE_DIR := $(RISCV_FORMAL_DIR)/cores/raptor
RVFI_CHECKS   := $(RVFI_CORE_DIR)/checks
RVFI_PACK     := build/rapt_pack_rvfi.sv
VSRC_PATH     := $(RAPTOR_HOME)/rtl
# uarch config preset providing rapt_config.svh (rtl/configs/<name>/rapt_config.svh).
# Must precede rtl/include on the verilator include path so its config wins.
# The `formal` preset is a minimal-but-valid RV32IMC config (tiny caches, no L2,
# bimodal BP, small ROB/RS) that keeps yosys prep/check and BMC tractable on the
# full-cluster wrapper. Override with RAPT_CONFIG=default for a full-size proof.
RAPT_CONFIG   ?= formal
RVFI_CFG_DIR  := $(VSRC_PATH)/configs/$(RAPT_CONFIG)
# Core-only sources: exclude SoC wrappers, DPI-C, and include-dir files.
# Note: rapt_npc_soc / wrap_rnp_soc live in $(RAPTOR_HOME)/sim/rtl/
# (TB-only); they are no longer found via $(VSRC_PATH), so excluding them is
# only kept for documentation purposes.
VSRCS_RVFI_PKG  := $(filter %/rapt_pkg.sv, $(shell find $(VSRC_PATH) -name "*.sv"))
VSRCS_RVFI_EXCL := %/rapt_pkg.sv %/wrap_rnp.sv %/rapt_dpi_c.sv
RVFI_DECODERS := $(VSRC_PATH)/generated/rapt_idu_decoder.sv \
	$(VSRC_PATH)/generated/rapt_idu_decoder_c.sv
RVFI_DECODER_SRCS := $(shell find $(RAPTOR_HOME)/tools/decodegen/src -type f) \
	$(RAPTOR_HOME)/tools/decodegen/Makefile $(RAPTOR_HOME)/tools/decodegen/build.sbt \
	$(RAPTOR_HOME)/tools/decodegen/project/build.properties
VSRCS_RVFI_RAW := $(shell find $(VSRC_PATH) -name "*.sv" \
	! -path "*/include/*" ! -path "*/generated/*")
VSRCS_RVFI := $(VSRCS_RVFI_PKG) $(filter-out $(VSRCS_RVFI_EXCL),$(VSRCS_RVFI_RAW)) \
	$(RVFI_DECODERS)

# Generated decoders are ignored by Git. A clean checkout must build them
# before packing; discovery via find alone silently omitted both modules.
$(RVFI_DECODERS) &: $(RVFI_DECODER_SRCS)
	$(MAKE) -C $(RAPTOR_HOME)/tools/decodegen verilog BUILD_DIR="$(VSRC_PATH)/generated"

# --- Auto-clone riscv-formal ---
$(RISCV_FORMAL_DIR)/checks/genchecks.py:
	@echo "[formal] Cloning riscv-formal ($(RISCV_FORMAL_COMMIT))..."
	git clone --no-checkout $(RISCV_FORMAL_REPO) $(RISCV_FORMAL_DIR)
	cd $(RISCV_FORMAL_DIR) && git checkout $(RISCV_FORMAL_COMMIT)

# --- Symlink project-owned files into riscv-formal tree ---
$(RVFI_CORE_DIR)/checks.cfg: $(RVFI_SRC_DIR)/checks.cfg $(RVFI_SRC_DIR)/wrapper.sv \
	$(RISCV_FORMAL_DIR)/checks/genchecks.py
	@mkdir -p $(RVFI_CORE_DIR)
	ln -sf $(abspath $(RVFI_SRC_DIR))/checks.cfg $(RVFI_CORE_DIR)/checks.cfg
	ln -sf $(abspath $(RVFI_SRC_DIR))/wrapper.sv $(RVFI_CORE_DIR)/wrapper.sv

# --- Generate RVFI pack file ---
.PHONY: FORCE_RVFI_PACK
FORCE_RVFI_PACK:

# Always rebuild the preprocessed pack when an RVFI target is requested. A
# normal source prerequisite list cannot notice a deleted or moved RTL file;
# without this force edge, a hierarchy refactor can leave removed modules in a
# timestamp-newer generated pack.
$(RVFI_PACK): FORCE_RVFI_PACK $(VSRCS_RVFI)
	@mkdir -p build
	@echo "[formal] Generating RVFI-enabled pack: $@"
	# Preprocess for formal synthesis, not Verilator runtime observation.
	verilator -E -P -DRAPT_RVFI -DSYNTHESIS -UVERILATOR \
		-I$(RVFI_CFG_DIR) -I$(VSRC_PATH)/include -I$(VSRC_PATH)/include/npc -I$(VSRC_PATH)/include/dpic_mock \
		$(VSRCS_RVFI) > $@

# --- Generate checks from config ---
$(RVFI_CHECKS)/makefile: $(RVFI_CORE_DIR)/checks.cfg $(RVFI_PACK) Makefile
	@echo "[formal] Generating riscv-formal checks..."
	cd $(RVFI_CORE_DIR) && python3 ../../checks/genchecks.py checks
	@echo "[formal] Patching .sby files for abc engine (removing unsupported 'skip' option)..."
	@sed -i.bak '/^skip /d' $(RVFI_CHECKS)/*.sby && rm -f $(RVFI_CHECKS)/*.sby.bak
	# Upstream emits literal 'sby', so make SBY= would otherwise be ignored.
	@sed -i.bak 's/^\tsby /\t+$$(SBY) /' $(RVFI_CHECKS)/makefile && rm -f $(RVFI_CHECKS)/makefile.bak

formal_rvfi_gen: $(RVFI_CHECKS)/makefile ## Generate riscv-formal check .sby files

.PHONY: check-rvfi-tools
check-rvfi-tools: check-tools
	@mkdir -p build
	@echo "[formal] RVFI Yosys: $(RAPTOR_YOSYS_REAL)"
	@"$(RAPTOR_YOSYS_REAL)" -Q -T -m slang -p \
		'read_slang --top rvfi_tool_probe $(RVFI_SRC_DIR)/tool_probe.sv; select -assert-none a:init' \
		> build/rvfi-tool-check.log 2>&1 || { \
		cat build/rvfi-tool-check.log; \
		echo 'ERROR: RVFI requires a yosys-slang frontend with $$countones support' \
		  'and correct combinational int initialization.'; \
		echo 'Set RAPTOR_YOSYS_REAL=/absolute/path/to/compatible/yosys (validated with Yosys 0.64 + slang).'; \
		exit 1; }

formal_rvfi: check-rvfi-tools $(RVFI_CHECKS)/makefile ## Run all riscv-formal checks
	PATH=$(RAPTOR_HOME)/verification/formal:$(PATH) \
	  $(MAKE) -C $(RVFI_CHECKS) -j$(FORMAL_JOBS) \
	  SBY="$(FORMAL_SBY) --yosys $(FORMAL_YOSYS)"

formal_rvfi_check: check-rvfi-tools $(RVFI_CHECKS)/makefile ## Run a single check (CHECK=insn_add_ch0)
	@test -n "$(CHECK)" || { echo "Usage: make formal_rvfi_check CHECK=insn_add_ch0"; exit 1; }
	cd $(RVFI_CHECKS) && PATH=$(RAPTOR_HOME)/verification/formal:$(PATH) sby -f $(CHECK).sby --yosys $(FORMAL_YOSYS)

formal_rvfi_clean: ## Clean generated riscv-formal checks
	rm -rf $(RVFI_CHECKS) $(RVFI_PACK)

.PHONY: pma-capabilities
PMA_PROOF_OUTPUT ?= $(RAPTOR_HOME)/build/rva22s64/pma-capabilities
pma-capabilities: ## Prove all-address storage-region PMA capability logic in RV32/RV64
	python3 "$(RAPTOR_HOME)/verification/scripts/formal_contract.py" pma-capabilities --output "$(PMA_PROOF_OUTPUT)"

.PHONY: ifetch-word-atomic
IFETCH_ATOMIC_OUTPUT ?= $(RAPTOR_HOME)/build/rva22s64/ifetch-word-atomic
ifetch-word-atomic: ## Prove aligned instruction-word assembly integrity in RV32/RV64
	python3 "$(RAPTOR_HOME)/verification/scripts/formal_contract.py" ifetch-word-atomic --output "$(IFETCH_ATOMIC_OUTPUT)"

.PHONY: npc-response-stability
NPC_RESPONSE_OUTPUT ?= $(RAPTOR_HOME)/build/rva22s64/npc-response-stability
npc-response-stability: ## Prove NPC R/B holds and test real watchdog-duration stalls in RV32/RV64
	python3 "$(RAPTOR_HOME)/verification/scripts/npc_response_stability_check.py" --output "$(NPC_RESPONSE_OUTPUT)"
