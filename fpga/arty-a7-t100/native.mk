# Explicit native Profile 1 fixture. Ordinary SoC and private-bridge flows are independent.
.DEFAULT_GOAL := help
.NOTPARALLEL:
PYTHON ?= python3
JOBS ?= 2
VIVADO ?= vivado
RAPT_CONFIG ?= chip32-small
CLOCK_HZ ?= 10000000
CROSS_COMPILE ?= riscv64-elf-
BUILD_ROOT ?=
.PHONY: help lint programs sim test export synth build clock-test monitor-test rom-test
help:
	@echo 'Native JESD fixture: lint programs sim test export synth build clock-test monitor-test'
	@echo 'Set BUILD_ROOT outside the checkout; CLOCK_HZ defaults to 10000000.'
lint programs sim export clock-test monitor-test:
	@test -n "$(BUILD_ROOT)" || { echo 'Set BUILD_ROOT outside the checkout'; exit 1; }
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) native/build.py $@ \
		--out "$(BUILD_ROOT)/$@" --jobs $(JOBS) --config $(RAPT_CONFIG) \
		--clock-hz $(CLOCK_HZ) \
		--cross $(CROSS_COMPILE) --vivado "$(VIVADO)"
test:
	cd ../.. && PYTHONDONTWRITEBYTECODE=1 $(PYTHON) -m unittest \
		tools.bringup.tests.test_native_flash -v
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) -m unittest discover \
		-s native/tests -p test_receiver_map.py -v
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) -m unittest discover \
		-s native/tests -p test_rom_boot.py -v
rom-test:
	@test -n "$(BUILD_ROOT)" || { echo 'Set BUILD_ROOT outside the checkout'; exit 1; }
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) native/tests/check_rom_boot.py \
		--out "$(BUILD_ROOT)/rom-test" --cross $(CROSS_COMPILE)
synth build: export
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) scripts/vivado.py --vivado "$(VIVADO)" --out "$(BUILD_ROOT)/export" \
		--script "$(BUILD_ROOT)/export/inputs/build.tcl" $@
