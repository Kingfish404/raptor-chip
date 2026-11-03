# Tests for raptor-chip OpenRAM SRAM integration.
#
#   make all          - Run consistency tests (no external deps)
#   make sta-smoke    - Opt-in end-to-end STA smoke (needs yosys+slang+OpenSTA)
#   make clean        - Remove temp test artefacts

HERE := $(abspath $(CURDIR))
SRAM := $(abspath $(HERE)/..)
PYTHON ?= python3
BUILD_DIR ?= $(HERE)/_tmp
SRAM_PKG := $(SRAM)/../../rtl/rapt_pkg.sv
SRAM_INCLUDES := -I$(SRAM)/../../rtl/include -I$(SRAM)/../../rtl/configs/default

.PHONY: all check rtl-sync macro-fallback rtl-2rw macro-2rw sta-smoke clean help

all: check rtl-sync macro-fallback rtl-2rw macro-2rw ## Check ports and memory timing contracts

check: ## Static cross-file consistency (configs / blackbox / RTL / stub gen)
	@$(PYTHON) $(HERE)/test_sram_integration.py

rtl-sync: ## Verify synchronous read, output hold, and byte-write behavior
	@mkdir -p $(BUILD_DIR)/rtl-sync
	@verilator --binary --timing --assert -Wno-fatal --top-module tb_rapt_sram_1rw \
		$(SRAM_INCLUDES) -Mdir $(BUILD_DIR)/rtl-sync $(SRAM_PKG) \
		$(SRAM)/../../rtl/sram/rapt_sram_1rw.sv \
		$(HERE)/fixtures/tb_rapt_sram_1rw.sv
	@$(BUILD_DIR)/rtl-sync/Vtb_rapt_sram_1rw

macro-fallback: ## Verify wrapper pins and timing with a functional 8x32 macro fixture
	@mkdir -p $(BUILD_DIR)/macro-fallback
	@verilator --binary --timing --assert -Wno-fatal -DRAPT_USE_SRAM_MACRO \
		--top-module tb_rapt_sram_1rw $(SRAM_INCLUDES) \
		-Mdir $(BUILD_DIR)/macro-fallback $(SRAM_PKG) \
		$(HERE)/fixtures/rapt_openram_1rw_8x32_model.sv \
		$(SRAM)/../../rtl/sram/rapt_sram_1rw.sv \
		$(HERE)/fixtures/tb_rapt_sram_1rw.sv
	@$(BUILD_DIR)/macro-fallback/Vtb_rapt_sram_1rw

rtl-2rw: ## Check both independent ports while changing the ignored control word
	@mkdir -p $(BUILD_DIR)/rtl-2rw
	@verilator --binary --timing --assert -Wno-fatal --top-module tb_rapt_sram_2rw \
		$(SRAM_INCLUDES) -Mdir $(BUILD_DIR)/rtl-2rw $(SRAM_PKG) \
		$(SRAM)/../../rtl/sram/rapt_sram_2rw.sv \
		$(HERE)/fixtures/tb_rapt_sram_2rw.sv
	@$(BUILD_DIR)/rtl-2rw/Vtb_rapt_sram_2rw

macro-2rw: ## Check the 2RW macro's ctrl forwarding and functional stand-in
	@mkdir -p $(BUILD_DIR)/macro-2rw/obj
	@$(PYTHON) $(SRAM)/scripts/gen_stub_lib.py rapt_openram_2rw_32x64 \
		32 64 64 $(BUILD_DIR)/macro-2rw
	@verilator --binary --timing --assert -Wno-fatal -DRAPT_USE_SRAM_MACRO \
		--top-module tb_rapt_sram_2rw $(SRAM_INCLUDES) -Mdir $(BUILD_DIR)/macro-2rw/obj \
		$(SRAM_PKG) $(BUILD_DIR)/macro-2rw/rapt_openram_2rw_32x64.v \
		$(SRAM)/../../rtl/sram/rapt_sram_2rw.sv \
		$(HERE)/fixtures/tb_rapt_sram_2rw.sv
	@$(BUILD_DIR)/macro-2rw/obj/Vtb_rapt_sram_2rw

sta-smoke: ## Run yosys+OpenSTA against a 1-macro wrapper (needs full toolchain)
	@bash $(HERE)/run_sta_smoke.sh

clean: ## Remove test temp artefacts
	rm -rf $(HERE)/_tmp_libs $(HERE)/_tmp_sta $(HERE)/_tmp_rtl_sync \
		$(HERE)/_tmp_macro_fallback

help: ## Show this help
	@awk 'BEGIN{FS=":.*##"} /^[a-zA-Z0-9_-]+:.*##/ {printf "  %-12s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
