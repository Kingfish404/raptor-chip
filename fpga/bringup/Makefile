PYTHON ?= python3
JOBS ?= 4
CROSS_COMPILE ?= riscv64-elf-
VIVADO ?= vivado
BUILD_ROOT ?=
.PHONY: sim programs emulation hardware clock-test ram-test test
sim programs emulation hardware clock-test ram-test:
	@test -n "$(BUILD_ROOT)" || { echo 'Set BUILD_ROOT to an output disk outside the tree'; exit 1; }
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) build.py $@ --work '$(BUILD_ROOT)/$@' \
		--jobs $(JOBS) --cross '$(CROSS_COMPILE)' --vivado '$(VIVADO)'
test:
	cd ../.. && PYTHONDONTWRITEBYTECODE=1 $(PYTHON) -m unittest discover -s tools/bringup/tests -v
