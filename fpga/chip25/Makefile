.DEFAULT_GOAL := help
.NOTPARALLEL:
PYTHON ?= python3
BUILD_ROOT ?=
MODE ?= flash
FULL_WAITS ?= 0
JOBS ?= 4
VIVADO ?= vivado
CROSS_COMPILE ?= riscv64-elf-
WAIT_ARG :=
ifeq ($(FULL_WAITS),1)
WAIT_ARG := --full-waits
endif
.PHONY: help programs target-test target-export sim export synth build
help:
	@echo 'CU08 25-signal emulation: programs target-test target-export sim export synth build'
	@echo 'Set BUILD_ROOT outside the checkout; MODE=flash|bridge, FULL_WAITS=0|1, JOBS=1..4.'
programs target-test target-export sim export synth build:
	@test -n "$(BUILD_ROOT)" || { echo 'Set BUILD_ROOT outside the checkout'; exit 1; }
	PYTHONDONTWRITEBYTECODE=1 $(PYTHON) build.py $@ --out "$(BUILD_ROOT)/$@" \
		--mode "$(MODE)" --jobs $(JOBS) --cross "$(CROSS_COMPILE)" \
		--vivado "$(VIVADO)" $(WAIT_ARG)
