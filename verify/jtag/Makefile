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
#                        0.12+ against verify/jtag/openocd.cfg, and PASSes if
#                        OpenOCD enumerates IDCODE = 0x10001913. Validates
#                        the full path real-OpenOCD -> TCP -> sim -> RTL TAP.
#                        Use `make openocd-server` to leave sim running for
#                        interactive OpenOCD/GDB sessions.
#
#   3. debug-tests - stages upstream riscv-tests/debug; runner remains a stub.
#      Bridge, drained-core halt/resume and 32-bit abstract register access
#      exist. Full Debug Mode, memory/SBA, progbuf and 64-bit abstract
#      transfers remain unsupported. See verify/jtag/README.md.
#
# ============================================================================

SHELL := /bin/bash
.DEFAULT_GOAL := help

RAPTOR_HOME ?= $(abspath ../..)
NSIM_HOME   ?= $(RAPTOR_HOME)/sim
JTAG_DIR    := $(abspath .)
BUILD_DIR   := $(JTAG_DIR)/build
RISCV_TESTS_REPO := $(JTAG_DIR)/riscv-tests
RISCV_TESTS_URL  := https://github.com/riscv-software-src/riscv-tests.git

.PHONY: help selftest openocd-server openocd-scan openocd-smoke openocd-halt-reg gdb-smoke debug-tests-setup debug-tests clean

JTAG_PORT       ?= 9824
NSIM_BIN        ?=
RAPT_CONFIG     ?= default
BUILD_PROFILE   ?= $(RAPT_CONFIG)
GDB_PORT        ?= 3333
PYTHON          ?= python3
SIM_FLAGS = RAPT_CONFIG="$(RAPT_CONFIG)" BUILD_PROFILE="$(BUILD_PROFILE)" VFLAGS="$(VFLAGS)"
OPENOCD         ?= openocd
OPENOCD_CFG     := $(JTAG_DIR)/openocd.cfg

# RISC-V GDB autodetect: pick the first available toolchain GDB on $PATH,
# falling back to a known-good local install for macOS dev environments.
RISCV_GDB ?= $(shell command -v riscv32-unknown-elf-gdb 2>/dev/null || \
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
	$(MAKE) -C $(NSIM_HOME) jtag-selftest

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

SELECTED_NPC = $(if $(strip $(NSIM_BIN)),$(NSIM_BIN),$$($(MAKE) --no-print-directory -s -C $(NSIM_HOME) $(SIM_FLAGS) print-jtag-bin))
SMOKE_ARGS = --npc "$(SELECTED_NPC)" --config "$(RAPTOR_HOME)/hdl/configs/$(RAPT_CONFIG)/rapt_config.svh" \
	--openocd "$(OPENOCD)" --openocd-config "$(OPENOCD_CFG)" \
	--port "$(JTAG_PORT)" --gdb-port "$(GDB_PORT)" --log-root "$(BUILD_DIR)/runs"

openocd-server: jtag-build ## Run foreground RV32 simulator JTAG server
	"$(SELECTED_NPC)" --jtag-server --jtag-port=$(JTAG_PORT)

openocd-smoke: jtag-build ## Check OpenOCD TAP enumeration
	$(PYTHON) run_smoke.py scan $(SMOKE_ARGS)

openocd-halt-reg: jtag-build ## Check RV32 halt and GPR/CSR round-trip
	$(PYTHON) run_smoke.py halt $(SMOKE_ARGS)

gdb-smoke: jtag-build ## Check RV32 GDB register access (missing tools fail)
	$(PYTHON) run_smoke.py gdb $(SMOKE_ARGS) --gdb "$(RISCV_GDB)"

# ---------------------------------------------------------------------------
# Layer 2: upstream riscv-tests debug suite (P1-blocked stub)
# ---------------------------------------------------------------------------
debug-tests-setup: ## Clone upstream riscv-tests (stages debug/ subdir for P1)
	@if [ ! -d "$(RISCV_TESTS_REPO)" ]; then \
		echo "[jtag] Cloning $(RISCV_TESTS_URL) ..."; \
		git clone --depth 1 --recurse-submodules $(RISCV_TESTS_URL) $(RISCV_TESTS_REPO); \
	else \
		echo "[jtag] $(RISCV_TESTS_REPO) already present."; \
	fi
	@echo ""
	@echo "[jtag] Upstream debug suite location:"
	@echo "       $(RISCV_TESTS_REPO)/debug/"
	@echo ""
	@echo "[jtag] Documented entry point: gdbserver.py (driven by gdb + OpenOCD)."

debug-tests: debug-tests-setup ## Run upstream riscv-tests/debug (BLOCKED on P1)
	@echo ""
	@echo "================================================================"
	@echo "[jtag] riscv-tests/debug is BLOCKED on the following preconditions:"
	@echo "================================================================"
	@echo ""
	@echo "  (a) OpenOCD bridge: sim must expose JTAG over OpenOCD's"
	@echo "      remote_bitbang protocol (TCP socket; see verify/jtag/README.md)."
	@echo "      Status: DONE — see 'make openocd-smoke' / 'make openocd-server'."
	@echo "              Implementation: sim/csrc/jtag/jtag_rbb_server.cc"
	@echo ""
	@echo "  (b) Halt/resume and 32-bit abstract GPR/selected-CSR access: DONE."
	@echo "      See openocd-halt-reg / gdb-smoke; debug CSRs are DM-local."
	@echo "      Commit-based stepping is a bring-up mechanism."
	@echo ""
	@echo "  Remaining: full Debug Mode entry/return, access_memory/SBA,"
	@echo "  program-buffer execution and 64-bit abstract transfers."
	@echo "  The upstream suite runner is not integrated; smoke tests do"
	@echo "  not establish full Debug Specification conformance."
	@echo ""
	@echo "================================================================"
	@exit 1

clean: ## Remove cloned repos and build artifacts (keeps nothing)
	rm -rf $(BUILD_DIR) $(RISCV_TESTS_REPO)
