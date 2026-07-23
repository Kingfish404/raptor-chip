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

BOARDS := tang_mega_138k_pro mlk_cu07_ku15p
BOARD_ALIASES := $(subst _,-,$(BOARDS))

# Gowin IDE bundle (macOS). Empty on Linux / when GowinIDE is not installed; it
# drives the on-board Gowin Tang synthesis/PnR flow (load/flash use openFPGALoader).
GOWIN_APP   ?= $(firstword $(wildcard /Applications/GowinIDE.app /Applications/GowinIDE.edu.app)) ## Gowin IDE app bundle path on macOS. Synthesis/PnR only; load/flash use openFPGALoader.

# ---------------------------------------------------------------------------
# Linux FPGA profile: auto-enabled on FPGA goals when VARIANT is linux/linux64.
# It flips the FPGA board/MIG/clock/baud/boot defaults to the KU15P Linux
# bring-up flow, so `make fpga-* VARIANT=linux` behaves like the retired
# `linux-fpga-*` commands. Sim goals (`make sim VARIANT=linux`, `make linux`)
# do not contain "fpga" and therefore keep the standard defaults.
#
# When an FPGA goal is requested without an explicit VARIANT and no Gowin IDE is
# installed (GOWIN_APP empty, e.g. on Linux), the on-board Gowin Tang flow cannot
# run, so default to VARIANT=linux (the KU15P Linux/MIG Vivado profile).
# ---------------------------------------------------------------------------
# Benchmark / firmware upload helpers run ON the already-loaded bitstream, so they
# must default to the SAME profile (and therefore SYS_CLK) as fpga-load. Otherwise
# the payload's rdtime timebase — baked in at build time from SYS_CLK — won't match
# the running SoC's mtime rate, giving a wrong reported time (e.g. coremark showed
# 64.8 s vs ~13 s wall clock when a 50 MHz linux bitstream was loaded but coremark
# was built for the 10 MHz standard profile: a 5x over-report).
_LINUX_PROFILE_BENCH_GOALS := coremark-fpga main-fpga main-fpga-build irqtest-fpga app-fpga-upload app-llm-fpga app-llm-ops-fpga app-llm-infer-fpga app-llm-train-fpga
_FPGA_ALIAS_GOALS := $(BOARD_ALIASES) $(addsuffix -build,$(BOARD_ALIASES))
_IS_FPGA_GOAL := $(strip \
	$(foreach g,$(MAKECMDGOALS),$(if $(findstring fpga,$(g)),y)) \
	$(filter $(_FPGA_ALIAS_GOALS),$(MAKECMDGOALS)))
_IS_LINUX_PROFILE_DEFAULT_GOAL := $(strip $(_IS_FPGA_GOAL) $(filter $(_LINUX_PROFILE_BENCH_GOALS),$(MAKECMDGOALS)))

VARIANT ?= $(if $(_IS_LINUX_PROFILE_DEFAULT_GOAL),$(if $(strip $(GOWIN_APP)),standard,linux),standard) ## CPU variant (standard|linux|linux64)
ifeq ($(origin VARIANT),file)
ifeq ($(VARIANT),linux)
ifneq (,$(_IS_LINUX_PROFILE_DEFAULT_GOAL))
ifeq ($(strip $(GOWIN_APP)),)
$(if $(filter 0,$(MAKELEVEL)),$(info [litex] GOWIN_APP empty on FPGA goal -> defaulting to VARIANT=linux (KU15P Linux/MIG profile)))
endif
endif
endif
endif

ifneq (,$(_IS_FPGA_GOAL))
ifneq (,$(filter linux linux64,$(VARIANT)))
LINUX_FPGA_PROFILE := 1
endif
endif
_LINUX_FPGA_ARGS := VARIANT=linux

SYS_CLK     ?= $(if $(LINUX_FPGA_PROFILE),50000000,10000000) ## System clock in Hz (linux FPGA profile: 50 MHz)
SIM_TIMEOUT ?= 30 ## Simulation timeout in seconds (0=unlimited)

BOARD_tang_mega_138k_pro_VENDOR    := gowin
BOARD_tang_mega_138k_pro_PY        := raptor_tang_mega_138k_pro.py
BOARD_tang_mega_138k_pro_BITNAME   := sipeed_tang_mega_138k_pro.fs
BOARD_tang_mega_138k_pro_TIMINGRPT :=
BOARD_tang_mega_138k_pro_UART      :=

BOARD_mlk_cu07_ku15p_VENDOR    := vivado
BOARD_mlk_cu07_ku15p_PY        := raptor_mlk_cu07_ku15p.py
BOARD_mlk_cu07_ku15p_BITNAME   := mlk_cu07_ku15p.bit
BOARD_mlk_cu07_ku15p_TIMINGRPT := mlk_cu07_ku15p_timing.rpt
BOARD_mlk_cu07_ku15p_UART      := /dev/ttyUSB0

RAPT_CONFIG ?= default ## Raptor uarch config preset (default|middle|small|...)
RAPT_CONFIG := $(strip $(RAPT_CONFIG))
export RAPT_CONFIG
FPGA_BOARD ?= $(if $(LINUX_FPGA_PROFILE),mlk_cu07_ku15p,tang_mega_138k_pro) ## Target FPGA board (linux FPGA profile: mlk_cu07_ku15p)
FPGA_BOARD := $(strip $(FPGA_BOARD))
ifeq ($(filter $(FPGA_BOARD),$(BOARDS)),)
$(error Invalid FPGA_BOARD='$(FPGA_BOARD)'. Known boards: $(BOARDS))
endif
FPGA_VENDOR    := $(BOARD_$(FPGA_BOARD)_VENDOR)
FPGA_PY        := $(BOARD_$(FPGA_BOARD)_PY)
FPGA_TIMINGRPT := $(BOARD_$(FPGA_BOARD)_TIMINGRPT)
LITEX_LOG_DIR := $(NSIM_DIR)/build/$(RAPT_CONFIG)/logs/litex
WITH_LED_CHASER ?= 0 ## Set to 1 to add LedChaser to fpga-build (off by default on the Pro for PnR density relief)
WITH_LITEDRAM ?= 0 ## Set to 1 to use external LiteDRAM/DDR4 as FPGA main_ram
LITEDRAM_SIZE ?= 0x40000000 ## Mapped external LiteDRAM main_ram size in bytes
WITH_MIG ?= $(if $(LINUX_FPGA_PROFILE),1,0) ## Set to 1 to use external Xilinx DDR4 MIG as FPGA main_ram (linux FPGA profile: 1)
MIG_SIZE ?= 0x40000000 ## Mapped external MIG main_ram size in bytes
WITH_SDCARD ?= $(if $(filter mlk_cu07_ku15p,$(FPGA_BOARD)),1,0) ## Add SDCard controller/DMA by default on MLK-CU07 KU15P; set 0 to omit
SDCARD_BOOT ?= 0 ## Set to 1 to make LiteX BIOS automatically try SDCard boot
ifneq (,$(filter 1 yes true on,$(WITH_SDCARD)))
ifneq ($(FPGA_BOARD),mlk_cu07_ku15p)
$(error WITH_SDCARD is only supported on FPGA_BOARD=mlk_cu07_ku15p)
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

_VSTRIP1 := VARIANT SYS_CLK SIM_TIMEOUT GOWIN_APP WITH_LED_CHASER WITH_LITEDRAM LITEDRAM_SIZE WITH_MIG MIG_SIZE WITH_SDCARD SDCARD_BOOT UART_PORT UART_BAUD SERIALBOOT_SAFE SIM_THREADS TRACE TRACE_START TRACE_END
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

INTEGRATED_MAIN_RAM_SIZE ?= $(if $(LINUX_FPGA_PROFILE),0,0x80000) ## BSRAM-backed main_ram size at 0x80000000 (default 512 KB; linux FPGA profile: 0=disabled)
INTEGRATED_MAIN_RAM_SIZE := $(strip $(INTEGRATED_MAIN_RAM_SIZE))
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

NSIM_RTL_DIR := $(RAPTOR_HOME)/sim/rtl
RTL_SOURCES := $(shell find $(RTL_DIR) $(NSIM_RTL_DIR) -type f \( -name '*.sv' -o -name '*.svh' -o -name '*.v' -o -name '*.vh' \) 2>/dev/null)

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
	$(MAKE) -C $(NSIM_DIR) pack RAPT_CONFIG=$(RAPT_CONFIG) VFLAGS="$(RAPT_PACK_VFLAGS)" CONFIG_MODE=

$(PACK_SV): $(RTL_SOURCES) $(RAPT_CONFIG_STAMP) $(RAPT_PACK_VFLAGS_STAMP)
	$(MAKE) -C $(NSIM_DIR) pack RAPT_CONFIG=$(RAPT_CONFIG) VFLAGS="$(RAPT_PACK_VFLAGS)" CONFIG_MODE=

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

$(FW_SIM_DIR):
	@mkdir -p $@

$(FW_SIM_DTB): $(FW_SIM_DTS) | $(FW_SIM_DIR)
	dtc -I dts -O dtb -o $@ $<

$(FW_SIM_ELF): $(FW_SIM_SRC)/boot.S $(FW_SIM_SRC)/link.ld $(FW_SIM_DTB) | $(FW_SIM_DIR)
	$(CROSS)gcc -march=rv32imac -mabi=ilp32 -nostdlib -nostartfiles -fno-pic -no-pie \
		-T $(FW_SIM_SRC)/link.ld -I$(FW_SIM_DIR) -o $@ $(FW_SIM_SRC)/boot.S

$(FW_SIM_BIN): $(FW_SIM_ELF)
	$(CROSS)objcopy -O binary $< $@

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

$(FW_FPGA_DIR):
	@mkdir -p $@

FW_FPGA_CFLAGS := -march=rv32imac_zicsr -mabi=ilp32 -ffreestanding -nostdlib \
	-nostartfiles -fno-pic -Os -ffunction-sections -fdata-sections \
	-Wall -Wextra -Wno-unused-parameter

$(FW_FPGA_DIR)/boot.o: $(FW_FPGA_SRC)/boot.S | $(FW_FPGA_DIR)
	$(CROSS)gcc $(FW_FPGA_CFLAGS) -c -o $@ $<

