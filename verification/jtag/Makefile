# ============================================================================
# JTAG / RISC-V Debug Verification
# ============================================================================
# Standardized verification flows for the rapt_dtm + rapt_dm implementation.
# Two layers, ordered by current readiness:
#
#   1. selftest        - runs today. Drives JTAG TCK/TMS/TDI directly against
#                        the Verilator-built RTL and probes 23 spec-aligned
#                        DTM/DM compliance points (IDCODE, BYPASS identity,
#                        DTMCS fields, dmcontrol RW, dmstatus version=3,
#                        abstractcs cmderr W1C, dmactive=0 quiesce, …).
#                        See sim/csrc/jtag/jtag_selftest.cc for the catalog.
#
#   2. openocd-smoke   - runs today. Builds sim, launches it as an OpenOCD
#                        `remote_bitbang` TCP server, runs upstream OpenOCD
#                        0.12+ against verification/jtag/openocd.cfg, and PASSes if
#                        OpenOCD enumerates IDCODE = 0x10001913. Validates
#                        the full path real-OpenOCD -> TCP -> sim -> RTL TAP.
#                        Use `make openocd-server` to leave sim running for
#                        interactive OpenOCD/GDB sessions.
#
#   3. debug-tests - runs a supported subset of upstream riscv-tests/debug.
#      Bridge, drained-core halt/resume and 32-bit abstract register access
#      exist. Program-buffer execution remains unsupported. See README.md.
#
# ============================================================================

SHELL := /bin/bash
.DEFAULT_GOAL := help

RAPTOR_HOME ?= $(abspath ../..)
NSIM_HOME   ?= $(RAPTOR_HOME)/sim
JTAG_DIR    := $(abspath .)
BUILD_DIR   := $(JTAG_DIR)/build
RISCV_TESTS_REPO ?= $(BUILD_DIR)/riscv-tests

.PHONY: help selftest openocd-server openocd-smoke openocd-halt-reg gdb-smoke
.PHONY: debug-tests-setup debug-tests clean

JTAG_PORT       ?= 9824
NSIM_BIN        ?=
RAPT_CONFIG     ?= default
BUILD_PROFILE   ?= $(RAPT_CONFIG)
GDB_PORT        ?= 3333
PYTHON          ?= python3
SIM_BUILD_ROOT ?= $(if $(strip $(BUILD_ROOT)),$(BUILD_ROOT),$(NSIM_HOME)/build)
SIM_BUILD_DIR ?= $(abspath $(SIM_BUILD_ROOT)/$(BUILD_PROFILE))
SIM_FLAGS = RAPT_CONFIG="$(RAPT_CONFIG)" BUILD_PROFILE="$(BUILD_PROFILE)" VFLAGS="$(VFLAGS)" \
	BUILD_ROOT="$(SIM_BUILD_ROOT)" BUILD_DIR="$(SIM_BUILD_DIR)"
OPENOCD         ?= openocd
OPENOCD_CFG     := $(JTAG_DIR)/openocd.cfg
JTAG_LOG_ROOT   ?= $(BUILD_DIR)/runs

# RISC-V GDB autodetect: pick the first available toolchain GDB on $PATH,
# falling back to a known-good local install for macOS dev environments.
RISCV_GDB ?= $(shell command -v riscv64-elf-gdb 2>/dev/null || \
                    command -v riscv32-unknown-elf-gdb 2>/dev/null || \
                    command -v riscv64-unknown-elf-gdb 2>/dev/null || \
                    command -v riscv-none-elf-gdb 2>/dev/null)

help: ## Show JTAG verification targets
	@echo "JTAG / RISC-V Debug Verification"
	@echo "================================"
	@echo "Targets:"
	@awk '/^[a-zA-Z0-9_-]+:.*## / { \
		t=$$0; sub(/:.*/,"",t); d=$$0; sub(/.*## /,"",d); \
		printf "  %-22s %s\n", t, d }' $(MAKEFILE_LIST)

# ---------------------------------------------------------------------------
# Layer 1: in-tree compliance probe (runs today)
# ---------------------------------------------------------------------------
selftest: ## Build & run DTM+DM compliance probe (23 checks, no NEMU needed)
	@echo "[jtag] Running in-tree DTM/DM compliance probe..."
	$(MAKE) -C $(NSIM_HOME) $(SIM_FLAGS) jtag-selftest

