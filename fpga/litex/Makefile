# ============================================================================
# fpga/litex/Makefile — Raptor LiteX SoC build system
# ============================================================================
#
# QUICK REFERENCE
# ---------------
#   make help                      # full target + variable list
#
# FLOW TAXONOMY
# -------------
#   The sim path is parameterized via three orthogonal knobs (ROM/SOC/PAYLOAD)
#   that fully determine the build dir + binary contents. See the header above
#   the "Verilator Simulation" section for the full matrix.
#
#     standard       sim asm trampoline  full sim topology     payload via --ram-init
#     ROM=fpga       fpga C firmware     full sim topology     no payload
#     ROM=bios       LiteX BIOS          full sim topology     no payload
#     ROM=bios SOC=fpga LiteX BIOS       FPGA topology         no payload
#     PAYLOAD=linux  sim asm trampoline  full sim topology     OpenSBI+kernel
#     <fpga_board>   custom OR LiteX BIOS FPGA topology         (Gowin gateware)
#
# NAMING CONVENTION
# -----------------
#   <flow>           build + run in one shot (most common entry point)
#   <flow>-gen       generate SoC sources only (no Verilator compile, no run)
#   <flow>-build     gen + compile Verilator binary
#   <flow>-run       run already-compiled binary
#   <flow>-trace     same as <flow> but with FST waves enabled
#   <flow>-clean     remove that flow's artifacts only
#
# AUTHORING CONVENTIONS
# ---------------------
#   * Targets carry an inline `## description` for `make help` extraction.
#   * Variables use `VAR ?= default ## description` (overridable on CLI).
#   * Section markers are `# ===...` + `# Title` + `# ===...` (3 lines).
#   * All `.PHONY` targets are collected at the bottom in a single block.
#   * Inline `## description` leaves trailing whitespace in $(VAR); strip
#     before any `ifeq`/`ifneq` exact-match comparison (see strip block below).
# ============================================================================

SHELL         := /bin/bash
.DEFAULT_GOAL := help

# --- Paths ---
LITEX_DIR   := $(abspath .)
RAPTOR_HOME := $(abspath ../..)
NSIM_DIR    := $(RAPTOR_HOME)/nsim
RTL_DIR     := $(RAPTOR_HOME)/rtl_sv
BUILD_DIR   := $(LITEX_DIR)/build
VENV_DIR    := $(LITEX_DIR)/.venv
PYTHON      := $(VENV_DIR)/bin/python3
PIP         := $(VENV_DIR)/bin/pip
HOST_PYTHON := $(shell if [ -x "$(PYTHON)" ]; then echo "$(PYTHON)"; elif command -v python3 >/dev/null 2>&1; then command -v python3; elif command -v python >/dev/null 2>&1; then command -v python; fi)
TIMEOUT_BIN := $(shell command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null)

export RAPTOR_HOME

ifeq ($(strip $(TIMEOUT_BIN)),)
	ifeq ($(strip $(HOST_PYTHON)),)
		$(error Neither timeout/gtimeout nor python3/python is available)
	endif
	TIMEOUT_RUN := $(HOST_PYTHON) $(LITEX_DIR)/scripts/run_with_timeout.py
	TIMEOUT_FOREGROUND :=
else
	TIMEOUT_RUN := $(TIMEOUT_BIN)
	TIMEOUT_FOREGROUND := --foreground
endif

# --- CPU variant ---
VARIANT     ?= standard ## CPU variant (standard|linux)
SYS_CLK     ?= 10000000 ## System clock in Hz
SIM_TIMEOUT ?= 30 ## Simulation timeout in seconds (0=unlimited)
# Raptor uarch preset (configs/<name>/rapt_config.svh).
#   * sim/coremark/...             default to 'default' (full uarch).
#   * fpga-* targets               default to 'small' (single-issue) for PnR fit.
# User CLI override (`make fpga-build RAPT_CONFIG=default`) wins because `?=`
# only sets when the variable is undefined.
FPGA_GOALS := fpga-detect fpga-gen fpga-build fpga-build-force fpga-load fpga-flash fpga \
              fpga-console fpga-upload fpga-clean tang-mega-138k-pro
ifneq (,$(filter $(FPGA_GOALS),$(MAKECMDGOALS)))
RAPT_CONFIG ?= small ## Raptor uarch config preset (default|small|...)
else
RAPT_CONFIG ?= default ## Raptor uarch config preset (default|small|...)
endif
RAPT_CONFIG := $(strip $(RAPT_CONFIG))
export RAPT_CONFIG
GOWIN_APP   ?= $(firstword $(wildcard /Applications/GowinIDE.app /Applications/GowinIDE.edu.app)) ## Gowin IDE app bundle path on macOS. Synthesis/PnR only; load/flash use openFPGALoader.
WITH_LED_CHASER ?= 0 ## Set to 1 to add LedChaser to fpga-build (off by default on the Pro for PnR density relief)
UART_PORT   ?= $(shell ls -1 /dev/tty.usbserial* /dev/tty.wchusbserial* /dev/tty.usbmodem* 2>/dev/null | sort | tail -n 1) ## Serial device for fpga-console
UART_BAUD   ?= 115200 ## Serial console baud rate

# --- Verilator parallel threading ---
# Verilator multi-threaded simulation (biggest lever for OpenSBI/Linux boot time
# in Verilator). LiteX passes --threads=N through to the verilator invocation,
# which enables coarse-grained parallel evaluation (OpenMP-based). A value of 1
# disables threading. Practical speedups are typically 1.5-2.5x on 4-8 host
# cores; benefit diminishes above ~4 threads for a single-core RISC-V SoC.
#
# Override at the command line:  make sim SIM_THREADS=8
SIM_THREADS ?= 4 ## Verilator simulation threads (1=off)

# --- Wave / trace ---
# Off by default — tracing is a huge perf hit. Enable on demand:
#   make sim     TRACE=fst     # FST (compact binary, ~5-10x smaller & faster than VCD)
#   make sim     TRACE=vcd     # VCD (universal text format, slowest + largest)
#   make test-fib TRACE=fst    # works for any run target
# Wave files land in $(SIM_GW_DIR)/sim.{fst,vcd} (LiteX default).
# Changing TRACE re-hashes build_sim.sh -> triggers Verilator rebuild.
# Partial files from Ctrl+C / timeout are viewable (LiteX flushes each tick).
TRACE ?= none ## Wave dump mode (none|fst|vcd)

# Windowed tracing (exact clock cycles, not ps).
# Default: TRACE_START=0 (dump from t=0), TRACE_END=-1 (no end).
TRACE_START ?= 0 ## Start dump at cycle N (0=from t=0)
TRACE_END   ?= -1 ## Stop dump at cycle N (-1=no end)

# Inline `## description` comments above leave trailing whitespace in the value.
# Strip before using in ifeq/ifneq (exact-match) comparisons.
VARIANT     := $(strip $(VARIANT))
SYS_CLK     := $(strip $(SYS_CLK))
SIM_TIMEOUT := $(strip $(SIM_TIMEOUT))
GOWIN_APP := $(strip $(GOWIN_APP))
WITH_LED_CHASER := $(strip $(WITH_LED_CHASER))
UART_PORT := $(strip $(UART_PORT))
UART_BAUD := $(strip $(UART_BAUD))
SIM_THREADS := $(strip $(SIM_THREADS))
TRACE       := $(strip $(TRACE))
TRACE_START := $(strip $(TRACE_START))
TRACE_END   := $(strip $(TRACE_END))


ifeq ($(TRACE),fst)
  TRACE_FLAGS := --trace --trace-fst
  TRACE_MSG   := FST tracing ON
else ifeq ($(TRACE),vcd)
  TRACE_FLAGS := --trace
  TRACE_MSG   := VCD tracing ON (consider TRACE=fst for ~5-10x less overhead)
else ifeq ($(TRACE),none)
  TRACE_FLAGS :=
  TRACE_MSG   :=
else
  $(error Invalid TRACE='$(TRACE)'. Use TRACE=fst, TRACE=vcd, or TRACE=none)
endif

# Pass cycle-based TRACE_START/TRACE_END to raptor_soc.py, which gates
# LiteX's `sim_trace` pin with an internal cycle counter.
ifneq ($(TRACE),none)
	TRACE_FLAGS += --trace-start-cycle=$(TRACE_START)
	TRACE_MSG   := $(TRACE_MSG) [start @ cycle $(TRACE_START)]
	ifneq ($(TRACE_END),-1)
		TRACE_FLAGS += --trace-end-cycle=$(TRACE_END)
		TRACE_MSG   := $(TRACE_MSG) [end(exclusive) @ cycle $(TRACE_END)]
	endif
endif

