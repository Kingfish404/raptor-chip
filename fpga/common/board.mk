# Shared targets for a native board directory (fpga/<board>/Makefile).
#
# The board Makefile sets its own variables and BOARD_OPTIONS, then includes
# this file. Every target runs fpga/common/scripts/native_build.py with
# --board pointing at the board directory, which holds board.json. Values left
# empty here fall back to board.json.

COMMON_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
BOARD_DIR := $(CURDIR)
BOARD_MAKEFILE := $(abspath $(firstword $(MAKEFILE_LIST)))

PYTHON ?= python3 ## Python interpreter for the native tools
XLEN ?= 64 ## Core XLEN (32|64)
RAPT_CONFIG ?= small ## Microarchitecture preset from hdl/configs/
MEMORY ?= ddr ## Main memory (ddr|bram)
CLOCK_MHZ ?= 50 ## Core clock in MHz (25|50|100)
RAM_BYTES ?= 131072 ## Main memory bytes when MEMORY=bram (power of two, 16 KiB-1 MiB)
USE_RESET_BUTTON ?= 0 ## Drive core reset from the board button (0|1)
DDR_PART ?= ## DDR4 part for the MIG (empty: board.json)
CROSS ?= riscv64-unknown-elf- ## Bare-metal toolchain prefix for the boot ROM
VIVADO ?= vivado ## Vivado executable
JOBS ?= 4 ## Vivado and Verilator jobs (1-32)
BUILD_ROOT ?= $(BOARD_DIR)/build ## Output root; each configuration gets its own subdirectory
HW_TARGET ?= ## JTAG target glob for load, e.g. */0ABC01A (empty: the only target)
TRACE ?= 0 ## Set to 1 to dump the focused boot AXI waveform in sim
# A trailing `## doc` leaves a space in the value; strip it before quoting.
$(foreach v,PYTHON XLEN RAPT_CONFIG MEMORY CLOCK_MHZ RAM_BYTES USE_RESET_BUTTON DDR_PART \
	CROSS VIVADO JOBS BUILD_ROOT HW_TARGET TRACE $(BOARD_VARIABLES),\
	$(eval $(v) := $(strip $($(v)))))

NATIVE_BUILD = $(PYTHON) $(COMMON_DIR)/scripts/native_build.py --board '$(BOARD_DIR)' \
	--xlen $(XLEN) --preset $(RAPT_CONFIG) --memory $(MEMORY) --clock-mhz $(CLOCK_MHZ) \
	--ram-bytes $(RAM_BYTES) --reset-button $(USE_RESET_BUTTON) \
	--cross '$(CROSS)' --vivado '$(VIVADO)' --jobs $(JOBS) --build-root '$(BUILD_ROOT)' \
	$(if $(DDR_PART),--ddr-part '$(DDR_PART)') \
	$(if $(HW_TARGET),--hw-target '$(HW_TARGET)') \
	$(if $(filter 1,$(TRACE)),--trace) $(BOARD_OPTIONS)

help: ## Show targets and variables
	@awk -f $(COMMON_DIR)/scripts/make_help.awk \
		$(COMMON_DIR)/board.mk $(COMMON_DIR)/ubuntu.mk $(BOARD_MAKEFILE)

# ============================================================================
# Native SoC (build steps regenerate their sources first)
# ============================================================================

info: ## Print the configuration and its output directory as JSON
	$(NATIVE_BUILD) info

prepare: ## Generate the boot ROM, device tree, packed RTL and Vivado inputs
	$(NATIVE_BUILD) prepare

lint: ## Verilator-lint the SoC
	$(NATIVE_BUILD) lint

test: ## Run the host unit tests and the bus/UART testbenches
	$(NATIVE_BUILD) test

sim: ## Simulate the boot ROM loading a payload (TRACE=1 for a waveform)
	$(NATIVE_BUILD) sim

ip-check: ## Elaborate the SoC with the generated Vivado IP
	$(NATIVE_BUILD) ip-check

peripheral-synth: ## Synthesize the bus and peripherals without the core
	$(NATIVE_BUILD) peripheral-synth

synth: ## Synthesize the whole SoC and write reports
	$(NATIVE_BUILD) synth

build: ## Synthesize, route and timing-check the bitstream
	$(NATIVE_BUILD) build

load: ## Program the board from a matching timing-clean build
	$(NATIVE_BUILD) load

refresh-software: ## Rebuild the ROM and DTB of a built bitstream if its hardware is unchanged
	$(NATIVE_BUILD) refresh-software

.PHONY: help info prepare lint test sim ip-check peripheral-synth synth build load \
	refresh-software