# ---------------------------------------------------------------------------
# Layer 1.5: live OpenOCD bring-up against the RTL TAP (works today)
# ---------------------------------------------------------------------------
# Explicit NSIM_BIN runs an existing RV32 build; otherwise build and resolve
# the simulator through sim/Makefile, including its mode/profile suffix.
.PHONY: jtag-build
jtag-build:
	@if [ -n "$(findstring DRAPT_RV64,$(VFLAGS))" ]; then echo "JTAG smoke requires RV32"; exit 1; fi
ifeq ($(strip $(NSIM_BIN)),)
	$(MAKE) -C $(NSIM_HOME) $(SIM_FLAGS) all
endif

NPC_FROM_SIM = $$($(MAKE) --no-print-directory -s -C $(NSIM_HOME) $(SIM_FLAGS) print-jtag-bin)
SELECTED_NPC = $(if $(strip $(NSIM_BIN)),$(NSIM_BIN),$(NPC_FROM_SIM))
SMOKE_ARGS = --npc "$(SELECTED_NPC)" \
	--config "$(RAPTOR_HOME)/rtl/configs/$(RAPT_CONFIG)/rapt_config.svh" \
	--openocd "$(OPENOCD)" --openocd-config "$(OPENOCD_CFG)" \
	--port "$(JTAG_PORT)" --gdb-port "$(GDB_PORT)" --log-root "$(JTAG_LOG_ROOT)"

openocd-server: jtag-build ## Run foreground RV32 simulator JTAG server
	"$(SELECTED_NPC)" --jtag-server --jtag-port=$(JTAG_PORT)

openocd-smoke: jtag-build ## Check OpenOCD TAP enumeration
	$(PYTHON) run_smoke.py scan $(SMOKE_ARGS)

openocd-halt-reg: jtag-build ## Check RV32 halt and GPR/CSR round-trip
	$(PYTHON) run_smoke.py halt $(SMOKE_ARGS)

gdb-smoke: jtag-build ## Check RV32 GDB register access (missing tools fail)
	$(PYTHON) run_smoke.py gdb $(SMOKE_ARGS) --gdb "$(RISCV_GDB)"

# ---------------------------------------------------------------------------
# Layer 2: selected upstream riscv-tests debug checks
# ---------------------------------------------------------------------------
debug-tests-setup: ## Stage upstream debug sources from a public archive (no git required)
	$(PYTHON) run_upstream.py --suite "$(RISCV_TESTS_REPO)" --setup

UPSTREAM_PYTHON ?= $(PYTHON)
DEBUG_TESTS ?=
debug-tests: sba-build ## Run supported upstream register, memory, PC and step tests
	$(UPSTREAM_PYTHON) run_upstream.py --suite "$(RISCV_TESTS_REPO)" \
		--npc "$(SBA_MODEL)/sba-server" --gdb "$(RISCV_GDB)" \
		--gcc "$(CROSS_COMPILE)gcc" --openocd "$(OPENOCD)" \
		--xlen $(SBA_XLEN) \
		--port $(JTAG_PORT) \
		--output "$(BUILD_DIR)/upstream" $(if $(DEBUG_TESTS),--tests $(DEBUG_TESTS))

clean: ## Remove cloned repos and build artifacts (keeps nothing)
	rm -rf $(BUILD_DIR) $(RISCV_TESTS_REPO)

# Focused protocol tests: both XLENs, assertions enabled, bounded compile jobs.
VERILATOR ?= verilator
JOBS ?= 4
UNIT_TOOL_KEY := $(shell $(VERILATOR) --version | sha256sum | cut -c1-12)
UNIT_MODEL = $(BUILD_DIR)/$@/obj-$(UNIT_TOOL_KEY)
UNIT_FLAGS = --binary --timing --assert -j $(JOBS) -Wno-fatal -Wno-PINMISSING \
	-Wno-TIMESCALEMOD -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -DRAPT_ASSERT_EN \
	-I$(RAPTOR_HOME)/rtl/configs/default -I$(RAPTOR_HOME)/rtl/include \
	-I$(RAPTOR_HOME)/rtl/include/npc -I$(RAPTOR_HOME)/rtl/include/dpic_mock

