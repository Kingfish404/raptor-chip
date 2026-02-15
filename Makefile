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
	@echo "NEMU (Software Emulator):"
	@echo "  make nemu-config        - Configure NEMU (riscv32 default)"
	@echo "  make nemu-build         - Build NEMU"
	@echo "  make nemu-run           - Build and run NEMU"
	@echo "  make nemu-menuconfig    - Open NEMU menuconfig"
	@echo "  make nemu-ref           - Build NEMU as DiffTest reference SO"
	@echo ""
	@echo "NPC Simulation (Verilator):"
	@echo "  make npc-config         - Configure NPC simulator (o2 default)"
	@echo "  make npc-build          - Build NPC simulator"
	@echo "  make npc-run            - Build and run NPC simulator"
	@echo "  make npc-menuconfig     - Open NPC menuconfig"
	@echo "  make npc-sim            - Shortcut: verilog + config + build + run"
	@echo ""
	@echo "AM Kernels / Benchmarks:"
	@echo "  make coremark           - Run CoreMark on NPC (riscv32e-npc)"
	@echo "  make microbench         - Run MicroBench on NPC (riscv32e-npc)"
	@echo "  make coremark-nemu      - Run CoreMark on NEMU"
	@echo "  make microbench-nemu    - Run MicroBench on NEMU"
	@echo ""
	@echo "Nanos-lite OS:"
	@echo "  make nanos-nemu         - Build and run nanos-lite on NEMU"
	@echo "  make nanos-npc          - Build and run nanos-lite on NPC"
	@echo ""
	@echo "Linux Kernel:"
	@echo "  make linux-boot         - Boot Linux on NEMU (via OpenSBI)"
	@echo ""
	@echo "FPGA:"
	@echo "  make fpga-syn           - Synthesize for Gowin Tang Nano 20K"
	@echo "  make fpga-pnr           - Place and route for FPGA"
	@echo ""
	@echo "Utilities:"
	@echo "  make pack               - Pack all SV files into one"
	@echo "  make sta                - Static timing analysis"
	@echo "  make lint               - Lint RTL with Verilator"
	@echo "  make clean              - Clean all build artifacts"
	@echo ""
	@echo "Args:"
	@echo "  ARGS=\"-b -n\"          - Pass args to runner (-b: batch [default], -n: no wave)"
	@echo "  ARGS=\"\"               - Disable batch mode (interactive)"
	@echo "  IMG=path/to/image       - Specify a custom image to load"
	@echo "  ARCH=riscv32e-npc       - Override ARCH for AM targets"
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

nemu-config:
	$(MAKE) -C $(NEMU_HOME) $(NEMU_DEFCONFIG)

nemu-menuconfig:
	$(MAKE) -C $(NEMU_HOME) menuconfig

nemu-build: nemu-config
	$(MAKE) -C $(NEMU_HOME) -j$(NPROC)

nemu-run: nemu-build
	$(MAKE) -C $(NEMU_HOME) run $(if $(IMG),IMG=$(IMG)) ARGS="$(ARGS)"

nemu-ref: nemu-config
	$(MAKE) -C $(NEMU_HOME) -j$(NPROC)

nemu-linux-config:
	$(MAKE) -C $(NEMU_HOME) riscv32_linux_defconfig

nemu-linux-run:
	$(MAKE) -C $(NEMU_HOME) riscv32_linux_defconfig
	$(MAKE) -C $(NEMU_HOME) -j$(NPROC)
	$(MAKE) -C $(NEMU_HOME) run $(if $(IMG),IMG=$(IMG)) ARGS="$(ARGS)"

# ============================================================================
# NPC Simulation Targets
# ============================================================================
NPC_DEFCONFIG ?= o2_defconfig
NPC_ARCH ?= riscv32e-npc

npc-config:
	$(MAKE) -C $(NSIM_HOME) $(NPC_DEFCONFIG)

npc-menuconfig:
	$(MAKE) -C $(NSIM_HOME) menuconfig