$(FW_FPGA_DIR)/main.o: $(FW_FPGA_MAIN_SRC) | $(FW_FPGA_DIR)
	$(CROSS)gcc $(FW_FPGA_CFLAGS) -c -o $@ $<

$(FW_FPGA_ELF): $(FW_FPGA_OBJS) $(FW_FPGA_LINK)
	$(CROSS)gcc $(FW_FPGA_CFLAGS) -Wl,--gc-sections -no-pie \
		-T $(FW_FPGA_LINK) -o $@ $(FW_FPGA_OBJS)

$(FW_FPGA_BIN): $(FW_FPGA_ELF)
	$(CROSS)objcopy -O binary $< $@

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
OPENSBI_FW_DIR  := $(LINUX_DIR)/opensbi/build/platform/generic/firmware
OPENSBI_BIN     := $(OPENSBI_FW_DIR)/fw_payload.bin
LINUX_IMG        = $(LINUX_RV32_PAYLOAD)

LINUX_FPGA_RAM_SIZE ?= 0x10000000 ## DTB RAM size: matches Raptor's 0x80000000..0x8fffffff PMEM window
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
_VSTRIP2 := LINUX_FPGA_RAM_SIZE LINUX_FPGA_PAYLOAD LINUX_FPGA_OPENSBI_PAYLOAD LINUX_FPGA_PAYLOAD_OFFSET LINUX_FPGA_OPENSBI_DTB_OFFSET LINUX_FPGA_DTB_OFFSET LINUX_FPGA_DTB_ADDR LINUX_FPGA_STAGE0_SRAM LINUX_FPGA_UART_BASE LINUX_FPGA_EGOS_IMAGE LINUX_FPGA_EGOS_DISK LINUX_FPGA_EGOS_KU15P_IMAGE LINUX_FPGA_XV6_KERNEL LINUX_FPGA_XV6_DISK
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
FW_LINUX_FPGA_DIR    := $(BUILD_DIR)/firmware/linux-fpga
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
# KU15P Linux/MIG BIOS bitstream. Forces VARIANT=linux so the FPGA profile (board,
# MIG, clocks, baud, and the timing-report path) is derived consistently.
_fpga_linux_upload = $(MAKE) --no-print-directory fpga-upload $(_LINUX_FPGA_ARGS) BIN=$(1) MAIN_RAM_BASE=$(MAIN_RAM_BASE)

$(FW_LINUX_FPGA_DIR):
	@mkdir -p $@

$(FW_EGOS_STAGE0_DIR):
	@mkdir -p $@

$(FW_EGOS_STAGE0_ELF): $(FW_EGOS_STAGE0_SRC)/boot.S $(FW_EGOS_STAGE0_SRC)/link.ld | $(FW_EGOS_STAGE0_DIR)
	$(CROSS)gcc -march=rv32imac_zicsr_zifencei -mabi=ilp32 -nostdlib -nostartfiles \
		-fno-pic -no-pie -Wl,--build-id=none -T $(FW_EGOS_STAGE0_SRC)/link.ld -o $@ $<

$(FW_EGOS_STAGE0_BIN): $(FW_EGOS_STAGE0_ELF)
	$(CROSS)objcopy -O binary $< $@

$(LINUX_FPGA_PAYLOAD): linux-build

$(LINUX_FPGA_OPENSBI_PAYLOAD): opensbi-build

$(FW_LINUX_FPGA_DTS): $(FW_LINUX_FPGA_DTS_IN) FORCE | $(FW_LINUX_FPGA_DIR)
	sed -e 's/@TIMEBASE@/$(SYS_CLK)/g' \
	    -e 's/@MEM_SIZE@/$(LINUX_FPGA_RAM_SIZE)/g' \
	    -e 's/@UART_BASE@/$(LINUX_FPGA_UART_BASE)/g' \
	    -e 's/@UART_UNIT_ADDR@/$(LINUX_FPGA_UART_UNIT_ADDR)/g' \
	    -e 's/@CBOM_BLOCK_SIZE@/$(RAPT_CACHE_LINE_BYTES)/g' \
	    $< > $@

$(FW_LINUX_FPGA_DTB): $(FW_LINUX_FPGA_DTS) | $(FW_LINUX_FPGA_DIR)
	dtc -I dts -O dtb -o $@ $<

FW_LINUX_FPGA_BASE_CFLAGS = -march=rv32imac_zicsr_zifencei -mabi=ilp32 -nostdlib -nostartfiles \
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

$(FW_LINUX_FPGA_ELF): $(FW_LINUX_FPGA_SRC)/boot.S $(FW_LINUX_FPGA_SRC)/link.ld $(FW_LINUX_FPGA_DTB) $(LINUX_FPGA_PAYLOAD) | $(FW_LINUX_FPGA_DIR)
	@if [ -z "$(LINUX_FPGA_PAYLOAD)" ] || [ ! -f "$(LINUX_FPGA_PAYLOAD)" ]; then \
		echo "[ERR] Linux FPGA payload not found after linux-build: $(LINUX_FPGA_PAYLOAD)"; exit 1; fi
	$(CROSS)gcc $(FW_LINUX_FPGA_CFLAGS) -T $(FW_LINUX_FPGA_SRC)/link.ld -o $@ $(FW_LINUX_FPGA_SRC)/boot.S

$(FW_LINUX_FPGA_BIN): $(FW_LINUX_FPGA_ELF)
	$(CROSS)objcopy -O binary $< $@

# $(call _emit_fpga_image,out,stage_bin,payload,dtb_offset,dtb_src,label): assemble
# stage0 + payload@PAYLOAD_OFFSET + DTB@dtb_offset with overlap guard; 'label' names the payload in logs.
define _emit_fpga_image
@if [ -z "$(3)" ] || [ ! -f "$(3)" ]; then \
	echo "[ERR] $(6) payload not found: $(3)"; exit 1; fi; \
stage_size=$$(stat -c%s "$(2)"); \
payload_size=$$(stat -c%s "$(3)"); \
dtb_size=$$(stat -c%s "$(FW_LINUX_FPGA_DTB)"); \
payload_offset=$$(( $(LINUX_FPGA_PAYLOAD_OFFSET) )); \
dtb_offset=$$(( $(4) )); \
if [ $$stage_size -gt $$payload_offset ]; then \
	echo "[ERR] stage0 too large ($$stage_size > payload offset $$payload_offset)"; exit 1; fi; \
if [ $$((payload_offset + payload_size)) -gt $$dtb_offset ]; then \
	echo "[ERR] $(6) payload overlaps DTB slot ($$payload_size bytes, offset $$payload_offset, dtb offset $$dtb_offset)"; exit 1; fi; \
cp "$(2)" "$(1)"; \
truncate -s $$payload_offset "$(1)"; \
cat "$(3)" >> "$(1)"; \
truncate -s $$dtb_offset "$(1)"; \
cat "$(FW_LINUX_FPGA_DTB)" >> "$(1)"; \
image_size=$$(stat -c%s "$(1)"); \
echo "[INFO] $(6) image: $(1) ($$image_size bytes)"; \
echo "[INFO]   stage0  @ $(MAIN_RAM_BASE) size=$$stage_size"; \
echo "[INFO]   payload @ $(LINUX_FPGA_PAYLOAD_SRC_ADDR) -> $(MAIN_RAM_BASE) size=$$payload_size"; \
echo "[INFO]   dtb     @ $(5) -> $(LINUX_FPGA_DTB_ADDR) size=$$dtb_size"
endef

$(FW_LINUX_FPGA_IMAGE): $(FW_LINUX_FPGA_BIN) $(FW_LINUX_FPGA_DTB) $(LINUX_FPGA_PAYLOAD)
	$(call _emit_fpga_image,$@,$(FW_LINUX_FPGA_BIN),$(LINUX_FPGA_PAYLOAD),$(LINUX_FPGA_DTB_OFFSET),$(LINUX_FPGA_DTB_SRC_ADDR),Linux FPGA)

fpga-img: $(FW_LINUX_FPGA_IMAGE) ## Build Linux FPGA stage0+OpenSBI+DTB upload image (VARIANT=linux)

$(FW_LINUX_FPGA_SMOKE_ELF): $(FW_LINUX_FPGA_SRC)/boot.S $(FW_LINUX_FPGA_SRC)/link.ld | $(FW_LINUX_FPGA_DIR)
	$(CROSS)gcc $(FW_LINUX_FPGA_SMOKE_CFLAGS) -T $(FW_LINUX_FPGA_SRC)/link.ld -o $@ $(FW_LINUX_FPGA_SRC)/boot.S

$(FW_LINUX_FPGA_SMOKE_BIN): $(FW_LINUX_FPGA_SMOKE_ELF)
	$(CROSS)objcopy -O binary $< $@

$(FW_LINUX_FPGA_SMOKE_IMAGE): $(FW_LINUX_FPGA_SMOKE_BIN)
	@cp $< $@
	@image_size=$$(stat -c%s "$@"); \
	 echo "[INFO] Linux FPGA smoke image: $@ ($$image_size bytes)"; \
	 echo "[INFO]   stage0-only diagnostic @ $(MAIN_RAM_BASE)"; \
	 echo "[INFO]   payload size=0, dtb size=0; expected to loop after jumping to $(MAIN_RAM_BASE)"

fpga-smoke-img: $(FW_LINUX_FPGA_SMOKE_IMAGE) ## Build tiny Linux FPGA stage0-only smoke upload image (VARIANT=linux)

$(FW_LINUX_FPGA_OPENSBI_ELF): opensbi-build $(FW_LINUX_FPGA_SRC)/boot.S $(FW_LINUX_FPGA_SRC)/link.ld $(FW_LINUX_FPGA_DTB) $(LINUX_FPGA_OPENSBI_PAYLOAD) | $(FW_LINUX_FPGA_DIR)
	@if [ -z "$(LINUX_FPGA_OPENSBI_PAYLOAD)" ] || [ ! -f "$(LINUX_FPGA_OPENSBI_PAYLOAD)" ]; then \
		echo "[ERR] Linux FPGA OpenSBI payload not found after opensbi-build: $(LINUX_FPGA_OPENSBI_PAYLOAD)"; exit 1; fi
	$(CROSS)gcc $(FW_LINUX_FPGA_OPENSBI_CFLAGS) -T $(FW_LINUX_FPGA_SRC)/link.ld -o $@ $(FW_LINUX_FPGA_SRC)/boot.S

