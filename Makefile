# ============================================================================
# Environment variables (auto-sourced from env.sh, no manual `source` needed)
# ============================================================================
export YSYX_HOME := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
export NEMU_HOME := $(YSYX_HOME)/nemu
export NSIM_HOME := $(YSYX_HOME)/nsim
export AM_HOME   := $(YSYX_HOME)/abstract-machine
export NAVY_HOME := $(YSYX_HOME)/navy-apps
export NVBOARD_HOME := $(YSYX_HOME)/third_party/NJU-ProjectN/nvboard
export CROSS_COMPILE ?= riscv64-elf-

# Default to batch mode (no interactive prompt). Override with ARGS="" to disable.
ARGS ?= -b

# ============================================================================
# Guard: only define project-level targets when invoked from root directory.
# Subprojects (nsim, nemu) include this file for env vars only.
# ============================================================================
ifeq ($(abspath $(dir $(firstword $(MAKEFILE_LIST)))),$(YSYX_HOME))

NPROC := $(shell nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

# ============================================================================
# Default target
# ============================================================================
.DEFAULT_GOAL := help

help:
	@echo ""
	@echo "Raptor Project - RISC-V Processor"
	@echo "=================================="
	@echo ""
	@echo "Setup:"
	@echo "  make setup              - Install dependencies and initialize workspace"
	@echo ""
	@echo "RTL Generation:"
	@echo "  make verilog            - Generate SystemVerilog from Chisel (Scala)"
	@echo ""
	@echo "NEMU (Software Emulator) - RV32:"
	@echo "  make config-nemu32      - Configure NEMU (riscv32 default)"
	@echo "  make build-nemu32       - Build NEMU"
	@echo "  make run-nemu32         - Build and run NEMU"
	@echo "  make menuconfig-nemu32  - Open NEMU menuconfig"
	@echo ""
	@echo "NEMU (Software Emulator) - RV64:"
	@echo "  make config-nemu64      - Configure NEMU (riscv64)"
	@echo "  make build-nemu64       - Build NEMU (riscv64)"
	@echo "  make run-nemu64         - Build and run NEMU (riscv64)"
	@echo ""
	@echo "NEMU Device Mode (interactive, VGA + keyboard):"
	@echo "  make run-nemu32-linux-device   - Run NEMU RV32 with VGA screen + keyboard"
	@echo "  make run-nemu64-linux-device   - Run NEMU RV64 with VGA screen + keyboard"
	@echo "  make linux-boot-nemu32-device  - Boot Linux on NEMU RV32 (auto-download)"
	@echo "  make linux-boot-nemu64-device  - Boot Linux on NEMU RV64 (auto-download)"
	@echo ""
	@echo "NPC Simulation (Verilator) - RV32:"
	@echo "  make config-npc32       - Configure NPC simulator (o2 default)"
	@echo "  make build-npc32        - Build NPC simulator"
	@echo "  make run-npc32          - Build and run NPC simulator"
	@echo "  make menuconfig-npc32   - Open NPC menuconfig"
	@echo "  make sim-npc32          - Shortcut: verilog + config + build + run"
	@echo ""
	@echo "NPC Simulation (Verilator) - RV64:"
	@echo "  make build-npc64        - Build NPC in RV64 mode"
	@echo "  make run-npc64          - Build and run NPC in RV64 mode"
	@echo "  make lint-npc64         - Lint RTL in RV64 mode"
	@echo "  (Or: make run-npc32 VFLAGS=\"-DYSYX_RV64\")"
	@echo ""
	@echo "AM Kernels / Benchmarks:"
	@echo "  make coremark-npc32     - Run CoreMark on NPC (riscv32e-npc)"
	@echo "  make microbench-npc32   - Run MicroBench on NPC (riscv32e-npc)"
	@echo "  make coremark-npc64     - Run CoreMark on NPC (riscv64-npc)"
	@echo "  make microbench-npc64   - Run MicroBench on NPC (riscv64-npc)"
	@echo "  make coremark-npc32-difftest  \t- Run CoreMark on NPC with difftest"
	@echo "  make microbench-npc32-difftest \t- Run MicroBench on NPC with difftest"
	@echo "  make coremark-ysyxsoc   - Run CoreMark on ysyxSoC"
	@echo "  make microbench-ysyxsoc - Run MicroBench on ysyxSoC"
	@echo "  make coremark-nemu32    - Run CoreMark on NEMU"
	@echo "  make microbench-nemu32  - Run MicroBench on NEMU"
	@echo "  make coremark-nemu64    - Run CoreMark on NEMU (riscv64)"
	@echo "  make microbench-nemu64  - Run MicroBench on NEMU (riscv64)"
	@echo ""
	@echo "Nanos-lite OS:"
	@echo "  make nanos-nemu32       - Build and run nanos-lite on NEMU"
	@echo "  make nanos-npc32        - Build and run nanos-lite on NPC"
	@echo ""
	@echo "Linux Kernel:"
	@echo "  make linux-download     - Download pre-built Linux (RV32 + RV64)"
	@echo "  make linux-download-rv32 - Download pre-built Linux (RV32 only)"
	@echo "  make linux-download-rv64 - Download pre-built Linux (RV64 only)"
	@echo "  make linux-boot-nemu32  - Boot Linux on NEMU (via OpenSBI, old payload)"
	@echo "  make linux-boot-npc32   - Boot Linux on NPC"
	@echo "  make linux-boot-nemu32-device  - Boot Linux on NEMU RV32 (auto-download)"
	@echo "  make linux-boot-nemu64-device  - Boot Linux on NEMU RV64 (auto-download)"
	@echo ""
	@echo "FPGA:"
	@echo "  make fpga-syn           - Synthesize for Gowin Tang Nano 20K"
	@echo "  make fpga-pnr           - Place and route for FPGA"
	@echo ""
	@echo "Utilities:"
	@echo "  make pack               - Pack all SV files into one"
	@echo "  make sta                - Static timing analysis"
	@echo "  make lint               - Lint RTL with Verilator"
	@echo "  make clean-npc          - Clean NPC build only (nsim)"
	@echo "  make clean              - Clean all build artifacts"
	@echo ""
	@echo "Args:"
	@echo "  ARGS=\"-b -n\"          - Pass args to runner (-b: batch [default], -n: no wave)"
	@echo "  DEVICE_ARGS=\"\"        - Args for -device targets (interactive by default)"
	@echo "  IMG=path/to/image       - Specify a custom image to load"
	@echo "  ARCH=riscv32e-npc       - Override ARCH for AM targets"
	@echo "  VFLAGS=\"-DYSYX_RV64\"  - Enable RV64 mode for NPC/lint targets"
	@echo "  (Switching between RV32/RV64 auto-invalidates the build cache.)"
	@echo ""

# ============================================================================
# Setup
# ============================================================================
setup:
	bash ./setup.sh

# ============================================================================
# RTL Generation (Chisel -> SystemVerilog)
# ============================================================================
verilog:
	$(MAKE) -C $(YSYX_HOME)/rtl_scala verilog

# ============================================================================
# NEMU Targets
# ============================================================================
NEMU_DEFCONFIG ?= riscv32_defconfig

config-nemu32:
	$(MAKE) -C $(NEMU_HOME) $(NEMU_DEFCONFIG)
	$(MAKE) -C $(NEMU_HOME) -j$(NPROC)

config-nemu32-linux:
	$(MAKE) -C $(NEMU_HOME) riscv32_linux_defconfig
	$(MAKE) -C $(NEMU_HOME) -j$(NPROC)

config-nemu32-ref:
	$(MAKE) -C $(NEMU_HOME) riscv32_ref_defconfig
	$(MAKE) -C $(NEMU_HOME) -j$(NPROC)

menuconfig-nemu32:
	$(MAKE) -C $(NEMU_HOME) menuconfig

build-nemu32: config-nemu32
	$(MAKE) -C $(NEMU_HOME) -j$(NPROC)

run-nemu32: build-nemu32
	$(MAKE) -C $(NEMU_HOME) run $(if $(IMG),IMG=$(IMG)) ARGS="$(ARGS)"
	$(MAKE) -C $(NEMU_HOME) -j$(NPROC)

run-nemu32-linux:
	$(MAKE) -C $(NEMU_HOME) riscv32_linux_defconfig
	$(MAKE) -C $(NEMU_HOME) -j$(NPROC)
	$(MAKE) -C $(NEMU_HOME) run $(if $(IMG),IMG=$(IMG)) ARGS="$(ARGS)"

config-nemu32-linux-device:
	$(MAKE) -C $(NEMU_HOME) riscv32_linux_device_defconfig
	$(MAKE) -C $(NEMU_HOME) -j$(NPROC)

DEVICE_ARGS ?= -b

run-nemu32-linux-device:
	$(MAKE) -C $(NEMU_HOME) riscv32_linux_device_defconfig
	$(MAKE) -C $(NEMU_HOME) -j$(NPROC)
	$(MAKE) -C $(NEMU_HOME) run $(if $(IMG),IMG=$(IMG)) ARGS="$(DEVICE_ARGS)"

# --- RV64 NEMU targets ---
config-nemu64:
	$(MAKE) -C $(NEMU_HOME) riscv64_defconfig
	$(MAKE) -C $(NEMU_HOME) -j$(NPROC)

config-nemu64-ref:
	$(MAKE) -C $(NEMU_HOME) riscv64_ref_defconfig
	$(MAKE) -C $(NEMU_HOME) -j$(NPROC)

build-nemu64: config-nemu64
	$(MAKE) -C $(NEMU_HOME) -j$(NPROC)

run-nemu64: build-nemu64
	$(MAKE) -C $(NEMU_HOME) run $(if $(IMG),IMG=$(IMG)) ARGS="$(ARGS)"

config-nemu64-linux-device:
	$(MAKE) -C $(NEMU_HOME) riscv64_linux_device_defconfig
	$(MAKE) -C $(NEMU_HOME) -j$(NPROC)

run-nemu64-linux-device:
	$(MAKE) -C $(NEMU_HOME) riscv64_linux_device_defconfig
	$(MAKE) -C $(NEMU_HOME) -j$(NPROC)
	$(MAKE) -C $(NEMU_HOME) run $(if $(IMG),IMG=$(IMG)) ARGS="$(DEVICE_ARGS)"

# ============================================================================
# NPC Simulation Targets
# ============================================================================
NPC_DEFCONFIG ?= o2_defconfig
NPC_ARCH ?= riscv32e-npc
YSYXSOC_ARCH ?= riscv32e-ysyxsoc

# RV64 mode: set via `make run-npc64` or explicitly `make run-npc32 VFLAGS="-DYSYX_RV64"`
VFLAGS ?=

config-npc32:
	$(MAKE) -C $(NSIM_HOME) $(NPC_DEFCONFIG)

config-npc32-difftest:
	$(MAKE) -C $(NSIM_HOME) o2_difftest_defconfig
	$(MAKE) -C $(NSIM_HOME) -j$(NPROC)

config-npc32-linux:
	$(MAKE) -C $(NSIM_HOME) o2linux_defconfig
	$(MAKE) -C $(NSIM_HOME) -j$(NPROC)

config-npc32-linux-difftest:
	$(MAKE) -C $(NSIM_HOME) o2linux_difftest_defconfig
	$(MAKE) -C $(NSIM_HOME) -j$(NPROC)

config-npc32-ysyxsoc:
	$(MAKE) -C $(NSIM_HOME) o2soc_defconfig
	$(MAKE) -C $(NSIM_HOME) -j$(NPROC)

menuconfig-npc32:
	$(MAKE) -C $(NSIM_HOME) menuconfig
	$(MAKE) -C $(NSIM_HOME) -j$(NPROC)

# Auto-generate RTL from Chisel if generated/ doesn't exist
GENERATED_DIR := $(YSYX_HOME)/rtl_sv/generated

$(GENERATED_DIR):
	$(MAKE) verilog

build-npc32: config-npc32 | $(GENERATED_DIR)
	$(MAKE) -C $(NSIM_HOME) -j$(NPROC) VFLAGS="$(VFLAGS)"

run-npc32: build-npc32
	$(MAKE) -C $(NSIM_HOME) run ARGS="$(ARGS)" VFLAGS="$(VFLAGS)" $(if $(IMG),IMG=$(IMG))

sim-npc32: verilog config-npc32 build-npc32
	$(MAKE) -C $(NSIM_HOME) run ARGS="$(ARGS)" VFLAGS="$(VFLAGS)" $(if $(IMG),IMG=$(IMG))

# --- RV64 convenience targets (equivalent to VFLAGS="-DYSYX_RV64") ---
build-npc64: VFLAGS := -DYSYX_RV64
build-npc64: build-npc32

run-npc64: VFLAGS := -DYSYX_RV64
run-npc64: run-npc32

lint-npc64: VFLAGS := -DYSYX_RV64
lint-npc64: lint

# ============================================================================
# AM Kernels / Benchmarks
# ============================================================================
AM_KERNELS = $(YSYX_HOME)/am-kernels

$(AM_KERNELS):
	git clone https://github.com/kingfish404/am-kernels $@

MAINARGS ?= test

coremark-nemu32: $(AM_KERNELS) config-nemu32
	$(MAKE) -C $(AM_KERNELS)/benchmarks/coremark_eembc ARCH=riscv32-nemu run ARGS="$(ARGS)"

microbench-nemu32: $(AM_KERNELS) config-nemu32
	$(MAKE) -C $(AM_KERNELS)/benchmarks/microbench ARCH=riscv32-nemu run ARGS="$(ARGS)" mainargs=$(MAINARGS)

coremark-nemu64: $(AM_KERNELS) config-nemu64
	$(MAKE) -C $(AM_KERNELS)/benchmarks/coremark_eembc ARCH=riscv64-nemu run ARGS="$(ARGS)"

microbench-nemu64: $(AM_KERNELS) config-nemu64
	$(MAKE) -C $(AM_KERNELS)/benchmarks/microbench ARCH=riscv64-nemu run ARGS="$(ARGS)" mainargs=$(MAINARGS)

am-tests-nemu32: build-nemu32
	$(MAKE) -C $(AM_KERNELS)/tests/am-tests ARCH=riscv32-nemu run ARGS="$(ARGS)" mainargs="i" VME=1

am-tests-npc32: build-npc32
	$(MAKE) -C $(AM_KERNELS)/tests/am-tests ARCH=$(NPC_ARCH) run ARGS="$(ARGS)" mainargs="i" VME=1

cpu-tests-nemu32: build-nemu32
	$(MAKE) -C $(AM_KERNELS)/tests/cpu-tests ARCH=riscv32-nemu run ARGS="$(ARGS)" mainargs="i" VME=1

cpu-tests-npc32: build-npc32
	$(MAKE) -C $(AM_KERNELS)/tests/cpu-tests ARCH=$(NPC_ARCH) run ARGS="$(ARGS)" mainargs="i" VME=1

coremark-npc32: $(AM_KERNELS) config-npc32
	$(MAKE) -C $(AM_KERNELS)/benchmarks/coremark_eembc ARCH=$(NPC_ARCH) run ARGS="$(ARGS)"

coremark-npc32-difftest: $(AM_KERNELS) config-npc32-difftest config-nemu32-ref
	$(MAKE) -C $(AM_KERNELS)/benchmarks/coremark_eembc ARCH=$(NPC_ARCH) run ARGS="$(ARGS)" mainargs=test

coremark-ysyxsoc: $(AM_KERNELS) config-npc32-ysyxsoc config-nemu32-ref
	$(MAKE) -C $(AM_KERNELS)/benchmarks/coremark_eembc ARCH=$(YSYXSOC_ARCH) run ARGS="$(ARGS)" mainargs=test

microbench-npc32: $(AM_KERNELS) config-npc32
	$(MAKE) -C $(AM_KERNELS)/benchmarks/microbench ARCH=$(NPC_ARCH) run ARGS="$(ARGS)" mainargs=$(MAINARGS)

micorbench-npc32-difftest: $(AM_KERNELS) config-npc32-difftest config-nemu32-ref
	$(MAKE) -C $(AM_KERNELS)/benchmarks/microbench ARCH=$(NPC_ARCH) run ARGS="$(ARGS)" mainargs=$(MAINARGS)

# --- RV64 benchmark targets ---
coremark-npc64: VFLAGS := -DYSYX_RV64
coremark-npc64: $(AM_KERNELS) config-npc32
	$(MAKE) -C $(AM_KERNELS)/benchmarks/coremark_eembc ARCH=riscv64-npc run ARGS="$(ARGS)" VFLAGS="$(VFLAGS)"

coremark-npc64-difftest: VFLAGS := -DYSYX_RV64
coremark-npc64-difftest: $(AM_KERNELS) config-npc32-difftest config-nemu32-ref
	$(MAKE) -C $(AM_KERNELS)/benchmarks/coremark_eembc ARCH=riscv64-npc run ARGS="$(ARGS)" VFLAGS="$(VFLAGS)"

microbench-npc64: VFLAGS := -DYSYX_RV64
microbench-npc64: $(AM_KERNELS) config-npc32
	$(MAKE) -C $(AM_KERNELS)/benchmarks/microbench ARCH=riscv64-npc run ARGS="$(ARGS)" VFLAGS="$(VFLAGS)" mainargs=$(MAINARGS)

microbench-npc64-difftest: VFLAGS := -DYSYX_RV64
microbench-npc64-difftest: $(AM_KERNELS) config-npc32-difftest config-nemu32-ref
	$(MAKE) -C $(AM_KERNELS)/benchmarks/microbench ARCH=riscv64-npc run ARGS="$(ARGS)" VFLAGS="$(VFLAGS)" mainargs=$(MAINARGS)

microbench-npc32-difftest: $(AM_KERNELS) config-npc32-difftest config-nemu32-ref
	$(MAKE) -C $(AM_KERNELS)/benchmarks/microbench ARCH=$(NPC_ARCH) run ARGS="$(ARGS)" mainargs=test

microbench-ysyxsoc: $(AM_KERNELS) config-npc32-ysyxsoc config-nemu32-ref
	$(MAKE) -C $(AM_KERNELS)/benchmarks/microbench ARCH=$(YSYXSOC_ARCH) run ARGS="$(ARGS)" mainargs=test

# ============================================================================
# Nanos-lite OS
# ============================================================================
ISA ?= riscv32

nanos-nemu32:
	$(MAKE) -C $(NAVY_HOME) ISA=$(ISA) fsimg
	$(MAKE) -C $(NAVY_HOME)/apps/menu ISA=$(ISA) install
	$(MAKE) -C $(YSYX_HOME)/nanos-lite ARCH=$(ISA)-nemu update run

nanos-npc32:
	$(MAKE) -C $(NAVY_HOME) ISA=$(ISA) fsimg
	$(MAKE) -C $(NAVY_HOME)/apps/menu ISA=$(ISA) install
	$(MAKE) -C $(YSYX_HOME)/nanos-lite ARCH=$(ISA)-npc update run

# ============================================================================
# Linux Kernel Boot (via OpenSBI on NEMU)
# ============================================================================
OPENSBI_PAYLOAD ?= $(YSYX_HOME)/third_party/riscv-software-src/opensbi/build/platform/generic/firmware/fw_payload.bin

# Pre-built Linux kernel downloads (from https://github.com/Kingfish404/linux-build/releases)
LINUX_BUILD_VERSION ?= v6.18.15
LINUX_BUILD_DIR     := $(YSYX_HOME)/linux/build
LINUX_BUILD_URL     := https://github.com/Kingfish404/linux-build/releases/download/$(LINUX_BUILD_VERSION)
LINUX_RV32_DIR      := $(LINUX_BUILD_DIR)/linux-riscv-rv32-$(LINUX_BUILD_VERSION)
LINUX_RV64_DIR      := $(LINUX_BUILD_DIR)/linux-riscv-rv64-$(LINUX_BUILD_VERSION)
LINUX_RV32_PAYLOAD  ?= $(LINUX_RV32_DIR)/fw_payload.bin
LINUX_RV64_PAYLOAD  ?= $(LINUX_RV64_DIR)/fw_payload.bin

$(LINUX_RV32_DIR)/fw_payload.bin:
	@mkdir -p $(LINUX_BUILD_DIR)
	curl -L -o $(LINUX_BUILD_DIR)/linux-riscv-rv32-$(LINUX_BUILD_VERSION).tar.gz \
		$(LINUX_BUILD_URL)/linux-riscv-rv32-$(LINUX_BUILD_VERSION).tar.gz
	tar xzf $(LINUX_BUILD_DIR)/linux-riscv-rv32-$(LINUX_BUILD_VERSION).tar.gz -C $(LINUX_BUILD_DIR)
	@echo "RV32 Linux build extracted to $(LINUX_RV32_DIR)"

$(LINUX_RV64_DIR)/fw_payload.bin:
	@mkdir -p $(LINUX_BUILD_DIR)
	curl -L -o $(LINUX_BUILD_DIR)/linux-riscv-rv64-$(LINUX_BUILD_VERSION).tar.gz \
		$(LINUX_BUILD_URL)/linux-riscv-rv64-$(LINUX_BUILD_VERSION).tar.gz
	tar xzf $(LINUX_BUILD_DIR)/linux-riscv-rv64-$(LINUX_BUILD_VERSION).tar.gz -C $(LINUX_BUILD_DIR)
	@echo "RV64 Linux build extracted to $(LINUX_RV64_DIR)"

linux-download-rv32: $(LINUX_RV32_DIR)/fw_payload.bin
linux-download-rv64: $(LINUX_RV64_DIR)/fw_payload.bin
linux-download: linux-download-rv32 linux-download-rv64
	@echo "Downloaded Linux $(LINUX_BUILD_VERSION) for RV32 and RV64"
	@echo "  RV32: $(LINUX_RV32_DIR)/"
	@echo "  RV64: $(LINUX_RV64_DIR)/"
	@cat $(LINUX_RV32_DIR)/README.md

linux-boot-nemu32: config-nemu32-linux
	$(MAKE) -C $(NEMU_HOME) -j$(NPROC)
	$(MAKE) -C $(NEMU_HOME) run IMG=$(OPENSBI_PAYLOAD) ARGS="$(ARGS)"

linux-boot-npc32: config-npc32-linux
	$(MAKE) -C $(NSIM_HOME) -j$(NPROC)
	$(MAKE) -C $(NSIM_HOME) run IMG=$(OPENSBI_PAYLOAD) ARGS="$(ARGS)"

linux-boot-npc32-difftest: config-npc32-linux-difftest
	$(MAKE) -C $(NSIM_HOME) -j$(NPROC)
	$(MAKE) -C $(NSIM_HOME) run IMG=$(OPENSBI_PAYLOAD) ARGS="$(ARGS)"

linux-boot-nemu32-device: config-nemu32-linux-device $(LINUX_RV32_DIR)/fw_payload.bin
	$(MAKE) -C $(NEMU_HOME) run IMG=$(LINUX_RV32_PAYLOAD) ARGS="$(DEVICE_ARGS)"

linux-boot-nemu64-device: config-nemu64-linux-device $(LINUX_RV64_DIR)/fw_payload.bin
	$(MAKE) -C $(NEMU_HOME) run IMG=$(LINUX_RV64_PAYLOAD) ARGS="$(DEVICE_ARGS)"

# ============================================================================
# FPGA Targets
# ============================================================================
fpga-syn:
	$(MAKE) -C $(YSYX_HOME)/fpga/gowin-tang-nano-20k syn

fpga-pnr:
	$(MAKE) -C $(YSYX_HOME)/fpga/gowin-tang-nano-20k pnr

# ============================================================================
# Utilities
# ============================================================================
pack:
	$(MAKE) -C $(NSIM_HOME) pack

lint:
	$(MAKE) -C $(NSIM_HOME) lint VFLAGS="$(VFLAGS)"

sta:
	$(MAKE) -C $(NSIM_HOME) sta

sta_detail:
	$(MAKE) -C $(NSIM_HOME) sta_detail

clean-npc:
	$(MAKE) -C $(NSIM_HOME) clean

clean:
	-$(MAKE) -C $(NEMU_HOME) clean 2>/dev/null || true
	-$(MAKE) -C $(NSIM_HOME) clean 2>/dev/null || true
	-$(MAKE) -C $(YSYX_HOME)/rtl_scala clean 2>/dev/null || true

.PHONY: help setup verilog \
	config-nemu32 config-nemu32-linux config-nemu32-ref config-nemu32-linux-device menuconfig-nemu32 build-nemu32 run-nemu32 run-nemu32-linux run-nemu32-linux-device \
	config-nemu64 config-nemu64-ref config-nemu64-linux-device build-nemu64 run-nemu64 run-nemu64-linux-device \
	config-npc32 config-npc32-difftest config-npc32-linux config-npc32-ysyxsoc menuconfig-npc32 build-npc32 run-npc32 sim-npc32 \
	build-npc64 run-npc64 lint-npc64 \
	coremark-npc32 coremark-npc64 coremark-npc32-difftest coremark-ysyxsoc microbench-npc32 microbench-npc64 microbench-npc32-difftest microbench-ysyxsoc \
	coremark-nemu32 microbench-nemu32 coremark-nemu64 microbench-nemu64 \
	nanos-nemu32 nanos-npc32 \
	linux-download linux-download-rv32 linux-download-rv64 \
	linux-boot-nemu32 linux-boot-npc32 linux-boot-nemu32-device linux-boot-nemu64-device \
	fpga-syn fpga-pnr pack lint sta clean-npc clean

endif # Guard: root-only targets