# --- Extra flags (user-overridable) ---
EXTRA_FLAGS ?= ## Extra flags passed to raptor_soc.py

# Integrated BSRAM-backed main_ram at 0x80000000. Required for `serialboot`
# upload workflow (rebuild bitstream once, then iterate firmware via
# `litex_term --kernel=<bin>`). 256 KB fits easily on Tang Mega 138K Pro
# (BSRAM was at ~6% with no main_ram). Set to 0 to disable.
INTEGRATED_MAIN_RAM_SIZE ?= 0x80000 ## BSRAM-backed main_ram size at 0x80000000 (default 512 KB; 0=disabled)
ifneq ($(INTEGRATED_MAIN_RAM_SIZE),0)
_MAIN_RAM_FLAG := --integrated-main-ram-size=$(INTEGRATED_MAIN_RAM_SIZE)
else
_MAIN_RAM_FLAG :=
endif

# ==============================================================================
# Environment
# ==============================================================================

setup: ## Install LiteX environment + register Raptor CPU
	@bash setup_env.sh

setup-skip: ## Activate venv without reinstalling
	@bash setup_env.sh --skip-install

$(VENV_DIR)/bin/activate:
	@echo "[INFO] Run 'make setup' first to create the virtual environment."
	@exit 1

# ==============================================================================
# RTL Packing
# ==============================================================================

PACK_SV := $(NSIM_DIR)/build/$(or $(RAPT_CONFIG),default)/rapt_pack.sv

# All hand-written RTL sources + headers. Any change must trigger re-pack.
# Chisel-generated sources under rtl_sv/generated/ are regenerated by
# `make verilog` in the top-level Makefile; we include them as deps too so
# an upstream decoder change is picked up.
RTL_SOURCES := $(shell find $(RTL_DIR) -type f \( -name '*.sv' -o -name '*.svh' -o -name '*.v' -o -name '*.vh' \) 2>/dev/null)

# Stamp file recording the last RAPT_CONFIG used here. Switching presets
# (default <-> small) doesn't touch RTL files, so the bare $(RTL_SOURCES)
# dependency would not re-pack. The stamp's mtime forces re-pack; nsim's
# own Makefile additionally clears its caches when RAPT_CONFIG changes.
RAPT_CONFIG_STAMP := $(BUILD_DIR)/.rapt_config_stamp
RAPT_CONFIG_PREV  := $(shell cat $(RAPT_CONFIG_STAMP) 2>/dev/null)
ifneq ($(RAPT_CONFIG),$(RAPT_CONFIG_PREV))
$(shell mkdir -p $(BUILD_DIR) && printf '%s' '$(RAPT_CONFIG)' > $(RAPT_CONFIG_STAMP))
$(info [litex] RAPT_CONFIG changed: '$(RAPT_CONFIG_PREV)' -> '$(RAPT_CONFIG)', re-packing...)
endif

pack: ## Pack all RTL into single preprocessed SV file
	$(MAKE) -C $(NSIM_DIR) pack RAPT_CONFIG=$(RAPT_CONFIG)

# Re-pack whenever any RTL file is newer than the packed output, OR the
# RAPT_CONFIG preset has just changed (stamp file mtime tracks this).
$(PACK_SV): $(RTL_SOURCES) $(RAPT_CONFIG_STAMP)
	$(MAKE) -C $(NSIM_DIR) pack RAPT_CONFIG=$(RAPT_CONFIG)

# ==============================================================================
# Firmware (minimal boot ROM)
# ==============================================================================
# Two separate firmware images for the two flows; both compile to the same
# `boot.bin` filename pattern but have different sources and link rules:
#   * firmware/sim/  — assembly-only stub: detects a payload at 0x80000000
#                      (placed there by --ram-init=...) and jumps to it,
#                      embeds DTB for OpenSBI/Linux. Used by sim-* / payload
#                      / coremark / opensbi / linux / etc.
#   * firmware/fpga/ — boot.S + main.c bring-up: clears .bss, copies .data,
#                      hands off to a C `main()` that talks to the LiteX
#                      liteuart for "is the FPGA alive?" diagnostics.
# Each variant has its own build dir under build/firmware/<variant>/ so the
# two flows never overwrite each other's artifacts.

CROSS     ?= riscv64-unknown-elf-
FW_BASE   := $(LITEX_DIR)/firmware

# --- Sim firmware (assembly + embedded DTB) ---
FW_SIM_SRC := $(FW_BASE)/sim
FW_SIM_DIR := $(BUILD_DIR)/firmware/sim
FW_SIM_BIN := $(FW_SIM_DIR)/boot.bin
FW_SIM_ELF := $(FW_SIM_DIR)/boot.elf
FW_SIM_DTB := $(FW_SIM_DIR)/litex-soc.dtb
FW_SIM_DTS := $(FW_SIM_SRC)/litex-soc.dts

$(FW_SIM_DIR):
	@mkdir -p $@

$(FW_SIM_DTB): $(FW_SIM_DTS) | $(FW_SIM_DIR)
	dtc -I dts -O dtb -o $@ $<

$(FW_SIM_ELF): $(FW_SIM_SRC)/boot.S $(FW_SIM_SRC)/link.ld $(FW_SIM_DTB) | $(FW_SIM_DIR)
	$(CROSS)gcc -march=rv32imac -mabi=ilp32 -nostdlib -nostartfiles \
		-T $(FW_SIM_SRC)/link.ld -I$(FW_SIM_DIR) -o $@ $(FW_SIM_SRC)/boot.S

$(FW_SIM_BIN): $(FW_SIM_ELF)
	$(CROSS)objcopy -O binary $< $@

# --- FPGA firmware (boot.S + main.c, UART hello) ---
# FW_FPGA_TARGET selects which main.c is linked against the shared
# boot.S/link.ld. Default `main` = full bring-up shell. `irqtest` = minimal
# IRQ probe used to bisect Raptor's IRQ delivery / mret bug. Adding new
# targets is just dropping main_<name>.c in firmware/fpga/.
#
# FW_FPGA_LOAD selects the link script:
#   rom       link.ld          — runs from integrated ROM @ 0x20000000 (default)
#   main_ram  link_main_ram.ld — runs from main_ram @ 0x80000000 (for serialboot upload)
FW_FPGA_TARGET ?= main ## firmware/fpga/main_<TARGET>.c (or main.c when =main)
FW_FPGA_LOAD   ?= rom  ## Link target: rom (integrated ROM) or main_ram (uploadable via serialboot)
MAIN_RAM_BASE  ?= 0x80000000 ## main_ram base addr (must match raptor_soc.py mem_map; serialboot upload target)
FW_FPGA_TARGET := $(strip $(FW_FPGA_TARGET))
FW_FPGA_LOAD   := $(strip $(FW_FPGA_LOAD))
FW_FPGA_SRC := $(FW_BASE)/fpga
FW_FPGA_DIR := $(BUILD_DIR)/firmware/fpga/$(FW_FPGA_TARGET)-$(FW_FPGA_LOAD)
FW_FPGA_BIN := $(FW_FPGA_DIR)/boot.bin
FW_FPGA_ELF := $(FW_FPGA_DIR)/boot.elf
ifeq ($(FW_FPGA_TARGET),main)
FW_FPGA_MAIN_SRC := $(FW_FPGA_SRC)/main.c
else
FW_FPGA_MAIN_SRC := $(FW_FPGA_SRC)/main_$(FW_FPGA_TARGET).c
endif
ifeq ($(FW_FPGA_LOAD),main_ram)
FW_FPGA_LINK := $(FW_FPGA_SRC)/link_main_ram.ld
else
FW_FPGA_LINK := $(FW_FPGA_SRC)/link.ld
endif
FW_FPGA_OBJS := $(FW_FPGA_DIR)/boot.o $(FW_FPGA_DIR)/main.o

$(FW_FPGA_DIR):
	@mkdir -p $@

FW_FPGA_CFLAGS := -march=rv32imac_zicsr -mabi=ilp32 -ffreestanding -nostdlib \
	-nostartfiles -Os -ffunction-sections -fdata-sections \
	-Wall -Wextra -Wno-unused-parameter

$(FW_FPGA_DIR)/boot.o: $(FW_FPGA_SRC)/boot.S | $(FW_FPGA_DIR)
	$(CROSS)gcc $(FW_FPGA_CFLAGS) -c -o $@ $<

$(FW_FPGA_DIR)/main.o: $(FW_FPGA_MAIN_SRC) | $(FW_FPGA_DIR)
	$(CROSS)gcc $(FW_FPGA_CFLAGS) -c -o $@ $<

$(FW_FPGA_ELF): $(FW_FPGA_OBJS) $(FW_FPGA_LINK)
	$(CROSS)gcc $(FW_FPGA_CFLAGS) -Wl,--gc-sections \
		-T $(FW_FPGA_LINK) -o $@ $(FW_FPGA_OBJS)

