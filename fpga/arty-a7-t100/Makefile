# Ordinary Raptor SoC by default; retain the pin-limited test fixture explicitly.
PLATFORM ?= soc
PLATFORM := $(strip $(PLATFORM))
ifeq ($(PLATFORM),octal)
include octal.mk
else ifeq ($(PLATFORM),jesd)
include native.mk
else ifeq ($(PLATFORM),soc)
SHELL := /bin/bash
.DEFAULT_GOAL := help
ROOT := $(abspath ../..)
LITEX := $(ROOT)/fpga/litex
XLEN ?= 32
RAPT_CONFIG ?= small
MEMORY ?= ddr
CLOCK_MHZ ?= 20
RAM_BYTES ?= 131072
BUILD_ROOT ?= $(CURDIR)/build
PYTHON ?= $(LITEX)/.venv/bin/python3
VIVADO ?= vivado
JOBS ?= 4
UART_PORT ?=
HW_TARGET ?=
RAPT_PROBE_SERIAL ?=
OPENOCD ?= openocd
$(foreach v,XLEN RAPT_CONFIG MEMORY CLOCK_MHZ RAM_BYTES BUILD_ROOT PYTHON VIVADO JOBS \
	UART_PORT HW_TARGET RAPT_PROBE_SERIAL OPENOCD,$(eval $(v) := $(strip $($(v)))))
ifeq ($(filter $(XLEN),32 64),)
$(error XLEN must be 32 or 64)
endif
ifeq ($(filter $(MEMORY),ddr bram),)
$(error MEMORY must be ddr or bram)
endif
_quote = '$(subst ','"'"',$(1))'
_ddr := $(if $(filter ddr,$(MEMORY)),1,0)
_main_ram := $(if $(filter ddr,$(MEMORY)),0,$(RAM_BYTES))
_args = FPGA_BOARD=arty_a7_t100 FPGA_AUTO_DETECT=0 VARIANT=linux$(XLEN) \
	RAPT_CONFIG=$(RAPT_CONFIG) SYS_CLK=$(CLOCK_MHZ)000000 \
	WITH_LITEDRAM=$(_ddr) WITH_MIG=0 WITH_SDCARD=0 \
	LINUX_FPGA_PROFILE=$(_ddr) BOOT_MODE=bios \
	INTEGRATED_MAIN_RAM_SIZE=$(_main_ram) WITH_ETHERNET=1 ETH_SPEED=100 \
	$(call _quote,BUILD_DIR=$(abspath $(BUILD_ROOT))) \
	$(call _quote,VIVADO=$(VIVADO)) VIVADO_JOBS=$(JOBS) \
	$(if $(UART_PORT),$(call _quote,UART_PORT=$(UART_PORT))) \
	$(if $(HW_TARGET),$(call _quote,FPGA_HW_TARGET=$(HW_TARGET)))
_targets := info prepare synth build load console linux-image linux-upload reports
_litex_info := info
_litex_prepare := fpga-gen
_litex_synth := fpga-synth
_litex_build := fpga-build
_litex_load := fpga-load
_litex_console := fpga-console
_litex_linux-image := fpga-img-rv$(XLEN)
_litex_linux-upload := fpga-upload
_litex_reports := fpga-reports-index
.PHONY: help $(_targets) debug test
help:
	@echo 'Arty Raptor SoC: info prepare synth build load console linux-image linux-upload'
	@echo '  netboot-{build,load,info,reports,check,bundle,serve,test,console}, debug, test'
	@echo '  XLEN=32|64 RAPT_CONFIG=small MEMORY=ddr|bram CLOCK_MHZ=20|25|50|100'
	@echo '  BUILD_ROOT=path UART_PORT=device HW_TARGET=glob JOBS=4 VIVADO=vivado'
	@echo '  debug: RAPT_PROBE_SERIAL=<CMSIS-DAP serial> (ChipKIT ck13/12/11/10)'
	@echo '  Octal-link fixture: make PLATFORM=octal <original-target> JOIN=internal|pins'
$(_targets):
	+$(MAKE) -C $(LITEX) $(_litex_$@) $(_args)

_netboot := build load info reports check bundle serve test console
.PHONY: $(addprefix netboot-,$(_netboot))
$(addprefix netboot-,$(_netboot)): netboot-%:
	+$(MAKE) -C $(LITEX) fpga-netboot-rv$(XLEN)-$* FPGA_BOARD=arty_a7_t100 \
		RAPT_CONFIG=$(RAPT_CONFIG) $(call _quote,VIVADO=$(VIVADO)) VIVADO_JOBS=$(JOBS) \
		$(call _quote,NETBOOT_BUILD_ROOT=$(abspath $(BUILD_ROOT))/netboot) \
		$(if $(UART_PORT),$(call _quote,NETBOOT_UART=$(UART_PORT)))

debug:
	@test -n $(call _quote,$(RAPT_PROBE_SERIAL)) || { \
		echo 'Set RAPT_PROBE_SERIAL to the CMSIS-DAP CPU JTAG probe serial.'; exit 1; }
	$(OPENOCD) -s scripts -c $(call _quote,set RAPT_PROBE_SERIAL $(RAPT_PROBE_SERIAL)) \
		-f gdb.cfg

test:
	$(PYTHON) -m unittest discover -s $(LITEX)/tests -p test_arty_soc.py -v
else
$(error PLATFORM must be soc, octal or jesd)
endif
