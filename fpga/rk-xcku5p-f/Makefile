# Native RK-XCKU5P-F board build.
.DEFAULT_GOAL := help
PYTHON ?= python3
XLEN ?= 64
RAPT_CONFIG ?= small
MEMORY ?= ddr
CLOCK_MHZ ?= 50
RAM_BYTES ?= 131072
USE_RESET_BUTTON ?= 0
DDR_PART ?= MT40A512M16LY-075
CROSS ?= riscv64-unknown-elf-
VIVADO ?= vivado
JOBS ?= 4
BUILD_ROOT ?= $(CURDIR)/build
OPTIONS = --xlen $(XLEN) --preset $(RAPT_CONFIG) --memory $(MEMORY) \
	--clock-mhz $(CLOCK_MHZ) --ram-bytes $(RAM_BYTES) --reset-button $(USE_RESET_BUTTON) \
	--ddr-part '$(DDR_PART)' --cross '$(CROSS)' --vivado '$(VIVADO)' --jobs $(JOBS) \
	--build-root '$(BUILD_ROOT)'
RV_ACTIONS := prepare lint test sim ip-check peripheral-synth synth build load info
RV32_TARGETS := $(addprefix fpga-rv32-,$(RV_ACTIONS))
RV64_TARGETS := $(addprefix fpga-rv64-,$(RV_ACTIONS))
NETBOOT_ACTIONS := build load info reports check bundle serve test console
NETBOOT_TARGETS := $(foreach x,32 64,$(addprefix fpga-netboot-rv$(x)-,$(NETBOOT_ACTIONS)))
LITEX_FPGA_TARGETS := fpga-gen fpga-build fpga-build-force fpga-load fpga-console fpga-info fpga-reports-index fpga-timing-ok fpga
.PHONY: help prepare refresh-software lint test sim ip-check peripheral-synth synth build load info \
	$(RV32_TARGETS) $(RV64_TARGETS) $(NETBOOT_TARGETS) $(LITEX_FPGA_TARGETS) \
	fpga-netboot-host-setup fpga-netboot-host-restore
help:
	@echo 'Native RK-XCKU5P-F: prepare refresh-software lint test sim ip-check peripheral-synth synth build load info'
	@echo 'RV shortcuts: fpga-rv{32,64}-{prepare,lint,test,sim,ip-check,peripheral-synth,synth,build,load,info}'
	@echo 'LiteX SoC: fpga-gen fpga-build fpga-load fpga-console fpga-info fpga-reports-index fpga-timing-ok'
	@echo 'DDR4 + onboard Ethernet: fpga-netboot-rv{32,64}-{build,load,info,reports,check,bundle,serve,test,console}'
	@echo 'Default: RV64, DDR, 50 MHz, RAPT_CONFIG=small; use MEMORY=bram for BRAM bring-up.'
	@echo 'Example: make fpga-rv64-build RAPT_CONFIG=small'
	@echo 'build routes and timing-gates the bitstream; load only programs a matching validated build.'
prepare refresh-software lint test sim ip-check peripheral-synth synth build load info:
	$(PYTHON) build.py $(OPTIONS) $@
$(RV32_TARGETS): override XLEN := 32
$(RV64_TARGETS): override XLEN := 64
$(RV32_TARGETS) $(RV64_TARGETS):
	$(PYTHON) build.py $(OPTIONS) $(patsubst fpga-rv32-%,%,$(patsubst fpga-rv64-%,%,$@))
$(LITEX_FPGA_TARGETS):
	$(MAKE) -C ../litex $(if $(filter fpga-info,$@),info,$@) FPGA_BOARD=rk_xcku5p_f FPGA_AUTO_DETECT=0
$(NETBOOT_TARGETS) fpga-netboot-host-setup fpga-netboot-host-restore:
	$(MAKE) -C ../litex $@ FPGA_BOARD=rk_xcku5p_f