$(FW_FPGA_BIN): $(FW_FPGA_ELF)
	$(CROSS)objcopy -O binary $< $@

# --- Aggregates / aliases ---
firmware: $(FW_SIM_BIN) $(FW_FPGA_BIN) ## Build both sim + fpga firmware images
firmware-sim:  $(FW_SIM_BIN)  ## Build sim firmware only
firmware-fpga: $(FW_FPGA_BIN) ## Build FPGA bring-up firmware only {FW_FPGA_TARGET,FW_FPGA_LOAD}

firmware-clean:
	rm -rf $(BUILD_DIR)/firmware
	@# Legacy in-tree artifacts from older versions of this Makefile:
	rm -f $(FW_SIM_SRC)/boot.elf $(FW_SIM_SRC)/boot.bin $(FW_SIM_SRC)/litex-soc.dtb

# ==============================================================================
# Payload paths (declared early so the sim dispatch below can reference them)
# ==============================================================================
# Each payload type contributes a {bin path, build-target} pair. The actual
# build rules + user-facing aliases live further down in "Payload aliases".

# CoreMark
COREMARK_BENCH  := $(LITEX_DIR)/benchmarks/coremark
COREMARK_BIN    := $(COREMARK_BENCH)/build/coremark.bin

# Embench-IoT
EMBENCH_BENCH   := $(LITEX_DIR)/benchmarks/embench
EMBENCH_BENCHES := aha-mont64 crc32 depthconv edn huffbench matmult-int \
                   md5sum nettle-aes nettle-sha256 nsichneu picojpeg \
                   qrduino sglib-combined slre statemate tarfind ud \
                   wikisort xgboost
EMBENCH_LOG_DIR := $(BUILD_DIR)/embench-logs

# app/ LLM-style benchmarks, linked as LiteX-native payloads so they run
# without pk/newlib in LiteX sim and on FPGA via BIOS serialboot.
APP_LLM_BENCH     := $(RAPTOR_HOME)/app/benchmarks/llm
APP_LLM_BUILD_DIR := $(RAPTOR_HOME)/app/build/rv32/benchmarks/llm-litex
APP_LLM_BENCHES   := ops infer train
LLM_OP_ITERS      ?= 8## LLM operator benchmark repeat count
LLM_GEN_TOKENS    ?= 12## LLM inference generated token count
LLM_TRAIN_STEPS   ?= 4## LLM training benchmark steps
RLLMBENCH_TIMEBASE_HZ ?= 1000000## RISC-V time CSR frequency in Hz
RLLMBENCH_CORE_CLOCK_MHZ ?= $(shell awk 'BEGIN { printf "%.6g", $(SYS_CLK) / 1000000 }')## Core clock in MHz for RLLMBench score/MHz reports

# MicroBench (AM-based)
MICROBENCH_DIR  := $(RAPTOR_HOME)/abstract-machine/app/am-kernels/benchmarks/microbench
MICROBENCH_BIN  := $(MICROBENCH_DIR)/build/microbench-riscv32-npc.bin

# Standalone C microbenchmarks (fpga/litex/tests)
TESTS_DIR       := $(LITEX_DIR)/tests
TESTS_BUILD_DIR := $(BUILD_DIR)/tests
TEST_NAMES      := hello text fib prime memcpy mul

# OpenSBI + Linux
LINUX_DIR       := $(RAPTOR_HOME)/linux
OPENSBI_FW_DIR  := $(LINUX_DIR)/opensbi/build/platform/generic/firmware
OPENSBI_BIN     := $(OPENSBI_FW_DIR)/fw_payload.bin
LINUX_IMG        = $(wildcard $(LINUX_DIR)/build/linux-riscv-rv32-*/fw_payload.bin)

# Custom payload (set IMG=/path/to.bin on the cmdline)
IMG ?= ## Custom payload binary (for 'make payload' / 'make sim PAYLOAD=img')

# ==============================================================================
# Verilator Simulation (unified ROM × SOC × PAYLOAD)
# ==============================================================================
# Three orthogonal knobs select what the sim builds and runs:
#
#   ROM      = sim | fpga | bios
#     sim    asm trampoline (firmware/sim) — boot to payload at 0x80000000 (default)
#     fpga   firmware/fpga C bring-up — same image used on FPGA hardware
#     bios   upstream LiteX BIOS — drops to `litex>` prompt; auto-applies
#            the BIOS picolibc + UART-polling + skip-memspeed patches
#
#   SOC      = default | fpga
#     default  full sim topology (LiteX SimSoC defaults: 256 MB main_ram)
#     fpga     match FPGA build (32 KB ROM, 8 KB SRAM, no main_ram)
#
#   PAYLOAD  = none | coremark | microbench | linux | opensbi
#              | embench-<NAME> | app-llm-<NAME> | test-<NAME>
#              | img (with IMG=/path)
#     Loaded into main_ram via --ram-init. PAYLOAD does NOT affect the
#     Verilator build cache (only ROM/SOC do), so iterating on different
#     payloads with the same ROM/SOC reuses the compiled Vsim binary.
#
# Output dir: build/sim/<variant>-<rom>-<soc>/gateware/
#
# Examples:
#   make sim                                 # ROM=sim SOC=default PAYLOAD=none
#   make sim TRACE=fst                       # add FST waves
#   make sim ROM=bios                        # boot LiteX BIOS in full sim SoC
#   make sim ROM=bios SOC=fpga               # BIOS in FPGA-style SoC
#   make sim ROM=fpga                        # FPGA bring-up firmware in sim
#   make sim PAYLOAD=coremark                # CoreMark payload
#   make sim PAYLOAD=linux VARIANT=linux     # Linux boot
#   make sim PAYLOAD=img IMG=/path/to.bin    # custom payload
#   make sim PAYLOAD=embench-crc32           # one Embench bench
#   make sim PAYLOAD=app-llm-infer           # app/ LLM E2E inference
#   make sim PAYLOAD=img IMG=$(FW_FPGA_BIN) ROM=bios  # debug FPGA payload via BIOS
#
# Convenience aliases (just recursive-make the right combination):
#   coremark / microbench / opensbi / linux / payload / embench-run-<N> / test-<N>

ROM     ?= sim ## Sim boot ROM (sim=asm trampoline, fpga=firmware/fpga C, bios=LiteX BIOS)
SOC     ?= default ## Sim SoC topology (default=full main_ram, fpga=ROM-only matching FPGA build)
PAYLOAD ?= none ## Payload at 0x80000000 (none|coremark|microbench|linux|opensbi|embench-NAME|test-NAME|img)
ROM     := $(strip $(ROM))
SOC     := $(strip $(SOC))
PAYLOAD := $(strip $(PAYLOAD))

# --- LiteX BIOS source patches ---
# In-place patch to LiteX upstream (third_party/.../litex/), reverted via
# `git checkout` on EXIT trap. Required for any BIOS-compiling target
# (`make sim ROM=bios` and `make fpga-build BOOT_MODE=bios`):
#   1. picolibc layout (picolibc>=1.7 moved sources under newlib/)
#   2. UART polling mode — bypass the IRQ/ring-buffer driven path
# NOTES (2026-04-27):
#   - patch_litex_uart_polling.py REINSTATED: the IRQ-driven UART path
#     in libbase/uart.c (`uart_isr` ring buffer + irq.h mscratch shadow
#     for emulating LiteX's per-peripheral mask convention on standard
#     RISC-V mie) loses RX bytes during back-to-back 64B SFL frames.
#     Polling mode is robust and adds negligible BIOS-time cost. The
#     interactive shell (login prompt, paste, commands) and `serialboot`
#     all work in polling mode. To investigate the IRQ path further,
#     drop this patch and add a litescope on the UART event interface.
#   - patch_litex_skip_memspeed.py dropped: was masking the same IRQ
#     hang; polling path completes mem_speed correctly.
LITEX_PATH := $(RAPTOR_HOME)/third_party/enjoy-digital/litex
define _litex_bios_patches_apply
	$(PYTHON) $(LITEX_DIR)/scripts/patch_litex_picolibc.py $(LITEX_PATH) && $(PYTHON) $(LITEX_DIR)/scripts/patch_litex_uart_polling.py $(LITEX_PATH)
endef
define _litex_bios_patches_restore
	cd $(LITEX_PATH) && git checkout -- litex/soc/software/common.mak litex/soc/software/libc/Makefile litex/soc/software/libbase/uart.c litex/soc/software/bios/main.c 2>/dev/null || true
endef

