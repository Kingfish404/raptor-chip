# Native RK-XCKU5P-F board build.
.DEFAULT_GOAL := help
PYTHON ?= python3
XLEN ?= 64
RAPT_CONFIG ?= small
MEMORY ?= ddr
CLOCK_MHZ ?= 50
RAM_BYTES ?= 131072
USE_RESET_BUTTON ?= 0
WITH_ETHERNET ?= 0
NATIVE_HW_TARGET ?=
DDR_PART ?= MT40A512M16LY-075
CROSS ?= riscv64-unknown-elf-
VIVADO ?= vivado
JOBS ?= 4
BUILD_ROOT ?= $(CURDIR)/build
OPTIONS = --xlen $(XLEN) --preset $(RAPT_CONFIG) --memory $(MEMORY) \
	--clock-mhz $(CLOCK_MHZ) --ram-bytes $(RAM_BYTES) --reset-button $(USE_RESET_BUTTON) \
	--ethernet $(WITH_ETHERNET) \
	--ddr-part '$(DDR_PART)' --cross '$(CROSS)' --vivado '$(VIVADO)' --jobs $(JOBS) \
	--build-root '$(BUILD_ROOT)' $(if $(strip $(NATIVE_HW_TARGET)),--hw-target '$(NATIVE_HW_TARGET)')
RV_ACTIONS := prepare lint test sim ip-check peripheral-synth synth build load info
RV32_TARGETS := $(addprefix fpga-rv32-,$(RV_ACTIONS))
RV64_TARGETS := $(addprefix fpga-rv64-,$(RV_ACTIONS))
NETBOOT_ACTIONS := build load info reports check bundle serve test console
NETBOOT_TARGETS := $(foreach x,32 64,$(addprefix fpga-netboot-rv$(x)-,$(NETBOOT_ACTIONS)))
LITEX_FPGA_TARGETS := fpga-gen fpga-build fpga-build-force fpga-load fpga-console fpga-info fpga-reports-index fpga-timing-ok fpga
UBUNTU_OUTPUT ?= $(CURDIR)/build/ubuntu
UBUNTU_ROOTFS ?= $(UBUNTU_OUTPUT)/rootfs
UBUNTU_SERVER ?= 192.168.50.1
UBUNTU_CLIENT ?= 192.168.50.0/24
UBUNTU_SSH_KEY ?= $(CURDIR)/keys/ubuntu-test.pub
UBUNTU_CROSS ?= riscv64-linux-gnu-
UBUNTU_UPLOAD_BAUD ?= 312500
UBUNTU_TRANSPORT ?= tftp
UBUNTU_BOOT_IP ?= 192.168.50.88
UBUNTU_TFTP_PORT ?= 6969
UART_PORT ?=
SUDO ?= sudo
UBUNTU_OPTIONS = --output '$(UBUNTU_OUTPUT)' --rootfs '$(UBUNTU_ROOTFS)' \
	--server '$(UBUNTU_SERVER)' --client '$(UBUNTU_CLIENT)' --cross '$(UBUNTU_CROSS)' \
	--jobs $(JOBS) --preset '$(RAPT_CONFIG)' --clock-mhz $(CLOCK_MHZ) \
	--native-build-root '$(BUILD_ROOT)' \
	$(if $(UBUNTU_SSH_KEY),--ssh-key '$(UBUNTU_SSH_KEY)')
UBUNTU_ACTIONS := kernel rootfs bundle check serve unserve boot
UBUNTU_TARGETS := $(addprefix ubuntu-,$(UBUNTU_ACTIONS))
UBUNTU_FPGA_TARGETS := ubuntu-fpga-build ubuntu-fpga-load ubuntu-fpga-info
.PHONY: help prepare refresh-software lint test sim ip-check peripheral-synth synth build load info \
	$(RV32_TARGETS) $(RV64_TARGETS) $(NETBOOT_TARGETS) $(LITEX_FPGA_TARGETS) \
	fpga-netboot-host-setup fpga-netboot-host-restore $(UBUNTU_TARGETS) $(UBUNTU_FPGA_TARGETS) ethernet-test ubuntu-test
help:
	@echo 'Native RK-XCKU5P-F: prepare refresh-software lint test sim ip-check peripheral-synth synth build load info'
	@echo 'RV shortcuts: fpga-rv{32,64}-{prepare,lint,test,sim,ip-check,peripheral-synth,synth,build,load,info}'
	@echo 'LiteX SoC: fpga-gen fpga-build fpga-load fpga-console fpga-info fpga-reports-index fpga-timing-ok'
	@echo 'DDR4 + onboard Ethernet: fpga-netboot-rv{32,64}-{build,load,info,reports,check,bundle,serve,test,console}'
	@echo 'Default: RV64, DDR, 50 MHz, RAPT_CONFIG=small; use MEMORY=bram for BRAM bring-up.'
	@echo 'Example: make fpga-rv64-build RAPT_CONFIG=small'
	@echo 'build routes and timing-gates the bitstream; load only programs a matching validated build.'
	@echo 'Native Ubuntu: ubuntu-fpga-{build,load,info}, ubuntu-{kernel,rootfs,bundle,check,serve,unserve,boot}'
	@echo 'ubuntu-boot UART_PORT=/dev/serial/by-id/...; ethernet-test runs packet/MAC regressions.'
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

# Native Ubuntu targets never dispatch to the LiteX SoC or netboot wrappers.
$(UBUNTU_TARGETS) $(UBUNTU_FPGA_TARGETS): RAPT_CONFIG = small-cache16
$(UBUNTU_FPGA_TARGETS): override XLEN := 64
$(UBUNTU_FPGA_TARGETS): override MEMORY := ddr
$(UBUNTU_FPGA_TARGETS): override WITH_ETHERNET := 1
$(UBUNTU_FPGA_TARGETS):
	$(PYTHON) build.py $(OPTIONS) $(patsubst ubuntu-fpga-%,%,$@)
ubuntu-kernel ubuntu-bundle ubuntu-check ubuntu-serve ubuntu-unserve:
	$(PYTHON) scripts/ubuntu.py $(patsubst ubuntu-%,%,$@) $(UBUNTU_OPTIONS)
ubuntu-rootfs:
	$(SUDO) $(PYTHON) scripts/ubuntu.py rootfs $(UBUNTU_OPTIONS)
ubuntu-boot:
	$(PYTHON) scripts/ubuntu.py boot $(UBUNTU_OPTIONS) --port '$(UART_PORT)' \
		--upload-baud $(UBUNTU_UPLOAD_BAUD) --transport $(UBUNTU_TRANSPORT) \
		--boot-ip $(UBUNTU_BOOT_IP) --tftp-port $(UBUNTU_TFTP_PORT) --console
ethernet-test:
	$(PYTHON) scripts/test_ethernet.py
ubuntu-test:
	$(PYTHON) -m unittest discover -s tests -p 'test_*.py' -v