$(FW_LINUX_FPGA_OPENSBI_BIN): $(FW_LINUX_FPGA_OPENSBI_ELF)
	$(CROSS)objcopy -O binary $< $@

$(FW_LINUX_FPGA_OPENSBI_IMAGE): $(FW_LINUX_FPGA_OPENSBI_BIN) $(FW_LINUX_FPGA_DTB) $(LINUX_FPGA_OPENSBI_PAYLOAD)
	$(call _emit_fpga_image,$@,$(FW_LINUX_FPGA_OPENSBI_BIN),$(LINUX_FPGA_OPENSBI_PAYLOAD),$(LINUX_FPGA_OPENSBI_DTB_OFFSET),$(LINUX_FPGA_OPENSBI_DTB_SRC_ADDR),Linux FPGA OpenSBI)

fpga-opensbi-img: $(FW_LINUX_FPGA_OPENSBI_IMAGE) ## Build Linux FPGA stage0+standalone OpenSBI+DTB upload image (VARIANT=linux)

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
define _litex_bios_patches_apply
	$(PYTHON) $(LITEX_DIR)/scripts/patch_litex_picolibc.py $(LITEX_PATH) && $(PYTHON) $(LITEX_DIR)/scripts/patch_litex_uart_polling.py $(LITEX_PATH)
endef
define _litex_bios_patches_restore
	cd $(LITEX_PATH) && git checkout -- litex/soc/software/common.mak litex/soc/software/libc/Makefile litex/soc/software/libbase/uart.c litex/soc/software/bios/main.c 2>/dev/null || true
endef

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

ifeq ($(SOC),default)
SIM_SOC_FLAGS :=
else ifeq ($(SOC),fpga)
SIM_SOC_FLAGS := --integrated-rom-size=0x8000 --integrated-sram-size=0x2000 --integrated-main-ram-size=0
else
$(error Invalid SOC='$(SOC)'. Use SOC=default|fpga)
endif

SIM_PAYLOAD_BIN   :=
SIM_PAYLOAD_BUILD :=
ifeq ($(PAYLOAD),none)
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

SIM_DIR    := $(BUILD_DIR)/sim/$(VARIANT)-$(ROM)-$(SOC)
SIM_BUILD_DIR := $(SIM_DIR)/gateware

define _soc_gen
	source $(VENV_DIR)/bin/activate && \
	$(PYTHON) raptor_soc.py $(1) $(EXTRA_FLAGS)
endef

_BASE_FLAGS = --sys-clk-freq=$(SYS_CLK) --threads=$(SIM_THREADS) $(TRACE_FLAGS)
SIM_FLAGS   = --output-dir=$(SIM_DIR) --cpu-variant=$(VARIANT) \
              $(SIM_ROM_FLAGS) $(SIM_SOC_FLAGS) $(SIM_PAYLOAD_FLAG) $(_BASE_FLAGS)