# --- ROM dispatch ---
ifeq ($(ROM),sim)
SIM_ROM_BIN  := $(FW_SIM_BIN)
SIM_ROM_DEP  := $(FW_SIM_BIN)
SIM_ROM_FLAGS := --no-compile-software --integrated-rom-init=$(SIM_ROM_BIN)
SIM_NEEDS_BIOS_PATCHES := 0
else ifeq ($(ROM),fpga)
SIM_ROM_BIN  := $(FW_FPGA_BIN)
SIM_ROM_DEP  := $(FW_FPGA_BIN)
SIM_ROM_FLAGS := --no-compile-software --integrated-rom-init=$(SIM_ROM_BIN)
SIM_NEEDS_BIOS_PATCHES := 0
else ifeq ($(ROM),bios)
SIM_ROM_BIN  :=
SIM_ROM_DEP  :=
SIM_ROM_FLAGS :=
SIM_NEEDS_BIOS_PATCHES := 1
else
$(error Invalid ROM='$(ROM)'. Use ROM=sim|fpga|bios)
endif

# --- SOC dispatch ---
ifeq ($(SOC),default)
SIM_SOC_FLAGS :=
else ifeq ($(SOC),fpga)
SIM_SOC_FLAGS := --integrated-rom-size=0x8000 --integrated-sram-size=0x2000 --integrated-main-ram-size=0
else
$(error Invalid SOC='$(SOC)'. Use SOC=default|fpga)
endif

# --- PAYLOAD dispatch ---
SIM_PAYLOAD_BIN   :=
SIM_PAYLOAD_BUILD :=
ifeq ($(PAYLOAD),none)
# nothing
else ifeq ($(PAYLOAD),coremark)
SIM_PAYLOAD_BIN   := $(COREMARK_BIN)
SIM_PAYLOAD_BUILD := coremark-build
else ifeq ($(PAYLOAD),microbench)
SIM_PAYLOAD_BIN   := $(MICROBENCH_BIN)
SIM_PAYLOAD_BUILD := microbench-build
else ifeq ($(PAYLOAD),opensbi)
SIM_PAYLOAD_BIN   := $(OPENSBI_BIN)
SIM_PAYLOAD_BUILD := opensbi-build
else ifeq ($(PAYLOAD),linux)
SIM_PAYLOAD_BIN    = $(LINUX_IMG)
SIM_PAYLOAD_BUILD := linux-build
else ifeq ($(PAYLOAD),img)
ifndef IMG
$(error PAYLOAD=img requires IMG=/path/to/binary.bin)
endif
SIM_PAYLOAD_BIN   := $(IMG)
else ifneq (,$(filter embench-%,$(PAYLOAD)))
_EMBENCH_NAME     := $(patsubst embench-%,%,$(PAYLOAD))
SIM_PAYLOAD_BIN   := $(EMBENCH_BENCH)/build/$(_EMBENCH_NAME)/$(_EMBENCH_NAME).bin
SIM_PAYLOAD_BUILD := embench-build-$(_EMBENCH_NAME)
else ifneq (,$(filter app-llm-%,$(PAYLOAD)))
_APP_LLM_NAME     := $(patsubst app-llm-%,%,$(PAYLOAD))
SIM_PAYLOAD_BIN   := $(APP_LLM_BUILD_DIR)/llm-$(_APP_LLM_NAME).bin
SIM_PAYLOAD_BUILD := app-llm-build-$(_APP_LLM_NAME)
else ifneq (,$(filter test-%,$(PAYLOAD)))
_TEST_NAME        := $(patsubst test-%,%,$(PAYLOAD))
SIM_PAYLOAD_BIN   := $(TESTS_BUILD_DIR)/$(_TEST_NAME).bin
SIM_PAYLOAD_BUILD := tests
else
$(error Invalid PAYLOAD='$(PAYLOAD)')
endif
ifneq ($(SIM_PAYLOAD_BIN),)
SIM_PAYLOAD_FLAG = --ram-init=$(SIM_PAYLOAD_BIN)
else
SIM_PAYLOAD_FLAG :=
endif

# --- Output dir keyed by VARIANT-ROM-SOC ---
SIM_DIR    := $(BUILD_DIR)/sim/$(VARIANT)-$(ROM)-$(SOC)
SIM_GW_DIR := $(SIM_DIR)/gateware

# --- Helpers ---
define _soc_gen
	source $(VENV_DIR)/bin/activate && \
	$(PYTHON) raptor_soc.py $(1) $(EXTRA_FLAGS)
endef

_BASE_FLAGS = --sys-clk-freq=$(SYS_CLK) --threads=$(SIM_THREADS) $(TRACE_FLAGS)
SIM_FLAGS   = --output-dir=$(SIM_DIR) --cpu-variant=$(VARIANT) \
              $(SIM_ROM_FLAGS) $(SIM_SOC_FLAGS) $(SIM_PAYLOAD_FLAG) $(_BASE_FLAGS)

# Compile Verilator binary only when sim.v + sim_init.cpp + build_sim.sh
# content has changed (hash-based).
define _compile_if_needed
	@mkdir -p $(1)
	@SIM_V_HASH=$$({ \
		grep -v -e '^// Date' -e '^//  Auto-Generated by LiteX on' $(1)/sim.v 2>/dev/null; \
		cat $(1)/sim_init.cpp 2>/dev/null; \
		cat $(1)/build_sim.sh 2>/dev/null; \
	} | md5 -q 2>/dev/null || { \
		grep -v -e '^// Date' -e '^//  Auto-Generated by LiteX on' $(1)/sim.v 2>/dev/null; \
		cat $(1)/sim_init.cpp 2>/dev/null; \
		cat $(1)/build_sim.sh 2>/dev/null; \
	} | md5sum | cut -d' ' -f1); \
	OLD_HASH=$$(cat $(1)/.sim_v_hash 2>/dev/null || echo ""); \
	if [ ! -f $(1)/obj_dir/Vsim ] || [ "$$SIM_V_HASH" != "$$OLD_HASH" ]; then \
		echo "[INFO] Compiling Verilator simulation (this may take several minutes)..."; \
		cd $(1) && bash build_sim.sh; \
		echo "$$SIM_V_HASH" > $(1)/.sim_v_hash; \
		echo "[INFO] Verilator compilation complete."; \
	else \
		echo "[INFO] Verilator binary up to date, skipping compilation."; \
	fi
endef

# Run Vsim with timeout + Ctrl+C/SIGTERM handling + wave summary.
define _run_vsim
	@if [ ! -f $(1)/obj_dir/Vsim ]; then \
		echo "[ERR] No sim binary at $(1). Run 'make sim-build' first."; exit 1; fi
	@echo "[INFO] Running sim (timeout=$(SIM_TIMEOUT)s, Ctrl+C to stop)"
	@if [ -n "$(TRACE_MSG)" ]; then echo "[INFO] $(TRACE_MSG) — wave -> $(1)/sim.$(TRACE)"; fi
	@cd $(1) && \
		$(TIMEOUT_RUN) $(TIMEOUT_FOREGROUND) $(SIM_TIMEOUT) obj_dir/Vsim; \
		rc=$$?; \
		if [ $$rc -eq 124 ]; then \
			echo ""; echo "[INFO] Simulation timed out after $(SIM_TIMEOUT)s."; \
		elif [ $$rc -eq 130 ] || [ $$rc -eq 143 ]; then \
			echo ""; echo "[INFO] Simulation interrupted (Ctrl+C / SIGTERM)."; \
		elif [ $$rc -ne 0 ]; then \
			exit $$rc; \
		fi
	@if [ -n "$(TRACE_MSG)" ] && [ -f $(1)/sim.$(TRACE) ]; then \
		sz=$$(wc -c < $(1)/sim.$(TRACE)); \
		echo "[INFO] Wave: $(1)/sim.$(TRACE) ($$sz bytes)"; \
	fi
endef

# --- Top-level sim targets (parameterized via ROM/SOC/PAYLOAD) ---

sim-gen: $(PACK_SV) $(SIM_ROM_DEP) $(SIM_PAYLOAD_BUILD) ## Generate SoC Verilog (no compile, no run) {ROM,SOC,PAYLOAD,VARIANT,IMG}
	@if [ "$(SIM_NEEDS_BIOS_PATCHES)" = "1" ]; then $(call _litex_bios_patches_apply); fi
	@trap '[ "$(SIM_NEEDS_BIOS_PATCHES)" = "1" ] && { $(call _litex_bios_patches_restore); } || true' EXIT; \
	$(call _soc_gen,$(SIM_FLAGS))

sim-build: sim-gen ## Generate SoC + compile Verilator binary {ROM,SOC,PAYLOAD,VARIANT,IMG}
	$(call _compile_if_needed,$(SIM_GW_DIR))

sim: sim-build ## Build + run sim {ROM,SOC,PAYLOAD,VARIANT,IMG,TRACE,SIM_TIMEOUT,SIM_THREADS}
	$(call _run_vsim,$(SIM_GW_DIR))

