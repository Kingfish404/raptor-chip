# Tests for raptor-chip OpenRAM SRAM integration.
#
#   make all          - Run consistency tests (no external deps)
#   make sta-smoke    - Opt-in end-to-end STA smoke (needs yosys+slang+OpenSTA)
#   make clean        - Remove temp test artefacts

HERE := $(abspath $(CURDIR))
SRAM := $(abspath $(HERE)/..)
PYTHON ?= python3

.PHONY: all check sta-smoke clean help

all: check ## Run all consistency tests

check: ## Static cross-file consistency (configs / blackbox / RTL / stub gen)
	@$(PYTHON) $(HERE)/test_sram_integration.py

sta-smoke: ## Run yosys+OpenSTA against a 1-macro wrapper (needs full toolchain)
	@bash $(HERE)/run_sta_smoke.sh

clean: ## Remove test temp artefacts
	rm -rf $(HERE)/_tmp_libs $(HERE)/_tmp_sta

help: ## Show this help
	@awk 'BEGIN{FS=":.*##"} /^[a-zA-Z0-9_-]+:.*##/ {printf "  %-12s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
