# Standalone whole-chip UVM. No parse-time builds or sim/.config changes.
SHELL := /bin/bash
.DEFAULT_GOAL := help
PYTHON ?= python3
UVM_HOME ?=
VERILATOR ?= verilator
CROSS_COMPILE ?= riscv64-elf-
XLEN ?= 32
RAPT_CONFIG ?= default
TOP ?= axi
JOBS ?= 4
CASES ?= all
SEEDS ?= 1 42
DELAYS ?= 0 7 31
ARGS = --uvm-home "$(UVM_HOME)" --verilator "$(VERILATOR)" \
       --cross-compile "$(CROSS_COMPILE)" --preset "$(RAPT_CONFIG)" \
       --xlen $(XLEN) --top $(TOP) --jobs $(JOBS) \
       --cases $(CASES) --seeds $(SEEDS) --delays $(DELAYS)
.PHONY: help chip chip-build chip-rv32 chip-rv64 chip-rnp chip-regress chip-checkers
help:
	@echo 'chip          Run all whole-chip scenarios for RAPT_CONFIG/XLEN/TOP'
	@echo 'chip-rv32/64  Run all scenarios at the selected XLEN'
	@echo 'chip-rnp      Run the RV32 package-pin integration scenarios'
	@echo 'chip-regress  Run the preset/XLEN/RNP matrix and checker negative tests'
	@echo 'chip-checkers Prove the scoreboard rejects injected observation errors'
	@echo 'Set UVM_HOME to Accellera UVM sources; see chip/README.md.'
chip:
	$(PYTHON) run.py $(ARGS)
chip-build:
	$(PYTHON) run.py $(ARGS) --build-only
chip-rv32:
	$(MAKE) chip XLEN=32
chip-rv64:
	$(MAKE) chip XLEN=64
chip-rnp:
	$(MAKE) chip XLEN=32 TOP=rnp
chip-regress:
	$(PYTHON) run.py $(ARGS) --matrix --negative
chip-checkers:
	$(PYTHON) run.py $(filter-out --cases $(CASES),$(ARGS)) --cases smoke --negative