sim-run: ## Run already-built sim (no rebuild) {ROM,SOC,PAYLOAD,VARIANT,SIM_TIMEOUT}
	$(call _run_vsim,$(SIM_GW_DIR))

sim-trace: ## Alias: make sim TRACE=fst
	@$(MAKE) --no-print-directory sim TRACE=fst

sim-trace-vcd: ## Alias: make sim TRACE=vcd (slower/larger than FST)
	@$(MAKE) --no-print-directory sim TRACE=vcd

# ==============================================================================
# Payload aliases
# ==============================================================================
# Thin wrappers around `make sim PAYLOAD=<X>`. Each alias just dispatches a
# recursive sub-make with the right PAYLOAD= value (and VARIANT= where the
# payload requires a specific CPU variant). Use the alias for convenience;
# use the full `sim` invocation when you need to combine payloads with non-
# default ROM/SOC (e.g. `make sim PAYLOAD=coremark ROM=bios`).
#
# Path variables (COREMARK_BIN, etc.) are declared earlier in "Payload paths".

# --- CoreMark ---
COREMARK_ITERATIONS ?= 64 ## CoreMark loop iterations (FPGA: 1000+ recommended; sim: 64)

coremark-build: ## Build CoreMark binary (clone + compile) {COREMARK_ITERATIONS,SYS_CLK}
	$(MAKE) -C $(COREMARK_BENCH) build ITERATIONS=$(COREMARK_ITERATIONS) SYS_CLK_HZ=$(SYS_CLK)

coremark: ## Alias: make sim PAYLOAD=coremark {COREMARK_ITERATIONS}
	@$(MAKE) --no-print-directory sim PAYLOAD=coremark COREMARK_ITERATIONS=$(COREMARK_ITERATIONS)

coremark-fpga: coremark-build ## Upload CoreMark to FPGA main_ram via BIOS serialboot {COREMARK_ITERATIONS,MAIN_RAM_BASE,UART_PORT,UART_BAUD}
	@$(MAKE) --no-print-directory fpga-upload BIN=$(COREMARK_BIN)

coremark-clean: ## Remove CoreMark build artifacts (keep cloned source)
	$(MAKE) -C $(COREMARK_BENCH) clean

# --- FPGA Bring-up firmware (main.c with interactive shell: donut, primes, etc.) ---
# Run the firmware main shell on FPGA main_ram via BIOS serialboot.

main-fpga-build: ## Build FPGA main firmware (uploadable via serialboot to main_ram) {UART_PORT,UART_BAUD}
	$(MAKE) -C $(LITEX_DIR) firmware-fpga FW_FPGA_TARGET=main FW_FPGA_LOAD=main_ram
	@echo "[INFO] FPGA main firmware ready: $(BUILD_DIR)/firmware/fpga/main-main_ram/boot.bin"

main-fpga: main-fpga-build ## Build + upload FPGA main firmware to main_ram {UART_PORT,UART_BAUD}
	@$(MAKE) --no-print-directory fpga-upload BIN=$(BUILD_DIR)/firmware/fpga/main-main_ram/boot.bin

# IRQ test firmware (minimal interrupt probe)
irqtest-fpga: ## Build + upload minimal IRQ test firmware {UART_PORT,UART_BAUD}
	$(MAKE) -C $(LITEX_DIR) firmware-fpga FW_FPGA_TARGET=irqtest FW_FPGA_LOAD=main_ram
	@$(MAKE) --no-print-directory fpga-upload BIN=$(BUILD_DIR)/firmware/fpga/irqtest-main_ram/boot.bin

main-fpga-clean: ## Remove FPGA firmware build artifacts
	rm -rf $(BUILD_DIR)/firmware/fpga/main-main_ram $(BUILD_DIR)/firmware/fpga/irqtest-main_ram

# --- Embench-IoT ---
EMBENCH_TARGETS := $(addprefix embench-run-,$(EMBENCH_BENCHES))
EMBENCH_BUILDS  := $(addprefix embench-build-,$(EMBENCH_BENCHES))

embench-build: ## Build all Embench-IoT benchmarks (one BIN per bench)
	$(MAKE) -C $(EMBENCH_BENCH) build SYS_CLK_HZ=$(SYS_CLK)

# Per-bench build (used as prereq by `make sim PAYLOAD=embench-<NAME>`).
$(EMBENCH_BUILDS): embench-build-%:
	$(MAKE) -C $(EMBENCH_BENCH) build BENCH=$* SYS_CLK_HZ=$(SYS_CLK)

embench-build-one: ## Build one Embench bench (BENCH=<name>) {BENCH}
	@if [ -z "$(BENCH)" ]; then echo "[ERR] Set BENCH=<name>"; exit 1; fi
	@$(MAKE) --no-print-directory embench-build-$(BENCH)

# Per-bench run alias.
$(EMBENCH_TARGETS): embench-run-%: ## Alias: make sim PAYLOAD=embench-<NAME>
	@$(MAKE) --no-print-directory sim PAYLOAD=embench-$*

embench-run: ## Run one Embench bench (BENCH=<name>) {BENCH}
	@if [ -z "$(BENCH)" ]; then echo "[ERR] Set BENCH=<name>"; exit 1; fi
	@$(MAKE) --no-print-directory sim PAYLOAD=embench-$(BENCH)

embench: $(PACK_SV) $(FW_SIM_BIN) sim-build ## Build + run all Embench benches (parallel) + Embench Score report
	@mkdir -p $(EMBENCH_LOG_DIR)
	@bash $(EMBENCH_BENCH)/run-embench.sh

embench-report: ## Re-run Embench Score report from existing logs
	@bash $(EMBENCH_BENCH)/report-embench.sh $(EMBENCH_LOG_DIR)

embench-clean: ## Remove Embench build artifacts and run logs
	$(MAKE) -C $(EMBENCH_BENCH) clean
	rm -rf $(EMBENCH_LOG_DIR)

# --- app/ LLM-style AI benchmarks ---
APP_LLM_TARGETS := $(addprefix app-llm-,$(APP_LLM_BENCHES))
APP_LLM_BUILDS  := $(addprefix app-llm-build-,$(APP_LLM_BENCHES))
APP_LLM_FPGAS   := $(addsuffix -fpga,$(APP_LLM_TARGETS))
APP_LLM_VARS    := LLM_OP_ITERS=$(LLM_OP_ITERS) \
                   LLM_GEN_TOKENS=$(LLM_GEN_TOKENS) \
				   LLM_TRAIN_STEPS=$(LLM_TRAIN_STEPS) \
				   RLLMBENCH_TIMEBASE_HZ=$(RLLMBENCH_TIMEBASE_HZ) \
				   RLLMBENCH_CORE_CLOCK_MHZ=$(RLLMBENCH_CORE_CLOCK_MHZ)

app-llm-build: ## Build all app/ LLM benchmarks as LiteX-native payloads
	$(MAKE) -C $(APP_LLM_BENCH) litex-build $(APP_LLM_VARS)

$(APP_LLM_BUILDS): app-llm-build-%:
	$(MAKE) -C $(APP_LLM_BENCH) litex-build-one BENCH=$* $(APP_LLM_VARS)

$(APP_LLM_TARGETS): app-llm-%: ## Alias: make sim PAYLOAD=app-llm-<NAME>
	@$(MAKE) --no-print-directory sim PAYLOAD=app-llm-$* $(APP_LLM_VARS)

app-llm-run: ## Run one app/ LLM benchmark in LiteX sim (BENCH=ops|infer|train) {BENCH}
	@if [ -z "$(BENCH)" ]; then echo "[ERR] Set BENCH=ops|infer|train"; exit 1; fi
	@$(MAKE) --no-print-directory sim PAYLOAD=app-llm-$(BENCH) $(APP_LLM_VARS)

$(APP_LLM_FPGAS): app-llm-%-fpga: app-llm-build-% ## Upload app/ LLM benchmark to FPGA via BIOS serialboot
	@$(MAKE) --no-print-directory fpga-upload BIN=$(APP_LLM_BUILD_DIR)/llm-$*.bin

app-llm-fpga: ## Upload one app/ LLM benchmark to FPGA (BENCH=ops|infer|train) {BENCH,UART_PORT,UART_BAUD}
	@if [ -z "$(BENCH)" ]; then echo "[ERR] Set BENCH=ops|infer|train"; exit 1; fi
	@$(MAKE) --no-print-directory app-llm-$(BENCH)-fpga $(APP_LLM_VARS)

