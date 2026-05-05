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
#                        See nsim/csrc/jtag/jtag_selftest.cc for the catalog.
#
#   2. openocd-smoke   - runs today. Builds nsim, launches it as an OpenOCD
#                        `remote_bitbang` TCP server, runs upstream OpenOCD
#                        0.12+ against verify/jtag/openocd.cfg, and PASSes if
#                        OpenOCD enumerates IDCODE = 0x10001913. Validates
#                        the full path real-OpenOCD -> TCP -> nsim -> RTL TAP.
#                        Use `make openocd-server` to leave nsim running for
#                        interactive OpenOCD/GDB sessions.
#
#   3. debug-tests     - clones https://github.com/riscv-software-src/riscv-tests
#                        and stages the upstream `debug/` GDB-driven debug-spec
#                        suite. *Currently P1-blocked*: requires (a) an OpenOCD
#                        remote_bitbang DPI bridge in nsim, (b) working
#                        halt/resume + abstract access_register/access_memory
#                        in rapt_dm, and (c) dcsr/dpc/dscratch CSRs in
#                        rapt_csr.sv. The setup target clones the repo and
#                        emits a clearly-marked checklist of preconditions.
#                        Running `make debug-tests` before that infra exists
#                        prints the gap list and exits with rc=1 instead of
#                        silently failing.
#
# ============================================================================

SHELL := /bin/bash
.DEFAULT_GOAL := help

RAPTOR_HOME ?= $(abspath ../..)
NSIM_HOME   ?= $(RAPTOR_HOME)/nsim
JTAG_DIR    := $(abspath .)
BUILD_DIR   := $(JTAG_DIR)/build
RISCV_TESTS_REPO := $(JTAG_DIR)/riscv-tests
RISCV_TESTS_URL  := https://github.com/riscv-software-src/riscv-tests.git

.PHONY: help selftest openocd-server openocd-scan openocd-smoke openocd-halt-reg gdb-smoke debug-tests-setup debug-tests clean

JTAG_PORT       ?= 9824
NSIM_BIN        ?= $(NSIM_HOME)/build/default/riscv32-npc-sim
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
# Foreground server: OpenOCD connects via remote_bitbang over TCP. Run in one
# terminal, then point OpenOCD at openocd.cfg from another.
openocd-server: ## Run nsim as foreground OpenOCD remote_bitbang server (Ctrl-C to exit)
	$(MAKE) -C $(NSIM_HOME) all
	@echo "[jtag] nsim listening on 127.0.0.1:$(JTAG_PORT) for OpenOCD"
	$(NSIM_BIN) --jtag-server --jtag-port=$(JTAG_PORT)

# Background end-to-end smoke: confirms OpenOCD enumerates the IDCODE.
# This validates the full TAP path: OpenOCD -> TCP -> nsim -> rapt_dtm -> TDO.
openocd-smoke: ## End-to-end OpenOCD bring-up smoke (expects IDCODE=0x10001913)
	$(MAKE) -C $(NSIM_HOME) all
	@echo "[jtag] starting nsim server..."
	@pkill -f 'riscv32-npc-sim --jtag-server' 2>/dev/null; sleep 1; \
	$(NSIM_BIN) --jtag-server --jtag-port=$(JTAG_PORT) >/tmp/jtag_srv.log 2>&1 & \
	SRV=$$!; sleep 2; \
	$(OPENOCD) -f $(OPENOCD_CFG) -c "scan_chain" -c "exit" 2>&1 | tee /tmp/jtag_oocd.log; \
	rc=$$?; kill $$SRV 2>/dev/null; wait 2>/dev/null; \
	if grep -q "tap/device found: 0x10001913" /tmp/jtag_oocd.log; then \
	  echo "[jtag] PASS: OpenOCD enumerated IDCODE 0x10001913 over remote_bitbang"; \
	  exit 0; \
	else \
	  echo "[jtag] FAIL: OpenOCD did not see expected IDCODE — see /tmp/jtag_oocd.log"; \
	  exit 1; \
	fi

# Halt + register access via real OpenOCD. Verifies the full debug stack:
#   OpenOCD -> remote_bitbang -> rapt_dtm -> rapt_dm -> rapt_core (halt+PRF).
# Round-trips MISA (read-only constant) and t0 (GPR x5 via abstract command),
# proving that abstract `access_register` and the sticky DM halt latch both
# work end-to-end. Does NOT need a running image because abstract command
# operates entirely on the halted hart.
openocd-halt-reg: ## OpenOCD halt + GPR/CSR round-trip (full debug stack)
	$(MAKE) -C $(NSIM_HOME) all
	@echo "[jtag] starting nsim server..."
	@pkill -f 'riscv32-npc-sim --jtag-server' 2>/dev/null; sleep 1; \
	$(NSIM_BIN) --jtag-server --jtag-port=$(JTAG_PORT) >/tmp/jtag_srv.log 2>&1 & \
	SRV=$$!; sleep 2; \
	$(OPENOCD) -f $(OPENOCD_CFG) \
	    -c "halt" \
	    -c "reg t0 0xCAFEF00D" \
	    -c "reg t0 -force" \
	    -c "reg t0 0x12345678" \
	    -c "reg t0 -force" \
	    -c "resume" -c "exit" 2>&1 | tee /tmp/jtag_oocd_halt.log; \
	rc=$$?; kill $$SRV 2>/dev/null; wait 2>/dev/null; \
	pass=1; \
	grep -q "Examined RISC-V core" /tmp/jtag_oocd_halt.log || { echo "[jtag] FAIL: examine"; pass=0; }; \
	grep -q "misa=0x40141105" /tmp/jtag_oocd_halt.log || { echo "[jtag] FAIL: misa enumeration"; pass=0; }; \
	grep -qi "t0 (/32): 0xcafef00d" /tmp/jtag_oocd_halt.log || { echo "[jtag] FAIL: t0=0xCAFEF00D round-trip"; pass=0; }; \
	grep -qi "t0 (/32): 0x12345678" /tmp/jtag_oocd_halt.log || { echo "[jtag] FAIL: t0=0x12345678 round-trip"; pass=0; }; \
	if [ "$$pass" = "1" ]; then \
	  echo "[jtag] PASS: OpenOCD halt + GPR/CSR access verified"; exit 0; \
	else \
	  echo "[jtag] FAIL: see /tmp/jtag_oocd_halt.log"; exit 1; \
	fi