define _compile_if_needed
	@mkdir -p $(1)
	@SIM_V_HASH=$$({ \
		grep -v -e '^// Date' -e '^//  Auto-Generated by LiteX on' $(1)/sim.v 2>/dev/null; \
		cat $(1)/sim_init.cpp 2>/dev/null; \
		cat $(1)/build_sim.sh 2>/dev/null; \
		cat $(PACK_SV) 2>/dev/null; \
	} | md5 -q 2>/dev/null || { \
		grep -v -e '^// Date' -e '^//  Auto-Generated by LiteX on' $(1)/sim.v 2>/dev/null; \
		cat $(1)/sim_init.cpp 2>/dev/null; \
		cat $(1)/build_sim.sh 2>/dev/null; \
		cat $(PACK_SV) 2>/dev/null; \
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

define _run_vsim
	@if [ ! -f $(1)/obj_dir/Vsim ]; then \
		echo "[ERR] No sim binary at $(1). Run 'make sim-build' first."; exit 1; fi
	@echo "[INFO] Running sim (timeout=$(SIM_TIMEOUT)s, Ctrl+C to stop)"
	@if [ -n "$(TRACE_MSG)" ]; then echo "[INFO] $(TRACE_MSG) — wave -> $(1)/sim.$(TRACE)"; fi
	@cd $(1) && \
	if [ -z "$(SIM_STOP_MARKER)" ]; then \
		$(TIMEOUT_RUN) $(TIMEOUT_FOREGROUND) $(SIM_TIMEOUT) obj_dir/Vsim; \
		rc=$$?; \
		if [ $$rc -eq 124 ]; then \
			echo ""; echo "[INFO] Simulation timed out after $(SIM_TIMEOUT)s."; \
		elif [ $$rc -eq 130 ] || [ $$rc -eq 143 ]; then \
			echo ""; echo "[INFO] Simulation interrupted (Ctrl+C / SIGTERM)."; \
		elif [ $$rc -ne 0 ]; then \
			exit $$rc; \
		fi; \
	else \
		: > sim_run.log; \
		obj_dir/Vsim > sim_run.log 2>&1 & vpid=$$!; \
		tail -n +1 -f sim_run.log 2>/dev/null & tpid=$$!; \
		limit=$(SIM_TIMEOUT); [ "$$limit" = "0" ] && limit=100000; i=0; \
		while kill -0 $$vpid 2>/dev/null; do \
			if grep -qF "$(SIM_STOP_MARKER)" sim_run.log; then \
				echo "[INFO] Sim reached completion marker ('$(SIM_STOP_MARKER)')."; break; fi; \
			i=$$((i+1)); \
			if [ $$i -ge $$limit ]; then echo ""; echo "[INFO] Simulation timed out after $(SIM_TIMEOUT)s."; break; fi; \
			sleep 1; \
		done; \
		kill $$vpid 2>/dev/null || true; sleep 0.3; \
		for _ in 1 2 3 4 5; do kill -0 $$vpid 2>/dev/null || break; sleep 0.2; done; \
		kill -9 $$vpid 2>/dev/null || true; wait $$vpid 2>/dev/null || true; \
		kill $$tpid 2>/dev/null || true; wait $$tpid 2>/dev/null || true; \
	fi
	@if [ -n "$(TRACE_MSG)" ] && [ -f $(1)/sim.$(TRACE) ]; then \
		sz=$$(wc -c < $(1)/sim.$(TRACE)); \
		echo "[INFO] Wave: $(1)/sim.$(TRACE) ($$sz bytes)"; \
	fi
endef

sim-gen: $(PACK_SV) $(SIM_ROM_DEP) $(SIM_PAYLOAD_BUILD) ## Generate SoC Verilog (no compile, no run) {ROM,SOC,PAYLOAD,VARIANT,IMG}
	@if [ "$(SIM_NEEDS_BIOS_PATCHES)" = "1" ]; then $(call _litex_bios_patches_apply); fi
	@trap '[ "$(SIM_NEEDS_BIOS_PATCHES)" = "1" ] && { $(call _litex_bios_patches_restore); } || true' EXIT; \
	$(call _soc_gen,$(SIM_FLAGS))

sim-build: sim-gen ## Generate SoC + compile Verilator binary {ROM,SOC,PAYLOAD,VARIANT,IMG}
	$(call _compile_if_needed,$(SIM_BUILD_DIR))

sim: sim-build ## Build + run sim {ROM,SOC,PAYLOAD,VARIANT,IMG,TRACE,SIM_TIMEOUT,SIM_THREADS}
	$(call _run_vsim,$(SIM_BUILD_DIR))

sim-run: ## Run already-built sim (no rebuild) {ROM,SOC,PAYLOAD,VARIANT,SIM_TIMEOUT}
	$(call _run_vsim,$(SIM_BUILD_DIR))

sim-trace: ## Alias: make sim TRACE=fst
	@$(MAKE) --no-print-directory sim TRACE=fst

sim-trace-vcd: ## Alias: make sim TRACE=vcd (slower/larger than FST)
	@$(MAKE) --no-print-directory sim TRACE=vcd

# ==============================================================================
# Payload aliases
# ==============================================================================

COREMARK_ITERATIONS ?= 64 ## CoreMark loop iterations (FPGA: 1000+ recommended; sim: 64)

coremark-build: ## Build CoreMark binary (clone + compile) {COREMARK_ITERATIONS,SYS_CLK}
	$(MAKE) -C $(COREMARK_BENCH) build ITERATIONS=$(COREMARK_ITERATIONS) SYS_CLK_HZ=$(SYS_CLK)

coremark: ## Alias: make sim PAYLOAD=coremark — tees output to $(LITEX_LOG_DIR)/coremark.log
	@mkdir -p $(LITEX_LOG_DIR)
	@set -o pipefail; $(MAKE) --no-print-directory sim PAYLOAD=coremark \
		SIM_STOP_MARKER='CoreMark: done.' \
		SIM_TIMEOUT=$(if $(filter command line environment,$(origin SIM_TIMEOUT)),$(SIM_TIMEOUT),600) \
		COREMARK_ITERATIONS=$(COREMARK_ITERATIONS) \
		2>&1 | tee $(LITEX_LOG_DIR)/coremark.log

# CoreMark needs >=10 s of run time for a valid score; on the ~10 MHz FPGA the
# core does ~30 iters/s, so the sim default of 64 is far too low (it prints
# "Must execute for at least 10 secs").  Default this FPGA target to a value that
# clears the 10 s floor.  NOTE: coremark-fpga rebuilds coremark-build with this
# value, so `make coremark-fpga` alone (default 64) would otherwise overwrite a
# prior `make coremark-build COREMARK_ITERATIONS=N`.  Override inline instead:
# `make coremark-fpga COREMARK_ITERATIONS=N`.
coremark-fpga: COREMARK_ITERATIONS := 2000
coremark-fpga: coremark-build ## Upload CoreMark to FPGA main_ram via BIOS serialboot {COREMARK_ITERATIONS,MAIN_RAM_BASE,UART_PORT}
	@echo "[INFO] CoreMark built for SYS_CLK=$(SYS_CLK) Hz (VARIANT=$(VARIANT)) — the LOADED bitstream must run at this clock, else 'Total time'/'Iterations/Sec' are off by the clock ratio (rdtime timebase == sys_clk)."
	@$(MAKE) --no-print-directory fpga-upload BIN=$(COREMARK_BIN)

coremark-clean: ## Remove CoreMark build artifacts (keep cloned source)
	$(MAKE) -C $(COREMARK_BENCH) clean

main-fpga-build: ## Build FPGA main firmware (uploadable via serialboot to main_ram) {UART_PORT}
	$(MAKE) -C $(LITEX_DIR) firmware-fpga FW_FPGA_TARGET=main FW_FPGA_LOAD=main_ram
	@echo "[INFO] FPGA main firmware ready: $(BUILD_DIR)/firmware/fpga/main-main_ram/boot.bin"

main-fpga: main-fpga-build ## Build + upload FPGA main firmware to main_ram {UART_PORT}
	@$(MAKE) --no-print-directory fpga-upload BIN=$(BUILD_DIR)/firmware/fpga/main-main_ram/boot.bin

u-sv32-s-ecall-stress-fpga-build: ## Build short Sv32 U->S syscall stress for LiteX FPGA
	$(MAKE) -C $(RAPTOR_HOME)/app/tests/irq $(ECALL_STRESS_FPGA_BIN) \
		BUILD_DIR=$(ECALL_STRESS_FPGA_DIR) EXTRA_CFLAGS=-DRAPT_LITEX_FPGA

u-sv32-s-ecall-stress-fpga-upload: u-sv32-s-ecall-stress-fpga-build ## Upload short Sv32 U->S syscall stress via BIOS serialboot
	@$(MAKE) --no-print-directory fpga-upload BIN=$(ECALL_STRESS_FPGA_BIN)

irqtest-fpga: ## Build + upload minimal IRQ test firmware {UART_PORT}
	$(MAKE) -C $(LITEX_DIR) firmware-fpga FW_FPGA_TARGET=irqtest FW_FPGA_LOAD=main_ram
	@$(MAKE) --no-print-directory fpga-upload BIN=$(BUILD_DIR)/firmware/fpga/irqtest-main_ram/boot.bin

main-fpga-clean: ## Remove FPGA firmware build artifacts
	rm -rf $(BUILD_DIR)/firmware/fpga/main-main_ram $(BUILD_DIR)/firmware/fpga/irqtest-main_ram

EMBENCH_TARGETS := $(addprefix embench-run-,$(EMBENCH_BENCHES))
EMBENCH_BUILDS  := $(addprefix embench-build-,$(EMBENCH_BENCHES))

embench-build: ## Build all Embench-IoT benchmarks (one BIN per bench)
	$(MAKE) -C $(EMBENCH_BENCH) build SYS_CLK_HZ=$(SYS_CLK) \
		NETTLE_SHA256_LOCAL_SCALE=$(EMBENCH_NETTLE_SHA256_LOCAL_SCALE)

$(EMBENCH_BUILDS): embench-build-%:
	$(MAKE) -C $(EMBENCH_BENCH) build BENCH=$* SYS_CLK_HZ=$(SYS_CLK) \
		NETTLE_SHA256_LOCAL_SCALE=$(EMBENCH_NETTLE_SHA256_LOCAL_SCALE)

embench-build-one: ## Build one Embench bench (BENCH=<name>) {BENCH}
	@if [ -z "$(BENCH)" ]; then echo "[ERR] Set BENCH=<name>"; exit 1; fi
	@$(MAKE) --no-print-directory embench-build-$(BENCH)

$(EMBENCH_TARGETS): embench-run-%: ## Alias: make sim PAYLOAD=embench-<NAME>
	@$(MAKE) --no-print-directory sim PAYLOAD=embench-$*

embench-run: ## Run one Embench bench (BENCH=<name>) {BENCH}
	@if [ -z "$(BENCH)" ]; then echo "[ERR] Set BENCH=<name>"; exit 1; fi
	@$(MAKE) --no-print-directory sim PAYLOAD=embench-$(BENCH)

# run-embench.sh loads each bench into main_ram and runs Vsim directly, so it
# needs the `sim` ROM (asm trampoline that jumps to main_ram), NOT the default
# `bios` ROM (which halts at the litex> shell). SIM_DIR is an immediate (`:=`)
# assignment, so a target-specific ROM would not recompute the build path;
# invoke sim-build recursively with ROM=sim and keep run-embench.sh in sync.
embench: $(PACK_SV) $(FW_SIM_BIN) ## Build + run all Embench benches (parallel) + Embench Score report
	@$(MAKE) --no-print-directory sim-build ROM=sim
	@mkdir -p $(EMBENCH_LOG_DIR)
	@set -o pipefail; env BENCHES="$(EMBENCH_RUN_BENCHES)" LOG_DIR=$(EMBENCH_LOG_DIR) ROM=sim \
		SYS_CLK_HZ=$(SYS_CLK) \
		SIM_TIMEOUT=$(if $(filter command line environment,$(origin SIM_TIMEOUT)),$(SIM_TIMEOUT),1200) \
		EMBENCH_NETTLE_SHA256_LOCAL_SCALE=$(EMBENCH_NETTLE_SHA256_LOCAL_SCALE) \
		$(if $(strip $(EMBENCH_JOBS)),JOBS=$(EMBENCH_JOBS),) \
		bash $(EMBENCH_BENCH)/run-embench.sh 2>&1 | tee $(LITEX_LOG_DIR)/embench.log

embench-report: ## Re-run Embench Score report from existing logs
	@env $(if $(filter command line environment,$(origin EMBENCH_NETTLE_SHA256_LOCAL_SCALE)),EMBENCH_NETTLE_SHA256_LOCAL_SCALE=$(EMBENCH_NETTLE_SHA256_LOCAL_SCALE)) \
		bash $(EMBENCH_BENCH)/report-embench.sh $(EMBENCH_LOG_DIR)

embench-clean: ## Remove Embench build artifacts and run logs
	$(MAKE) -C $(EMBENCH_BENCH) clean
	rm -rf $(EMBENCH_LOG_DIR)

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

app-llm-fpga: ## Upload one app/ LLM benchmark to FPGA (BENCH=ops|infer|train) {BENCH,UART_PORT}
	@if [ -z "$(BENCH)" ]; then echo "[ERR] Set BENCH=ops|infer|train"; exit 1; fi
	@$(MAKE) --no-print-directory app-llm-$(BENCH)-fpga $(APP_LLM_VARS)

APP_FPGA_BIN ?= ## Custom app-built LiteX-native binary for app-fpga-upload
app-fpga-upload: ## Upload a prebuilt app LiteX-native bin via BIOS serialboot {APP_FPGA_BIN,UART_PORT}
	@if [ -z "$(APP_FPGA_BIN)" ]; then echo "[ERR] Set APP_FPGA_BIN=/path/to.bin"; exit 1; fi
	@$(MAKE) --no-print-directory fpga-upload BIN=$(APP_FPGA_BIN)

microbench-build: ## Build MicroBench binary
	$(MAKE) -C $(MICROBENCH_DIR) ARCH=riscv32-npc

microbench: ## Alias: make sim PAYLOAD=microbench — tees output to $(LITEX_LOG_DIR)/microbench.log
	@mkdir -p $(LITEX_LOG_DIR)
	@set -o pipefail; $(MAKE) --no-print-directory sim PAYLOAD=microbench \
		2>&1 | tee $(LITEX_LOG_DIR)/microbench.log

TEST_TARGETS := $(addprefix test-,$(TEST_NAMES))

tests: ## Build all standalone C microbenchmarks (build/tests/*.bin)
	$(MAKE) -C $(TESTS_DIR) BUILD_DIR=$(TESTS_BUILD_DIR)

tests-clean: ## Clean standalone microbenchmark build artifacts
	$(MAKE) -C $(TESTS_DIR) BUILD_DIR=$(TESTS_BUILD_DIR) clean

$(TEST_TARGETS): test-%: ## Alias: make sim PAYLOAD=test-<NAME>
	@$(MAKE) --no-print-directory sim PAYLOAD=test-$*

tests-run: tests ## Run every standalone test sequentially — tees aggregate output to $(LITEX_LOG_DIR)/tests-run.log
	@mkdir -p $(LITEX_LOG_DIR)
	@{ set -e; for t in $(TEST_NAMES); do \
		echo "================================================================"; \
		echo "[tests-run] Running test-$$t"; \
		echo "================================================================"; \
		$(MAKE) --no-print-directory sim PAYLOAD=test-$$t SIM_TIMEOUT=$(SIM_TIMEOUT) || exit 1; \
	done; \
	echo "[tests-run] All tests completed."; } 2>&1 | tee $(LITEX_LOG_DIR)/tests-run.log

opensbi-build: ## Build OpenSBI (standalone, from linux/opensbi)
	$(MAKE) -C $(LINUX_DIR) opensbi

opensbi: ## Alias: make sim PAYLOAD=opensbi
	@$(MAKE) --no-print-directory sim PAYLOAD=opensbi

opensbi-clean: ## Clean OpenSBI build artifacts
	$(MAKE) -C $(LINUX_DIR) opensbi-clean

payload: ## Alias: make sim PAYLOAD=img IMG=/path/to.bin {IMG,TRACE,SIM_TIMEOUT}
	@if [ -z "$(IMG)" ]; then echo "[ERR] Set IMG=/path/to/binary.bin"; exit 1; fi
	@$(MAKE) --no-print-directory sim PAYLOAD=img IMG=$(IMG)

EGOS_KU15P_BIN ?= $(LINUX_FPGA_EGOS_KU15P_IMAGE) ## egos-ku15p.bin path (default: auto-built)

egos-ku15p-sim: fpga-egos-prepare ## Simulate egos-ku15p in LiteX Verilator SoC {TRACE,SIM_TIMEOUT,EGOS_KU15P_BIN}
	@echo "[INFO] Simulating egos-ku15p (Verilator LiteX SoC — same map as FPGA, zero-latency SRAM)."
	@echo "[INFO] If this runs fine but FPGA hangs → DDR4-latency or FPGA-specific RTL bug."
	@echo "[INFO] Use TRACE=fst to capture waveform: make egos-ku15p-sim TRACE=fst"
	@$(MAKE) --no-print-directory sim PAYLOAD=img IMG=$(EGOS_KU15P_BIN) \
		SIM_TIMEOUT=$(SIM_TIMEOUT)

egos-ku15p-sim-trace: fpga-egos-prepare ## Simulate egos-ku15p with FST waveform dump {TRACE_START,TRACE_END}
	@$(MAKE) --no-print-directory egos-ku15p-sim TRACE=fst

linux-build: ## Download pre-built Linux payload (if needed)
	$(MAKE) -s -C $(LINUX_DIR) download-rv32

linux: ## Alias: make sim PAYLOAD=linux VARIANT=linux
	@$(MAKE) --no-print-directory sim PAYLOAD=linux VARIANT=linux

# ------------------------------------------------------------------------------
# KU15P Linux/MIG FPGA helpers. These wrappers force VARIANT=linux so callers do
# not need to repeat the profile on every build/load/upload command. `*-run`
# reloads an existing timing-clean bitstream before uploading software; `*-e2e`
# builds the bitstream when stale, loads it, then uploads software.
# ------------------------------------------------------------------------------

linux-fpga-build: ## Build the timing-gated KU15P Linux/MIG bitstream
	@$(MAKE) --no-print-directory fpga-build $(_LINUX_FPGA_ARGS)

linux-fpga-load: ## Load the existing KU15P Linux/MIG bitstream
	@$(MAKE) --no-print-directory fpga-load $(_LINUX_FPGA_ARGS)

linux-fpga-upload: ## Upload the contiguous Linux image with litex_term (SD-boot fallback) {UART_PORT}
	@$(MAKE) --no-print-directory fpga-upload $(_LINUX_FPGA_ARGS)

linux-fpga-run: ## Load the existing bitstream, then upload OpenSBI + Linux {UART_PORT}
	@$(MAKE) --no-print-directory fpga-load $(_LINUX_FPGA_ARGS)
	@$(MAKE) --no-print-directory linux-fpga-upload

linux-fpga-e2e: ## Build/load the bitstream, then upload OpenSBI + Linux {UART_PORT}
	@$(MAKE) --no-print-directory fpga-build $(_LINUX_FPGA_ARGS)
	@$(MAKE) --no-print-directory linux-fpga-run

opensbi-fpga-upload: ## Upload standalone OpenSBI without rebuilding or reloading {UART_PORT}
	@$(MAKE) --no-print-directory fpga-opensbi-upload $(_LINUX_FPGA_ARGS)

opensbi-fpga-run: ## Load the existing bitstream, then upload standalone OpenSBI {UART_PORT}
	@$(MAKE) --no-print-directory fpga-load $(_LINUX_FPGA_ARGS)
	@$(MAKE) --no-print-directory opensbi-fpga-upload

opensbi-fpga-e2e: ## Build/load the bitstream, then upload standalone OpenSBI {UART_PORT}
	@$(MAKE) --no-print-directory fpga-build $(_LINUX_FPGA_ARGS)
	@$(MAKE) --no-print-directory opensbi-fpga-run

fpga-opensbi-upload: fpga-opensbi-img ## Build/upload standalone linux/opensbi image through BIOS serialboot {UART_PORT,LINUX_FPGA_OPENSBI_PAYLOAD}
	@$(call _fpga_linux_upload,$(FW_LINUX_FPGA_OPENSBI_IMAGE))

fpga-smoke-upload: fpga-smoke-img ## Upload tiny stage0-only image through BIOS serialboot {UART_PORT}
	@$(call _fpga_linux_upload,$(FW_LINUX_FPGA_SMOKE_IMAGE))

fpga-smoke: ## Build/load Linux FPGA bitstream, then upload tiny stage0-only smoke image {UART_PORT,VIVADO}
	@$(MAKE) --no-print-directory fpga $(_LINUX_FPGA_ARGS)
	@$(MAKE) --no-print-directory fpga-smoke-upload

fpga-tinyos-prepare: ## Build TinyOS simulator artifacts for OS=egos|xv6 {OS,TINYOS_OS}
	@os="$(LINUX_FPGA_TINYOS_OS)"; \
	if [ -z "$$os" ]; then echo "[ERR] Set OS=egos|xv6 or TINYOS_OS=egos|xv6"; exit 1; fi; \
	case "$$os" in \
	  egos) $(MAKE) --no-print-directory fpga-egos-prepare ;; \
	  xv6)  $(MAKE) --no-print-directory fpga-xv6-prepare ;; \
	  *) echo "[ERR] Unsupported TinyOS OS '$$os' (use OS=egos or OS=xv6)"; exit 1 ;; \
	esac

