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
FORMAL_YOSYS := $(RAPTOR_HOME)/verify/formal/yosys-rvfi-compat.sh
FORMAL_BUS_PACK := build/formal_bus_pack.sv

.PHONY: zkt-mul
zkt-mul: ## Prove default RV32/RV64 multiply operand-independent completion timing
	$(FORMAL_SBY) -f zkt_mul.sby

.PHONY: zkt-muldiv
zkt-muldiv: ## Prove shared multiply/divide port timing under independent operand streams
	$(FORMAL_SBY) -f zkt_muldiv.sby

.PHONY: zkt-alu-ports
zkt-alu-ports: ## Check both actual integer ALU ports for operand-independent control
	$(FORMAL_SBY) -f zkt_alu_ports.sby

.PHONY: zkt-cdb
zkt-cdb: ## Check shared ALU/FP endpoint control independently of result values
	$(FORMAL_SBY) -f zkt_cdb.sby

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

check-tools: ## Verify sby and yosys are available
	@command -v sby >/dev/null 2>&1 || \
		{ echo "ERROR: sby not found in PATH."; \
		  echo "  Run: make setup"; \
		  echo "  Or:  source $(OSS_CAD_DIR)/environment"; \
		  exit 1; }
	@command -v yosys >/dev/null 2>&1 || \
		{ echo "ERROR: yosys not found in PATH."; \
		  echo "  Run: make setup"; exit 1; }
	@echo "[formal] Tools OK: sby=$$(which sby), yosys=$$(which yosys)"

# ============================================================================
# Formal Verification Targets
# ============================================================================
all: formal_ieu_alu formal_ieu_mul formal_pmp formal_plru formal_rnu_maptable formal_clint formal_plic formal_dtm formal_bus formal_divsqrt ## Run all formal verification (excludes RVFI)

FORMAL_BUS_SRCS := \
		$(RAPTOR_HOME)/hdl/rapt_pkg.sv \
		$(RAPTOR_HOME)/hdl/memory/rapt_bus.sv \
		$(RAPTOR_HOME)/hdl/memory/rapt_axi_master.sv
