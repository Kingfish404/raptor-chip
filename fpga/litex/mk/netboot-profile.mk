# Standalone fixed profile: no hardware probing or normal Makefile parsing here.
SHELL := /bin/bash
_NETBOOT_LITEX := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)
_NETBOOT_ROOT := $(abspath $(_NETBOOT_LITEX)/../..)
-include $(_NETBOOT_LITEX)/netboot.local.mk
include $(_NETBOOT_ROOT)/linux/vars.mk
RAPT_CONFIG ?= default
override RAPT_CONFIG := $(strip $(RAPT_CONFIG))
_nb_configs := $(notdir $(patsubst %/rapt_config.svh,%,$(wildcard $(_NETBOOT_ROOT)/hdl/configs/*/rapt_config.svh)))
ifneq ($(filter-out fpga-netboot-host-setup fpga-netboot-host-restore,$(MAKECMDGOALS)),)
ifneq ($(words $(RAPT_CONFIG)),1)
$(error RAPT_CONFIG must name one preset)
endif
ifeq ($(filter $(_nb_configs),$(RAPT_CONFIG)),)
$(error Invalid RAPT_CONFIG='$(RAPT_CONFIG)'. Known presets: $(_nb_configs))
endif
endif
# Custom roots are containers too: presets must never share SoC/receipt paths.
ifeq ($(origin NETBOOT_BUILD_ROOT),undefined)
NETBOOT_BUILD_ROOT = $(_NETBOOT_LITEX)/build/netboot-$(RAPT_CONFIG)
_nb_root = $(NETBOOT_BUILD_ROOT)
else
_nb_root = $(NETBOOT_BUILD_ROOT)/$(RAPT_CONFIG)
endif
# Host networking is shared across presets/XLEN; retain the original journal path.
NETBOOT_STATE_ROOT ?= $(_NETBOOT_LITEX)/build/netboot-default
ifeq ($(filter /%,$(NETBOOT_STATE_ROOT)),)
$(error NETBOOT_STATE_ROOT must be an absolute path)
endif
ifeq ($(filter /%,$(NETBOOT_BUILD_ROOT)),)
$(error NETBOOT_BUILD_ROOT must be an absolute path)
endif
NETBOOT_PAYLOAD_RV32 ?= $(LINUX_RV32GC_FPGA_PAYLOAD)
NETBOOT_PAYLOAD_RV64 ?= $(LINUX_RV64GC_DIST_DIR)/fw_payload.bin
VIVADO ?= vivado
VIVADO_JOBS ?= 8
CROSS ?= riscv64-linux-gnu-
# Do not propagate arbitrary command-line profile overrides into this fixed build.
override MAKEOVERRIDES :=
# Reject conflicting fixed settings instead of silently building other hardware.
_nb_fixed = $(if $(filter undefined,$(origin $(1))),,$(if $(filter-out x$(2),x$(strip $($(1)))),$(error $(1)='$($(1))' conflicts with netboot $(1)='$(2)'; use ordinary fpga-* targets for another hardware profile)))$(1)=$(2)
_nb_quote = '$(subst ','"'"',$(1))'
_nb_targets := $(foreach x,32 64,$(foreach op,build load info check bundle serve test console,fpga-netboot-rv$(x)-$(op))) fpga-netboot-host-setup fpga-netboot-host-restore
ifneq ($(filter-out $(_nb_targets),$(MAKECMDGOALS)),)
$(error Use only fpga-netboot targets in this invocation)
endif
# Serial execution also prevents a multi-goal build/load race under make -j.
.NOTPARALLEL:
.PHONY: $(_nb_targets)
$(filter fpga-netboot-rv32-%,$(_nb_targets)): _nb_xlen := 32
$(filter fpga-netboot-rv64-%,$(_nb_targets)): _nb_xlen := 64
_nb_dir = $(_nb_root)/rv$(_nb_xlen)
_nb_payload = $(NETBOOT_PAYLOAD_RV$(_nb_xlen))
_nb_args = $(call _nb_fixed,FPGA_BOARD,mlk_cu08_ku15p) $(call _nb_fixed,FPGA_AUTO_DETECT,0) $(call _nb_fixed,VARIANT,linux$(_nb_xlen)) \
 $(call _nb_quote,RAPT_CONFIG=$(RAPT_CONFIG)) $(call _nb_fixed,SYS_CLK,50000000) $(call _nb_fixed,WITH_MIG,1) $(call _nb_fixed,WITH_LITEDRAM,0) \
 $(call _nb_fixed,WITH_SDCARD,1) $(call _nb_fixed,WITH_ETHERNET,1) $(call _nb_fixed,ETH_SPEED,1000) $(call _nb_fixed,FMC_SLOT,c) $(call _nb_fixed,ETH_PORT,a) \
 $(call _nb_fixed,BOOT_MODE,bios) $(call _nb_fixed,EXTRA_FLAGS,) $(call _nb_fixed,LINUX_FPGA_INIT,full) \
 $(call _nb_quote,CROSS=$(CROSS)) \
 $(call _nb_fixed,RAPT_PACK_VFLAGS,) \
 $(call _nb_fixed,LINUX_ISA,rv$(_nb_xlen)imafdc_zicbom_zicntr_zicond_zicsr_zifencei_zcb_zba_zbb_zbc_zbs) \
 $(call _nb_quote,LINUX_IMG=$(_nb_payload)) $(call _nb_quote,LINUX_FPGA_PAYLOAD=$(_nb_payload)) \
 $(call _nb_fixed,LINUX_FPGA_DTB_OFFSET,0x4000000) $(call _nb_fixed,LINUX_FPGA_DTB_ADDR,0x83f00000) \
 $(call _nb_quote,BUILD_DIR=$(_nb_dir)/build) $(call _nb_quote,FPGA_DIR=$(_nb_dir)/soc) \
 $(call _nb_fixed,FPGA_FLAVOR_SUFFIX,$(RAPT_CONFIG)-no-ila) \
 $(call _nb_quote,VIVADO_JOBS=$(VIVADO_JOBS)) $(call _nb_fixed,VIVADO_ROUTE_DIRECTIVE,Explore) $(call _nb_quote,VIVADO=$(VIVADO))

NETBOOT_PYTHON ?= $(_NETBOOT_LITEX)/.venv/bin/python3
NETBOOT_INTERFACE ?=
NETBOOT_UART ?= $(UART_PORT)
NETBOOT_SERVER_IP ?= 192.168.1.100
NETBOOT_HOST_IP ?= 192.168.50.1
NETBOOT_TFTP_ROOT ?= /srv/tftp
NETBOOT_INTERNET ?= 0
# Buildroot remains available for diagnostics; distro selection does not change RTL.
NETBOOT_DISTRO_RV32 ?= buildroot
NETBOOT_DISTRO_RV64 ?= alpine
NETBOOT_DISTRO ?= $(NETBOOT_DISTRO_RV$(_nb_xlen))
NETBOOT_DATA_SELECTOR ?= LABEL=RAPTOR_DATA
NETBOOT_PERSIST_LOGS ?= 0
NETBOOT_BASE_DTB ?=
NETBOOT_HARDWARE_REFERENCE ?=
NETBOOT_INITRAMFS_COMPRESSION ?= none
fpga-netboot-host-setup fpga-netboot-host-restore: _nb_xlen := 64
_nb_action = $(if $(filter fpga-netboot-host-%,$@),$(patsubst fpga-netboot-%,%,$@),$(patsubst fpga-netboot-rv$(_nb_xlen)-%,%,$@))
$(_nb_targets):
	@$(if $(filter fpga-netboot-host-%,$@),,$(if $(strip $(BOARD)),$(if $(filter-out mlk_cu08_ku15p,$(strip $(BOARD))),$(error BOARD conflicts with netboot FPGA_BOARD=mlk_cu08_ku15p))))
	@$(call _nb_quote,$(NETBOOT_PYTHON)) $(call _nb_quote,$(_NETBOOT_LITEX)/scripts/netboot_flow.py) \
	 $(_nb_action) --xlen $(_nb_xlen) --root $(call _nb_quote,$(_nb_root)) \
	 --state-root $(call _nb_quote,$(NETBOOT_STATE_ROOT)) \
	 --interface $(call _nb_quote,$(NETBOOT_INTERFACE)) --uart $(call _nb_quote,$(NETBOOT_UART)) \
	 --server-ip $(call _nb_quote,$(NETBOOT_SERVER_IP)) --host-ip $(call _nb_quote,$(NETBOOT_HOST_IP)) \
	 --tftp-root $(call _nb_quote,$(NETBOOT_TFTP_ROOT)) \
	 --distro $(call _nb_quote,$(NETBOOT_DISTRO)) --release $(call _nb_quote,$(LINUX_BUILD_RELEASE)) \
	 --version $(call _nb_quote,$(LINUX_BUILD_VERSION)) \
	 --data-selector $(call _nb_quote,$(NETBOOT_DATA_SELECTOR)) \
	 --initramfs-compression $(call _nb_quote,$(NETBOOT_INITRAMFS_COMPRESSION)) \
	 $(if $(filter 1,$(NETBOOT_PERSIST_LOGS)),--persist-logs,) \
	 $(if $(strip $(NETBOOT_BASE_DTB)),--base-dtb $(call _nb_quote,$(NETBOOT_BASE_DTB)),) \
	 $(if $(strip $(NETBOOT_HARDWARE_REFERENCE)),--hardware-reference $(call _nb_quote,$(NETBOOT_HARDWARE_REFERENCE)),) \
	 $(if $(filter 1,$(NETBOOT_INTERNET)),--internet,) -- $(if $(filter fpga-netboot-host-%,$@),,$(_nb_args))