APP_FPGA_BIN ?= ## Custom app-built LiteX-native binary for app-fpga-upload
app-fpga-upload: ## Upload a prebuilt app LiteX-native bin via BIOS serialboot {APP_FPGA_BIN,UART_PORT,UART_BAUD}
	@if [ -z "$(APP_FPGA_BIN)" ]; then echo "[ERR] Set APP_FPGA_BIN=/path/to.bin"; exit 1; fi
	@$(MAKE) --no-print-directory fpga-upload BIN=$(APP_FPGA_BIN)

# --- MicroBench ---
microbench-build: ## Build MicroBench binary
	$(MAKE) -C $(MICROBENCH_DIR) ARCH=riscv32-npc

microbench: ## Alias: make sim PAYLOAD=microbench
	@$(MAKE) --no-print-directory sim PAYLOAD=microbench

# --- Self-contained C microbenchmarks (fpga/litex/tests) ---
# Standalone payloads that do NOT depend on AM / nanos-lite / libc. They talk
# directly to LiteX UART (0xf000_1800) and read `rdcycle`, so they exercise the
# core and memory system without any build-cache or MMIO-map pitfalls.
TEST_TARGETS := $(addprefix test-,$(TEST_NAMES))

tests: ## Build all standalone C microbenchmarks (build/tests/*.bin)
	$(MAKE) -C $(TESTS_DIR) BUILD_DIR=$(TESTS_BUILD_DIR)

tests-clean: ## Clean standalone microbenchmark build artifacts
	$(MAKE) -C $(TESTS_DIR) BUILD_DIR=$(TESTS_BUILD_DIR) clean

# Per-test alias.
$(TEST_TARGETS): test-%: ## Alias: make sim PAYLOAD=test-<NAME>
	@$(MAKE) --no-print-directory sim PAYLOAD=test-$*

tests-run: tests ## Run every standalone test sequentially
	@set -e; for t in $(TEST_NAMES); do \
		echo "================================================================"; \
		echo "[tests-run] Running test-$$t"; \
		echo "================================================================"; \
		$(MAKE) --no-print-directory sim PAYLOAD=test-$$t SIM_TIMEOUT=$(SIM_TIMEOUT) || exit 1; \
	done
	@echo "[tests-run] All tests completed."

# --- OpenSBI (standalone test payload) ---
opensbi-build: ## Build OpenSBI (standalone, from linux/opensbi)
	$(MAKE) -C $(LINUX_DIR) opensbi

opensbi: ## Alias: make sim PAYLOAD=opensbi
	@$(MAKE) --no-print-directory sim PAYLOAD=opensbi

opensbi-clean: ## Clean OpenSBI build artifacts
	$(MAKE) -C $(LINUX_DIR) opensbi-clean

# --- Custom payload ---
payload: ## Alias: make sim PAYLOAD=img IMG=/path/to.bin {IMG,TRACE,SIM_TIMEOUT}
	@if [ -z "$(IMG)" ]; then echo "[ERR] Set IMG=/path/to/binary.bin"; exit 1; fi
	@$(MAKE) --no-print-directory sim PAYLOAD=img IMG=$(IMG)

# --- Linux (OpenSBI + Kernel) ---
linux-build: ## Download pre-built Linux payload (if needed)
	$(MAKE) -s -C $(LINUX_DIR) download-rv32

linux: ## Alias: make sim PAYLOAD=linux VARIANT=linux
	@$(MAKE) --no-print-directory sim PAYLOAD=linux VARIANT=linux

# --- LiteX BIOS in sim (compiles BIOS into integrated_rom; applies BIOS patches) ---
bios: ## Alias: make sim ROM=bios (run LiteX BIOS in sim) {SOC,PAYLOAD,TRACE,SIM_TIMEOUT}
	@$(MAKE) --no-print-directory sim ROM=bios SOC=$(SOC) PAYLOAD=$(PAYLOAD)

# ==============================================================================
# FPGA Targets
# ==============================================================================
# Hardware target: Sipeed Tang Mega 138K Pro (Gowin GW5AST-LV138FPG676AES).
#
# Toolchain prerequisites:
#   * Gowin IDE  — synthesis + place&route (gw_sh from GowinIDE.app/.edu.app)
#   * openFPGALoader — bitstream upload + SPI flashing (Homebrew formula)
#
# Common workflow:
#   make fpga-build                   # generate + synthesise + P&R -> bitstream
#   make fpga-load                    # load bitstream into FPGA SRAM (volatile)
#   make fpga-flash                   # write bitstream to on-board SPI flash
#   make fpga-console                 # open serial terminal on the dock UART
#
# Pass extra flags through EXTRA_FLAGS, e.g.:
#   make fpga-build EXTRA_FLAGS="--integrated-main-ram-size=0x8000"

FPGA_BOARD     ?= tang_mega_138k_pro ## Target FPGA board
FPGA_BOARD     := $(strip $(FPGA_BOARD))

# Boot ROM contents on the FPGA. Declared early because FPGA_DIR includes
# $(BOOT_MODE) in its path so `custom` and `bios` builds coexist without
# invalidating each other's PnR cache (switching is then free).
#   * BOOT_MODE=custom (default) — use firmware/fpga/ (boot.S + main.c) as the
#     ROM image; the SoC is built with `--no-compile-software`.
#   * BOOT_MODE=bios              — let LiteX compile + bake its own BIOS into
#     the ROM; produces the familiar `litex>` prompt over UART.
# Override on the command line, e.g.:  make fpga-build BOOT_MODE=bios
BOOT_MODE      ?= custom ## FPGA boot ROM source (custom=firmware/fpga, bios=LiteX BIOS)
BOOT_MODE      := $(strip $(BOOT_MODE))
ifneq ($(BOOT_MODE),custom)
ifneq ($(BOOT_MODE),bios)
$(error Invalid BOOT_MODE='$(BOOT_MODE)'. Use BOOT_MODE=custom or BOOT_MODE=bios)
endif
endif

# Per-BOOT_MODE output dir so `custom` and `bios` builds coexist and switching
# between them costs nothing (no cache invalidation, no re-PnR). Bitstream
# layout: build/<board>/<boot_mode>/gateware/<...>.fs
FPGA_DIR       := $(BUILD_DIR)/$(FPGA_BOARD)/$(BOOT_MODE)
FPGA_GW_DIR    := $(FPGA_DIR)/gateware
# LiteX names the bitstream after the platform module ("sipeed_<board>.fs").
FPGA_BITSTREAM := $(FPGA_GW_DIR)/sipeed_$(FPGA_BOARD).fs

# Resolve gw_sh from the Gowin IDE bundle (macOS .app layout).
ifneq ($(strip $(GOWIN_APP)),)
	GOWIN_BIN_DIR := $(GOWIN_APP)/Contents/Resources/Gowin_EDA/IDE/bin
	export PATH   := $(GOWIN_BIN_DIR):$(PATH)
endif

# openFPGALoader cable. Tang Mega 138K Pro ships with an FT2232-based debugger.
OFL          ?= openFPGALoader ## openFPGALoader binary
OFL_CABLE    ?= ft2232 ## openFPGALoader cable (ft2232 for Tang Mega Pro on-board debugger)
OFL := $(strip $(OFL))
OFL_CABLE := $(strip $(OFL_CABLE))

# Optional LedChaser (off by default to keep PnR density low on the Pro).
WITH_LED_CHASER_FLAG := $(if $(filter 1 yes true on,$(WITH_LED_CHASER)),--with-led-chaser,)

# FPGA SoC generator. Sim and FPGA flows live in separate scripts so each one
# only pulls in its own toolchain dependencies (Verilator vs. Gowin):
#   * raptor_soc.py                     — sim only (SimPlatform + Verilator)
#   * raptor_tang_mega_138k_pro.py      — Tang Mega 138K Pro only
FPGA_PY    := raptor_tang_mega_138k_pro.py

ifeq ($(BOOT_MODE),custom)
_FPGA_BOOT_FLAGS := --boot-mode=custom --integrated-rom-init=$(FW_FPGA_BIN)
_FPGA_FW_DEP     := $(FW_FPGA_BIN)
else
_FPGA_BOOT_FLAGS := --boot-mode=bios
_FPGA_FW_DEP     :=
endif

_FPGA_FLAGS = --output-dir=$(FPGA_DIR) \
	--cpu-variant=$(VARIANT) --sys-clk-freq=$(SYS_CLK) \
	$(_FPGA_BOOT_FLAGS) \
	$(_MAIN_RAM_FLAG) \
	$(WITH_LED_CHASER_FLAG) $(EXTRA_FLAGS)

# Content-hash skip for fpga-build (avoid re-running 10+ minute Gowin PnR
# when nothing the bitstream depends on has changed). The hash covers:
#   * the packed RTL ($(PACK_SV))
#   * the FPGA-side firmware bin ($(FW_FPGA_BIN), only used when BOOT_MODE=custom)
#   * all flags that flow into _FPGA_FLAGS (board, variant, clock, boot mode,
#     extra Python args)
# Stored at $(FPGA_DIR)/.bitstream_stamp; if it matches and the .fs exists,
# fpga-build short-circuits with a one-line "[INFO] up-to-date" message.
#
# Why content-hash instead of mtime: switching git branches or re-packing RTL
# can leave the .fs newer than its inputs even though the inputs would
# regenerate identical content. The hash catches both directions.
#
# Tip: when iterating *only* on payloads (programs that run in main_ram,
# not the boot ROM), you don't need to rebuild the bitstream at all.
# Burn the bitstream once with `BOOT_MODE=bios`, then upload payloads via
# `litex_term --kernel=<bin>` over UART (LiteX BIOS `serialboot`). This
# requires `--integrated-main-ram-size=...` in EXTRA_FLAGS, which is
# currently disabled on the Pro for PnR-density reasons.
FPGA_STAMP    := $(FPGA_DIR)/.bitstream_stamp
ifeq ($(BOOT_MODE),custom)
_FPGA_HASH_INPUTS = $(PACK_SV) $(FW_FPGA_BIN)
else
_FPGA_HASH_INPUTS = $(PACK_SV)
endif
# `_FPGA_HASH_KEY` mixes file content + flags so any change forces a rebuild.
_FPGA_HASH_KEY = $(shell { cat $(_FPGA_HASH_INPUTS) 2>/dev/null; printf '%s' '$(_FPGA_FLAGS)'; } | shasum 2>/dev/null | cut -d' ' -f1)

fpga-detect: ## Detect connected Gowin/Sipeed FPGA via openFPGALoader {OFL,OFL_CABLE}
	@command -v $(OFL) >/dev/null 2>&1 || { echo "[ERR] openFPGALoader not found (install via brew install openfpgaloader)"; exit 1; }
	$(OFL) --detect --cable $(OFL_CABLE)

fpga-gen: $(PACK_SV) $(_FPGA_FW_DEP) ## Generate FPGA SoC sources only (no PnR) {BOOT_MODE,FPGA_BOARD,RAPT_CONFIG,INTEGRATED_MAIN_RAM_SIZE}
	source $(VENV_DIR)/bin/activate && \
	$(PYTHON) $(FPGA_PY) $(_FPGA_FLAGS) --build --no-compile-gateware
	@echo "[INFO] Sources generated under $(FPGA_GW_DIR) (BOOT_MODE=$(BOOT_MODE))"

fpga-build: $(PACK_SV) $(_FPGA_FW_DEP) ## Build FPGA bitstream (synth + P&R) {BOOT_MODE,FPGA_BOARD,RAPT_CONFIG,INTEGRATED_MAIN_RAM_SIZE,WITH_LED_CHASER}
	@if [ -z "$(strip $(GOWIN_APP))" ]; then \
		echo "[ERR] GOWIN_APP is empty — install GowinIDE.app or set GOWIN_APP=/path/to/GowinIDE.app"; exit 1; fi
	@if [ ! -x "$(GOWIN_BIN_DIR)/gw_sh" ]; then \
		echo "[ERR] gw_sh not found at $(GOWIN_BIN_DIR)/gw_sh"; exit 1; fi
	@mkdir -p $(FPGA_DIR)
	@OLD_HASH=$$(cat $(FPGA_STAMP) 2>/dev/null || echo ""); \
	NEW_HASH="$(_FPGA_HASH_KEY)"; \
	if [ -f "$(FPGA_BITSTREAM)" ] && [ "$$OLD_HASH" = "$$NEW_HASH" ]; then \
		echo "[INFO] Bitstream up to date (BOOT_MODE=$(BOOT_MODE), hash=$${NEW_HASH:0:12})"; \
		echo "[INFO]   $(FPGA_BITSTREAM)"; \
		echo "[INFO] Force rebuild with: make fpga-build-force"; \
		$(MAKE) --no-print-directory fpga-reports-index; \
		exit 0; \
	fi; \
	echo "[INFO] Bitstream stale (old=$${OLD_HASH:0:12} new=$${NEW_HASH:0:12}); running Gowin..."; \
	if [ "$(BOOT_MODE)" = "bios" ]; then $(call _litex_bios_patches_apply); fi; \
	trap '[ "$(BOOT_MODE)" = "bios" ] && { $(call _litex_bios_patches_restore); } || true' EXIT; \
	source $(VENV_DIR)/bin/activate && \
	$(PYTHON) $(FPGA_PY) $(_FPGA_FLAGS) --build && \
	printf '%s' "$$NEW_HASH" > $(FPGA_STAMP)
	@$(MAKE) --no-print-directory fpga-reports-index
	@echo ""
	@echo "========================================="
	@echo " Bitstream ready: $(FPGA_BITSTREAM)"
	@echo " Load (volatile):  make fpga-load"
	@echo " Flash (persist):  make fpga-flash"
	@echo " Reports index:    $(FPGA_GW_DIR)/impl/index.html"
	@echo "========================================="

# Aggregated HTML dashboard for all Gowin synth/PnR reports. Lets you open one
# file (impl/reports.html) and switch between syn / PnR / timing / power / pin
# reports via a sidebar, instead of hunting them down individually.
FPGA_REPORTS_INDEX_SRC := $(LITEX_DIR)/scripts/reports_index.html
FPGA_REPORTS_INDEX_DST := $(FPGA_GW_DIR)/impl/index.html

fpga-reports-index: ## Install aggregated HTML report dashboard at impl/index.html
	@if [ -d "$(FPGA_GW_DIR)/impl" ]; then \
		cp $(FPGA_REPORTS_INDEX_SRC) $(FPGA_REPORTS_INDEX_DST); \
		echo "[INFO] Reports index: $(FPGA_REPORTS_INDEX_DST)"; \
	else \
		echo "[WARN] $(FPGA_GW_DIR)/impl not found — run 'make fpga-build' first."; \
	fi

fpga-build-force: ## Force full re-PnR (ignore content-hash cache) {BOOT_MODE,FPGA_BOARD,RAPT_CONFIG,INTEGRATED_MAIN_RAM_SIZE}
	@rm -f $(FPGA_STAMP)
	@$(MAKE) --no-print-directory fpga-build

fpga-load: ## Load bitstream into FPGA SRAM (volatile, lost on power-cycle) {OFL,OFL_CABLE,BOOT_MODE,FPGA_BOARD}
	@if [ ! -f "$(FPGA_BITSTREAM)" ]; then \
		echo "[ERR] $(FPGA_BITSTREAM) not found — run 'make fpga-build' first."; exit 1; fi
	@command -v $(OFL) >/dev/null 2>&1 || { echo "[ERR] openFPGALoader not found"; exit 1; }
	$(OFL) --cable $(OFL_CABLE) --bitstream $(FPGA_BITSTREAM)

fpga-flash: ## Write bitstream to external SPI flash (persists across power cycles) {OFL,OFL_CABLE,BOOT_MODE,FPGA_BOARD}
	@if [ ! -f "$(FPGA_BITSTREAM)" ]; then \
		echo "[ERR] $(FPGA_BITSTREAM) not found — run 'make fpga-build' first."; exit 1; fi
	@command -v $(OFL) >/dev/null 2>&1 || { echo "[ERR] openFPGALoader not found"; exit 1; }
	$(OFL) --cable $(OFL_CABLE) --write-flash --external-flash --bitstream $(FPGA_BITSTREAM)

fpga: fpga-build fpga-load ## Build + load (volatile) in one shot

fpga-console: ## Open serial terminal on the FPGA UART (Ctrl-A K to quit) {UART_PORT,UART_BAUD}
	@if [ -z "$(UART_PORT)" ]; then \
		echo "[ERR] UART_PORT empty — plug in the board or set UART_PORT=/dev/tty.usbserial-XXXX"; exit 1; fi
	@command -v lm.flterm >/dev/null 2>&1 || command -v litex_term >/dev/null 2>&1 || true
	@echo "[INFO] Opening $(UART_PORT) @ $(UART_BAUD) baud (Ctrl-A K = quit)"
	source $(VENV_DIR)/bin/activate && \
	litex_term --speed=$(UART_BAUD) $(UART_PORT)