# Preprocessing consumes these headers too. Keep them as dependencies, not
# standalone Verilator inputs, so header/config edits invalidate cached packs.
FORMAL_COMMON_HEADERS := $(wildcard $(RAPTOR_HOME)/hdl/include/*.svh)
FORMAL_BUS_HEADERS := $(FORMAL_COMMON_HEADERS) \
	$(wildcard $(RAPTOR_HOME)/hdl/configs/formal/*.svh) \
	$(wildcard $(RAPTOR_HOME)/hdl/include/npc/*.svh) \
	$(wildcard $(RAPTOR_HOME)/hdl/include/dpic_mock/*.svh)

$(FORMAL_BUS_PACK): $(FORMAL_BUS_SRCS) $(FORMAL_BUS_HEADERS)
	@mkdir -p $(@D)
	verilator -E -P \
		-I$(RAPTOR_HOME)/hdl/configs/formal \
		-I$(RAPTOR_HOME)/hdl/include \
		-I$(RAPTOR_HOME)/hdl/include/npc \
		-I$(RAPTOR_HOME)/hdl/include/dpic_mock \
		$(FORMAL_BUS_SRCS) > $@

formal_bus: check-tools $(FORMAL_BUS_PACK) ## Verify AXI bus
	sby -f bus.sby

formal_ieu_mul: check-tools ## Verify IEU multiplier
	sby -f ieu_mul.sby

formal_ieu_alu: check-tools ## Verify RV32 IEU ALU and bitmanip equivalence
	sby -f ieu_alu.sby

formal_pmp: check-tools ## Prove RV32/RV64 PMP matching, priority and permissions
	sby -f pmp.sby

.PHONY: formal_pmp_composed
formal_pmp_composed: check-tools ## Prove every PMP range, then compose with priority/permissions
	@set -e; for bits in 32 64; do \
	  for base in 0 4 8 12; do \
	    tasks=(); for offset in 0 1 2 3; do tasks+=("range$${bits}_$$((base + offset))"); done; \
	    sby -j 8 -f pmp_ranges.sby "$${tasks[@]}"; \
	  done; \
	done
	sby -f pmp_composed.sby selector32 selector64

formal_plru: check-tools ## Prove 2/4/8-way PLRU selection and state updates
	sby -f plru.sby

formal_rnu_maptable: check-tools ## Prove rename MAP/RAT WAW priority and flush recovery
	sby -f rnu_maptable.sby

formal_clint: check-tools ## Prove CLINT timer, compare, register and interrupt behavior
	sby -f clint.sby

formal_plic: check-tools ## Prove RV32/RV64 PLIC arbitration, contexts and gateway lifecycle
	sby -f plic.sby

formal_dtm: check-tools ## Prove single-clock JTAG TAP and DMI transport behavior
	sby -f dtm.sby

DIVSQRT_PACK := build/divsqrt_pack.sv
$(DIVSQRT_PACK): \
		$(RAPTOR_HOME)/hdl/backend/feu/fpu/rapt_fpu_divsqrt.sv \
		$(FORMAL_COMMON_HEADERS) \
		$(wildcard $(RAPTOR_HOME)/hdl/configs/small/*.svh)
	@mkdir -p $(@D)
	verilator -E -P \
		-I$(RAPTOR_HOME)/hdl/configs/small -I$(RAPTOR_HOME)/hdl/include \
		$< > $@

formal_divsqrt: check-tools $(DIVSQRT_PACK) ## Verify FPU divider/sqrt safety+liveness (BMC)
	sby -f divsqrt.sby bmc

formal_divsqrt_prove: check-tools $(DIVSQRT_PACK) ## Prove FPU divider/sqrt safety properties (k-induction)
	sby -f divsqrt.sby prove

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
VSRC_PATH     := $(RAPTOR_HOME)/hdl
# uarch config preset providing rapt_config.svh (hdl/configs/<name>/rapt_config.svh).
# Must precede hdl/include on the verilator include path so its config wins.
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
VSRCS_RVFI      := $(VSRCS_RVFI_PKG) $(filter-out $(VSRCS_RVFI_EXCL), $(shell find $(VSRC_PATH) -name "*.sv" ! -path "*/include/*"))

# --- Auto-clone riscv-formal ---
$(RISCV_FORMAL_DIR)/checks/genchecks.py:
	@echo "[formal] Cloning riscv-formal ($(RISCV_FORMAL_COMMIT))..."
	git clone --no-checkout $(RISCV_FORMAL_REPO) $(RISCV_FORMAL_DIR)
	cd $(RISCV_FORMAL_DIR) && git checkout $(RISCV_FORMAL_COMMIT)

# --- Symlink project-owned files into riscv-formal tree ---
$(RVFI_CORE_DIR)/checks.cfg: $(RVFI_SRC_DIR)/checks.cfg $(RVFI_SRC_DIR)/wrapper.sv $(RISCV_FORMAL_DIR)/checks/genchecks.py
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
		echo 'ERROR: RVFI requires a yosys-slang frontend with $$countones support and correct combinational int initialization.'; \
		echo 'Set RAPTOR_YOSYS_REAL=/absolute/path/to/compatible/yosys (validated with Yosys 0.64 + slang).'; \
		exit 1; }

formal_rvfi: check-rvfi-tools $(RVFI_CHECKS)/makefile ## Run all riscv-formal checks
	PATH=$(RAPTOR_HOME)/verify/formal:$(PATH) $(MAKE) -C $(RVFI_CHECKS) -j$(FORMAL_JOBS) SBY="$(FORMAL_SBY) --yosys $(FORMAL_YOSYS)"

formal_rvfi_check: check-rvfi-tools $(RVFI_CHECKS)/makefile ## Run a single check (CHECK=insn_add_ch0)
	@test -n "$(CHECK)" || { echo "Usage: make formal_rvfi_check CHECK=insn_add_ch0"; exit 1; }
	cd $(RVFI_CHECKS) && PATH=$(RAPTOR_HOME)/verify/formal:$(PATH) sby -f $(CHECK).sby --yosys $(FORMAL_YOSYS)

formal_rvfi_clean: ## Clean generated riscv-formal checks
	rm -rf $(RVFI_CHECKS) $(RVFI_PACK)

.PHONY: pma-capabilities
PMA_PROOF_OUTPUT ?= $(RAPTOR_HOME)/build/rva22s64/pma-capabilities
pma-capabilities: ## Prove all-address storage-region PMA capability logic in RV32/RV64
	python3 "$(RAPTOR_HOME)/verify/scripts/formal_contract.py" pma-capabilities --output "$(PMA_PROOF_OUTPUT)"

.PHONY: ifetch-word-atomic
IFETCH_ATOMIC_OUTPUT ?= $(RAPTOR_HOME)/build/rva22s64/ifetch-word-atomic
ifetch-word-atomic: ## Prove aligned instruction-word assembly integrity in RV32/RV64
	python3 "$(RAPTOR_HOME)/verify/scripts/formal_contract.py" ifetch-word-atomic --output "$(IFETCH_ATOMIC_OUTPUT)"

.PHONY: npc-response-stability
NPC_RESPONSE_OUTPUT ?= $(RAPTOR_HOME)/build/rva22s64/npc-response-stability
npc-response-stability: ## Prove NPC R/B holds and test real watchdog-duration stalls in RV32/RV64
	python3 "$(RAPTOR_HOME)/verify/scripts/npc_response_stability_check.py" --output "$(NPC_RESPONSE_OUTPUT)"
