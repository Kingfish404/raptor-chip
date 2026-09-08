# ==============================================================================
# Shared Linux variables (single source of truth)
#
# Included by both:
#   - linux/Makefile    (download targets, OpenSBI build)
#   - <root>/Makefile   (boot Linux on NEMU/NPC)
#
# LINUX_HOME is derived from this file's own location, so includers don't
# need to set it.  The GitHub release tag and the kernel/build version are
# intentionally separate: rv-v6.18.50 publishes assets suffixed with v6.18.50.
# Override both variables and the matching *_SHA256 values when switching to
# a release with different assets.
# ==============================================================================

LINUX_HOME          ?= $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
LINUX_BUILD_RELEASE ?= rv-v6.18.50
LINUX_BUILD_VERSION ?= v6.18.50
LINUX_BUILD_RELEASE := $(strip $(LINUX_BUILD_RELEASE))
LINUX_BUILD_VERSION := $(strip $(LINUX_BUILD_VERSION))

# Keep firmware compilation and both device-tree ISA properties in lockstep.
# Zicbom also makes [ms]envcfg architectural state visible to OpenSBI/Linux.
RAPTOR_RV32_ISA := rv32imafdc_zicbom_zicntr_zicond_zicsr_zifencei_zcb_zba_zbb_zbc_zbs
RAPTOR_RV64_ISA := rv64imac_zicbom_zicntr_zicond_zicsr_zifencei_zcb_zba_zbb_zbc_zbs
RAPTOR_DT_ISA_EXTENSIONS := "i", "m", "a", "c", "zicbom", "zicntr", "zicond", "zicsr", "zifencei", "zcb", "zba", "zbb", "zbc", "zbs"

# Pre-built kernel releases: https://github.com/Kingfish404/linux-build/releases
LINUX_BUILD_DIR     := $(LINUX_HOME)/build
LINUX_BUILD_URL     := https://github.com/Kingfish404/linux-build/releases/download/$(LINUX_BUILD_RELEASE)
LINUX_RV32_NAME     := linux-riscv-qemu-rv32-fast-$(LINUX_BUILD_VERSION)
LINUX_RV64_NAME     := linux-riscv-qemu-rv64-m-$(LINUX_BUILD_VERSION)
LINUX_RV32_DIR      := $(LINUX_BUILD_DIR)/$(LINUX_RV32_NAME)
LINUX_RV64_DIR      := $(LINUX_BUILD_DIR)/$(LINUX_RV64_NAME)
LINUX_RV32_PAYLOAD  ?= $(LINUX_RV32_DIR)/fw_payload.bin
LINUX_RV64_PAYLOAD  ?= $(LINUX_RV64_DIR)/fw_payload.bin
LINUX_RV32_SHA256   ?= 6da7fd5c1b481f9fa5d2096709dc9698f52e894fec70a1cfb768334a79f0276b
LINUX_RV64_SHA256   ?= 8f49c16caed287915396d858cc1681d7c137b6208ec35b582afa14e3ac94068a

# rv32/64gc (IMAFD + C) Buildroot images published by linux-build.
# Use the fast kernel variants by default so RTL simulation can reach userspace
# in a practical time.  Re-wrap their Images with a simulation-specific OpenSBI:
# reserve the final 64 KiB of the simulated 256 MiB DRAM for the FDT.
# The v6.18.50 release itself uses a safe +63 MiB FDT offset; this wrapper
# retains the simulator-specific layout used by the Raptor boot targets.
LINUX_RV32GC_NAME := linux-riscv-rv32-qemu-rv32-fast-buildroot-$(LINUX_BUILD_VERSION)
LINUX_RV64GC_NAME := linux-riscv-rv64-qemu-rv64-fast-buildroot-$(LINUX_BUILD_VERSION)
LINUX_RV32GC_DIST_DIR := $(LINUX_BUILD_DIR)/$(LINUX_RV32GC_NAME)
LINUX_RV64GC_DIST_DIR := $(LINUX_BUILD_DIR)/$(LINUX_RV64GC_NAME)
LINUX_RV32GC_IMAGE := $(LINUX_RV32GC_DIST_DIR)/Image
LINUX_RV64GC_IMAGE := $(LINUX_RV64GC_DIST_DIR)/Image
LINUX_RV32GC_SHA256 ?= 678416b5e17ca141e04b34e1c19855870b0e04beb0369c73e6c3a058c67c79fc
LINUX_RV64GC_SHA256 ?= 4a1f992cb7bffd16976b637fbb3b21e492ccdbc40481a31cbf6ad2a5537f8235
LINUX_RV32GC_SIM_PAYLOAD := $(LINUX_HOME)/opensbi/build-rv32gc/platform/generic/firmware/fw_payload.bin
LINUX_RV64GC_SIM_PAYLOAD := $(LINUX_HOME)/opensbi/build-rv64gc/platform/generic/firmware/fw_payload.bin
LINUX_RV32GC_PAYLOAD ?= $(LINUX_RV32GC_SIM_PAYLOAD)
LINUX_RV64GC_PAYLOAD ?= $(LINUX_RV64GC_SIM_PAYLOAD)

# FPGA default: the complete RV32GC Buildroot release (14+ MiB initramfs),
# rather than the small rv32-fast diagnostic payload.  Keep this separate from
# LINUX_RV32GC_PAYLOAD, whose re-wrapped fast image is optimized for simulation.
LINUX_RV32GC_FPGA_NAME := linux-riscv-rv32-qemu-rv32-buildroot-$(LINUX_BUILD_VERSION)
LINUX_RV32GC_FPGA_DIST_DIR := $(LINUX_BUILD_DIR)/$(LINUX_RV32GC_FPGA_NAME)
LINUX_RV32GC_FPGA_PAYLOAD ?= $(LINUX_RV32GC_FPGA_DIST_DIR)/fw_payload.bin
LINUX_RV32GC_FPGA_SHA256 ?= bcd15f97e3eead920b10901eb092f0425ffe9ecc66666a829f2135833a9b867e

# Exported so sub-makes (fpga/litex, etc.) inherit the resolved paths.
export LINUX_BUILD_RELEASE
export LINUX_BUILD_VERSION
export LINUX_RV32_PAYLOAD
export LINUX_RV64_PAYLOAD
export LINUX_RV32GC_FPGA_PAYLOAD
