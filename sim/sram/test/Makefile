# Tests for raptor-chip OpenRAM SRAM integration.
#
#   make all          - Run consistency tests (no external deps)
#   make sta-smoke    - Opt-in end-to-end STA smoke (needs yosys+slang+OpenSTA)
#   make clean        - Remove temp test artefacts

HERE := $(abspath $(CURDIR))
SRAM := $(abspath $(HERE)/..)
PYTHON ?= python3

.PHONY: all check rtl-sync macro-fallback sta-smoke clean help

all: check rtl-sync macro-fallback ## Run consistency and RTL timing-contract tests

check: ## Static cross-file consistency (configs / blackbox / RTL / stub gen)
	@$(PYTHON) $(HERE)/test_sram_integration.py

rtl-sync: ## Verify synchronous read, output hold, and byte-write behavior
	@verilator --binary --timing -Wno-fatal --top-module tb_rapt_sram_1rw \
		-Mdir $(HERE)/_tmp_rtl_sync \
		$(SRAM)/../../hdl/memory/rapt_sram_1rw.sv \
		$(HERE)/fixtures/tb_rapt_sram_1rw.sv
	@$(HERE)/_tmp_rtl_sync/Vtb_rapt_sram_1rw

macro-fallback: ## Verify unsupported OpenRAM shapes use synchronous inference
	@verilator --binary --timing -Wno-fatal -DRAPT_USE_SRAM_MACRO \
		--top-module tb_rapt_sram_1rw -Mdir $(HERE)/_tmp_macro_fallback \
		$(SRAM)/wrappers/rapt_sram_blackbox.v \
		$(SRAM)/../../hdl/memory/rapt_sram_1rw.sv \
		$(HERE)/fixtures/tb_rapt_sram_1rw.sv
	@$(HERE)/_tmp_macro_fallback/Vtb_rapt_sram_1rw

sta-smoke: ## Run yosys+OpenSTA against a 1-macro wrapper (needs full toolchain)
	@bash $(HERE)/run_sta_smoke.sh

clean: ## Remove test temp artefacts
	rm -rf $(HERE)/_tmp_libs $(HERE)/_tmp_sta $(HERE)/_tmp_rtl_sync \
		$(HERE)/_tmp_macro_fallback

help: ## Show this help
	@awk 'BEGIN{FS=":.*##"} /^[a-zA-Z0-9_-]+:.*##/ {printf "  %-12s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