# Auto-generate RTL from Chisel if generated/ doesn't exist
GENERATED_DIR := $(YSYX_HOME)/rtl_sv/generated

$(GENERATED_DIR):
	$(MAKE) verilog

npc-build: npc-config | $(GENERATED_DIR)
	$(MAKE) -C $(NSIM_HOME) -j$(NPROC)

npc-run: npc-build
	$(MAKE) -C $(NSIM_HOME) run ARGS="$(ARGS)" $(if $(IMG),IMG=$(IMG))

npc-sim: verilog npc-config npc-build
	$(MAKE) -C $(NSIM_HOME) run ARGS="$(ARGS)" $(if $(IMG),IMG=$(IMG))

# ============================================================================
# AM Kernels / Benchmarks
# ============================================================================
AM_KERNELS = $(YSYX_HOME)/am-kernels

$(AM_KERNELS):
	git clone https://github.com/kingfish404/am-kernels $@

MAINARGS ?= test

coremark: $(AM_KERNELS)
	$(MAKE) -C $(AM_KERNELS)/benchmarks/coremark_eembc ARCH=$(NPC_ARCH) run ARGS="$(ARGS)"

microbench: $(AM_KERNELS)
	$(MAKE) -C $(AM_KERNELS)/benchmarks/microbench ARCH=$(NPC_ARCH) run ARGS="$(ARGS)" mainargs=$(MAINARGS)

coremark-nemu: $(AM_KERNELS)
	$(MAKE) -C $(AM_KERNELS)/benchmarks/coremark_eembc ARCH=riscv32-nemu run ARGS="$(ARGS)"

microbench-nemu: $(AM_KERNELS)
	$(MAKE) -C $(AM_KERNELS)/benchmarks/microbench ARCH=riscv32-nemu run ARGS="$(ARGS)" mainargs=$(MAINARGS)

# ============================================================================
# Nanos-lite OS
# ============================================================================
ISA ?= riscv32

nanos-nemu:
	$(MAKE) -C $(NAVY_HOME) ISA=$(ISA) fsimg
	$(MAKE) -C $(NAVY_HOME)/apps/menu ISA=$(ISA) install
	$(MAKE) -C $(YSYX_HOME)/nanos-lite ARCH=$(ISA)-nemu update run

nanos-npc:
	$(MAKE) -C $(NAVY_HOME) ISA=$(ISA) fsimg
	$(MAKE) -C $(NAVY_HOME)/apps/menu ISA=$(ISA) install
	$(MAKE) -C $(YSYX_HOME)/nanos-lite ARCH=$(ISA)-npc update run

# ============================================================================
# Linux Kernel Boot (via OpenSBI on NEMU)
# ============================================================================
OPENSBI_PAYLOAD ?= $(YSYX_HOME)/third_party/riscv-software-src/opensbi/build/platform/generic/firmware/fw_payload.bin

linux-boot: nemu-linux-config
	$(MAKE) -C $(NEMU_HOME) -j$(NPROC)
	$(MAKE) -C $(NEMU_HOME) run IMG=$(OPENSBI_PAYLOAD) ARGS="$(ARGS)"

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
	$(MAKE) -C $(NSIM_HOME) lint

sta:
	$(MAKE) -C $(NSIM_HOME) sta

clean:
	-$(MAKE) -C $(NEMU_HOME) clean 2>/dev/null || true
	-$(MAKE) -C $(NSIM_HOME) clean 2>/dev/null || true
	-$(MAKE) -C $(YSYX_HOME)/rtl_scala clean 2>/dev/null || true

.PHONY: help setup verilog \
	nemu-config nemu-menuconfig nemu-build nemu-run nemu-ref nemu-linux-config nemu-linux-run \
	npc-config npc-menuconfig npc-build npc-run npc-sim \
	coremark microbench coremark-nemu microbench-nemu \
	nanos-nemu nanos-npc linux-boot \
	fpga-syn fpga-pnr pack lint sta clean

endif # Guard: root-only targets
