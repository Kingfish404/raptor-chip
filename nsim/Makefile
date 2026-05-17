ifneq ($(words $(CURDIR)),1)
 $(error Unsupported: GNU Make cannot build in directories containing spaces, build elsewhere: '$(CURDIR)')
endif

# Keep RAPTOR_HOME as the canonical repo root.
RAPTOR_HOME ?= $(abspath $(CURDIR)/..)

ifeq ($(wildcard $(RAPTOR_HOME)/nsim/Makefile),)
	$(error RAPTOR_HOME=$(RAPTOR_HOME) is not a raptor-chip repo)
endif

ifeq ($(VERILATOR_ROOT),)
VERILATOR = verilator
else
export VERILATOR_ROOT
VERILATOR = $(VERILATOR_ROOT)/bin/verilator
endif

-include ./include/config/auto.conf
-include ./include/config/auto.conf.cmd

NSIM_HOME = $(abspath .)
VSRC_PATH ?= $(abspath ../rtl_sv)

# Configuration preset selection. Each preset lives in
# `$(RAPTOR_HOME)/configs/<name>/rapt_config.svh` and is picked up first via
# include path so it takes precedence over any older copy. Override at the
# command line: `make pack RAPT_CONFIG=small`.
RAPT_CONFIG ?= default
# Defensive strip: top-level Makefiles use `?= default ## help text` style;
# GNU make's `#` comment can leave trailing whitespace in the value, which
# corrupts BUILD_DIR (e.g. `./build/default ` with a trailing space).
RAPT_CONFIG := $(strip $(RAPT_CONFIG))
CONFIG_DIR  := $(abspath $(RAPTOR_HOME)/configs/$(RAPT_CONFIG))
ifeq ($(wildcard $(CONFIG_DIR)/rapt_config.svh),)
$(error RAPT_CONFIG='$(RAPT_CONFIG)' but $(CONFIG_DIR)/rapt_config.svh does not exist. \
Available: $(notdir $(wildcard $(RAPTOR_HOME)/configs/*)))
endif

# Config dir MUST come before rtl_sv/include so its rapt_config.svh wins.
INC_PATH ?= $(CONFIG_DIR) $(abspath ./include) $(abspath $(VSRC_PATH)/include)

remove_quote = $(patsubst "%",%,$(1))
NPROC ?= $(shell nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)

ifeq ($(CONFIG_MODE), "soc")
SOC_HOME  = $(abspath $(RAPTOR_HOME)/third_party/kingfish404/ysyxSoC)
INC_PATH += $(abspath $(SOC_HOME)/perip/uart16550/rtl) $(abspath $(SOC_HOME)/perip/spi/rtl)
VTARGET=ysyxSoCFull
SOC_DEFINE=-DRAPT_SOC
SOC_SOURCE=$(shell find $(abspath $(SOC_HOME)/perip) -name "*.v") \
    $(SOC_HOME)/build/ysyxSoCFull.v
INC_PATH +=	$(abspath $(VSRC_PATH)/include/ysyxsoc)
else
ifeq ($(CONFIG_wrapBus), y)
VTARGET=wrapSoC
else
VTARGET=raptSoC
endif
SOC_SOURCE=
INC_PATH +=	$(abspath $(VSRC_PATH)/include/npc)
endif
# Scope all build artifacts under $(BUILD_ROOT)/$(RAPT_CONFIG) so that
# different presets (default/small/...) and parallel runs don't stomp on
# each other's outputs (objects, binary, packed RTL, stamps).
BUILD_ROOT = ./build
BUILD_DIR = $(BUILD_ROOT)/$(RAPT_CONFIG)
DATA_DIR = ./data
OBJ_DIR = $(BUILD_DIR)/obj_dir
ISA_NAME = $(if $(findstring DRAPT_RV64,$(VFLAGS)),riscv64,riscv32)
NPC_MODE = $(if $(findstring soc,$(call remove_quote,$(CONFIG_MODE))),soc,sim)
BIN = $(BUILD_DIR)/$(ISA_NAME)-npc-$(NPC_MODE)
VERILATOR_FLAG =--prof-c --prof-cfuncs \
	--public \
	--autoflush --timescale "1ns/1ns" --no-timing \
	-Wno-WIDTHEXPAND -Wno-WIDTHTRUNC # -Wall -Wno-DECLFILENAME -Wno-UNUSED
VERILATOR_EXTRA ?= ## Extra Verilator CLI flags (e.g. --coverage-line --coverage-toggle)
CXXFLAGS = -Wall -Werror \
	-Wno-bool-operation -Wno-implicit-fallthrough -Wno-macro-redefined \
	-Wno-parentheses-equality -Wno-unused-variable \
	$(call remove_quote,$(CONFIG_CC_OPT))
LDFLAGS = -lreadline -ldl

# RV64 support: pass VFLAGS="-DRAPT_RV64" to enable 64-bit mode.
# Simulation assertions are enabled by default for Verilator builds only;
# pack/STA/synthesis still use raw VFLAGS and therefore do not pick up the
# default assertion define.
VFLAGS ?= ## Extra RTL defines for NPC (-DRAPT_RV64, etc.)
# Propagate SOC_DEFINE (e.g. -DRAPT_SOC for ysyxSoC builds) to RTL VFLAGS so
# bus-level `ifdef` workarounds can be conditionally enabled.
ifneq ($(SOC_DEFINE),)
VFLAGS += $(SOC_DEFINE)
endif
RAPT_SIM_ASSERT ?= 1## Enable RTL SVA assertions by default in Verilator simulation (1=on, 0=off)
RAPT_SIM_ASSERT := $(strip $(RAPT_SIM_ASSERT))
SIM_ASSERT_VFLAGS :=
ifneq ($(RAPT_SIM_ASSERT),0)
ifeq (,$(findstring DRAPT_ASSERT_EN,$(VFLAGS)))
SIM_ASSERT_VFLAGS := -DRAPT_ASSERT_EN
endif
endif
SIM_VFLAGS := $(strip $(VFLAGS) $(SIM_ASSERT_VFLAGS))
ifneq (,$(findstring DRAPT_RV64,$(VFLAGS)))
CXXFLAGS += -DCONFIG_ISA64
ISA64 = 1
else
ISA64 = 0
endif

FILELIST_MK = $(shell find -L ./csrc -name "filelist.mk")
include $(FILELIST_MK)

$(shell mkdir -p $(BUILD_DIR))
$(shell mkdir -p $(DATA_DIR))

# Auto-invalidate simulator build when effective simulation RTL flags change
# (e.g., switching RV32/RV64 or enabling/disabling default assertions). Only do
# this for Verilator simulator goals; pack/STA use raw VFLAGS and must not mark
# the simulator binary as having been rebuilt with SIM_VFLAGS.
SIM_STAMP_GOALS := all run run_log sim print-npc-exec lint
SIM_STAMP_ACTIVE := $(if $(MAKECMDGOALS),$(filter $(SIM_STAMP_GOALS),$(MAKECMDGOALS)),all)
SIM_STAMP_QUIET := $(filter print-npc-exec,$(MAKECMDGOALS))
VFLAGS_STAMP := $(BUILD_DIR)/.vflags_stamp
ifneq ($(SIM_STAMP_ACTIVE),)
VFLAGS_PREV  := $(shell cat $(VFLAGS_STAMP) 2>/dev/null)
ifneq ($(SIM_VFLAGS),$(VFLAGS_PREV))
$(shell rm -rf $(OBJ_DIR) $(BUILD_DIR)/riscv*-npc-* $(VFLAGS_STAMP))
ifeq ($(SIM_STAMP_QUIET),)
$(info [nsim] SIM_VFLAGS changed: '$(VFLAGS_PREV)' -> '$(SIM_VFLAGS)', rebuilding...)
endif
endif
$(shell printf '%s' '$(SIM_VFLAGS)' > $(VFLAGS_STAMP))
endif

# RAPT_CONFIG no longer needs its own invalidation stamp: BUILD_DIR is now
# rooted at $(BUILD_ROOT)/$(RAPT_CONFIG), so each preset has its own artifact
# tree and switching presets just selects a different directory.

# Auto-invalidate build when Kconfig changes (e.g., switching between o2/o2linux)
CONFIG_STAMP := $(BUILD_DIR)/.config_stamp
CONFIG_SIG   := $(shell md5sum .config 2>/dev/null || md5 -q .config 2>/dev/null || echo none)
CONFIG_PREV  := $(shell cat $(CONFIG_STAMP) 2>/dev/null)
ifneq ($(CONFIG_SIG),$(CONFIG_PREV))
$(shell rm -rf $(OBJ_DIR) $(BUILD_DIR)/riscv*-npc-* $(CONFIG_STAMP))
ifeq ($(SIM_STAMP_QUIET),)
$(info [nsim] Config changed, rebuilding...)
endif
endif
$(shell printf '%s' '$(CONFIG_SIG)' > $(CONFIG_STAMP))

# nsim-owned RTL: TB-only top-level wrappers (raptSoC / wrap_rnp_soc /
# rapt_npc_soc) live under $(NSIM_HOME)/rtl/ so the simulation/test harness
# can wire them without touching rtl_sv. They are still treated as RTL for
# packing and verilation.
NSIM_RTL_PATH := $(abspath ./rtl)
VSRCS_RAW = $(shell find $(VSRC_PATH) $(NSIM_RTL_PATH) -name "*.sv")
# Ensure rapt_pkg.sv comes first (DC requires package before import)
VSRCS_PKG = $(filter %/rapt_pkg.sv, $(VSRCS_RAW))
VSRCS = $(VSRCS_PKG) $(filter-out %/rapt_pkg.sv, $(VSRCS_RAW)) \
	$(SOC_SOURCE)
VHSRCS = $(shell find $(VSRC_PATH) $(NSIM_RTL_PATH) -name "*.svh")
CSRCS = $(shell find $(abspath ./csrc) -name "*.c")
CCSRCS = $(shell find $(abspath ./csrc) -name "*.cc" -or -name "*.cpp")
CHSRCS = $(shell find $(abspath ./csrc) -name "*.h" -or -name "*.hpp")

ifeq ($(MROM_IMG),)
MROM_IMG ?= $(NSIM_HOME)/csrc/mem/mrom-data/build/mrom-data.bin
endif

# Always descend so mrom-data's Makefile can rebuild when ISA64 changes
.PHONY: $(NSIM_HOME)/csrc/mem/mrom-data/build/mrom-data.bin
$(NSIM_HOME)/csrc/mem/mrom-data/build/mrom-data.bin:
	$(MAKE) -C $(NSIM_HOME)/csrc/mem/mrom-data ISA64=$(ISA64)

all: $(BIN) ## Build NPC simulator

ifeq ($(CONFIG_NVBoard),y) # rules for NVBoard
include $(NVBOARD_HOME)/scripts/nvboard.mk
endif

INCFLAGS = $(addprefix -I, $(INC_PATH))
CXXFLAGS += -g $(INCFLAGS) -DTOP_NAME="\"V$(VTARGET)\"" $(SOC_DEFINE) \
	-DMROM_PATH=$(MROM_IMG)

ifneq (,$(filter sta% pack%,$(MAKECMDGOALS)))
INC_PATH += $(abspath $(VSRC_PATH)/include/dpic_mock)
else
INC_PATH += $(abspath $(VSRC_PATH)/include/dpic)
endif

$(BIN): $(VSRCS) $(VHSRCS) $(CCSRCS) $(CHSRCS) $(NVBOARD_ARCHIVE)
	$(VERILATOR) --trace-fst -cc --exe --build -j $(NPROC) $(VERILATOR_FLAG) $(VERILATOR_EXTRA) $^ \
		--threads 1 \
		--top-module $(VTARGET) \
		$(addprefix -CFLAGS , $(CXXFLAGS)) $(addprefix -LDFLAGS , $(LDFLAGS)) \
		$(addprefix -I, $(INC_PATH)) \
		$(SIM_VFLAGS) \
		--Mdir $(OBJ_DIR) --exe -o $(abspath $(BIN))

ifeq ($(ISA64),1)
DIFF_REF_SO ?= -d $(abspath $(NEMU_HOME)/build/riscv64-nemu-interpreter-so)
else
DIFF_REF_SO ?= -d $(abspath $(NEMU_HOME)/build/riscv32-nemu-interpreter-so)
endif
IMG ?= ## Custom image to load
DISK ?= ## Virtio block disk image to load with --disk
SDCARD ?= ## LiteX SPI SD-card image to load with --sdcard
NPC_EXEC := $(BIN) $(ARGS) $(if $(DISK),--disk $(DISK),) $(if $(SDCARD),--sdcard $(SDCARD),) $(DIFF_REF_SO) -r $(MROM_IMG) $(IMG)

verilog: ## Generate SystemVerilog from Chisel
	make -C ssrc verilog

run: $(BIN) $(MROM_IMG) ## Run NPC simulation
	$(NPC_EXEC)


print-npc-exec: ## Print NPC run command (without ARGS/IMG/DISK, for parallel callers)
	@$(MAKE) --no-print-directory $(BIN) $(MROM_IMG) >/dev/null
	@echo $(abspath $(BIN)) $(DIFF_REF_SO) -r $(abspath $(MROM_IMG))

run_log: $(BIN) $(MROM_IMG) ## Run NPC and log output
	$(NPC_EXEC) 2>&1 | tee $(DATA_DIR)/npc.log

sim: $(BIN) ## Run NPC binary directly
	@$^

jtag-selftest: ## Build and run JTAG TAP/DTM/DM self-test (no NEMU needed)
	$(MAKE) all
	$(BIN) --jtag-selftest

# JTAG OpenOCD bridge: spins the live RTL TAP and serves OpenOCD over its
# `remote_bitbang` TCP protocol on 127.0.0.1:9824. Pair with
# `openocd -f verify/jtag/openocd.cfg` in another shell.
JTAG_PORT ?= 9824
jtag-server: ## Build & launch nsim as an OpenOCD remote_bitbang server
	$(MAKE) all
	$(BIN) --jtag-server --jtag-port=$(JTAG_PORT)

AM_KERNEL = $(RAPTOR_HOME)/abstract-machine/app/am-kernels

AM_KERNEL:
	mkdir -p $(abspath $(AM_KERNEL))
	git clone https://github.com/kingfish404/am-kernels $(AM_KERNEL)

perf: ## Run microbenchmark for performance testing
	if [ ! -d $(AM_KERNEL) ]; then make AM_KERNEL; fi
	make -s -C $(AM_KERNEL)/benchmarks/microbench/ ARCH=riscv32-ysyxsoc ARGS='-b -n' mainargs=test run

YOSYS_OPENSTA = $(RAPTOR_HOME)/third_party/yosys-opensta

YOSYS_OPENSTA:
	git clone https://github.com/Kingfish404/yosys-opensta $(YOSYS_OPENSTA)
	make -C $(YOSYS_OPENSTA) setup-opensta setup-nangate45 setup-sky130hd

pack: $(VSRCS) $(VHSRCS) ## Pack all SV files into one
	mkdir -p $(BUILD_DIR)
	verilator -E -P $(VFLAGS) $(addprefix -I, $(INC_PATH)) $(VSRCS) > $(BUILD_DIR)/rapt_pack.sv
	verilator -E -P --dump-defines $(VFLAGS) $(addprefix -I, $(INC_PATH)) $(VSRCS) > $(BUILD_DIR)/rapt_pack.svh

STA_PLATFORM ?= nangate45 ## STA platform: nangate45, asap7, sky130hd
CLK_FREQ_MHZ ?= 50 ## Target clock frequency for STA (MHz)

sta: pack ## Static timing analysis
	echo $(MAKECMDGOALS)
	if [ ! -d $(YOSYS_OPENSTA) ]; then make YOSYS_OPENSTA; fi
	make -C $(YOSYS_OPENSTA) sta show \
		DESIGN=rapt \
		PLATFORM=$(STA_PLATFORM) \
		CLK_FREQ_MHZ=$(CLK_FREQ_MHZ) \
		RTL_FILES="$(abspath $(BUILD_DIR)/rapt_pack.sv)"

sta-detail: pack ## Detailed static timing analysis
	make -C $(YOSYS_OPENSTA) sta-detail show \
		DESIGN=rapt \
		PLATFORM=$(STA_PLATFORM) \
		CLK_FREQ_MHZ=$(CLK_FREQ_MHZ) \
		RTL_FILES="$(abspath $(BUILD_DIR)/rapt_pack.sv)"

sta_show: pack ## Show timing analysis results
	make -C $(YOSYS_OPENSTA) show \
		DESIGN=rapt \
		PLATFORM=$(STA_PLATFORM) \
		CLK_FREQ_MHZ=$(CLK_FREQ_MHZ) \
		RTL_FILES="$(abspath $(BUILD_DIR)/rapt_pack.sv)"

lint: ## Lint RTL with Verilator
	$(VERILATOR) --lint-only -Wall $(VSRCS) $(INCFLAGS) $(SIM_VFLAGS) --top-module $(VTARGET)

VSRCS_LINT = $(filter-out $(abspath $(VSRC_PATH)/generated/%) $(abspath $(SOC_HOME)/perip/%.v), $(VSRCS))

lint-verible: ## Lint RTL with Verible
	verible-verilog-lint $(VSRCS_LINT)

test:
	echo $(CXXFLAGS)

include ../Makefile

help: ## Show this help message
	@echo "Usage: make <target> [VAR=value ...]"
	@awk '\
		BEGIN { state=0; pending=""; first_target=1 } \
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
			printf "  %-20s %s\n", target, desc }' $(firstword $(MAKEFILE_LIST))
	@echo ""
	@echo "Variables (override with VAR=value):"
	@grep -hE '^[A-Z_]+\s*\?=' $(firstword $(MAKEFILE_LIST)) | \
		awk '{ \
			if (match($$0, /## /)) { \
				name=$$0; sub(/\s*\?=.*/, "", name); \
				desc=substr($$0, RSTART+3); \
				printf "  %-20s %s\n", name, desc } \
			else { \
				split($$0, a, "\\?="); \
				gsub(/^[ \t]+|[ \t]+$$/, "", a[1]); gsub(/^[ \t]+|[ \t]+$$/, "", a[2]); \
				printf "  %-20s %s\n", a[1], a[2] } }'

maintainer-copy::
clean mostlyclean distclean maintainer-clean:: ## Clean build artifacts (all configs)
	-rm -rf obj_dir *.log *.dmp *.vpd core $(BUILD_ROOT)

include ./scripts/config.mk

all: $(BINARY)
.DEFAULT_GOAL = all