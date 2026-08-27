# ==============================================================================
# Shared Linux variables (single source of truth)
#
# Included by both:
#   - linux/Makefile    (download targets, OpenSBI build)
#   - <root>/Makefile   (boot Linux on NEMU/NPC)
#
# LINUX_HOME is derived from this file's own location, so includers don't
# need to set it. Override LINUX_BUILD_VERSION on the command line to switch
# to a different pre-built kernel release.
# ==============================================================================

LINUX_HOME          ?= $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
LINUX_BUILD_VERSION ?= v6.18.39
LINUX_BUILD_VERSION := $(strip $(LINUX_BUILD_VERSION))

# Keep firmware compilation and both device-tree ISA properties in lockstep.
# Zicbom also makes [ms]envcfg architectural state visible to OpenSBI/Linux.
RAPTOR_RV32_ISA := rv32imac_zicbom_zicntr_zicond_zicsr_zifencei_zcb_zba_zbb_zbc_zbs
RAPTOR_RV64_ISA := rv64imac_zicbom_zicntr_zicond_zicsr_zifencei_zcb_zba_zbb_zbc_zbs
RAPTOR_DT_ISA_EXTENSIONS := "i", "m", "a", "c", "zicbom", "zicntr", "zicond", "zicsr", "zifencei", "zcb", "zba", "zbb", "zbc", "zbs"

# Pre-built kernel releases: https://github.com/Kingfish404/linux-build/releases
LINUX_BUILD_DIR     := $(LINUX_HOME)/build
LINUX_BUILD_URL     := https://github.com/Kingfish404/linux-build/releases/download/rv-$(LINUX_BUILD_VERSION)
LINUX_RV32_NAME     := linux-riscv-qemu-rv32-fast-$(LINUX_BUILD_VERSION)
LINUX_RV64_NAME     := linux-riscv-qemu-rv64-m-$(LINUX_BUILD_VERSION)
LINUX_RV32_DIR      := $(LINUX_BUILD_DIR)/$(LINUX_RV32_NAME)
LINUX_RV64_DIR      := $(LINUX_BUILD_DIR)/$(LINUX_RV64_NAME)
LINUX_RV32_PAYLOAD  ?= $(LINUX_RV32_DIR)/fw_payload.bin
LINUX_RV64_PAYLOAD  ?= $(LINUX_RV64_DIR)/fw_payload.bin

# rv32gc (rv32imafd + C) Buildroot image built by third_party/linux-build.
# Hard-float userspace; requires a DTB advertising F/D (see linux-boot-rv32gc).
LINUX_BUILD_GC_DIR  := $(LINUX_HOME)/../third_party/linux-build/dist
LINUX_RV32GC_PAYLOAD ?= $(abspath $(LINUX_BUILD_GC_DIR)/linux-riscv-rv32-qemu-rv32-buildroot-v$(LINUX_BUILD_VERSION)/fw_payload.bin)
LINUX_RV64GC_PAYLOAD ?= $(abspath $(LINUX_BUILD_GC_DIR)/linux-riscv-rv64-qemu-rv64-buildroot-v$(LINUX_BUILD_VERSION)/fw_payload.bin)

# Exported so sub-makes (fpga/litex, etc.) inherit the resolved paths.
export LINUX_BUILD_VERSION
export LINUX_RV32_PAYLOAD
export LINUX_RV64_PAYLOAD
