# Standalone CU08-KU15P: no LiteX/Migen environment is required.
.DEFAULT_GOAL := help
PYTHON ?= python3
XLEN ?= 64
RAPT_CONFIG ?= small
MEMORY ?= bram
CLOCK_MHZ ?= 50
RAM_BYTES ?= 131072
USE_RESET_BUTTON ?= 0
DDR_PART ?= MT40A512M16HA-083E
CROSS ?= riscv64-unknown-elf-
VIVADO ?= vivado
JOBS ?= 4
BUILD_ROOT ?= $(CURDIR)/build
OPTIONS = --xlen $(XLEN) --preset $(RAPT_CONFIG) --memory $(MEMORY) \
	--clock-mhz $(CLOCK_MHZ) --ram-bytes $(RAM_BYTES) --reset-button $(USE_RESET_BUTTON) \
	--ddr-part '$(DDR_PART)' --cross '$(CROSS)' --vivado '$(VIVADO)' --jobs $(JOBS) \
	--build-root '$(BUILD_ROOT)'
.PHONY: help prepare refresh-software lint test sim ip-check peripheral-synth synth build load info
help:
	@echo 'Native CU08-KU15P: prepare refresh-software lint test sim ip-check peripheral-synth synth build load info'
	@echo 'Example: make build XLEN=64 MEMORY=ddr RAPT_CONFIG=small CLOCK_MHZ=50'
	@echo 'build routes and timing-gates the bitstream; load only programs a matching validated build.'
prepare refresh-software lint test sim ip-check peripheral-synth synth build load info:
	$(PYTHON) build.py $(OPTIONS) $@