fpga-egos-prepare: ## Build egos kernel, disk.img, and legacy flat simulation image
	@echo "[INFO] Building egos-2000 KU15P RAM-disk image via app/tinyos"
	@$(MAKE) --no-print-directory -C $(RAPTOR_HOME)/app/tinyos egos-ku15p-image
	@test -f "$(LINUX_FPGA_EGOS_KU15P_IMAGE)" || { echo "[ERR] Missing egos KU15P image: $(LINUX_FPGA_EGOS_KU15P_IMAGE)"; exit 1; }
	@test -f "$(LINUX_FPGA_EGOS_IMAGE)" || { echo "[ERR] Missing egos kernel: $(LINUX_FPGA_EGOS_IMAGE)"; exit 1; }
	@test -f "$(LINUX_FPGA_EGOS_DISK)" || { echo "[ERR] Missing egos disk: $(LINUX_FPGA_EGOS_DISK)"; exit 1; }
	@echo "[INFO] egos kernel: $(LINUX_FPGA_EGOS_IMAGE)"
	@echo "[INFO] egos disk:   $(LINUX_FPGA_EGOS_DISK)"
	@echo "[INFO]   upload: make fpga-egos-upload   (forces VARIANT=linux; UART $(UART_PORT) @ linux-profile baud)"

fpga-egos-bundle: fpga-egos-prepare $(FW_EGOS_STAGE0_BIN) ## Build compact stage0+kernel+disk serialboot bundle
	@stage_size=$$(stat -c%s "$(FW_EGOS_STAGE0_BIN)"); \
	 kernel_size=$$(stat -c%s "$(LINUX_FPGA_EGOS_IMAGE)"); \
	 disk_size=$$(stat -c%s "$(LINUX_FPGA_EGOS_DISK)"); \
	 if [ $$stage_size -gt $$((0x1000)) ]; then echo "[ERR] egos stage0 exceeds 4 KiB: $$stage_size"; exit 1; fi; \
	 if [ $$kernel_size -gt $$((0x10000)) ]; then echo "[ERR] egos kernel exceeds 64 KiB slot: $$kernel_size"; exit 1; fi; \
	 if [ $$disk_size -ne $$((0x400000)) ]; then echo "[ERR] egos disk must be exactly 4 MiB: $$disk_size"; exit 1; fi; \
	 cp "$(FW_EGOS_STAGE0_BIN)" "$(FW_EGOS_STAGE0_BUNDLE)"; \
	 truncate -s $$((0x1000)) "$(FW_EGOS_STAGE0_BUNDLE)"; \
	 cat "$(LINUX_FPGA_EGOS_IMAGE)" >> "$(FW_EGOS_STAGE0_BUNDLE)"; \
	 truncate -s $$((0x11000)) "$(FW_EGOS_STAGE0_BUNDLE)"; \
	 cat "$(LINUX_FPGA_EGOS_DISK)" >> "$(FW_EGOS_STAGE0_BUNDLE)"; \
	 bundle_size=$$(stat -c%s "$(FW_EGOS_STAGE0_BUNDLE)"); \
	 echo "[INFO] Compact egos bundle: $(FW_EGOS_STAGE0_BUNDLE) ($$bundle_size bytes)"; \
	 echo "[INFO]   stage0 @ $(LINUX_FPGA_EGOS_STAGE_ADDR), kernel -> 0x80000000, disk -> 0x80800000"

fpga-xv6-prepare: ## Build xv6 kernel.bin and fs.img used by TinyOS xv6 checks
	@echo "[INFO] Building xv6-riscv kernel.bin and fs.img via app/tinyos"
	@$(MAKE) --no-print-directory -C $(RAPTOR_HOME)/app/tinyos xv6-sim-image
	@test -f "$(LINUX_FPGA_XV6_KERNEL)" || { echo "[ERR] Missing xv6 kernel: $(LINUX_FPGA_XV6_KERNEL)"; exit 1; }
	@test -f "$(LINUX_FPGA_XV6_DISK)" || { echo "[ERR] Missing xv6 disk: $(LINUX_FPGA_XV6_DISK)"; exit 1; }
	@echo "[INFO] xv6 kernel: $(LINUX_FPGA_XV6_KERNEL)"
	@echo "[INFO] xv6 disk:   $(LINUX_FPGA_XV6_DISK)"

fpga-tinyos-check: ## Explain TinyOS FPGA serialboot compatibility for OS=egos|xv6 {OS,TINYOS_OS}
	@os="$(LINUX_FPGA_TINYOS_OS)"; \
	if [ -z "$$os" ]; then echo "[ERR] Set OS=egos|xv6 or TINYOS_OS=egos|xv6"; exit 1; fi; \
	case "$$os" in \
	  egos) \
		echo "[INFO] egos-2000 KU15P compact bundle is ready for serialboot upload."; \
		echo "      Bundle: $(FW_EGOS_STAGE0_BUNDLE)"; \
		echo "      Build: make fpga-egos-prepare"; \
		echo "      Upload: make fpga-egos-upload UART_PORT=$(UART_PORT) UART_BAUD=$(UART_BAUD)"; \
		echo "      Stage0 restores egos at 0x80000000 and disk.img at 0x80800000."; \
		;; \
	  xv6) \
		echo "[ERR] xv6-riscv artifacts are prepared, but they cannot run on the current KU15P Linux/MIG bitstream."; \
		echo "      Kernel: $(LINUX_FPGA_XV6_KERNEL)"; \
		echo "      Disk:   $(LINUX_FPGA_XV6_DISK)"; \
		echo "      Prepare/build command:"; \
		echo "        make fpga-xv6-prepare"; \
		echo "      Required before FPGA serialboot can be correct:"; \
		echo "        - RV64/Sv39 FPGA CPU/bitstream, not the current RV32 VARIANT=linux bitstream"; \
		echo "        - UART/CLINT/PLIC/virtio-blk map compatible with xv6, or an xv6 LiteX port"; \
		echo "        - $(LINUX_FPGA_XV6_DISK) exposed as the xv6 block device"; \
		echo "      Simulator validation command:"; \
		echo "        make -C $(RAPTOR_HOME)/app/tinyos xv6-cli-nsim ARGS='-b -n'"; \
		exit 2; \
		;; \
	  *) echo "[ERR] Unsupported TinyOS OS '$$os' (use OS=egos or OS=xv6)"; exit 1 ;; \
	esac

