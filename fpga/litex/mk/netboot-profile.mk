# Standalone fixed profile: no hardware probing or normal Makefile parsing here.
SHELL := /bin/bash
_NETBOOT_LITEX := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)
_NETBOOT_ROOT := $(abspath $(_NETBOOT_LITEX)/../..)
-include $(_NETBOOT_LITEX)/netboot.local.mk
NETBOOT_BUILD_ROOT ?= $(_NETBOOT_LITEX)/build/netboot-default
ifeq ($(filter /%,$(NETBOOT_BUILD_ROOT)),)
$(error NETBOOT_BUILD_ROOT must be an absolute path)
endif
NETBOOT_PAYLOAD_RV32 ?= $(_NETBOOT_ROOT)/linux/build/linux-riscv-rv32-qemu-rv32-buildroot-v6.18.50/fw_payload.bin
NETBOOT_PAYLOAD_RV64 ?= $(_NETBOOT_ROOT)/linux/build/linux-riscv-rv64-qemu-rv64-fast-buildroot-v6.18.50/fw_payload.bin
VIVADO ?= vivado
# Do not propagate arbitrary command-line profile overrides into this fixed build.
override MAKEOVERRIDES :=
_nb_quote = '$(subst ','"'"',$(1))'
_nb_targets := $(foreach x,32 64,$(foreach op,build load info check bundle serve run test console,fpga-netboot-rv$(x)-$(op))) fpga-netboot-host-setup fpga-netboot-host-restore
ifneq ($(filter-out $(_nb_targets),$(MAKECMDGOALS)),)
$(error Use only fpga-netboot targets in this invocation)
endif
# Serial execution also prevents a multi-goal build/load race under make -j.
.NOTPARALLEL:
.PHONY: $(_nb_targets)
$(filter fpga-netboot-rv32-%,$(_nb_targets)): _nb_xlen := 32
$(filter fpga-netboot-rv64-%,$(_nb_targets)): _nb_xlen := 64
_nb_dir = $(NETBOOT_BUILD_ROOT)/rv$(_nb_xlen)
_nb_payload = $(NETBOOT_PAYLOAD_RV$(_nb_xlen))
_nb_args = FPGA_BOARD=mlk_cu08_ku15p FPGA_AUTO_DETECT=0 VARIANT=linux$(_nb_xlen) \
 RAPT_CONFIG=default SYS_CLK=50000000 WITH_MIG=1 WITH_LITEDRAM=0 \
 WITH_SDCARD=1 WITH_ETHERNET=1 ETH_SPEED=1000 FMC_SLOT=c ETH_PORT=a \
 BOOT_MODE=bios EXTRA_FLAGS=--sdcard-autoboot LINUX_FPGA_INIT=full \
 CROSS=riscv64-linux-gnu- \
 RAPT_PACK_VFLAGS= \
 LINUX_ISA=rv$(_nb_xlen)imafdc_zicbom_zicntr_zicond_zicsr_zifencei_zcb_zba_zbb_zbc_zbs \
 $(call _nb_quote,LINUX_IMG=$(_nb_payload)) $(call _nb_quote,LINUX_FPGA_PAYLOAD=$(_nb_payload)) \
 LINUX_FPGA_DTB_OFFSET=0x4000000 LINUX_FPGA_DTB_ADDR=0x83f00000 \
 $(call _nb_quote,BUILD_DIR=$(_nb_dir)/build) $(call _nb_quote,FPGA_DIR=$(_nb_dir)/soc) \
 FPGA_FLAVOR_SUFFIX=default-no-ila \
 VIVADO_JOBS=8 VIVADO_ROUTE_DIRECTIVE=Explore $(call _nb_quote,VIVADO=$(VIVADO))

NETBOOT_PYTHON ?= $(_NETBOOT_LITEX)/.venv/bin/python3
NETBOOT_INTERFACE ?=
NETBOOT_UART ?=
NETBOOT_SERVER_IP ?= 192.168.1.100
NETBOOT_HOST_IP ?= 192.168.50.1
NETBOOT_TFTP_ROOT ?= /srv/tftp
NETBOOT_TIMEOUT ?= 2400
NETBOOT_INTERNET ?= 0
fpga-netboot-host-setup fpga-netboot-host-restore: _nb_xlen := 64
_nb_action = $(if $(filter fpga-netboot-host-%,$@),$(patsubst fpga-netboot-%,%,$@),$(patsubst fpga-netboot-rv$(_nb_xlen)-%,%,$@))
$(_nb_targets):
	@$(call _nb_quote,$(NETBOOT_PYTHON)) $(call _nb_quote,$(_NETBOOT_LITEX)/scripts/netboot_flow.py) \
	 $(_nb_action) --xlen $(_nb_xlen) --root $(call _nb_quote,$(NETBOOT_BUILD_ROOT)) \
	 --interface $(call _nb_quote,$(NETBOOT_INTERFACE)) --uart $(call _nb_quote,$(NETBOOT_UART)) \
	 --server-ip $(call _nb_quote,$(NETBOOT_SERVER_IP)) --host-ip $(call _nb_quote,$(NETBOOT_HOST_IP)) \
	 --tftp-root $(call _nb_quote,$(NETBOOT_TFTP_ROOT)) --timeout $(NETBOOT_TIMEOUT) \
	 $(if $(filter 1,$(NETBOOT_INTERNET)),--internet,) -- $(_nb_args)