# Real GDB attached to OpenOCD's gdbserver. Validates the full host stack:
#   GDB -> tcp:3333 -> OpenOCD gdbserver -> remote_bitbang -> rapt_dtm -> rapt_dm.
# Round-trips two GPR writes via `set $reg = value` and verifies misa
# decodes correctly. Uses --batch + a here-doc gdbinit so the test runs
# fully unattended. Skips `detach`/`quit` because SiFive GDB 8.3.0 trips an
# internal assertion in thread.c during detach against OpenOCD's
# gdbserver — harmless (occurs after all test commands complete).
gdb-smoke: ## OpenOCD + GDB end-to-end (info reg, set $reg, MISA decode)
	$(MAKE) -C $(NSIM_HOME) all
	@if [ ! -x "$(RISCV_GDB)" ]; then \
	  echo "[jtag] SKIP: no riscv-gdb on \$$PATH (set RISCV_GDB=...)"; exit 0; \
	fi
	@echo "[jtag] GDB: $(RISCV_GDB)"
	@pkill -f 'riscv32-npc-sim --jtag-server' 2>/dev/null; \
	pkill -f 'openocd .*$(notdir $(OPENOCD_CFG))' 2>/dev/null; sleep 1; \
	$(NSIM_BIN) --jtag-server --jtag-port=$(JTAG_PORT) >/tmp/jtag_srv.log 2>&1 & \
	SRV=$$!; sleep 2; \
	$(OPENOCD) -f $(OPENOCD_CFG) >/tmp/jtag_oocd_gdb.log 2>&1 & \
	OOCD=$$!; sleep 3; \
	$(RISCV_GDB) --batch \
	    -ex "set arch riscv:rv32" \
	    -ex "set confirm off" \
	    -ex "target extended-remote :3333" \
	    -ex "info reg misa pc t0" \
	    -ex "set \$$t0 = 0xDEADBEEF" \
	    -ex "info reg t0" \
	    -ex "set \$$t1 = 0x12345678" \
	    -ex "info reg t0 t1" \
	    -ex "kill" \
	    2>&1 | tee /tmp/jtag_gdb.log; \
	rc=$$?; kill $$OOCD $$SRV 2>/dev/null; wait 2>/dev/null; \
	pass=1; \
	grep -q "RV32" /tmp/jtag_gdb.log || { echo "[jtag] FAIL: misa decode"; pass=0; }; \
	grep -qi "t0 *0xdeadbeef" /tmp/jtag_gdb.log || { echo "[jtag] FAIL: t0=0xDEADBEEF"; pass=0; }; \
	grep -qi "t1 *0x12345678" /tmp/jtag_gdb.log || { echo "[jtag] FAIL: t1=0x12345678"; pass=0; }; \
	if [ "$$pass" = "1" ]; then \
	  echo "[jtag] PASS: GDB <-> OpenOCD <-> Raptor end-to-end"; exit 0; \
	else \
	  echo "[jtag] FAIL: see /tmp/jtag_gdb.log"; exit 1; \
	fi

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
	@echo "  (a) OpenOCD bridge: nsim must expose JTAG over OpenOCD's"
	@echo "      remote_bitbang protocol (TCP socket per dev.jtag.md §8.1)."
	@echo "      Status: DONE — see 'make openocd-smoke' / 'make openocd-server'."
	@echo "              Implementation: nsim/csrc/jtag/jtag_rbb_server.cc"
	@echo ""
	@echo "  (b) Halt / resume: the DM must drive the core's CMU into a"
	@echo "      halt boundary on haltreq, and IFU must redirect to"
	@echo "      dm_haltaddr_o on entry. dcsr/dpc/dscratch CSRs must be"
	@echo "      added to rapt_csr.sv (they are absent today)."
	@echo "      Status: NOT IMPLEMENTED (P1 in dev.jtag.md)."
	@echo ""
	@echo "  (c) Abstract commands: access_register and access_memory must"
	@echo "      be wired (rapt_dm currently returns cmderr=2 for any"
	@echo "      command write). The compliance probe verifies that"
	@echo "      cmderr=2 path; it does NOT cover the success path."
	@echo "      Status: NOT IMPLEMENTED (P1)."
	@echo ""
	@echo "  In the meantime, run 'make selftest' for the 23-check"
	@echo "  compliance probe that exercises everything the RTL implements"
	@echo "  today (TAP FSM, IR routing, BYPASS, DTMCS, all DM regs)."
	@echo ""
	@echo "================================================================"
	@exit 1

clean: ## Remove cloned repos and build artifacts (keeps nothing)
	rm -rf $(BUILD_DIR) $(RISCV_TESTS_REPO)