fpga-tinyos-upload: ## Guarded TinyOS upload entry; dispatches OS=egos|xv6 {OS,TINYOS_OS}
	@os="$(LINUX_FPGA_TINYOS_OS)"; \
	if [ -z "$$os" ]; then echo "[ERR] Set OS=egos|xv6 or TINYOS_OS=egos|xv6"; exit 1; fi; \
	case "$$os" in \
	  egos) $(MAKE) --no-print-directory fpga-egos-upload ;; \
	  xv6)  $(MAKE) --no-print-directory fpga-xv6-upload ;; \
	  *) echo "[ERR] Unsupported TinyOS OS '$$os' (use OS=egos or OS=xv6)"; exit 1 ;; \
	esac

fpga-egos-upload: fpga-egos-bundle ## Upload compact KU15P egos bundle through LiteX BIOS serialboot {UART_PORT}
	@$(MAKE) --no-print-directory fpga-upload $(_LINUX_FPGA_ARGS) \
		BIN=$(FW_EGOS_STAGE0_BUNDLE) MAIN_RAM_BASE=$(LINUX_FPGA_EGOS_STAGE_ADDR)

RAPTOS_KU15P_BIN := $(RAPTOR_HOME)/app/tinyos/raptos/build/ku15p/raptos.bin

fpga-raptos-build: ## Build the single RaptOS image with all built-in U-mode payload commands
	@$(MAKE) --no-print-directory -C $(RAPTOR_HOME)/app/tinyos/raptos all PLATFORM=ku15p

fpga-raptos-upload: fpga-raptos-build ## Build and upload RaptOS with payload commands through the loaded KU15P BIOS {UART_PORT}
	@$(MAKE) --no-print-directory fpga-upload $(_LINUX_FPGA_ARGS) \
		BIN=$(RAPTOS_KU15P_BIN) MAIN_RAM_BASE=$(MAIN_RAM_BASE)

fpga-raptos-run: ## Build, upload, and attach to the interactive RaptOS shell {UART_PORT}
	@$(MAKE) --no-print-directory fpga-raptos-upload $(_LINUX_FPGA_ARGS)

fpga-xv6-upload: fpga-xv6-prepare ## Prepare xv6, then explain why current Linux/MIG bitstream refuses it
	@$(MAKE) --no-print-directory fpga-tinyos-check OS=xv6

bios: ## Alias: make sim ROM=bios (run LiteX BIOS in sim) {SOC,PAYLOAD,TRACE,SIM_TIMEOUT}
	@$(MAKE) --no-print-directory sim ROM=bios SOC=$(SOC) PAYLOAD=$(PAYLOAD)

# ==============================================================================
# FPGA Targets
# ==============================================================================

BOOT_MODE      ?= $(if $(LINUX_FPGA_PROFILE),bios,custom) ## FPGA boot ROM source (custom=firmware/fpga, bios=LiteX BIOS; linux FPGA profile: bios)
BOOT_MODE      := $(strip $(BOOT_MODE))
ifneq ($(BOOT_MODE),custom)
ifneq ($(BOOT_MODE),bios)
$(error Invalid BOOT_MODE='$(BOOT_MODE)'. Use BOOT_MODE=custom or BOOT_MODE=bios)
endif
endif

FPGA_FLAVOR    := $(BOOT_MODE)
ifneq ($(VARIANT),standard)
FPGA_FLAVOR    := $(FPGA_FLAVOR)-$(VARIANT)
endif
ifneq (,$(filter 1 yes true on,$(WITH_LITEDRAM)))
FPGA_FLAVOR    := $(FPGA_FLAVOR)-litedram
endif
ifneq (,$(filter 1 yes true on,$(WITH_MIG)))
FPGA_FLAVOR    := $(FPGA_FLAVOR)-mig
endif
ifneq (,$(filter 1 yes true on,$(WITH_SDCARD)))
FPGA_FLAVOR    := $(FPGA_FLAVOR)-sdcard
endif
ifneq (,$(filter 1 yes true on,$(SDCARD_BOOT)))
FPGA_FLAVOR    := $(FPGA_FLAVOR)-boot
endif
ifneq ($(VARIANT),standard)
FPGA_FLAVOR    := $(FPGA_FLAVOR)-$(RAPT_CONFIG)
endif
FPGA_FLAVOR_SUFFIX ?= ## Optional suffix for diagnostic FPGA builds, e.g. bimodal or ioq-in-order
FPGA_FLAVOR_SUFFIX := $(strip $(FPGA_FLAVOR_SUFFIX))
ifneq ($(FPGA_FLAVOR_SUFFIX),)
FPGA_FLAVOR    := $(FPGA_FLAVOR)-$(FPGA_FLAVOR_SUFFIX)
endif
FPGA_DIR       := $(BUILD_DIR)/$(FPGA_BOARD)/$(FPGA_FLAVOR)
FPGA_BUILD_DIR    := $(FPGA_DIR)/gateware

# fpga-build shells out to `$(MAKE) fpga-reports-index`; that sub-make would
# otherwise re-derive the FPGA profile from scratch and (since fpga-reports-index
# is not a profile-default goal, and VARIANT/BOOT_MODE/WITH_MIG are not exported)
# look in the wrong build dir -- e.g. bios/gateware instead of
# bios-linux-mig-default/gateware -- and warn "not found". Pin the resolved dir,
# board (=> vendor) and boot mode so the sub-make targets exactly what was built.
_FPGA_REPORTS_INDEX_ARGS = FPGA_BUILD_DIR="$(FPGA_BUILD_DIR)" FPGA_BOARD="$(FPGA_BOARD)" BOOT_MODE="$(BOOT_MODE)"

FPGA_BITSTREAM := $(FPGA_BUILD_DIR)/$(BOARD_$(FPGA_BOARD)_BITNAME)

ifneq ($(strip $(GOWIN_APP)),)
	GOWIN_BIN_DIR := $(GOWIN_APP)/Contents/Resources/Gowin_EDA/IDE/bin
	export PATH   := $(GOWIN_BIN_DIR):$(PATH)
endif

VIVADO       ?= vivado ## Vivado executable (Xilinx KU15P flow)
VIVADO_JOBS  ?= $(NPROC) ## Maximum Vivado worker threads
VIVADO_INCREMENTAL ?= 0 ## Set to 1 to reuse a compatible routed checkpoint
VIVADO := $(strip $(VIVADO))
VIVADO_JOBS := $(strip $(VIVADO_JOBS))
VIVADO_INCREMENTAL := $(strip $(VIVADO_INCREMENTAL))

OFL          ?= openFPGALoader ## openFPGALoader binary
OFL_CABLE    ?= ft2232 ## openFPGALoader cable (ft2232 for Tang Mega Pro on-board debugger)
OFL := $(strip $(OFL))
OFL_CABLE := $(strip $(OFL_CABLE))

ifeq ($(FPGA_VENDOR),vivado)
FPGA_LOAD_TOOL_CHECK = command -v $(VIVADO) >/dev/null 2>&1 || { echo "[ERR] $(VIVADO) not found on PATH — source settings64.sh"; exit 1; }
FPGA_LOAD_CMD  = $(VIVADO) -mode batch -nojournal -nolog -source $(LITEX_DIR)/scripts/vivado_load.tcl -tclargs $(FPGA_BITSTREAM)
FPGA_FLASH_CMD = $(VIVADO) -mode batch -nojournal -nolog -source $(LITEX_DIR)/scripts/vivado_flash.tcl -tclargs $(FPGA_BITSTREAM) $(FPGA_BUILD_DIR)
else
FPGA_LOAD_TOOL_CHECK = command -v $(OFL) >/dev/null 2>&1 || { echo "[ERR] openFPGALoader not found"; exit 1; }
FPGA_LOAD_CMD  = $(OFL) --cable $(OFL_CABLE) --bitstream $(FPGA_BITSTREAM)
FPGA_FLASH_CMD = $(OFL) --cable $(OFL_CABLE) --write-flash --external-flash --bitstream $(FPGA_BITSTREAM)
endif

WITH_LED_CHASER_FLAG := $(if $(filter 1 yes true on,$(WITH_LED_CHASER)),--with-led-chaser,)

WITH_LITEDRAM_FLAG := $(if $(filter 1 yes true on,$(WITH_LITEDRAM)),--with-litedram,)
LITEDRAM_SIZE_FLAG := $(if $(WITH_LITEDRAM_FLAG),--litedram-size=$(LITEDRAM_SIZE),)

WITH_MIG_FLAG := $(if $(filter 1 yes true on,$(WITH_MIG)),--with-mig,)
MIG_SIZE_FLAG := $(if $(WITH_MIG_FLAG),--mig-size=$(MIG_SIZE),)
WITH_SDCARD_FLAG := $(if $(filter 1 yes true on,$(WITH_SDCARD)),--with-sdcard,)
SDCARD_BOOT_FLAG := $(if $(filter 1 yes true on,$(SDCARD_BOOT)),--sdcard-boot,)
VIVADO_INCREMENTAL_FLAG := $(if $(filter 1 yes true on,$(VIVADO_INCREMENTAL)),--vivado-incremental,)

