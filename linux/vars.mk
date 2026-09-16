# ==============================================================================
# Shared Linux variables (single source of truth)
#
# Included by both:
#   - linux/Makefile    (download targets, OpenSBI build)
#   - <root>/Makefile   (boot Linux on NEMU/NPC)
#
# LINUX_HOME is derived from this file's own location, so includers don't
# need to set it.  The GitHub release tag and the kernel/build version are
# intentionally separate: rv-v6.18.51 publishes assets suffixed with v6.18.51.
# Override both variables and the matching *_SHA256 values when switching to
# a release with different assets.
# ==============================================================================

LINUX_HOME          ?= $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
LINUX_BUILD_RELEASE ?= rv-v6.18.51
LINUX_BUILD_VERSION ?= v6.18.51
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
LINUX_RV32_SHA256   ?= e72a227909ab699e70efd5ef5b6c43e7d152af28f5d6492393d883a3fa01c120
LINUX_RV64_SHA256   ?= aa2d30fbb9e80f388b0f0964556144944cffa46ea2fe53dd7216299f06cfcd86

# rv32/64gc (IMAFD + C) Buildroot images published by linux-build.
# Use the fast kernel variants by default so RTL simulation can reach userspace
# in a practical time.  Re-wrap their Images with a simulation-specific OpenSBI:
# reserve the final 64 KiB of the simulated 256 MiB DRAM for the FDT.
# The v6.18.51 release itself uses a safe +63 MiB FDT offset; this wrapper
# retains the simulator-specific layout used by the Raptor boot targets.
LINUX_RV32GC_NAME := linux-riscv-rv32-qemu-rv32-fast-buildroot-$(LINUX_BUILD_VERSION)
LINUX_RV64GC_NAME := linux-riscv-rv64-qemu-rv64-fast-buildroot-$(LINUX_BUILD_VERSION)
LINUX_RV32GC_DIST_DIR := $(LINUX_BUILD_DIR)/$(LINUX_RV32GC_NAME)
LINUX_RV64GC_DIST_DIR := $(LINUX_BUILD_DIR)/$(LINUX_RV64GC_NAME)
LINUX_RV32GC_IMAGE := $(LINUX_RV32GC_DIST_DIR)/Image
LINUX_RV64GC_IMAGE := $(LINUX_RV64GC_DIST_DIR)/Image
LINUX_RV32GC_SHA256 ?= bd6683b6685dcef54f6a5c11eaaa8a869a463f44f31343fbe5219e852d617f68
LINUX_RV64GC_SHA256 ?= e3a39cc1c569c580a0df4a3cde555acc98c1957f775b1fdc8c82929dc06e8608
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
LINUX_RV32GC_FPGA_SHA256 ?= f2f5036be35f3e8c0f8d64e6480406436f70e8fbf73729442f7f83660c235399

# Exported so sub-makes (fpga/litex, etc.) inherit the resolved paths.
export LINUX_BUILD_RELEASE
export LINUX_BUILD_VERSION
export LINUX_RV32_PAYLOAD
export LINUX_RV64_PAYLOAD
export LINUX_RV32GC_FPGA_PAYLOAD

# RV64 alpine: disk package; converted to RAM root for FPGA netboot.
LINUX_RV64_ALPINE_NAME := linux-riscv-qemu-rv64-alpine-$(LINUX_BUILD_VERSION)
LINUX_RV64_ALPINE_DIR := $(LINUX_BUILD_DIR)/$(LINUX_RV64_ALPINE_NAME)
LINUX_RV64_ALPINE_SHA256 ?= 2289209dc757697db462fd3ddd030d20d237766a3fcc46a13109744d6fd140aa

# RV64 debian: disk package; converted to RAM root for FPGA netboot.
LINUX_RV64_DEBIAN_NAME := linux-riscv-qemu-rv64-debian-$(LINUX_BUILD_VERSION)
LINUX_RV64_DEBIAN_DIR := $(LINUX_BUILD_DIR)/$(LINUX_RV64_DEBIAN_NAME)
LINUX_RV64_DEBIAN_SHA256 ?= 60f30aaac286cfcbb4ae638ec4e62b9503dcd89874192b7732dff8e49ed2ed76