.PHONY: sba-unit-rv32 sba-unit-rv64 sba-unit-pa36
sba-unit-rv32 sba-unit-rv64 sba-unit-pa36: ## Check DM SBA size/lane/error/busy/reset protocol
	@mkdir -p $(UNIT_MODEL)
	$(VERILATOR) $(UNIT_FLAGS) $(if $(filter %-rv64 sba-unit-pa36,$@),-DRAPT_RV64) \
		$(if $(filter sba-unit-pa36,$@),-DRAPT_PADDR_BITS=36) \
		--top-module tb_dm_sba $(RAPTOR_HOME)/rtl/rapt_pkg.sv \
		$(RAPTOR_HOME)/rtl/perip/rapt_dm.sv tb_dm_sba.sv \
		--Mdir $(UNIT_MODEL) -o test > $(BUILD_DIR)/$@/build.log 2>&1
	$(UNIT_MODEL)/test

.PHONY: arbiter-unit-rv32 arbiter-unit-rv64
arbiter-unit-rv32 arbiter-unit-rv64: ## Check fair AXI arbitration, IDs, bursts and reset drain
	@mkdir -p $(UNIT_MODEL)
	$(VERILATOR) $(UNIT_FLAGS) $(if $(filter %-rv64,$@),-DRAPT_RV64) \
		--top-module tb_debug_arbiter $(RAPTOR_HOME)/rtl/rapt_pkg.sv \
		$(RAPTOR_HOME)/rtl/uncore/rapt_debug_arbiter.sv tb_debug_arbiter.sv \
		--Mdir $(UNIT_MODEL) -o test > $(BUILD_DIR)/$@/build.log 2>&1
	$(UNIT_MODEL)/test

SBA_XLEN ?= 32
SBA_MODEL = $(BUILD_DIR)/chip-$(RAPT_CONFIG)-rv$(SBA_XLEN)
.PHONY: sba-build openocd-sba openocd-ndmreset
sba-build:
	$(PYTHON) build_sba.py --build "$(SBA_MODEL)" --config "$(RAPT_CONFIG)" \
		--xlen $(SBA_XLEN) --jobs $(JOBS)

openocd-sba openocd-ndmreset: sba-build ## Test SBA or reset/load/run over sampled chip JTAG
	$(PYTHON) run_smoke.py $(if $(filter openocd-sba,$@),sba,reset) \
		--npc "$(SBA_MODEL)/sba-server" --openocd "$(OPENOCD)" \
		--openocd-config "$(OPENOCD_CFG)" --port $(JTAG_PORT) --xlen $(SBA_XLEN) \
		--config "$(RAPTOR_HOME)/rtl/configs/$(RAPT_CONFIG)/rapt_config.svh" \
		--log-root "$(BUILD_DIR)/runs" --timeout 120

.PHONY: openocd-sba-rv32 openocd-sba-rv64 openocd-ndmreset-rv32 openocd-ndmreset-rv64
openocd-sba-rv32 openocd-sba-rv64: ## Chip JTAG SBA integration, selected XLEN
	$(MAKE) openocd-sba SBA_XLEN=$(if $(filter %-rv64,$@),64,32)

openocd-ndmreset-rv32 openocd-ndmreset-rv64: ## Chip reset-halt and JTAG-loaded boot
	$(MAKE) openocd-ndmreset SBA_XLEN=$(if $(filter %-rv64,$@),64,32)

.PHONY: openocd-step openocd-step-rv32 openocd-step-rv64 gdb-step
openocd-step: sba-build ## Strict instruction count, DPC, trap, MMIO and software breakpoint checks
	$(PYTHON) run_step.py --npc "$(SBA_MODEL)/sba-server" --xlen $(SBA_XLEN) \
		--gcc "$(CROSS_COMPILE)gcc" --openocd "$(OPENOCD)" --port $(JTAG_PORT) \
		--output "$(BUILD_DIR)/runs"

openocd-step-rv32 openocd-step-rv64:
	$(MAKE) openocd-step SBA_XLEN=$(if $(filter %-rv64,$@),64,32)

gdb-step: sba-build ## Run strict chip checks and a GDB stepi/set-pc/break/continue/finish session
	@test -n "$(RISCV_GDB)" || { echo "RISC-V GDB unavailable: set RISCV_GDB"; exit 1; }
	$(PYTHON) run_step.py --npc "$(SBA_MODEL)/sba-server" --xlen $(SBA_XLEN) \
		--gcc "$(CROSS_COMPILE)gcc" --openocd "$(OPENOCD)" --gdb "$(RISCV_GDB)" \
		--port $(JTAG_PORT) --gdb-port $(GDB_PORT) --output "$(BUILD_DIR)/runs"