ifneq ($(WITH_LITEDRAM_FLAG),)
ifneq ($(WITH_MIG_FLAG),)
$(error WITH_LITEDRAM and WITH_MIG are mutually exclusive)
endif
endif

ifeq ($(BOOT_MODE),custom)
_FPGA_BOOT_FLAGS := --boot-mode=custom --integrated-rom-init=$(FW_FPGA_BIN)
_FPGA_FW_DEP     := $(FW_FPGA_BIN)
else
_FPGA_BOOT_FLAGS := --boot-mode=bios
_FPGA_FW_DEP     :=
endif

_FPGA_FLAGS = --output-dir=$(FPGA_DIR) \
	--cpu-variant=$(VARIANT) --sys-clk-freq=$(SYS_CLK) \
	--vivado-max-threads=$(VIVADO_JOBS) $(VIVADO_INCREMENTAL_FLAG) \
	--uart-baudrate=$(UART_BAUD) \
	$(_FPGA_BOOT_FLAGS) \
	$(_MAIN_RAM_FLAG) \
	$(WITH_LED_CHASER_FLAG) $(WITH_LITEDRAM_FLAG) $(LITEDRAM_SIZE_FLAG) \
	$(WITH_MIG_FLAG) $(MIG_SIZE_FLAG) $(WITH_SDCARD_FLAG) $(SDCARD_BOOT_FLAG) $(EXTRA_FLAGS)

FPGA_STAMP    := $(FPGA_DIR)/.bitstream_stamp
_FPGA_HASH_COMMON_INPUTS = $(PACK_SV) $(FPGA_PY) $(if $(WITH_MIG_FLAG),$(LITEX_DIR)/scripts/ku15p_ddr4_mig.tcl,)
ifeq ($(BOOT_MODE),custom)
_FPGA_HASH_INPUTS = $(_FPGA_HASH_COMMON_INPUTS) $(FW_FPGA_BIN)
else
_FPGA_HASH_INPUTS = $(_FPGA_HASH_COMMON_INPUTS)
endif
_FPGA_HASH_KEY = $(shell { cat $(_FPGA_HASH_INPUTS) 2>/dev/null; printf '%s' '$(_FPGA_FLAGS)'; printf '%s' '$(RAPT_PACK_VFLAGS)'; } | shasum 2>/dev/null | cut -d' ' -f1)

fpga-detect: ## Detect connected Gowin/Sipeed FPGA via openFPGALoader {OFL,OFL_CABLE}
	@command -v $(OFL) >/dev/null 2>&1 || { echo "[ERR] openFPGALoader not found (install via brew install openfpgaloader)"; exit 1; }
	$(OFL) --detect --cable $(OFL_CABLE)

fpga-gen: $(PACK_SV) $(_FPGA_FW_DEP) ## Generate FPGA SoC sources only (no PnR) {BOOT_MODE,FPGA_BOARD,RAPT_CONFIG,INTEGRATED_MAIN_RAM_SIZE}
	@if [ "$(BOOT_MODE)" = "bios" ]; then $(call _litex_bios_patches_apply); fi; \
	trap '[ "$(BOOT_MODE)" = "bios" ] && { $(call _litex_bios_patches_restore); } || true' EXIT; \
	source $(VENV_DIR)/bin/activate && \
	$(PYTHON) $(FPGA_PY) $(_FPGA_FLAGS) --build --no-compile-gateware
	@echo "[INFO] Sources generated under $(FPGA_BUILD_DIR) (BOOT_MODE=$(BOOT_MODE))"

fpga-build: $(PACK_SV) $(_FPGA_FW_DEP) ## Build FPGA bitstream (synth + P&R) {BOOT_MODE,FPGA_BOARD,RAPT_CONFIG,INTEGRATED_MAIN_RAM_SIZE,WITH_LED_CHASER}
ifeq ($(FPGA_VENDOR),gowin)
	@if [ -z "$(strip $(GOWIN_APP))" ]; then \
		echo "[ERR] GOWIN_APP is empty — install GowinIDE.app or set GOWIN_APP=/path/to/GowinIDE.app"; exit 1; fi
	@if [ ! -x "$(GOWIN_BIN_DIR)/gw_sh" ]; then \
		echo "[ERR] gw_sh not found at $(GOWIN_BIN_DIR)/gw_sh"; exit 1; fi
else
	@command -v $(VIVADO) >/dev/null 2>&1 || { \
		echo "[ERR] $(VIVADO) not found on PATH — source the Vivado settings64.sh first"; exit 1; }
endif
	@mkdir -p $(FPGA_DIR)
	@OLD_HASH=$$(cat $(FPGA_STAMP) 2>/dev/null || echo ""); \
	NEW_HASH="$(_FPGA_HASH_KEY)"; \
	if [ -f "$(FPGA_BITSTREAM)" ] && [ "$$OLD_HASH" = "$$NEW_HASH" ]; then \
		echo "[INFO] Bitstream up to date (BOOT_MODE=$(BOOT_MODE), hash=$${NEW_HASH:0:12})"; \
		echo "[INFO]   $(FPGA_BITSTREAM)"; \
		echo "[INFO] Force rebuild with: make fpga-build-force"; \
		$(MAKE) --no-print-directory fpga-reports-index $(_FPGA_REPORTS_INDEX_ARGS); \
		exit 0; \
	fi; \
	echo "[INFO] Bitstream stale (old=$${OLD_HASH:0:12} new=$${NEW_HASH:0:12}); running $(FPGA_VENDOR)..."; \
	if [ "$(BOOT_MODE)" = "bios" ]; then $(call _litex_bios_patches_apply); fi; \
	trap '[ "$(BOOT_MODE)" = "bios" ] && { $(call _litex_bios_patches_restore); } || true' EXIT; \
	source $(VENV_DIR)/bin/activate && \
	$(PYTHON) $(FPGA_PY) $(_FPGA_FLAGS) --build && \
	printf '%s' "$$NEW_HASH" > $(FPGA_STAMP)
	@$(MAKE) --no-print-directory fpga-reports-index $(_FPGA_REPORTS_INDEX_ARGS)
	@echo ""
	@echo "========================================="
	@echo " Bitstream ready: $(FPGA_BITSTREAM)"
	@echo " Load (volatile):  make fpga-load"
	@echo " Flash (persist):  make fpga-flash"
	@if [ "$(FPGA_VENDOR)" = "gowin" ]; then \
		echo " Reports index:    $(GOWIN_REPORTS_INDEX_DST)"; \
	else \
		echo " Reports index:    $(VIVADO_REPORTS_INDEX_DST)"; \
	fi
	@echo "========================================="
ifeq ($(LINUX_FPGA_PROFILE),1)
	@$(MAKE) --no-print-directory fpga-timing-ok
endif

GOWIN_REPORTS_INDEX_SRC  := $(LITEX_DIR)/scripts/reports_index.html
GOWIN_REPORTS_INDEX_DST  := $(FPGA_BUILD_DIR)/impl/index.html
VIVADO_REPORTS_INDEX_GEN := $(LITEX_DIR)/scripts/vivado_reports_index.py
VIVADO_REPORTS_INDEX_DST := $(FPGA_BUILD_DIR)/index.html

fpga-reports-index: ## Generate/install aggregated FPGA report HTML dashboard
ifeq ($(FPGA_VENDOR),gowin)
	@if [ -d "$(FPGA_BUILD_DIR)/impl" ]; then \
		cp $(GOWIN_REPORTS_INDEX_SRC) $(GOWIN_REPORTS_INDEX_DST); \
		echo "[INFO] Reports index: $(GOWIN_REPORTS_INDEX_DST)"; \
	else \
		echo "[WARN] $(FPGA_BUILD_DIR)/impl not found — run 'make fpga-build' first."; \
	fi
