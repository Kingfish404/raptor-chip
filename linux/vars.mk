# ==============================================================================
# Shared Linux variables (single source of truth)
#
# Included by both:
#   - linux/Makefile    (download targets, OpenSBI build)
#   - <root>/Makefile   (boot Linux on NEMU/NPC)
#
# LINUX_HOME is derived from this file's own location, so includers don't
# need to set it.  The GitHub release tag and the kernel/build version are
# intentionally separate: rv-v6.18.49 publishes assets suffixed with v6.18.49.
# Override both variables and the matching *_SHA256 values when switching to
# a release with different assets.
# ==============================================================================

LINUX_HOME          ?= $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
LINUX_BUILD_RELEASE ?= rv-v6.18.49
LINUX_BUILD_VERSION ?= v6.18.49
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
LINUX_RV32_SHA256   ?= 5b5ec792229e5d2d4d9b343caf1f8fe7354dc870d8a04fdf04edb80041b70c62
LINUX_RV64_SHA256   ?= 527add444c23c7ac58ff0b8abfe4aeefa8086bf188caa8674ea259703476c1b6

# rv32/64gc (IMAFD + C) Buildroot images published by linux-build.
# Use the fast kernel variants by default so RTL simulation can reach userspace
# in a practical time.  Re-wrap their Images with a simulation-specific OpenSBI:
# the release firmware relocates its FDT to 0x82200000, which overlaps both of
# these embedded kernels and silently corrupts their tail.  The generated
# payloads instead reserve the final 64 KiB of the simulated 256 MiB DRAM.
LINUX_RV32GC_NAME := linux-riscv-rv32-qemu-rv32-fast-buildroot-$(LINUX_BUILD_VERSION)
LINUX_RV64GC_NAME := linux-riscv-rv64-qemu-rv64-fast-buildroot-$(LINUX_BUILD_VERSION)
LINUX_RV32GC_DIST_DIR := $(LINUX_BUILD_DIR)/$(LINUX_RV32GC_NAME)
LINUX_RV64GC_DIST_DIR := $(LINUX_BUILD_DIR)/$(LINUX_RV64GC_NAME)
LINUX_RV32GC_IMAGE := $(LINUX_RV32GC_DIST_DIR)/Image
LINUX_RV64GC_IMAGE := $(LINUX_RV64GC_DIST_DIR)/Image
LINUX_RV32GC_SHA256 ?= ad94a6005f45b3577e3d8b53032ce63971ea9c1f9edf510e71546bcecdfcf2ed
LINUX_RV64GC_SHA256 ?= 80261077fc318059577e8c9a9064d1af17989f05ed7fdfe8718b053383b16e4a
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
LINUX_RV32GC_FPGA_SHA256 ?= bf25795b2089ce13418b3964acc804ff13ff73f55b3f40b10999f59c561b1de1

# Exported so sub-makes (fpga/litex, etc.) inherit the resolved paths.
export LINUX_BUILD_RELEASE
export LINUX_BUILD_VERSION
export LINUX_RV32_PAYLOAD
export LINUX_RV64_PAYLOAD
export LINUX_RV32GC_FPGA_PAYLOAD
