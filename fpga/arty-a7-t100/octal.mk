# Legacy octal-link fixture, selected with PLATFORM=octal in the board Makefile.
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
ROOT := $(abspath ../..)
BOARD := $(CURDIR)
OUT ?= $(ROOT)/fpga/build/arty-a7-t100
JOIN ?= internal
VIVADO ?= vivado
CROSS_COMPILE ?= riscv64-elf-
PYTHON ?= python3
SIM_FAST ?= 0
SIM_FAST_FLAG := $(if $(filter 1,$(SIM_FAST)),--fast,)
BUILD := $(abspath $(OUT))/$(JOIN)
HW_OUT ?= $(ROOT)/fpga/build/arty-a7-t100/hw-logs
JOIN_FLAG := $(if $(filter internal,$(JOIN)),--internal,)

ifeq ($(filter $(JOIN),pins internal),)
$(error JOIN must be pins or internal)
endif

.PHONY: all export synth build program test clean-help
all: build

$(BUILD)/boot.bin: firmware/boot.S firmware/boot.c firmware/boot.ld
	mkdir -p $(BUILD)
	$(CROSS_COMPILE)gcc -march=rv32im_zicsr_zifencei -mabi=ilp32 -nostdlib \
		-Os -ffreestanding -fno-pic -fno-builtin -fno-stack-protector -msmall-data-limit=0 \
		-Wl,-T,firmware/boot.ld -Wl,--no-relax -o $(BUILD)/boot.elf firmware/boot.S firmware/boot.c
	$(CROSS_COMPILE)objcopy -O binary $(BUILD)/boot.elf $@

$(BUILD)/mrom.hex: $(BUILD)/boot.bin scripts/hex.py
	$(PYTHON) scripts/hex.py $< $@

$(BUILD)/finish.bin: firmware/finish.S
	mkdir -p $(BUILD)
	$(CROSS_COMPILE)gcc -march=rv32im -mabi=ilp32 -nostdlib \
		-Wl,-Ttext=0 -Wl,--no-relax -o $(BUILD)/finish.elf $<
	$(CROSS_COMPILE)objcopy -O binary $(BUILD)/finish.elf $@

export: $(BUILD)/mrom.hex $(BUILD)/finish.bin
	$(PYTHON) scripts/export.py --out $(BUILD) $(JOIN_FLAG)

synth build: export
	$(PYTHON) scripts/vivado.py --vivado $(VIVADO) --out $(BUILD) \
		--script scripts/build.tcl $(JOIN) $@

.PHONY: retime
retime:
	$(PYTHON) scripts/refresh_constraints.py --out $(BUILD)
	$(PYTHON) scripts/vivado.py --vivado $(VIVADO) --out $(BUILD) \
		--script scripts/build.tcl $(JOIN) retime

program:
	$(PYTHON) scripts/hw/program.py --vivado $(VIVADO) --build $(BUILD) \
		--output $(HW_OUT)/program-$(JOIN)

.PHONY: test-flash test-loader
test-loader:
	$(PYTHON) scripts/test_loader.py --out $(abspath $(OUT))/loader

test-flash:
	$(PYTHON) scripts/test_flash.py --out $(abspath $(OUT))/flash

.PHONY: format-check check-host
format-check:
	$(PYTHON) scripts/checks.py

check-host:
	$(PYTHON) -m unittest discover -s tests -p 'test_*.py' -v

.PHONY: payloads
payloads: $(BUILD)/flasher.bin $(BUILD)/ram_march.bin $(BUILD)/jtag_fixture.bin \
	$(BUILD)/flash_xip.bin $(BUILD)/xip_probe.bin $(BUILD)/boot_check.bin

$(BUILD)/jtag_fixture.bin: firmware/payloads/jtag_fixture.S firmware/payloads/ram.ld
	mkdir -p $(BUILD)
	$(CROSS_COMPILE)gcc -march=rv32im -mabi=ilp32 -nostdlib \
		-Wl,-T,firmware/payloads/ram.ld -Wl,--no-relax -o $(BUILD)/jtag_fixture.elf $<
	$(CROSS_COMPILE)objcopy -O binary $(BUILD)/jtag_fixture.elf $@

$(BUILD)/flash_xip.bin: firmware/payloads/flash_xip.S firmware/payloads/ram.ld
	mkdir -p $(BUILD)
	$(CROSS_COMPILE)gcc -march=rv32im -mabi=ilp32 -nostdlib \
		-Wl,-T,firmware/payloads/ram.ld -Wl,--no-relax -o $(BUILD)/flash_xip.elf $<
	$(CROSS_COMPILE)objcopy -O binary $(BUILD)/flash_xip.elf $@

$(BUILD)/%.bin: firmware/payloads/%.c firmware/payloads/start.S firmware/payloads/board.h firmware/payloads/ram.ld
	mkdir -p $(BUILD)
	$(CROSS_COMPILE)gcc -march=rv32im_zicsr_zifencei -mabi=ilp32 -nostdlib \
		-Os -ffreestanding -fno-pic -fno-builtin -fno-stack-protector -msmall-data-limit=0 \
		-Wl,-T,firmware/payloads/ram.ld -Wl,--no-relax -o $(BUILD)/$*.elf firmware/payloads/start.S $<
	$(CROSS_COMPILE)objcopy -O binary $(BUILD)/$*.elf $@

test: $(BUILD)/mrom.hex $(BUILD)/finish.bin
	$(PYTHON) scripts/simulate.py --out $(BUILD) $(SIM_FAST_FLAG)

clean-help:
	@echo 'Remove a chosen OUT directory manually; no broad cleanup target is provided.'
