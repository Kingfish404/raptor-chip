# Standalone on purpose: never parse FPGA Makefile or rewrite shared configuration.
# Usage: make -C fpga/litex -f netboot.mk netboot-help
.DEFAULT_GOAL := netboot-help
NETBOOT_ROOT := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
NETBOOT_PYTHON ?= python3
NETBOOT_FIRMWARE ?=
NETBOOT_PACKAGE ?=
NETBOOT_OUT ?=
NETBOOT_XLEN ?= 64
NETBOOT_CROSS ?= riscv64-linux-gnu-
NETBOOT_SERVER_IP ?=
NETBOOT_SERVER_PORT ?= 69
export NETBOOT_FIRMWARE NETBOOT_PACKAGE NETBOOT_OUT NETBOOT_XLEN NETBOOT_CROSS
export NETBOOT_SERVER_IP NETBOOT_SERVER_PORT

.PHONY: netboot-help netboot-check netboot-pack-rv32 netboot-pack-rv64 netboot-verify netboot-serve-plan netboot-test
netboot-help:
	@$(NETBOOT_PYTHON) -B "$(NETBOOT_ROOT)/scripts/netboot.py" --help
	@echo 'Targets: netboot-check netboot-pack-rv32 netboot-pack-rv64 netboot-verify netboot-serve-plan netboot-test'
	@echo 'Set NETBOOT_FIRMWARE (finished stage0/DTB directory), NETBOOT_PACKAGE (release directory), NETBOOT_OUT (new directory). See NETBOOT.md.'

netboot-check:
	@$(NETBOOT_PYTHON) -B "$(NETBOOT_ROOT)/scripts/netboot.py" check

netboot-pack-rv32:
	@$(NETBOOT_PYTHON) -B "$(NETBOOT_ROOT)/scripts/netboot.py" pack --xlen 32

netboot-pack-rv64:
	@$(NETBOOT_PYTHON) -B "$(NETBOOT_ROOT)/scripts/netboot.py" pack --xlen 64

netboot-verify:
	@$(NETBOOT_PYTHON) -B "$(NETBOOT_ROOT)/scripts/netboot.py" verify

netboot-serve-plan:
	@$(NETBOOT_PYTHON) -B "$(NETBOOT_ROOT)/scripts/netboot.py" serve-plan

netboot-test:
	@$(NETBOOT_PYTHON) -B "$(NETBOOT_ROOT)/tests/test_netboot.py"