else
	@if [ -d "$(FPGA_BUILD_DIR)" ]; then \
		if ls "$(FPGA_BUILD_DIR)"/*.rpt >/dev/null 2>&1; then \
			$(HOST_PYTHON) $(VIVADO_REPORTS_INDEX_GEN) $(FPGA_BUILD_DIR) \
				--output $(VIVADO_REPORTS_INDEX_DST) \
				--title "Vivado Reports - $(FPGA_BOARD) $(BOOT_MODE) $(RAPT_CONFIG)"; \
		else \
			echo "[WARN] no Vivado .rpt files under $(FPGA_BUILD_DIR) — run 'make fpga-build' first."; \
		fi; \
	else \
		echo "[WARN] $(FPGA_BUILD_DIR) not found — run 'make fpga-build' first."; \
	fi
endif

fpga-timing-ok: ## Check FPGA timing report before hardware load/flash {FPGA_BOARD,BOOT_MODE,RAPT_CONFIG}
ifeq ($(FPGA_VENDOR),vivado)
	@rpt="$(FPGA_BUILD_DIR)/$(FPGA_TIMINGRPT)"; \
	if [ ! -f "$$rpt" ]; then \
		echo "[ERR] Vivado timing report not found: $$rpt"; \
		echo "[ERR] Run 'make fpga-build' first."; \
		exit 1; \
	fi; \
	if grep -q "Timing constraints are not met" "$$rpt"; then \
		echo "[ERR] Vivado timing constraints are not met; refusing hardware load/flash/upload."; \
		echo "[ERR] Report: $$rpt"; \
		awk '/Design Timing Summary/{show=1} show && /Timing constraints are not met/{print; exit} show{print}' "$$rpt" | sed -n '1,18p'; \
		exit 1; \
	fi; \
	if grep -Eiq "Timing constraints are met|All user specified timing constraints are met" "$$rpt"; then \
		echo "[INFO] Vivado timing constraints are met: $$rpt"; \
	else \
		echo "[ERR] Could not determine Vivado timing status from: $$rpt"; \
		exit 1; \
	fi
else
	@echo "[INFO] Timing gate not implemented for FPGA_VENDOR=$(FPGA_VENDOR); skipping."
endif

fpga-build-force: ## Force full re-PnR (ignore content-hash cache) {BOOT_MODE,FPGA_BOARD,RAPT_CONFIG,INTEGRATED_MAIN_RAM_SIZE}
	@rm -f $(FPGA_STAMP)
	@$(MAKE) --no-print-directory fpga-build

# Linux FPGA profile: gate hardware load/flash on a passing Vivado timing report.
ifeq ($(LINUX_FPGA_PROFILE),1)
fpga-load fpga-flash: fpga-timing-ok
endif

fpga-load: ## Load bitstream into FPGA SRAM (volatile, lost on power-cycle) {OFL,OFL_CABLE,VIVADO,BOOT_MODE,FPGA_BOARD}
	@if [ ! -f "$(FPGA_BITSTREAM)" ]; then \
		echo "[ERR] $(FPGA_BITSTREAM) not found — run 'make fpga-build' first."; exit 1; fi
	@$(FPGA_LOAD_TOOL_CHECK)
	$(FPGA_LOAD_CMD)

fpga-flash: ## Write bitstream to external SPI flash (persists across power cycles) {OFL,OFL_CABLE,VIVADO,BOOT_MODE,FPGA_BOARD}
	@if [ ! -f "$(FPGA_BITSTREAM)" ]; then \
		echo "[ERR] $(FPGA_BITSTREAM) not found — run 'make fpga-build' first."; exit 1; fi
	@$(FPGA_LOAD_TOOL_CHECK)
	$(FPGA_FLASH_CMD)

fpga: fpga-build fpga-load ## Build + load (volatile) in one shot

mlk-cu07-ku15p: ## Build + load on MLK-CU07-KU15P (Vivado) {BOOT_MODE,RAPT_CONFIG}
	@$(MAKE) --no-print-directory fpga FPGA_BOARD=mlk_cu07_ku15p

mlk-cu07-ku15p-build: ## Build bitstream only on MLK-CU07-KU15P (Vivado) {BOOT_MODE,RAPT_CONFIG}
	@$(MAKE) --no-print-directory fpga-build FPGA_BOARD=mlk_cu07_ku15p

fpga-console: ## Open serial terminal on the FPGA UART at fixed 115200 baud (Ctrl-A K to quit) {UART_PORT}
	@if [ -z "$(UART_PORT)" ]; then \
		echo "[ERR] UART_PORT empty — plug in the board or set UART_PORT=/dev/tty.usbserial-XXXX"; exit 1; fi
	@command -v lm.flterm >/dev/null 2>&1 || command -v litex_term >/dev/null 2>&1 || true
	@echo "[INFO] Opening $(UART_PORT) @ $(UART_BAUD) baud (Ctrl-A K = quit)"
	source $(VENV_DIR)/bin/activate && \
	litex_term --speed=$(UART_BAUD) $(UART_PORT)

# fpga-upload payload defaults + Linux-profile serialboot prerequisites. Linux
# uses the existing contiguous stage0+OpenSBI+DTB image so every upload can use
# LiteX's maintained litex_term implementation. BIN=... selects a raw image.
ifeq ($(LINUX_FPGA_PROFILE),1)
_FPGA_UPLOAD_DEFAULT_BIN := $(FW_LINUX_FPGA_IMAGE)
ifeq ($(strip $(BIN)),)
fpga-upload: $(FW_LINUX_FPGA_IMAGE) fpga-timing-ok
else
fpga-upload: fpga-timing-ok
endif
else
_FPGA_UPLOAD_DEFAULT_BIN := $(FW_FPGA_BIN)
endif

fpga-upload: ## Upload one firmware image via LiteX serialboot at fixed 115200 baud {MAIN_RAM_BASE,UART_PORT,SERIALBOOT_SAFE,BIN}
fpga-upload:
	@if [ -z "$(UART_PORT)" ]; then \
		echo "[ERR] UART_PORT empty — set UART_PORT=/dev/tty.usbserial-XXXX"; exit 1; fi
	@bin="$(BIN)"; [ -z "$$bin" ] && bin="$(_FPGA_UPLOAD_DEFAULT_BIN)"; \
	if [ ! -f "$$bin" ]; then \
		echo "[ERR] $$bin not found — build it first (e.g. 'make firmware-fpga FW_FPGA_TARGET=$(FW_FPGA_TARGET) FW_FPGA_LOAD=main_ram')"; exit 1; fi; \
	echo "[INFO] Uploading $$bin to MAIN_RAM ($(MAIN_RAM_BASE)) via BIOS serialboot on $(UART_PORT)"; \
	if [ -n "$(SERIALBOOT_SAFE_FLAG)" ]; then echo "[INFO] Using litex_term --safe (SERIALBOOT_SAFE=$(SERIALBOOT_SAFE))"; fi; \
	echo "[INFO] Power-cycle / press the reboot button on the board if the BIOS prompt has timed out."; \
	source $(VENV_DIR)/bin/activate && \
	litex_term --speed=$(UART_BAUD) $(SERIALBOOT_SAFE_FLAG) --kernel="$$bin" --kernel-adr=$(MAIN_RAM_BASE) $(UART_PORT)

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

lint: ## Lint RTL (via sim)
	$(MAKE) -C $(RAPTOR_HOME) lint

_INFO_VARS := RAPTOR_HOME LITEX_DIR VARIANT SYS_CLK RAPT_CONFIG GOWIN_APP GOWIN_BIN_DIR OFL OFL_CABLE WITH_LITEDRAM LITEDRAM_SIZE WITH_MIG MIG_SIZE WITH_SDCARD SDCARD_BOOT UART_PORT UART_BAUD SIM_TIMEOUT PACK_SV BUILD_DIR PYTHON

info: ## Show configuration info
	@$(foreach v,$(_INFO_VARS),echo "$v = $($v)";)
	@echo "---- sim ----"
	@echo "ROM          = $(ROM)"
	@echo "SOC          = $(SOC)"
	@echo "PAYLOAD      = $(PAYLOAD)"
	@echo "SIM_DIR      = $(SIM_DIR)"
	@echo "SIM_BUILD_DIR   = $(SIM_BUILD_DIR)"
	@echo "VSIM         = $(SIM_BUILD_DIR)/obj_dir/Vsim (exists: $(shell test -f $(SIM_BUILD_DIR)/obj_dir/Vsim && echo yes || echo no))"
	@echo "---- fpga ----"
	@echo "FPGA_BOARD   = $(FPGA_BOARD)"
	@echo "FPGA_DIR     = $(FPGA_DIR)"
	@echo "FPGA_BITSTRM = $(FPGA_BITSTREAM) (exists: $(shell test -f $(FPGA_BITSTREAM) && echo yes || echo no))"
	@echo "BOOT_MODE    = $(BOOT_MODE)"
	@echo "FPGA_STAMP   = $(FPGA_STAMP) (cached: $(shell test -f $(FPGA_STAMP) && echo yes || echo no))"
	@echo "---- linux fpga profile ----"
	@echo "LINUX_FPGA_PROFILE = $(LINUX_FPGA_PROFILE)"
	@echo "LINUX_FPGA_RAM_SIZE= $(LINUX_FPGA_RAM_SIZE)"
	@echo "LINUX_FPGA_PAYLOAD = $(LINUX_FPGA_PAYLOAD)"
	@echo "LINUX_FPGA_IMAGE   = $(FW_LINUX_FPGA_IMAGE) (exists: $(shell test -f $(FW_LINUX_FPGA_IMAGE) && echo yes || echo no))"

help: ## Show this help message
	@echo "Usage: make <target> [VAR=value ...]"
	@awk -v files="$(MAKEFILE_LIST)" 'BEGIN { \
			nfiles=split(files, filelist, /[ \t]+/); \
			for (file_idx=1; file_idx<=nfiles; file_idx++) { \
				file=filelist[file_idx]; \
				while ((getline line < file) > 0) { \
					if (match(line, /^[A-Z_][A-Z_0-9]*[ \t]*\?=/)) { \
						name = substr(line, 1, RLENGTH); sub(/[ \t]*\?=$$/, "", name); \
						rest = substr(line, RLENGTH+1); \
						sub(/^[ \t]+/, "", rest); sub(/[ \t]*##.*/, "", rest); sub(/[ \t]+$$/, "", rest); \
						if (!(name in defaults)) defaults[name] = rest; \
					} \
				} \
				close(file); \
			} \
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
					if (def ~ /^\$$\(/) def="<auto>"; \
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
	@echo "Workflow guide: $(LITEX_DIR)/README.md"

# ==============================================================================
# PHONY declarations
# ==============================================================================
.PHONY: FORCE help setup setup-skip \
	pack \
	firmware firmware-sim firmware-fpga firmware-clean \
	sim-gen sim-build sim sim-run sim-trace sim-trace-vcd sim-clean \
	coremark coremark-build coremark-clean coremark-fpga \
	main-fpga-build main-fpga irqtest-fpga main-fpga-clean \
	embench embench-build embench-build-one embench-run embench-report embench-clean \
	$(EMBENCH_TARGETS) $(EMBENCH_BUILDS) \
	app-llm-build app-llm-run app-llm-fpga app-fpga-upload \
	$(APP_LLM_TARGETS) $(APP_LLM_BUILDS) $(APP_LLM_FPGAS) \
	microbench microbench-build \
	tests tests-clean tests-run $(TEST_TARGETS) \
	opensbi opensbi-build opensbi-clean fpga-opensbi-jump-build \
	payload \
	linux linux-build \
	bios \
	linux-fpga-build linux-fpga-load linux-fpga-upload linux-fpga-run linux-fpga-e2e \
	opensbi-fpga-upload opensbi-fpga-run opensbi-fpga-e2e \
	fpga-gen fpga-build fpga-build-force fpga-load fpga-flash fpga fpga-console fpga-upload fpga-clean fpga-detect fpga-reports-index fpga-timing-ok \
	fpga-img fpga-smoke-img fpga-opensbi-img \
	fpga-smoke fpga-smoke-upload fpga-opensbi-upload \
	fpga-egos-prepare fpga-egos-bundle fpga-egos-upload fpga-xv6-prepare fpga-xv6-upload \
	fpga-raptos-build fpga-raptos-upload fpga-raptos-run \
	fpga-tinyos-prepare fpga-tinyos-check fpga-tinyos-upload \
	tang-mega-138k-pro \
	mlk-cu07-ku15p mlk-cu07-ku15p-build \
	lint info clean clean-all

FORCE:
