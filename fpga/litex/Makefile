# fpga/litex/Makefile — Raptor LiteX SoC build system. Run `make help` for targets/vars.

# ============================================================================
# fpga/litex/Makefile — Raptor LiteX SoC build system
# ============================================================================

SHELL         := /bin/bash
.DEFAULT_GOAL := help

LITEX_DIR   := $(abspath .)
RAPTOR_HOME := $(abspath ../..)
NSIM_DIR    := $(RAPTOR_HOME)/sim
RTL_DIR     := $(RAPTOR_HOME)/hdl
BUILD_DIR   := $(LITEX_DIR)/build
VENV_DIR    := $(LITEX_DIR)/.venv
PYTHON      := $(VENV_DIR)/bin/python3
PIP         := $(VENV_DIR)/bin/pip
HOST_PYTHON := $(shell if [ -x "$(PYTHON)" ]; then echo "$(PYTHON)"; elif command -v python3 >/dev/null 2>&1; then command -v python3; elif command -v python >/dev/null 2>&1; then command -v python; fi)
TIMEOUT_BIN := $(shell command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null)
NPROC       := $(shell nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

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

BOARDS := tang_mega_138k_pro mlk_cu08_ku15p mlk_cu07_ku15p alinx_axau15 xilinx_vcu118
BOARD_ALIASES := $(subst _,-,$(BOARDS))

# Gowin IDE bundle (macOS). Empty on Linux / when GowinIDE is not installed; it
# drives the on-board Gowin Tang synthesis/PnR flow (load/flash use openFPGALoader).
GOWIN_APP   ?= $(firstword $(wildcard /Applications/GowinIDE.app /Applications/GowinIDE.edu.app)) ## Gowin IDE app bundle path on macOS. Synthesis/PnR only; load/flash use openFPGALoader.
VIVADO     ?= vivado ## Vivado executable for Xilinx build, detection, load, and flash flows
OFL        ?= openFPGALoader ## openFPGALoader binary
OFL_CABLE  ?= ft2232 ## openFPGALoader cable (ft2232 for Tang Mega Pro on-board debugger)
FPGA_AUTO_DETECT ?= 1 ## Auto-select a connected supported Xilinx board for FPGA goals (1=yes, 0=use defaults)
FPGA_DETECT_REFRESH ?= 0 ## Set to 1 to refresh the cached Vivado board detection before an FPGA goal
FPGA_DETECT_CACHE ?= $(BUILD_DIR)/.fpga_detect_parts ## Persistent Vivado detection cache (refreshed by fpga-detect)
FPGA_DETECT_INFO_CACHE ?= $(BUILD_DIR)/.fpga_detect_info ## Connected FPGA target details cache
FPGA_DETECT_COUNT_CACHE ?= $(BUILD_DIR)/.fpga_detect_count ## Connected FPGA count cache
FPGA_DETECT_CACHE := $(strip $(FPGA_DETECT_CACHE))
FPGA_DETECT_INFO_CACHE := $(strip $(FPGA_DETECT_INFO_CACHE))
FPGA_DETECT_COUNT_CACHE := $(strip $(FPGA_DETECT_COUNT_CACHE))
VIVADO := $(strip $(VIVADO))
OFL := $(strip $(OFL))
OFL_CABLE := $(strip $(OFL_CABLE))

BOARD ?= ## Convenience alias for FPGA_BOARD (for example BOARD=mlk_cu08_ku15p)
# BOARD is a convenience alias for selecting a build board. Normalize it before
# profile configuration so it also disables connected-board auto-detection.
ifneq ($(strip $(BOARD)),)
ifneq ($(filter command line environment override,$(origin FPGA_BOARD)),)
ifneq ($(strip $(BOARD)),$(strip $(FPGA_BOARD)))
$(error Conflicting board selections: BOARD='$(BOARD)' and FPGA_BOARD='$(FPGA_BOARD)')
endif
else
override FPGA_BOARD := $(strip $(BOARD))
endif
endif

LITEX_CONFIG_PHASE := profile
include $(LITEX_DIR)/mk/config.mk

# ---------------------------------------------------------------------------
# Linux FPGA profile: enabled on FPGA goals when VARIANT is linux32/linux64.
#
# It flips the FPGA board/MIG/clock/baud/boot defaults to the KU15P Linux
# bring-up flow, so `make fpga-* VARIANT=linux32` behaves like the retired
# `linux-fpga-*` commands. Sim goals (`make sim VARIANT=linux32`, `make linux32`)
# do not contain "fpga" and therefore keep the simulation defaults.
#
# When an FPGA goal is requested without an explicit VARIANT and no Gowin IDE is
# installed (GOWIN_APP empty, e.g. on Linux), the on-board Gowin Tang flow cannot
# run, so default to VARIANT=linux32 (the KU15P Linux/MIG Vivado profile).
# ---------------------------------------------------------------------------
# Benchmark / firmware upload helpers run ON the already-loaded bitstream, so they
# must default to the SAME profile (and therefore SYS_CLK) as fpga-load. Otherwise
# the payload's rdtime timebase — baked in at build time from SYS_CLK — won't match
# the running SoC's mtime rate, giving a wrong reported time (e.g. coremark showed
# 64.8 s vs ~13 s wall clock when a 50 MHz linux bitstream was loaded but coremark
# was built for a 10 MHz profile: a 5x over-report).
VARIANT ?= $(call _default_variant) ## CPU variant (linux32|linux64)
VARIANT := $(strip $(VARIANT))
ifeq ($(filter $(VARIANT),linux32 linux64),)
$(error Invalid VARIANT='$(VARIANT)'. Use VARIANT=linux32 or VARIANT=linux64)
endif
$(call _linux_profile_notice)
LINUX_FPGA_PROFILE := $(if $(or $(call _linux_fpga_profile,$(VARIANT)),$(filter mlk_cu08_ku15p,$(FPGA_BOARD))),1,)
FPGA_BOARD ?= $(call _default_fpga_board) ## Target FPGA board (auto-detected for FPGA goals, otherwise profile default)
FPGA_BOARD := $(strip $(FPGA_BOARD))
ifeq ($(filter $(FPGA_BOARD),$(BOARDS)),)
$(error Invalid FPGA_BOARD='$(FPGA_BOARD)'. Known boards: $(BOARDS))
endif
FPGA_BOARD_SOURCE := $(if $(_FPGA_BOARD_EXPLICIT),explicit,$(if $(FPGA_DETECTED_BOARD),auto,default))
FPGA_VENDOR    := $(BOARD_$(FPGA_BOARD)_VENDOR)
FPGA_PY        := $(BOARD_$(FPGA_BOARD)_PY)
FPGA_TIMINGRPT := $(BOARD_$(FPGA_BOARD)_TIMINGRPT)
FPGA_DEVICE    := $(BOARD_$(FPGA_BOARD)_DEVICE)
FPGA_PART      := $(BOARD_$(FPGA_BOARD)_PART)
_LINUX_FPGA_ARGS = VARIANT=$(LINUX_VARIANT) FPGA_BOARD=$(FPGA_BOARD)
_LINUX_FPGA_RV32_ARGS = VARIANT=linux32 FPGA_BOARD=$(FPGA_BOARD)
_LINUX_FPGA_RV64_ARGS = VARIANT=linux64 FPGA_BOARD=$(FPGA_BOARD)

SYS_CLK     ?= $(if $(LINUX_FPGA_PROFILE),$(BOARD_$(FPGA_BOARD)_LINUX_SYS_CLK),$(BOARD_$(FPGA_BOARD)_DEFAULT_SYS_CLK)) ## System clock in Hz (board/profile default)
SIM_TIMEOUT ?= 30 ## Simulation timeout in seconds (0=unlimited)
RAPT_CONFIG ?= $(BOARD_$(FPGA_BOARD)_DEFAULT_RAPT_CONFIG) ## Raptor uarch config preset (default|middle|small|...)
RAPT_CONFIG := $(strip $(RAPT_CONFIG))
export RAPT_CONFIG
LITEX_LOG_DIR := $(NSIM_DIR)/build/$(RAPT_CONFIG)/logs/litex
WITH_LED_CHASER ?= 0 ## Set to 1 to add LedChaser to fpga-build (off by default on the Pro for PnR density relief)
WITH_LITEDRAM ?= $(if $(LINUX_FPGA_PROFILE),$(BOARD_$(FPGA_BOARD)_LINUX_WITH_LITEDRAM),0) ## Set to 1 to use external LiteDRAM/DDR4 as FPGA main_ram
LITEDRAM_SIZE ?= $(BOARD_$(FPGA_BOARD)_LITEDRAM_SIZE) ## Mapped external LiteDRAM main_ram size in bytes
WITH_MIG ?= $(if $(LINUX_FPGA_PROFILE),$(BOARD_$(FPGA_BOARD)_LINUX_WITH_MIG),0) ## Set to 1 to use board-supported Xilinx DDR4 MIG as FPGA main_ram
MIG_SIZE ?= 0x40000000 ## Mapped external MIG main_ram size in bytes
WITH_SDCARD ?= $(if $(LINUX_FPGA_PROFILE),$(BOARD_$(FPGA_BOARD)_LINUX_WITH_SDCARD),$(BOARD_$(FPGA_BOARD)_DEFAULT_WITH_SDCARD)) ## Add the board-supported SDCard controller/DMA when available
SDCARD_BOOT ?= 0 ## Set to 1 to make LiteX BIOS automatically try SDCard boot
ifneq (,$(filter 1 yes true on,$(WITH_LITEDRAM)))
ifeq ($(BOARD_$(FPGA_BOARD)_HAS_LITEDRAM),0)
$(error WITH_LITEDRAM is not implemented for FPGA_BOARD=$(FPGA_BOARD))
endif
endif
ifneq (,$(filter 1 yes true on,$(WITH_SDCARD)))
ifeq ($(BOARD_$(FPGA_BOARD)_HAS_SDCARD),0)
$(error WITH_SDCARD is not implemented for FPGA_BOARD=$(FPGA_BOARD))
endif
endif
ifneq (,$(filter 1 yes true on,$(WITH_MIG)))
ifeq ($(BOARD_$(FPGA_BOARD)_HAS_MIG),0)
$(error WITH_MIG is not implemented for FPGA_BOARD=$(FPGA_BOARD))
endif
endif
ifneq (,$(filter 1 yes true on,$(SDCARD_BOOT)))
ifeq (,$(filter 1 yes true on,$(WITH_SDCARD)))
$(error SDCARD_BOOT requires WITH_SDCARD=1)
endif
endif
# Auto-detect the serial device. Prefer /dev/ttyUSB0 (the common UART channel,
# e.g. the MLK-CU07 KU15P), then fall back to the highest-sorted device for
# macOS / other setups. A board-specific BOARD_<b>_UART override (see above)
# still takes precedence, and an explicit UART_PORT=... always wins.
UART_PORT_AUTO := $(firstword $(wildcard /dev/ttyUSB0) $(shell ls -1 /dev/tty.usbserial* /dev/tty.wchusbserial* /dev/tty.usbmodem* /dev/ttyUSB* /dev/ttyACM* 2>/dev/null | sort | tail -n 1))
UART_PORT   ?= $(firstword $(wildcard $(BOARD_$(FPGA_BOARD)_UART)) $(UART_PORT_AUTO)) ## Serial device for fpga-console
override UART_BAUD := 115200 ## Fixed FPGA UART/SFL baud; command-line and environment overrides are intentionally ignored
SERIALBOOT_SAFE ?= 1 ## Set to 0 to re-enable litex_term upload speed optimizations

SIM_THREADS ?= 4 ## Verilator simulation threads (1=off)

TRACE ?= none ## Wave dump mode (none|fst|vcd)

TRACE_START ?= 0 ## Start dump at cycle N (0=from t=0)
TRACE_END   ?= -1 ## Stop dump at cycle N (-1=no end)

_VSTRIP1 := VARIANT SYS_CLK SIM_TIMEOUT GOWIN_APP FPGA_DETECT_REFRESH FPGA_DETECT_CACHE WITH_LED_CHASER WITH_LITEDRAM LITEDRAM_SIZE WITH_MIG MIG_SIZE WITH_SDCARD SDCARD_BOOT UART_PORT UART_BAUD SERIALBOOT_SAFE SIM_THREADS TRACE TRACE_START TRACE_END
$(foreach v,$(_VSTRIP1),$(eval $v := $(strip $($v))))
SERIALBOOT_SAFE_FLAG := $(if $(filter 1 yes true on,$(SERIALBOOT_SAFE)),--safe,)

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

ifneq ($(TRACE),none)
	TRACE_FLAGS += --trace-start-cycle=$(TRACE_START)
	TRACE_MSG   := $(TRACE_MSG) [start @ cycle $(TRACE_START)]
	ifneq ($(TRACE_END),-1)
		TRACE_FLAGS += --trace-end-cycle=$(TRACE_END)
		TRACE_MSG   := $(TRACE_MSG) [end(exclusive) @ cycle $(TRACE_END)]
	endif
endif

EXTRA_FLAGS ?= ## Extra flags passed to raptor_soc.py
ifeq ($(LINUX_FPGA_PROFILE),1)
MEMSPEED_TRACE ?= 0 ## (linux FPGA profile) add LiteX BIOS memspeed phase trace markers
EXTRA_FLAGS := $(strip $(EXTRA_FLAGS) $(if $(filter 1 yes true on,$(MEMSPEED_TRACE)),--rapt-memspeed-trace,))
endif
RAPT_PACK_VFLAGS ?= ## Extra defines passed to the sim RTL pack rule
RAPT_PACK_VFLAGS := $(strip $(RAPT_PACK_VFLAGS))
RAPT_PACK_SYS_CLK_MHZ := $(shell awk 'BEGIN { printf "%d", ($(SYS_CLK) + 500000) / 1000000 }')
ifeq (,$(findstring -DRAPT_CORE_CLOCK_MHZ=,$(RAPT_PACK_VFLAGS)))
RAPT_PACK_VFLAGS := $(strip $(RAPT_PACK_VFLAGS) -DRAPT_CORE_CLOCK_MHZ=$(RAPT_PACK_SYS_CLK_MHZ))
endif
ifeq (,$(findstring -DRAPT_MTIME_FREQ_MHZ=,$(RAPT_PACK_VFLAGS)))
RAPT_PACK_VFLAGS := $(strip $(RAPT_PACK_VFLAGS) -DRAPT_MTIME_FREQ_MHZ=$(RAPT_PACK_SYS_CLK_MHZ))
endif
export RAPT_PACK_VFLAGS

_WITH_EXTERNAL_MAIN_RAM := $(strip $(filter 1 yes true on,$(WITH_LITEDRAM) $(WITH_MIG)))
INTEGRATED_MAIN_RAM_SIZE ?= $(if $(_WITH_EXTERNAL_MAIN_RAM),0,$(if $(LINUX_FPGA_PROFILE),$(BOARD_$(FPGA_BOARD)_LINUX_MAIN_RAM_SIZE),0x80000)) ## BSRAM-backed main_ram size at 0x80000000 (automatically 0 with external RAM)
INTEGRATED_MAIN_RAM_SIZE := $(strip $(INTEGRATED_MAIN_RAM_SIZE))
ifneq ($(_WITH_EXTERNAL_MAIN_RAM),)
ifneq ($(INTEGRATED_MAIN_RAM_SIZE),0)
$(error External RAM requires INTEGRATED_MAIN_RAM_SIZE=0 (got $(INTEGRATED_MAIN_RAM_SIZE)))
endif
endif
ifneq ($(INTEGRATED_MAIN_RAM_SIZE),0)
_MAIN_RAM_FLAG := --integrated-main-ram-size=$(INTEGRATED_MAIN_RAM_SIZE)
else
_MAIN_RAM_FLAG :=
endif

# ==============================================================================
# Environment
# ==============================================================================

setup: ## Install LiteX environment + register Raptor CPU

setup-skip: ## Activate venv without reinstalling

# ==============================================================================
# RTL Packing
# ==============================================================================

PACK_SV := $(NSIM_DIR)/build/$(or $(RAPT_CONFIG),default)/rapt_pack.sv

NSIM_RTL_DIR := $(RAPTOR_HOME)/sim/rtl
CHISEL_DIR := $(RTL_DIR)/chisel
CHISEL_GENERATED_SRCS := $(RTL_DIR)/generated/rapt_idu_decoder.sv \
	$(RTL_DIR)/generated/rapt_idu_decoder_c.sv
CHISEL_INPUTS := $(shell find $(CHISEL_DIR)/src $(CHISEL_DIR)/project -type f 2>/dev/null) \
	$(CHISEL_DIR)/build.sbt $(CHISEL_DIR)/Makefile
RTL_SOURCES := $(sort $(shell find $(RTL_DIR) $(NSIM_RTL_DIR) -type f \( -name '*.sv' -o -name '*.svh' -o -name '*.v' -o -name '*.vh' \) 2>/dev/null) $(CHISEL_GENERATED_SRCS))

RAPT_CONFIG_STAMP := $(BUILD_DIR)/.rapt_config_stamp
RAPT_CONFIG_PREV  := $(shell cat $(RAPT_CONFIG_STAMP) 2>/dev/null)
RAPT_CONFIG_STAMP_EXISTS := $(wildcard $(RAPT_CONFIG_STAMP))
ifneq ($(RAPT_CONFIG),$(RAPT_CONFIG_PREV))
$(shell mkdir -p $(BUILD_DIR) && printf '%s' '$(RAPT_CONFIG)' > $(RAPT_CONFIG_STAMP))
$(info [litex] RAPT_CONFIG changed: '$(RAPT_CONFIG_PREV)' -> '$(RAPT_CONFIG)', re-packing...)
else ifeq ($(RAPT_CONFIG_STAMP_EXISTS),)
$(shell mkdir -p $(BUILD_DIR) && printf '%s' '$(RAPT_CONFIG)' > $(RAPT_CONFIG_STAMP))
endif

RAPT_PACK_VFLAGS_STAMP := $(BUILD_DIR)/.rapt_pack_vflags_stamp
RAPT_PACK_VFLAGS_PREV  := $(shell cat $(RAPT_PACK_VFLAGS_STAMP) 2>/dev/null)
RAPT_PACK_VFLAGS_STAMP_EXISTS := $(wildcard $(RAPT_PACK_VFLAGS_STAMP))
ifneq ($(RAPT_PACK_VFLAGS),$(RAPT_PACK_VFLAGS_PREV))
$(shell mkdir -p $(BUILD_DIR) && printf '%s' '$(RAPT_PACK_VFLAGS)' > $(RAPT_PACK_VFLAGS_STAMP))
$(info [litex] RAPT_PACK_VFLAGS changed: '$(RAPT_PACK_VFLAGS_PREV)' -> '$(RAPT_PACK_VFLAGS)', re-packing...)
else ifeq ($(RAPT_PACK_VFLAGS_STAMP_EXISTS),)
$(shell mkdir -p $(BUILD_DIR) && printf '%s' '$(RAPT_PACK_VFLAGS)' > $(RAPT_PACK_VFLAGS_STAMP))
endif

pack: ## Pack all RTL into single preprocessed SV file

# ==============================================================================
# Firmware (minimal boot ROM)
# ==============================================================================

ifeq ($(shell uname -s),Linux)
CROSS     ?= riscv64-linux-gnu-
else
CROSS     ?= riscv64-unknown-elf-
endif
FW_BASE   := $(LITEX_DIR)/firmware

FW_SIM_SRC := $(FW_BASE)/sim
FW_SIM_DIR := $(BUILD_DIR)/firmware/sim
FW_SIM_BIN := $(FW_SIM_DIR)/boot.bin
FW_SIM_ELF := $(FW_SIM_DIR)/boot.elf
FW_SIM_DTB := $(FW_SIM_DIR)/litex-soc.dtb
FW_SIM_DTS := $(FW_SIM_SRC)/litex-soc.dts

FW_FPGA_TARGET ?= main ## firmware/fpga/main_<TARGET>.c (or main.c when =main)
FW_FPGA_LOAD   ?= rom  ## Link target: rom (integrated ROM) or main_ram (uploadable via serialboot)
MAIN_RAM_BASE  ?= 0x80000000 ## main_ram base addr (must match raptor_soc.py mem_map; serialboot upload target)
FW_FPGA_TARGET := $(strip $(FW_FPGA_TARGET))
FW_FPGA_LOAD   := $(strip $(FW_FPGA_LOAD))
MAIN_RAM_BASE  := $(strip $(MAIN_RAM_BASE))
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

FW_FPGA_CFLAGS := -march=rv32imac_zicsr -mabi=ilp32 -ffreestanding -nostdlib \
	-nostartfiles -fno-pic -Os -ffunction-sections -fdata-sections \
	-Wall -Wextra -Wno-unused-parameter

firmware: $(FW_SIM_BIN) $(FW_FPGA_BIN) ## Build both sim + fpga firmware images
firmware-sim:  $(FW_SIM_BIN)  ## Build sim firmware only
firmware-fpga: $(FW_FPGA_BIN) ## Build FPGA bring-up firmware only {FW_FPGA_TARGET,FW_FPGA_LOAD}

firmware-clean:

# ==============================================================================
# Payload paths (declared early so the sim dispatch below can reference them)
# ==============================================================================

COREMARK_BENCH  := $(LITEX_DIR)/benchmarks/coremark
COREMARK_BIN    := $(COREMARK_BENCH)/build/coremark.bin

EMBENCH_BENCH   := $(LITEX_DIR)/benchmarks/embench
EMBENCH_BENCHES := aha-mont64 crc32 depthconv edn huffbench matmult-int \
                   md5sum nettle-aes nettle-sha256 nsichneu picojpeg \
                   qrduino sglib-combined slre statemate tarfind ud \
                   wikisort xgboost
EMBENCH_LOG_DIR := $(LITEX_LOG_DIR)/embench-logs
EMBENCH_JOBS ?= ## Parallel Vsim processes for `make embench` (empty=auto)
EMBENCH_NETTLE_SHA256_LOCAL_SCALE ?= 562 ## Nettle SHA-256 loop count (CI smoke may lower this)
EMBENCH_RUN_BENCHES ?= $(EMBENCH_BENCHES) ## Space-separated Embench workload selection

APP_LLM_BENCH     := $(RAPTOR_HOME)/app/benchmarks/llm
APP_LLM_BUILD_DIR := $(RAPTOR_HOME)/app/build/rv32/benchmarks/llm-litex
APP_LLM_BENCHES   := ops infer train
LLM_OP_ITERS      ?= 8## LLM operator benchmark repeat count
LLM_GEN_TOKENS    ?= 12## LLM inference generated token count
LLM_TRAIN_STEPS   ?= 4## LLM training benchmark steps
# rdtime timebase: on this SoC mtime ticks once per sys_clk cycle
# (rapt_clint MTIME_DIV = RAPT_CORE_CLOCK_MHZ / RAPT_MTIME_FREQ_MHZ = 1, since the
# pack sets both to round(SYS_CLK/1e6)), so the rdtime rate == sys_clk. Track
# SYS_CLK so the LLM-bench wall-clock/score stays correct at any build frequency
# (was hardcoded 1 MHz -> 10x inflated time at the 10 MHz FPGA sys_clk).
RLLMBENCH_TIMEBASE_HZ ?= $(SYS_CLK)## RISC-V time CSR frequency in Hz (= sys_clk; mtime ticks once per cycle)
RLLMBENCH_CORE_CLOCK_MHZ ?= $(shell awk 'BEGIN { printf "%.6g", $(SYS_CLK) / 1000000 }')## Core clock in MHz for RLLMBench score/MHz reports

MICROBENCH_DIR  := $(RAPTOR_HOME)/abstract-machine/app/am-kernels/benchmarks/microbench
MICROBENCH_BIN  := $(MICROBENCH_DIR)/build/microbench-riscv32-npc.bin

TESTS_DIR       := $(LITEX_DIR)/tests
TESTS_BUILD_DIR := $(BUILD_DIR)/tests
TEST_NAMES      := hello text fib prime memcpy mul
ECALL_STRESS_FPGA_DIR := $(BUILD_DIR)/tests/irq-fpga
ECALL_STRESS_FPGA_BIN := $(ECALL_STRESS_FPGA_DIR)/u_sv32_s_ecall_stress.bin

LINUX_DIR       := $(RAPTOR_HOME)/linux
include $(LINUX_DIR)/vars.mk
LINUX_XLEN      := $(if $(filter linux64,$(VARIANT)),64,32)
LINUX_ARCH      := rv$(LINUX_XLEN)
LINUX_VARIANT   := $(if $(filter 64,$(LINUX_XLEN)),linux64,linux32)
LINUX_MABI      := $(if $(filter 64,$(LINUX_XLEN)),lp64,ilp32)
LINUX_MMU       := $(if $(filter 64,$(LINUX_XLEN)),sv39,sv32)
LINUX_ISA_BASE  := rv$(LINUX_XLEN)i
LINUX_ISA       := $(if $(filter 64,$(LINUX_XLEN)),$(RAPTOR_RV64_ISA),$(RAPTOR_RV32_ISA))
LINUX_DT_ISA_EXTENSIONS := $(shell printf '%s\n' '$(LINUX_ISA)' | awk '{ sub(/^rv(32|64)/, ""); count = split($$0, parts, "_"); for (i = 1; i <= length(parts[1]); i++) extensions[++n] = substr(parts[1], i, 1); for (i = 2; i <= count; i++) extensions[++n] = parts[i]; for (i = 1; i <= n; i++) printf "%s\"%s\"", (i == 1 ? "" : ", "), extensions[i] }')
LINUX_DOWNLOAD_TARGET := download-rv$(LINUX_XLEN)
OPENSBI_BUILD_TARGET  := opensbi-rv$(LINUX_XLEN)
OPENSBI_FW_DIR  := $(LINUX_DIR)/opensbi/build-rv$(LINUX_XLEN)/platform/generic/firmware
OPENSBI_BIN     := $(OPENSBI_FW_DIR)/fw_payload.bin
LINUX_IMG        = $(if $(filter 64,$(LINUX_XLEN)),$(LINUX_RV64_PAYLOAD),$(LINUX_RV32_PAYLOAD))

LINUX_FPGA_RAM_SIZE ?= 0x10000000 ## DTB RAM size: matches Raptor's 0x80000000..0x8fffffff PMEM window
LINUX_FPGA_BOOTARGS ?= console=liteuart0,115200 earlycon=sbi rdinit=/init ## Linux FPGA kernel command line
LINUX_FPGA_PAYLOAD ?= $(LINUX_IMG) ## Legacy stage0-bundled payload for fpga-img
LINUX_FPGA_OPENSBI_PAYLOAD ?= $(OPENSBI_BIN) ## Standalone linux/opensbi fw_payload.bin for fpga-opensbi-upload
LINUX_FPGA_PAYLOAD_OFFSET ?= 0x00100000 ## Offset of fw_payload source inside uploaded image
LINUX_FPGA_DTB_OFFSET ?= 0x02000000 ## Offset of DTB source inside uploaded image
LINUX_FPGA_OPENSBI_DTB_OFFSET ?= 0x00800000 ## Offset of DTB source inside OpenSBI-only upload image
LINUX_FPGA_DTB_ADDR ?= 0x83f00000 ## DTB runtime address passed to OpenSBI in a1
LINUX_FPGA_STAGE0_SRAM ?= 0x0f000000 ## SRAM address for stage0 relocation loop
override LINUX_FPGA_UART_BASE := 0xf0001800 # Stable LiteUART CSR base (board csr_map slot 3).
OS ?= ## Generic OS selector for fpga-tinyos-* helpers: egos or xv6
TINYOS_OS ?= ## TinyOS OS selector for fpga-tinyos-* helpers: egos or xv6
LINUX_FPGA_EGOS_IMAGE ?= $(RAPTOR_HOME)/app/build/tinyos-sim-src/egos-2000/tools/egos.bin ## Prepared egos flat image path
LINUX_FPGA_EGOS_DISK ?= $(RAPTOR_HOME)/app/build/tinyos-sim-src/egos-2000/tools/disk.img ## Prepared egos disk image path
LINUX_FPGA_EGOS_KU15P_IMAGE ?= $(RAPTOR_HOME)/app/build/tinyos-sim-src/egos-2000/tools/egos-ku15p.bin ## KU15P RAM-disk egos image (embedded disk.img)
LINUX_FPGA_EGOS_STAGE_ADDR := 0x82000000
LINUX_FPGA_XV6_KERNEL ?= $(RAPTOR_HOME)/app/build/tinyos-sim-src/xv6-riscv/kernel/kernel.bin ## Prepared xv6 kernel.bin path
LINUX_FPGA_XV6_DISK ?= $(RAPTOR_HOME)/app/build/tinyos-sim-src/xv6-riscv/fs.img ## Prepared xv6 fs.img path
_VSTRIP2 := LINUX_FPGA_RAM_SIZE LINUX_FPGA_BOOTARGS LINUX_FPGA_PAYLOAD LINUX_FPGA_OPENSBI_PAYLOAD LINUX_FPGA_PAYLOAD_OFFSET LINUX_FPGA_OPENSBI_DTB_OFFSET LINUX_FPGA_DTB_OFFSET LINUX_FPGA_DTB_ADDR LINUX_FPGA_STAGE0_SRAM LINUX_FPGA_UART_BASE LINUX_FPGA_EGOS_IMAGE LINUX_FPGA_EGOS_DISK LINUX_FPGA_EGOS_KU15P_IMAGE LINUX_FPGA_XV6_KERNEL LINUX_FPGA_XV6_DISK
$(foreach v,$(_VSTRIP2),$(eval $v := $(strip $($v))))
LINUX_FPGA_TINYOS_OS := $(strip $(if $(OS),$(OS),$(TINYOS_OS)))
LINUX_FPGA_UART_UNIT_ADDR := $(patsubst 0x%,%,$(LINUX_FPGA_UART_BASE))
LINUX_FPGA_PAYLOAD_SRC_ADDR = $(shell printf "0x%08x" $$(( $(MAIN_RAM_BASE) + $(LINUX_FPGA_PAYLOAD_OFFSET) )))
LINUX_FPGA_DTB_SRC_ADDR = $(shell printf "0x%08x" $$(( $(MAIN_RAM_BASE) + $(LINUX_FPGA_DTB_OFFSET) )))
LINUX_FPGA_OPENSBI_DTB_SRC_ADDR = $(shell printf "0x%08x" $$(( $(MAIN_RAM_BASE) + $(LINUX_FPGA_OPENSBI_DTB_OFFSET) )))
LINUX_FPGA_PAYLOAD_SIZE = $(shell stat -c%s "$(LINUX_FPGA_PAYLOAD)" 2>/dev/null || echo 0)
LINUX_FPGA_OPENSBI_PAYLOAD_SIZE = $(shell stat -c%s "$(LINUX_FPGA_OPENSBI_PAYLOAD)" 2>/dev/null || echo 0)
LINUX_FPGA_DTB_SIZE = $(shell stat -c%s "$(FW_LINUX_FPGA_DTB)" 2>/dev/null || echo 0)
RAPT_CACHE_LINE_BYTES := $(word 3,$(shell grep '^`define RAPT_CACHE_LINE_BYTES ' \
	$(RAPTOR_HOME)/hdl/configs/$(RAPT_CONFIG)/rapt_config.svh))


FW_LINUX_FPGA_SRC    := $(FW_BASE)/linux-fpga
FW_LINUX_FPGA_DIR    := $(BUILD_DIR)/firmware/linux-fpga/rv$(LINUX_XLEN)
FW_LINUX_FPGA_BIN    := $(FW_LINUX_FPGA_DIR)/stage0.bin
FW_LINUX_FPGA_ELF    := $(FW_LINUX_FPGA_DIR)/stage0.elf
FW_LINUX_FPGA_DTB    := $(FW_LINUX_FPGA_DIR)/litex-soc.dtb
FW_LINUX_FPGA_DTS    := $(FW_LINUX_FPGA_DIR)/litex-soc.dts
FW_LINUX_FPGA_DTS_IN := $(FW_LINUX_FPGA_SRC)/litex-soc.dts.in
FW_LINUX_FPGA_IMAGE  := $(FW_LINUX_FPGA_DIR)/linux-fpga.img
FW_LINUX_FPGA_SMOKE_ELF   := $(FW_LINUX_FPGA_DIR)/stage0-smoke.elf
FW_LINUX_FPGA_SMOKE_BIN   := $(FW_LINUX_FPGA_DIR)/stage0-smoke.bin
FW_LINUX_FPGA_SMOKE_IMAGE := $(FW_LINUX_FPGA_DIR)/linux-fpga-smoke.img
FW_LINUX_FPGA_OPENSBI_ELF   := $(FW_LINUX_FPGA_DIR)/stage0-opensbi.elf
FW_LINUX_FPGA_OPENSBI_BIN   := $(FW_LINUX_FPGA_DIR)/stage0-opensbi.bin
FW_LINUX_FPGA_OPENSBI_IMAGE := $(FW_LINUX_FPGA_DIR)/linux-fpga-opensbi.img
FW_EGOS_STAGE0_SRC    := $(FW_BASE)/egos-stage0
FW_EGOS_STAGE0_DIR    := $(BUILD_DIR)/firmware/egos-stage0
FW_EGOS_STAGE0_ELF    := $(FW_EGOS_STAGE0_DIR)/stage0.elf
FW_EGOS_STAGE0_BIN    := $(FW_EGOS_STAGE0_DIR)/stage0.bin
FW_EGOS_STAGE0_BUNDLE := $(FW_EGOS_STAGE0_DIR)/egos-ku15p-compact.bin
# $(call _fpga_linux_upload,<bin>): serialboot a flat bin to main_ram through the
# KU15P Linux/MIG BIOS bitstream. Forces VARIANT=linux32 so the FPGA profile (board,
# MIG, clocks, baud, and the timing-report path) is derived consistently.
_fpga_linux_upload = $(call _make,fpga-upload $(_LINUX_FPGA_ARGS) BIN=$(1) MAIN_RAM_BASE=$(MAIN_RAM_BASE))

FW_LINUX_FPGA_BASE_CFLAGS = -march=rv$(LINUX_XLEN)imac_zicsr_zifencei -mabi=$(LINUX_MABI) -nostdlib -nostartfiles \
	-fno-pic -no-pie -Wl,--build-id=none -DRAPT_MAIN_RAM=$(MAIN_RAM_BASE) \
	-DRAPT_STAGE0_SRAM=$(LINUX_FPGA_STAGE0_SRAM) \
	-DRAPT_UART_BASE=$(LINUX_FPGA_UART_BASE) \
	-DRAPT_PAYLOAD_SRC=$(LINUX_FPGA_PAYLOAD_SRC_ADDR) \
	-DRAPT_DTB_DEST=$(LINUX_FPGA_DTB_ADDR)

FW_LINUX_FPGA_CFLAGS = $(FW_LINUX_FPGA_BASE_CFLAGS) \
	-DRAPT_PAYLOAD_SIZE=$(LINUX_FPGA_PAYLOAD_SIZE) \
	-DRAPT_DTB_SRC=$(LINUX_FPGA_DTB_SRC_ADDR) \
	-DRAPT_DTB_SIZE=$(LINUX_FPGA_DTB_SIZE)

FW_LINUX_FPGA_SMOKE_CFLAGS = $(FW_LINUX_FPGA_BASE_CFLAGS) \
	-DRAPT_PAYLOAD_SIZE=0 \
	-DRAPT_DTB_SRC=$(LINUX_FPGA_DTB_SRC_ADDR) \
	-DRAPT_DTB_SIZE=0

FW_LINUX_FPGA_OPENSBI_CFLAGS = $(FW_LINUX_FPGA_BASE_CFLAGS) \
	-DRAPT_PAYLOAD_SIZE=$(LINUX_FPGA_OPENSBI_PAYLOAD_SIZE) \
	-DRAPT_DTB_SRC=$(LINUX_FPGA_OPENSBI_DTB_SRC_ADDR) \
	-DRAPT_DTB_SIZE=$(LINUX_FPGA_DTB_SIZE)

fpga-img-rv32: ## Build RV32 Linux FPGA upload image
fpga-img-rv64: ## Build RV64 Linux FPGA upload image
fpga-linux-dtb-check: $(FW_LINUX_FPGA_DTB) ## Validate Linux FPGA DT ISA/MMU/timer/cache consistency
fpga-linux-dtb-check-rv32: ## Validate the generated RV32 Linux FPGA device tree
fpga-linux-dtb-check-rv64: ## Validate the generated RV64 Linux FPGA device tree

fpga-smoke-img-rv32: ## Build RV32 Linux FPGA stage0-only smoke image
fpga-smoke-img-rv64: ## Build RV64 Linux FPGA stage0-only smoke image

fpga-opensbi-img-rv32: ## Build RV32 standalone OpenSBI FPGA image
fpga-opensbi-img-rv64: ## Build RV64 standalone OpenSBI FPGA image

IMG ?= ## Custom payload binary (for 'make payload' / 'make sim PAYLOAD=img')

# ==============================================================================
# Verilator Simulation (unified ROM × SOC × PAYLOAD)
# ==============================================================================

SOC     ?= default ## Sim SoC topology (default=full main_ram, fpga=ROM-only matching FPGA build)
PAYLOAD ?= none ## Payload at 0x80000000 (none|coremark|microbench|linux|opensbi|embench-NAME|test-NAME|img)
SOC     := $(strip $(SOC))
PAYLOAD := $(strip $(PAYLOAD))

# ROM default is PAYLOAD-aware. Bare-metal payloads (coremark/microbench/embench/
# test/img/app-llm) execute directly from main_ram and require the `sim` asm
# trampoline ROM. The `bios` ROM instead boots the LiteX BIOS, fails serialboot
# ("No boot medium found"), and halts at the litex> prompt so the payload never
# runs (a silent CI/benchmark breakage). none/linux/opensbi keep the LiteX BIOS.
# An explicit ROM=... on the command line or environment always wins (via ?=).
_MAIN_RAM_PAYLOAD := $(strip \
    $(filter coremark microbench img,$(PAYLOAD)) \
    $(filter embench-% test-% app-llm-%,$(PAYLOAD)))
ROM     ?= $(if $(_MAIN_RAM_PAYLOAD),sim,bios) ## Sim boot ROM (bios=LiteX BIOS->litex> shell; sim=asm trampoline [auto for main_ram payloads]; fpga=firmware/fpga C)
ROM     := $(strip $(ROM))

LITEX_PATH := $(RAPTOR_HOME)/third_party/enjoy-digital/litex

LITEX_CONFIG_PHASE := sim
include $(LITEX_DIR)/mk/config.mk

SIM_DIR    := $(BUILD_DIR)/sim/$(VARIANT)-$(ROM)-$(SOC)
SIM_BUILD_DIR := $(SIM_DIR)/gateware

_BASE_FLAGS = --sys-clk-freq=$(SYS_CLK) --threads=$(SIM_THREADS) $(TRACE_FLAGS)
SIM_FLAGS   = --output-dir=$(SIM_DIR) --cpu-variant=$(VARIANT) \
              $(SIM_ROM_FLAGS) $(SIM_SOC_FLAGS) $(SIM_PAYLOAD_FLAG) $(_BASE_FLAGS)

sim-gen: $(PACK_SV) $(SIM_ROM_DEP) $(SIM_PAYLOAD_BUILD) ## Generate SoC Verilog (no compile, no run) {ROM,SOC,PAYLOAD,VARIANT,IMG}

sim-build: sim-gen ## Generate SoC + compile Verilator binary {ROM,SOC,PAYLOAD,VARIANT,IMG}

sim: sim-build ## Build + run sim {ROM,SOC,PAYLOAD,VARIANT,IMG,TRACE,SIM_TIMEOUT,SIM_THREADS}

sim-run: ## Run already-built sim (no rebuild) {ROM,SOC,PAYLOAD,VARIANT,SIM_TIMEOUT}

sim-trace: ## Alias: make sim TRACE=fst

sim-trace-vcd: ## Alias: make sim TRACE=vcd (slower/larger than FST)

# ==============================================================================
# Payload aliases
# ==============================================================================

COREMARK_ITERATIONS ?= 64 ## CoreMark loop iterations (FPGA: 1000+ recommended; sim: 64)

coremark-build: ## Build CoreMark binary (clone + compile) {COREMARK_ITERATIONS,SYS_CLK}

coremark: ## Alias: make sim PAYLOAD=coremark — tees output to $(LITEX_LOG_DIR)/coremark.log

# CoreMark needs >=10 s of run time for a valid score; on the ~10 MHz FPGA the
# core does ~30 iters/s, so the sim default of 64 is far too low (it prints
# "Must execute for at least 10 secs").  Default this FPGA target to a value that
# clears the 10 s floor.  NOTE: coremark-fpga rebuilds coremark-build with this
# value, so `make coremark-fpga` alone (default 64) would otherwise overwrite a
# prior `make coremark-build COREMARK_ITERATIONS=N`.  Override inline instead:
# `make coremark-fpga COREMARK_ITERATIONS=N`.
coremark-fpga: COREMARK_ITERATIONS := 2000
coremark-fpga: coremark-build ## Upload CoreMark to FPGA main_ram via BIOS serialboot {COREMARK_ITERATIONS,MAIN_RAM_BASE,UART_PORT}

coremark-clean: ## Remove CoreMark build artifacts (keep cloned source)

main-fpga-build: ## Build FPGA main firmware (uploadable via serialboot to main_ram) {UART_PORT}

main-fpga: main-fpga-build ## Build + upload FPGA main firmware to main_ram {UART_PORT}

u-sv32-s-ecall-stress-fpga-build: ## Build short Sv32 U->S syscall stress for LiteX FPGA

u-sv32-s-ecall-stress-fpga-upload: u-sv32-s-ecall-stress-fpga-build ## Upload short Sv32 U->S syscall stress via BIOS serialboot

irqtest-fpga: ## Build + upload minimal IRQ test firmware {UART_PORT}

main-fpga-clean: ## Remove FPGA firmware build artifacts

EMBENCH_TARGETS := $(addprefix embench-run-,$(EMBENCH_BENCHES))
EMBENCH_BUILDS  := $(addprefix embench-build-,$(EMBENCH_BENCHES))

embench-build: ## Build all Embench-IoT benchmarks (one BIN per bench)

$(EMBENCH_BUILDS): embench-build-%:

embench-build-one: ## Build one Embench bench (BENCH=<name>) {BENCH}

$(EMBENCH_TARGETS): embench-run-%: ## Alias: make sim PAYLOAD=embench-<NAME>

embench-run: ## Run one Embench bench (BENCH=<name>) {BENCH}

# run-embench.sh loads each bench into main_ram and runs Vsim directly, so it
# needs the `sim` ROM (asm trampoline that jumps to main_ram), NOT the default
# `bios` ROM (which halts at the litex> shell). SIM_DIR is an immediate (`:=`)
# assignment, so a target-specific ROM would not recompute the build path;
# invoke sim-build recursively with ROM=sim and keep run-embench.sh in sync.
embench: $(PACK_SV) $(FW_SIM_BIN) ## Build + run all Embench benches (parallel) + Embench Score report

embench-report: ## Re-run Embench Score report from existing logs

embench-clean: ## Remove Embench build artifacts and run logs

APP_LLM_TARGETS := $(addprefix app-llm-,$(APP_LLM_BENCHES))
APP_LLM_BUILDS  := $(addprefix app-llm-build-,$(APP_LLM_BENCHES))
APP_LLM_FPGAS   := $(addsuffix -fpga,$(APP_LLM_TARGETS))
APP_LLM_VARS    := LLM_OP_ITERS=$(LLM_OP_ITERS) \
                   LLM_GEN_TOKENS=$(LLM_GEN_TOKENS) \
				   LLM_TRAIN_STEPS=$(LLM_TRAIN_STEPS) \
				   RLLMBENCH_TIMEBASE_HZ=$(RLLMBENCH_TIMEBASE_HZ) \
				   RLLMBENCH_CORE_CLOCK_MHZ=$(RLLMBENCH_CORE_CLOCK_MHZ)

app-llm-build: ## Build all app/ LLM benchmarks as LiteX-native payloads

$(APP_LLM_BUILDS): app-llm-build-%:

$(APP_LLM_TARGETS): app-llm-%: ## Alias: make sim PAYLOAD=app-llm-<NAME>

app-llm-run: ## Run one app/ LLM benchmark in LiteX sim (BENCH=ops|infer|train) {BENCH}

$(APP_LLM_FPGAS): app-llm-%-fpga: app-llm-build-% ## Upload app/ LLM benchmark to FPGA via BIOS serialboot

app-llm-fpga: ## Upload one app/ LLM benchmark to FPGA (BENCH=ops|infer|train) {BENCH,UART_PORT}

APP_FPGA_BIN ?= ## Custom app-built LiteX-native binary for app-fpga-upload
app-fpga-upload: ## Upload a prebuilt app LiteX-native bin via BIOS serialboot {APP_FPGA_BIN,UART_PORT}

microbench-build: ## Build MicroBench binary

microbench: ## Alias: make sim PAYLOAD=microbench — tees output to $(LITEX_LOG_DIR)/microbench.log

TEST_TARGETS := $(addprefix test-,$(TEST_NAMES))

tests: ## Build all standalone C microbenchmarks (build/tests/*.bin)

tests-clean: ## Clean standalone microbenchmark build artifacts

$(TEST_TARGETS): test-%: ## Alias: make sim PAYLOAD=test-<NAME>

tests-run: tests ## Run every standalone test sequentially — tees aggregate output to $(LITEX_LOG_DIR)/tests-run.log

opensbi-build: ## Build OpenSBI for the selected VARIANT
opensbi-rv32-build: ## Build RV32 OpenSBI (standalone, from linux/opensbi)
opensbi-rv64-build: ## Build RV64 OpenSBI (standalone, from linux/opensbi)

opensbi-rv32: ## Simulate RV32 OpenSBI
opensbi-rv64: ## Simulate RV64 OpenSBI

opensbi-clean: ## Clean OpenSBI build artifacts

payload: ## Alias: make sim PAYLOAD=img IMG=/path/to.bin {IMG,TRACE,SIM_TIMEOUT}

EGOS_KU15P_BIN ?= $(LINUX_FPGA_EGOS_KU15P_IMAGE) ## egos-ku15p.bin path (default: auto-built)

egos-ku15p-sim: fpga-egos-prepare ## Simulate egos-ku15p in LiteX Verilator SoC {TRACE,SIM_TIMEOUT,EGOS_KU15P_BIN}

egos-ku15p-sim-trace: fpga-egos-prepare ## Simulate egos-ku15p with FST waveform dump {TRACE_START,TRACE_END}

raptos-bios-sim-rv32: ## Simulate RV32 RaptOS booting through LiteX BIOS (boot 0x80000000)
raptos-bios-sim-rv64: ## Simulate RV64 RaptOS booting through LiteX BIOS (boot 0x80000000)

linux32-build: ## Download pre-built RV32 Linux payload
linux64-build: ## Download pre-built RV64 Linux payload

linux32: ## Simulate RV32 Linux
linux64: ## Simulate RV64 Linux

# ------------------------------------------------------------------------------
# KU15P Linux/MIG FPGA helpers. These wrappers force VARIANT=linux32 so callers do
# not need to repeat the profile on every build/load/upload command. `*-run`
# reloads an existing timing-clean bitstream before uploading software; `*-e2e`
# builds the bitstream when stale, loads it, then uploads software.
# ------------------------------------------------------------------------------

linux-fpga-rv32-build: ## Build the RV32 Linux/MIG bitstream
linux-fpga-rv64-build: ## Build the RV64 Linux/MIG bitstream

linux-fpga-rv32-load: ## Load the RV32 Linux/MIG bitstream
linux-fpga-rv64-load: ## Load the RV64 Linux/MIG bitstream

linux-fpga-rv32-upload: ## Upload the RV32 Linux image
linux-fpga-rv64-upload: ## Upload the RV64 Linux image

linux-fpga-rv32-run: ## Load bitstream, then upload RV32 Linux
linux-fpga-rv64-run: ## Load bitstream, then upload RV64 Linux

linux-fpga-rv32-e2e: ## Build/load/upload RV32 Linux end to end
linux-fpga-rv64-e2e: ## Build/load/upload RV64 Linux end to end

opensbi-fpga-rv32-upload: ## Upload standalone RV32 OpenSBI
opensbi-fpga-rv64-upload: ## Upload standalone RV64 OpenSBI

opensbi-fpga-rv32-run: ## Load bitstream, then upload RV32 OpenSBI
opensbi-fpga-rv64-run: ## Load bitstream, then upload RV64 OpenSBI

opensbi-fpga-rv32-e2e: ## Build/load/upload RV32 OpenSBI end to end
opensbi-fpga-rv64-e2e: ## Build/load/upload RV64 OpenSBI end to end

fpga-opensbi-upload: fpga-opensbi-img ## Build/upload standalone linux/opensbi image through BIOS serialboot {UART_PORT,LINUX_FPGA_OPENSBI_PAYLOAD}

fpga-smoke-upload: fpga-smoke-img ## Upload tiny stage0-only image through BIOS serialboot {UART_PORT}

fpga-smoke: ## Build/load Linux FPGA bitstream, then upload tiny stage0-only smoke image {UART_PORT,VIVADO}

fpga-tinyos-prepare: ## Build TinyOS simulator artifacts for OS=egos|xv6 {OS,TINYOS_OS}

fpga-egos-prepare: ## Build egos kernel, disk.img, and legacy flat simulation image

fpga-egos-bundle: fpga-egos-prepare $(FW_EGOS_STAGE0_BIN) ## Build compact stage0+kernel+disk serialboot bundle

fpga-xv6-prepare: ## Build xv6 kernel.bin and fs.img used by TinyOS xv6 checks

fpga-tinyos-check: ## Explain TinyOS FPGA serialboot compatibility for OS=egos|xv6 {OS,TINYOS_OS}

fpga-tinyos-upload: ## Guarded TinyOS upload entry; dispatches OS=egos|xv6 {OS,TINYOS_OS}

fpga-egos-upload: fpga-egos-bundle ## Upload compact KU15P egos bundle through LiteX BIOS serialboot {UART_PORT}

RAPTOS_KU15P_RV32_BIN := $(RAPTOR_HOME)/app/tinyos/raptos/build/ku15p-rv32/raptos.bin
RAPTOS_KU15P_RV64_BIN := $(RAPTOR_HOME)/app/tinyos/raptos/build/ku15p-rv64/raptos.bin
RAPTOS_KU15P_BIN := $(RAPTOS_KU15P_RV32_BIN)

fpga-raptos-rv32-build: ## Build RV32 RaptOS image with all built-in U-mode payload commands
fpga-raptos-rv64-build: ## Build RV64 RaptOS image with all built-in U-mode payload commands

fpga-raptos-rv32-upload: fpga-raptos-rv32-build ## Build and upload RV32 RaptOS through the loaded KU15P BIOS {UART_PORT}
fpga-raptos-rv64-upload: fpga-raptos-rv64-build ## Build and upload RV64 RaptOS through the loaded KU15P BIOS {UART_PORT}

fpga-raptos-rv32-run: ## Build, upload, and attach to the interactive RV32 RaptOS shell {UART_PORT}
fpga-raptos-rv64-run: ## Build, upload, and attach to the interactive RV64 RaptOS shell {UART_PORT}

fpga-xv6-upload: fpga-xv6-prepare ## Prepare xv6, then explain why current Linux/MIG bitstream refuses it

bios: ## Alias: make sim ROM=bios (run LiteX BIOS in sim) {SOC,PAYLOAD,TRACE,SIM_TIMEOUT}

# ==============================================================================
# FPGA Targets
# ==============================================================================

BOOT_MODE      ?= $(if $(LINUX_FPGA_PROFILE),bios,custom) ## FPGA boot ROM source (custom=firmware/fpga, bios=LiteX BIOS; linux FPGA profile: bios)
FPGA_FLAVOR_SUFFIX ?= ## Optional suffix for diagnostic FPGA builds, e.g. bimodal or ioq-in-order

VIVADO_JOBS  ?= $(shell n='$(NPROC)'; if [ "$$n" -gt 32 ]; then echo 32; else echo "$$n"; fi) ## Maximum Vivado worker threads (default capped at Vivado's limit of 32)
VIVADO_INCREMENTAL ?= 0 ## Set to 1 to reuse a compatible routed checkpoint
VIVADO_ROUTE_DIRECTIVE ?= default ## Vivado route_design directive (for example AlternateCLBRouting)

LITEX_CONFIG_PHASE := fpga
include $(LITEX_DIR)/mk/config.mk

fpga-detect: ## Refresh and show connected FPGA count, target info, and board mapping {FPGA_AUTO_DETECT,VIVADO,FPGA_DETECT_CACHE}

fpga-info: fpga-detect ## Alias for fpga-detect: list all FPGAs visible through Vivado Hardware Manager

fpga-gen: $(PACK_SV) $(_FPGA_FW_DEP) ## Generate FPGA SoC sources only (no PnR) {BOOT_MODE,FPGA_BOARD,RAPT_CONFIG,INTEGRATED_MAIN_RAM_SIZE}

fpga-build: $(PACK_SV) $(_FPGA_FW_DEP) ## Build FPGA bitstream (synth + P&R) {BOOT_MODE,FPGA_BOARD,RAPT_CONFIG,INTEGRATED_MAIN_RAM_SIZE,WITH_LED_CHASER}

fpga-reports-index: ## Generate/install aggregated FPGA report HTML dashboard

fpga-timing-ok: ## Check FPGA timing report before hardware load/flash {FPGA_BOARD,BOOT_MODE,RAPT_CONFIG}

fpga-build-force: ## Force full re-PnR (ignore content-hash cache) {BOOT_MODE,FPGA_BOARD,RAPT_CONFIG,INTEGRATED_MAIN_RAM_SIZE}

# Linux FPGA profile: gate hardware load/flash on a passing Vivado timing report.
ifeq ($(LINUX_FPGA_PROFILE),1)
fpga-load fpga-flash: fpga-timing-ok
endif

fpga-load: ## Load bitstream into FPGA SRAM (volatile, lost on power-cycle) {OFL,OFL_CABLE,VIVADO,BOOT_MODE,FPGA_BOARD}

fpga-flash: ## Write bitstream to external SPI flash (persists across power cycles) {OFL,OFL_CABLE,VIVADO,BOOT_MODE,FPGA_BOARD}

fpga: fpga-build fpga-load ## Build + load (volatile) in one shot

mlk-cu07-ku15p: ## Build + load on MLK-CU07-KU15P (Vivado) {BOOT_MODE,RAPT_CONFIG}

mlk-cu07-ku15p-build: ## Build bitstream only on MLK-CU07-KU15P (Vivado) {BOOT_MODE,RAPT_CONFIG}

xilinx-vcu118: ## Build + load on Xilinx VCU118 (Vivado) {BOOT_MODE,RAPT_CONFIG}

xilinx-vcu118-build: ## Build bitstream only on Xilinx VCU118 (Vivado) {BOOT_MODE,RAPT_CONFIG}

fpga-console: ## Open serial terminal on the FPGA UART at fixed 115200 baud; board selection is optional (Ctrl-A K to quit) {UART_PORT}

# fpga-upload payload defaults + Linux-profile serialboot prerequisites. Linux
# uses the existing contiguous stage0+OpenSBI+DTB image so every upload can use
# LiteX's maintained litex_term implementation. BIN=... selects a raw image.
ifeq ($(LINUX_FPGA_PROFILE),1)
_FPGA_UPLOAD_DEFAULT_BIN := $(FW_LINUX_FPGA_IMAGE)
_FPGA_UPLOAD_DEPS := fpga-timing-ok $(if $(strip $(BIN)),,$(FW_LINUX_FPGA_IMAGE))
else
_FPGA_UPLOAD_DEFAULT_BIN := $(FW_FPGA_BIN)
_FPGA_UPLOAD_DEPS :=
endif

fpga-upload: $(_FPGA_UPLOAD_DEPS) ## Upload one firmware image via LiteX serialboot at fixed 115200 baud; board selection is optional {MAIN_RAM_BASE,UART_PORT,SERIALBOOT_SAFE,BIN}

fpga-clean: ## Remove FPGA build artifacts

# ==============================================================================
# Utilities
# ==============================================================================

clean: ## Remove build artifacts

sim-clean: ## Force next sim-build to recompile (clear all verilator caches under build/sim/)

clean-all: clean firmware-clean ## Remove build artifacts + firmware + venv

lint: ## Lint RTL (via sim)

_INFO_VARS := RAPTOR_HOME LITEX_DIR VARIANT LINUX_XLEN LINUX_IMG LINUX_FPGA_BOOTARGS SYS_CLK RAPT_CONFIG GOWIN_APP GOWIN_BIN_DIR OFL OFL_CABLE FPGA_AUTO_DETECT FPGA_DETECT_REFRESH FPGA_DETECT_CACHE FPGA_DETECT_INFO_CACHE FPGA_DETECT_COUNT_CACHE FPGA_DETECTED_COUNT FPGA_DETECTED_PARTS FPGA_DETECTED_INFO FPGA_BOARD_SOURCE FPGA_DEVICE FPGA_PART WITH_LITEDRAM LITEDRAM_SIZE WITH_MIG MIG_SIZE WITH_SDCARD SDCARD_BOOT VIVADO_ROUTE_DIRECTIVE UART_PORT UART_BAUD SIM_TIMEOUT PACK_SV BUILD_DIR PYTHON

info: ## Show configuration info

help: ## Show this help message

# Target implementations are loaded after all profile/sim/FPGA configuration.
include $(LITEX_DIR)/mk/recipes.mk

# ==============================================================================
# PHONY declarations
# ==============================================================================
.PHONY: FORCE help setup setup-skip \
	pack \
	firmware firmware-sim firmware-fpga firmware-clean \
	sim-gen sim-build sim sim-run sim-trace sim-trace-vcd sim-clean \
	fpga-img-rv32 fpga-img-rv64 fpga-smoke-img-rv32 fpga-smoke-img-rv64 fpga-opensbi-img-rv32 fpga-opensbi-img-rv64 \
	fpga-linux-dtb-check fpga-linux-dtb-check-rv32 fpga-linux-dtb-check-rv64 \
	coremark coremark-build coremark-clean coremark-fpga \
	main-fpga-build main-fpga irqtest-fpga main-fpga-clean \
	embench embench-build embench-build-one embench-run embench-report embench-clean \
	$(EMBENCH_TARGETS) $(EMBENCH_BUILDS) \
	app-llm-build app-llm-run app-llm-fpga app-fpga-upload \
	$(APP_LLM_TARGETS) $(APP_LLM_BUILDS) $(APP_LLM_FPGAS) \
	microbench microbench-build \
	tests tests-clean tests-run $(TEST_TARGETS) \
	opensbi-build opensbi-rv32 opensbi-rv64 opensbi-rv32-build opensbi-rv64-build opensbi-clean fpga-opensbi-jump-build \
	payload \
	linux32 linux64 linux32-build linux64-build \
	raptos-bios-sim-rv32 raptos-bios-sim-rv64 \
	bios \
	linux-fpga-rv32-build linux-fpga-rv32-load linux-fpga-rv32-upload linux-fpga-rv32-run linux-fpga-rv32-e2e \
	linux-fpga-rv64-build linux-fpga-rv64-load linux-fpga-rv64-upload linux-fpga-rv64-run linux-fpga-rv64-e2e \
	opensbi-fpga-rv32-upload opensbi-fpga-rv32-run opensbi-fpga-rv32-e2e \
	opensbi-fpga-rv64-upload opensbi-fpga-rv64-run opensbi-fpga-rv64-e2e \
	fpga-gen fpga-build fpga-build-force fpga-load fpga-flash fpga fpga-console fpga-upload fpga-clean fpga-detect fpga-reports-index fpga-timing-ok \
	fpga-smoke fpga-smoke-upload fpga-opensbi-upload \
	fpga-egos-prepare fpga-egos-bundle fpga-egos-upload fpga-xv6-prepare fpga-xv6-upload \
	fpga-raptos-rv32-build fpga-raptos-rv32-upload fpga-raptos-rv32-run \
	fpga-raptos-rv64-build fpga-raptos-rv64-upload fpga-raptos-rv64-run \
	fpga-tinyos-prepare fpga-tinyos-check fpga-tinyos-upload \
	tang-mega-138k-pro \
	mlk-cu08-ku15p mlk-cu08-ku15p-build \
	mlk-cu07-ku15p mlk-cu07-ku15p-build \
	xilinx-vcu118 xilinx-vcu118-build \
	lint info clean clean-all

FORCE:
