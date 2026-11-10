ROOT := $(abspath ../../..)
PYTHON ?= python3
CROSS_COMPILE ?= riscv64-elf-
CLOCK_HZ ?= 10000000
BUILD_ROOT ?=
.DEFAULT_GOAL := programs
.PHONY: programs
programs:
	@test -n "$(BUILD_ROOT)" || { echo 'Set BUILD_ROOT outside the checkout'; exit 1; }
	cd "$(ROOT)" && PYTHONDONTWRITEBYTECODE=1 $(PYTHON) -m tools.bringup.programs \
		--output "$(BUILD_ROOT)" --cross "$(CROSS_COMPILE)" --clock-hz $(CLOCK_HZ)