# Upload a binary into main_ram via LiteX BIOS `serialboot` and run it.
# Requires:
#   * BOOT_MODE=bios bitstream flashed (LiteX BIOS in ROM)
#   * INTEGRATED_MAIN_RAM_SIZE > 0 in that bitstream (default 512 KB)
#   * Firmware linked at 0x80000000 (use FW_FPGA_LOAD=main_ram)
#
# `litex_term --kernel=BIN` keeps the console open and intercepts the BIOS
# `Booting from serial...` prompt to send the binary via SFL, after which
# the BIOS jumps to MAIN_RAM_BASE. Saves a full PnR (~10 min) for every
# firmware iteration.
#
# Usage:
#   make firmware-fpga FW_FPGA_TARGET=irqtest FW_FPGA_LOAD=main_ram
#   make fpga-upload   FW_FPGA_TARGET=irqtest FW_FPGA_LOAD=main_ram
# Or override the binary directly:
#   make fpga-upload   BIN=/path/to/firmware.bin
fpga-upload: ## Upload a firmware bin to main_ram via BIOS serialboot (no PnR) {FW_FPGA_TARGET,FW_FPGA_LOAD,MAIN_RAM_BASE,UART_PORT,UART_BAUD}
	@if [ -z "$(UART_PORT)" ]; then \
		echo "[ERR] UART_PORT empty — set UART_PORT=/dev/tty.usbserial-XXXX"; exit 1; fi
	@bin="$(BIN)"; [ -z "$$bin" ] && bin="$(FW_FPGA_BIN)"; \
	if [ ! -f "$$bin" ]; then \
		echo "[ERR] $$bin not found — build it first (e.g. 'make firmware-fpga FW_FPGA_TARGET=$(FW_FPGA_TARGET) FW_FPGA_LOAD=main_ram')"; exit 1; fi; \
	echo "[INFO] Uploading $$bin to MAIN_RAM ($(MAIN_RAM_BASE)) via BIOS serialboot on $(UART_PORT)"; \
	echo "[INFO] Power-cycle / press the reboot button on the board if the BIOS prompt has timed out."; \
	source $(VENV_DIR)/bin/activate && \
	litex_term --speed=$(UART_BAUD) --kernel="$$bin" --kernel-adr=$(MAIN_RAM_BASE) $(UART_PORT)

fpga-clean: ## Remove FPGA build artifacts
	rm -rf $(FPGA_DIR)

# ==============================================================================
# Utilities
# ==============================================================================

clean: ## Remove build artifacts
	rm -rf $(BUILD_DIR)
	@echo "Build artifacts cleaned."

sim-clean: ## Force next sim-build to recompile (clear all verilator caches under build/sim/)
	@rm -rf $(BUILD_DIR)/sim
	@echo "Verilator binary + hash cache cleared (all VARIANT-ROM-SOC combinations)."

clean-all: clean firmware-clean ## Remove build artifacts + firmware + venv
	rm -rf $(VENV_DIR)
	@echo "Virtual environment removed."

lint: ## Lint RTL (via nsim)
	$(MAKE) -C $(RAPTOR_HOME) lint

info: ## Show configuration info
	@echo "RAPTOR_HOME  = $(RAPTOR_HOME)"
	@echo "LITEX_DIR    = $(LITEX_DIR)"
	@echo "VARIANT      = $(VARIANT)"
	@echo "SYS_CLK      = $(SYS_CLK)"
	@echo "RAPT_CONFIG  = $(RAPT_CONFIG)"
	@echo "GOWIN_APP    = $(GOWIN_APP)"
	@echo "GOWIN_BIN_DIR= $(GOWIN_BIN_DIR)"
	@echo "OFL          = $(OFL)"
	@echo "OFL_CABLE    = $(OFL_CABLE)"
	@echo "UART_PORT    = $(UART_PORT)"
	@echo "SIM_TIMEOUT  = $(SIM_TIMEOUT)"
	@echo "PACK_SV      = $(PACK_SV)"
	@echo "BUILD_DIR    = $(BUILD_DIR)"
	@echo "---- sim ----"
	@echo "ROM          = $(ROM)"
	@echo "SOC          = $(SOC)"
	@echo "PAYLOAD      = $(PAYLOAD)"
	@echo "SIM_DIR      = $(SIM_DIR)"
	@echo "SIM_GW_DIR   = $(SIM_GW_DIR)"
	@echo "VSIM         = $(SIM_GW_DIR)/obj_dir/Vsim (exists: $(shell test -f $(SIM_GW_DIR)/obj_dir/Vsim && echo yes || echo no))"
	@echo "---- fpga ----"
	@echo "FPGA_BOARD   = $(FPGA_BOARD)"
	@echo "FPGA_DIR     = $(FPGA_DIR)"
	@echo "FPGA_BITSTRM = $(FPGA_BITSTREAM) (exists: $(shell test -f $(FPGA_BITSTREAM) && echo yes || echo no))"
	@echo "BOOT_MODE    = $(BOOT_MODE)"
	@echo "FPGA_STAMP   = $(FPGA_STAMP) (cached: $(shell test -f $(FPGA_STAMP) && echo yes || echo no))"
	@echo "PYTHON       = $(PYTHON)"

help: ## Show this help message
	@echo "Usage: make <target> [VAR=value ...]"
	@awk -v file="$(MAKEFILE_LIST)" 'BEGIN { \
			while ((getline line < file) > 0) { \
				if (match(line, /^[A-Z_][A-Z_0-9]*[ \t]*\?=/)) { \
					name = substr(line, 1, RLENGTH); sub(/[ \t]*\?=$$/, "", name); \
					rest = substr(line, RLENGTH+1); \
					sub(/^[ \t]+/, "", rest); sub(/[ \t]*##.*/, "", rest); sub(/[ \t]+$$/, "", rest); \
					if (!(name in defaults)) defaults[name] = rest; \
				} \
			} \
			close(file); \
			state=0; pending=""; first_target=1 \
		} \
		/^# =+$$/ { \
			if (state==0) state=1; \
			else if (state==2) { pending=section; state=0 } \
			else state=0; next } \
		state==1 && /^# .+/ { section=substr($$0,3); state=2; next } \
		{ if (state==1) state=0 } \
		/^[a-zA-Z0-9_-]+:.*## / { \
			if (pending!="") { printf "\n%s:\n", pending; pending="" } \
			else if (first_target) printf "\nTargets:\n"; \
			first_target=0; \
			target=$$0; sub(/:.*/, "", target); \
			desc=$$0; sub(/.*## /, "", desc); \
			vars=""; \
			if (match(desc, /\{[^}]+\}[ \t]*$$/)) { \
				vars=substr(desc, RSTART+1, RLENGTH-2); sub(/[ \t]+$$/, "", vars); \
				desc=substr(desc, 1, RSTART-1); sub(/[ \t]+$$/, "", desc); \
				out="["; n=split(vars, vlist, /[ \t]*,[ \t]*/); \
				for (i=1; i<=n; i++) { \
					v=vlist[i]; def=(v in defaults) ? defaults[v] : ""; \
					if (def ~ /^\$$\(shell/) def="<auto>"; \
					if (i>1) out=out" "; \
					out=out v "=" def; \
				} \
				out=out"]"; \
				desc=desc " " out; \
			} \
			printf "  %-20s %s\n", target, desc }' $(MAKEFILE_LIST)
	@echo ""
	@echo "Variables (override with VAR=value):"
	@grep -hE '^[A-Z_][A-Z_0-9]*\s*\?=' $(MAKEFILE_LIST) | \
		awk '!seen[$$1]++ { \
			if (match($$0, /## /)) { \
				name=$$0; sub(/\s*\?=.*/, "", name); \
				desc=substr($$0, RSTART+3); \
				printf "  %-20s %s\n", name, desc } \
			else { \
				split($$0, a, "\\?="); \
				gsub(/^[ \t]+|[ \t]+$$/, "", a[1]); gsub(/^[ \t]+|[ \t]+$$/, "", a[2]); \
				if (a[2] != "") printf "  %-20s (default: %s)\n", a[1], a[2] } }'
	@echo ""

# ==============================================================================
# PHONY declarations
# ==============================================================================
.PHONY: help setup setup-skip \
	pack \
	firmware firmware-sim firmware-fpga firmware-clean \
	sim-gen sim-build sim sim-run sim-trace sim-trace-vcd sim-clean \
	coremark coremark-build coremark-clean coremark-fpga \
	main-fpga-build main-fpga donut-fpga irqtest-fpga main-fpga-clean \
	embench embench-build embench-build-one embench-run embench-report embench-clean \
	$(EMBENCH_TARGETS) $(EMBENCH_BUILDS) \
	app-llm-build app-llm-run app-llm-fpga app-fpga-upload \
	$(APP_LLM_TARGETS) $(APP_LLM_BUILDS) $(APP_LLM_FPGAS) \
	microbench microbench-build \
	tests tests-clean tests-run $(TEST_TARGETS) \
	opensbi opensbi-build opensbi-clean \
	payload \
	linux linux-build \
	bios \
	fpga-gen fpga-build fpga-build-force fpga-load fpga-flash fpga fpga-console fpga-upload fpga-clean fpga-detect fpga-reports-index \
	tang-mega-138k-pro \
	lint info clean clean-all
