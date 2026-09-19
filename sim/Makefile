ifneq ($(words $(CURDIR)),1)
 $(error Unsupported: GNU Make cannot build in directories containing spaces, build elsewhere: '$(CURDIR)')
endif

# Keep RAPTOR_HOME as the canonical repo root.
RAPTOR_HOME ?= $(abspath $(CURDIR)/..)
NEMU_HOME ?= $(abspath $(RAPTOR_HOME)/nemu)
export NEMU_HOME

ifeq ($(wildcard $(RAPTOR_HOME)/sim/Makefile),)
	$(error RAPTOR_HOME=$(RAPTOR_HOME) is not a raptor-chip repo)
endif

ifeq ($(VERILATOR_ROOT),)
VERILATOR = verilator
else
export VERILATOR_ROOT
VERILATOR = $(VERILATOR_ROOT)/bin/verilator
endif

XLEN ?= $(if $(findstring DRAPT_RV64,$(VFLAGS)),64,32)
XLEN := $(strip $(XLEN))
ifeq ($(filter $(XLEN),32 64),)
$(error XLEN must be 32 or 64)
endif
ifeq ($(XLEN),64)
ifeq ($(findstring DRAPT_RV64,$(VFLAGS)),)
override VFLAGS += -DRAPT_RV64
endif
endif

NSIM_HOME = $(abspath .)
VSRC_PATH ?= $(abspath ../hdl)

# Configuration preset selection. Each preset lives in
# `$(RAPTOR_HOME)/hdl/configs/<name>/rapt_config.svh` and is picked up first via
# include path so it takes precedence over any older copy. Override at the
# command line: `make pack RAPT_CONFIG=small`.
RAPT_CONFIG ?= default
# Defensive strip: top-level Makefiles use `?= default ## help text` style;
# GNU make's `#` comment can leave trailing whitespace in the value, which
# corrupts BUILD_DIR (e.g. `./build/default ` with a trailing space).
RAPT_CONFIG := $(strip $(RAPT_CONFIG))
CONFIG_DIR  := $(abspath $(RAPTOR_HOME)/hdl/configs/$(RAPT_CONFIG))
ifeq ($(wildcard $(CONFIG_DIR)/rapt_config.svh),)
$(error RAPT_CONFIG='$(RAPT_CONFIG)' but $(CONFIG_DIR)/rapt_config.svh does not exist. \
Available: $(notdir $(wildcard $(RAPTOR_HOME)/hdl/configs/*)))
endif

# Each profile/XLEN owns its Kconfig state, generated headers and run output.
# No source-tree .config or generated header is read or rewritten.
SIM_PLATFORM ?= sim
SIM_PLATFORM := $(strip $(SIM_PLATFORM))
BUILD_ROOT ?= ./build
BUILD_PROFILE ?= $(RAPT_CONFIG)$(if $(filter ysyxsoc,$(SIM_PLATFORM)),-ysyxsoc,)
BUILD_PROFILE := $(strip $(BUILD_PROFILE))
BUILD_DIR = $(BUILD_ROOT)/$(BUILD_PROFILE)
ISA_NAME = $(if $(findstring DRAPT_RV64,$(VFLAGS)),riscv64,riscv32)
SIM_CONFIG_ROOT ?= $(abspath $(BUILD_DIR)/config-$(ISA_NAME))
SIM_CONFIG_FILE := $(SIM_CONFIG_ROOT)/.config
SIM_AUTOCONFIG := $(SIM_CONFIG_ROOT)/include/config/auto.conf
SIM_AUTOHEADER := $(SIM_CONFIG_ROOT)/include/generated/autoconf.h
DIFFTEST ?= 1
DIFFTEST := $(strip $(DIFFTEST))
ifeq ($(filter $(DIFFTEST),0 1),)
$(error DIFFTEST must be 0 or 1)
endif
NPC_DEFCONFIG ?= $(if $(filter 1,$(DIFFTEST)),o2_difftest_defconfig,o2_defconfig)
DATA_DIR ?= $(abspath $(BUILD_DIR)/run-$(ISA_NAME)/data)
RUN_DIR ?= $(abspath $(BUILD_DIR)/run-$(ISA_NAME))
-include $(SIM_AUTOCONFIG)
-include $(SIM_AUTOCONFIG).cmd

# Config dir MUST come before hdl/include so its rapt_config.svh wins.
INC_PATH ?= $(CONFIG_DIR) $(SIM_CONFIG_ROOT)/include $(abspath ./include) $(abspath $(VSRC_PATH)/include)

remove_quote = $(patsubst "%",%,$(1))
NPROC ?= $(shell nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)
SUBMAKE_JOBS = $(if $(filter --jobserver-auth=% --jobserver-fds=%,$(MAKEFLAGS)),,-j$(NPROC))
# Verilated translation units are memory-heavy. Keep the recursive C++ build
# conservative by default; callers with more RAM can override explicitly.
VERILATOR_JOBS ?= $(shell awk 'BEGIN { n=$(NPROC); print (n < 4 ? n : 4) }')
# Verilator otherwise tends to aggregate generated sources into roughly the
# build-job count.  For this core that produces a few enormous C++ translation
# units which have repeatedly made GCC die with SIGBUS during parallel gates.
# More, smaller groups retain compile parallelism while bounding each cc1plus
# process's working set.
VERILATOR_OUTPUT_GROUPS ?= 16
# Verilator multi-threaded evaluation.  1 (default) keeps the historical
# single-threaded model and artifact names.  Verilator partitions the RTL into
# independent mtasks, so values >1 produce bit-identical results while cutting
# wall-clock time roughly linearly with the cores actually available.  Keep the
# count modest (2-4) on shared machines: a count above the free cores
# oversubscribes the spin-based thread pool and can slow the run down.
VERILATOR_THREADS ?= 1
VERILATOR_THREADS := $(strip $(VERILATOR_THREADS))
VERILATOR_THREADS := $(if $(VERILATOR_THREADS),$(VERILATOR_THREADS),1)

SIM_PLATFORM ?= sim
SIM_PLATFORM := $(strip $(SIM_PLATFORM))
ifeq ($(SIM_PLATFORM),ysyxsoc)
ifneq (,$(findstring DRAPT_RV64,$(VFLAGS)))
$(error ysyxSoC has a 32-bit CPU interface; use SIM_PLATFORM=sim for RV64)
endif
SOC_HOME ?= $(abspath $(RAPTOR_HOME)/third_party/OSCPU/ysyxSoC)
SOC_VSRC ?= $(SOC_HOME)/build/ysyxSoCFull.v
VTARGET = ysyxSoCFull
# Upstream leaves the SPI XIP sequencer as an exercise. FAST_FLASH is its
# provided functional boot path; it does not validate serial flash timing.
YSYXSOC_FAST_FLASH ?= 1
PLATFORM_VFLAGS = -DRAPT_YSYXSOC $(if $(filter 1,$(YSYXSOC_FAST_FLASH)),-DFAST_FLASH,)
PLATFORM_CFLAGS = -DRAPT_SOC
SOC_SOURCE = $(filter-out $(SOC_HOME)/perip/sdram/sdram.v $(SOC_HOME)/perip/psram/psram.v, $(shell find $(SOC_HOME)/perip -name '*.v')) $(SOC_VSRC) $(abspath ./ysyxsoc/sdram.sv) $(abspath ./ysyxsoc/psram.sv)
INC_PATH += $(SOC_HOME)/perip/uart16550/rtl $(SOC_HOME)/perip/spi/rtl
INC_PATH += $(abspath $(VSRC_PATH)/include/ysyxsoc)
else ifeq ($(SIM_PLATFORM),sim)
ifeq ($(CONFIG_wrapBus), y)
VTARGET=wrapSoC
else
VTARGET=raptSoC
endif
INC_PATH += $(abspath $(VSRC_PATH)/include/npc)
else
$(error Unknown SIM_PLATFORM=$(SIM_PLATFORM); expected sim or ysyxsoc)
endif
# Scope all build artifacts under $(BUILD_ROOT)/$(BUILD_PROFILE).  Normally the
# build profile matches the RTL preset, but verification flows that require a
# different simulator configuration (for example, plain RISCOF versus a
# difftest/coverage build) can select a separate artifact directory without
# inventing a non-existent hdl/configs preset.
RAPT_SIM_PROFILE ?= 0## Enable Verilator C profiling instrumentation (1=on, 0=off)
RAPT_SIM_PROFILE := $(strip $(RAPT_SIM_PROFILE))
PROFILE_SUFFIX = $(if $(filter 1,$(RAPT_SIM_PROFILE)),-profile,)
# Give each thread count its own model/binary so a model built with one mtask
# schedule is never reused for another.  Threads=1 keeps the historical names.
THREADS_SUFFIX = $(if $(filter-out 1,$(VERILATOR_THREADS)),-t$(VERILATOR_THREADS),)
OBJ_DIR = $(BUILD_DIR)/obj_dir$(PROFILE_SUFFIX)-$(ISA_NAME)$(THREADS_SUFFIX)-$(SIM_BUILD_KEY)
BIN = $(BUILD_DIR)/$(ISA_NAME)-npc-$(if $(filter ysyxsoc,$(SIM_PLATFORM)),soc,sim)$(PROFILE_SUFFIX)$(THREADS_SUFFIX)
MODEL_BIN = $(OBJ_DIR)/$(notdir $(BIN))
VERILATOR_PROFILE_FLAGS :=
ifeq ($(RAPT_SIM_PROFILE),1)
VERILATOR_PROFILE_FLAGS := --prof-c --prof-cfuncs
endif
VERILATOR_FLAG = $(VERILATOR_PROFILE_FLAGS) --public \
	--autoflush --timescale "1ns/1ns" --no-timing \
	-Wno-WIDTHEXPAND -Wno-WIDTHTRUNC # -Wall -Wno-DECLFILENAME -Wno-UNUSED
VERILATOR_FLAG += -Wno-ASCRANGE -Wno-UNSIGNED
VERILATOR_EXTRA ?= ## Extra Verilator CLI flags (e.g. --coverage-line --coverage-toggle)
VERILATOR_EXTRA_EFFECTIVE := --output-groups $(VERILATOR_OUTPUT_GROUPS) $(strip $(VERILATOR_EXTRA))
ifeq ($(origin CXX),default)
CXX := c++
endif
# Probe the compiler used by Verilator's nested make, including CXX overrides.
SIM_CXX_MACROS := $(shell $(CXX) -dM -E -x c++ /dev/null 2>/dev/null)
SIM_CXX_WARNING_FLAGS := -Wall -Werror -Wno-bool-operation \
	-Wno-implicit-fallthrough -Wno-unused-variable -Wno-unused-but-set-variable
ifneq ($(findstring __clang__,$(SIM_CXX_MACROS)),)
SIM_CXX_WARNING_FLAGS += -Wno-macro-redefined -Wno-parentheses-equality
else ifneq ($(findstring __GNUC__,$(SIM_CXX_MACROS)),)
# GCC diagnoses Verilator 5.052's VL_MULS_WWW scratch array at -O2.
# Keep the diagnostic visible without letting this warning stop the build.
SIM_CXX_WARNING_FLAGS += -Wno-error=maybe-uninitialized
endif
CXXFLAGS = $(SIM_CXX_WARNING_FLAGS) \
	$(call remove_quote,$(CONFIG_CC_OPT))
LDFLAGS = -lreadline -ldl
# Verilator FST includes lz4.h and links -llz4. Homebrew may keep lz4 in its
# own keg, so its headers and libraries are not necessarily on compiler paths.
LZ4_PREFIX ?= $(shell brew --prefix lz4 2>/dev/null)
ifneq ($(wildcard $(LZ4_PREFIX)/include/lz4.h),)
CXXFLAGS += -I$(LZ4_PREFIX)/include
LDFLAGS += -L$(LZ4_PREFIX)/lib
endif
# -ltinfo does not exist on macOS (readline links against system ncurses there).
ifneq ($(shell uname -s),Darwin)
LDFLAGS += -ltinfo
endif

# RV64 support: pass VFLAGS="-DRAPT_RV64" to enable 64-bit mode.
# Simulation assertions are enabled by default for Verilator builds only;
# pack/STA/synthesis still use raw VFLAGS and therefore do not pick up the
# default assertion define.
VFLAGS ?= ## Extra RTL defines for NPC (-DRAPT_RV64, etc.)
LINT_EXTRA ?= ## Extra Verilator lint flags (for example -Wno-fatal in matrix checks)
RAPT_SIM_ASSERT ?= 1## Enable RTL SVA assertions by default in Verilator simulation (1=on, 0=off)
RAPT_SIM_ASSERT := $(strip $(RAPT_SIM_ASSERT))
SIM_ASSERT_VFLAGS :=
ifneq ($(RAPT_SIM_ASSERT),0)
ifeq (,$(findstring DRAPT_ASSERT_EN,$(VFLAGS)))
SIM_ASSERT_VFLAGS := -DRAPT_ASSERT_EN
endif
endif
SIM_VFLAGS := $(strip $(VFLAGS) $(PLATFORM_VFLAGS) $(SIM_ASSERT_VFLAGS))
# Expanding assertion macros is not enough: Verilator also needs --assert to
# execute concurrent properties. Keep both controls in the build signature.
SIM_ASSERT_FLAGS := $(if $(findstring DRAPT_ASSERT_EN,$(SIM_VFLAGS)),--assert,)
# BUILD_PROFILE may intentionally differ from RAPT_CONFIG.  Include the actual
# RTL preset in the signature so reusing a profile with another preset cannot
# silently reuse an incompatible Verilated model.
SIM_BUILD_SIGNATURE := SIM_PLATFORM=$(SIM_PLATFORM) SOC_VSRC=$(SOC_VSRC) RAPT_CONFIG=$(RAPT_CONFIG) SIM_VFLAGS=$(SIM_VFLAGS) SIM_ASSERT_FLAGS=$(SIM_ASSERT_FLAGS) CXX=$(CXX) SIM_CXX_WARNING_FLAGS=$(SIM_CXX_WARNING_FLAGS)
ifneq (,$(findstring DRAPT_RV64,$(VFLAGS)))
CXXFLAGS += -DCONFIG_ISA64
ISA64 = 1
else
ISA64 = 0
endif

FILELIST_MK = $(shell find -L ./csrc -name "filelist.mk")
include $(FILELIST_MK)


# sim-owned RTL: TB-only top-level wrappers (raptSoC / wrap_rnp_soc /
# rapt_npc_soc) live under $(NSIM_HOME)/rtl/ so the simulation/test harness
# can wire them without touching hdl. They are still treated as RTL for
# packing and verilation.
NSIM_RTL_PATH := $(abspath ./rtl)
INC_PATH += $(NSIM_RTL_PATH)
GENERATED_RTL_PATH := $(abspath $(VSRC_PATH)/generated)
GENERATED_DECODERS := $(GENERATED_RTL_PATH)/rapt_idu_decoder.sv \
	$(GENERATED_RTL_PATH)/rapt_idu_decoder_c.sv
CHISEL_DECODER_SRCS := $(shell find $(RAPTOR_HOME)/hdl/chisel/src -type f) \
	$(RAPTOR_HOME)/hdl/chisel/Makefile

# The instruction decoders are generated and ignored by Git. Make them explicit
# prerequisites so a clean checkout can build the simulator without a separate
# manual `make -C hdl/chisel verilog` step.
$(GENERATED_DECODERS) &: $(CHISEL_DECODER_SRCS)
	$(MAKE) -C $(RAPTOR_HOME)/hdl/chisel verilog

VSRCS_RAW = $(shell find $(VSRC_PATH) $(NSIM_RTL_PATH) -path $(GENERATED_RTL_PATH) -prune -o -name "*.sv" -print) \
	$(GENERATED_DECODERS)
# Ensure rapt_pkg.sv comes first (DC requires package before import)
VSRCS_PKG = $(filter %/rapt_pkg.sv, $(VSRCS_RAW))
VSRCS = $(VSRCS_PKG) $(filter-out %/rapt_pkg.sv, $(VSRCS_RAW)) $(SOC_SOURCE)
VHSRCS = $(shell find $(VSRC_PATH) $(NSIM_RTL_PATH) -name "*.svh")
CSRCS = $(shell find $(abspath ./csrc) -name "*.c")
CCSRCS = $(shell find $(abspath ./csrc) -name "*.cc" -or -name "*.cpp")
CHSRCS = $(filter-out $(abspath ./include/generated/autoconf.h),$(shell find $(abspath ./csrc) $(abspath ./include) -name "*.h" -or -name "*.hpp")) $(SIM_AUTOHEADER)

MROM_DT_SOURCE := $(if $(DT_SOURCE),$(DT_SOURCE),$(if $(filter 1,$(ISA64)),spike-rv64ima.dts,spike-rv32ima.dts))
MROM_BUILD_TAG := rv$(if $(filter 1,$(ISA64)),64,32)-$(basename $(notdir $(MROM_DT_SOURCE)))
MROM_BUILD_DIR := $(abspath $(BUILD_DIR)/mrom/$(MROM_BUILD_TAG))
MROM_IMG ?= $(MROM_BUILD_DIR)/mrom-data.bin
MROM_DT_PATH := $(if $(filter /%,$(MROM_DT_SOURCE)),$(MROM_DT_SOURCE),$(RAPTOR_HOME)/linux/dts/$(MROM_DT_SOURCE))
MROM_INPUTS := $(NSIM_HOME)/csrc/mem/mrom-data/Makefile \
	$(NSIM_HOME)/csrc/mem/mrom-data/rom.c $(MROM_DT_PATH)

# Keep this as a real file target so independent test runners do not rebuild the
# same MROM concurrently.  The input list still propagates source/DT changes.
$(MROM_IMG): $(MROM_INPUTS)
	+$(MAKE) -C $(NSIM_HOME)/csrc/mem/mrom-data BUILD_DIR=$(MROM_BUILD_DIR) \
		ISA64=$(ISA64) DT_SOURCE=$(MROM_DT_SOURCE)

ifeq ($(SIM_PLATFORM),ysyxsoc)
$(SOC_VSRC):
	@echo "Missing upstream SoC RTL: $@. Run make -C $(RAPTOR_HOME) ysyxsoc-setup."
	@exit 1
endif

all: $(BIN) ## Build NPC simulator

INCFLAGS = $(addprefix -I, $(INC_PATH))
CXXFLAGS += $(PLATFORM_CFLAGS) -g $(INCFLAGS) -DTOP_NAME="\"V$(VTARGET)\""

ifneq (,$(filter sta% pack%,$(MAKECMDGOALS)))
INC_PATH += $(abspath $(VSRC_PATH)/include/dpic_mock)
else
INC_PATH += $(abspath $(VSRC_PATH)/include/dpic)
endif

# Read-only fingerprinting at parse time; changing options selects another
# object directory instead of deleting an existing build or stale-config stamp.
_sim_quote = '$(subst ','"'"',$(1))'
SIM_BUILD_KEY := $(shell python3 $(NSIM_HOME)/scripts/build_cache.py fingerprint \
    --config $(call _sim_quote,$(SIM_CONFIG_FILE)) \
    -- \
    $(call _sim_quote,$(SIM_BUILD_SIGNATURE)) \
    $(call _sim_quote,$(VERILATOR_FLAG) $(SIM_ASSERT_FLAGS) $(VERILATOR_EXTRA_EFFECTIVE)) \
    $(call _sim_quote,$(CXXFLAGS) $(LDFLAGS)) $(call _sim_quote,$(VERILATOR_THREADS)))

$(MODEL_BIN): $(VSRCS) $(VHSRCS) $(CCSRCS) $(CHSRCS)
	@mkdir -p "$(OBJ_DIR)"
	+$(VERILATOR) --trace-fst -cc --exe --build -j $(VERILATOR_JOBS) $(VERILATOR_FLAG) $(SIM_ASSERT_FLAGS) $(VERILATOR_EXTRA_EFFECTIVE) $(filter-out $(CHSRCS) $(VHSRCS),$^) \
		--threads $(VERILATOR_THREADS) \
		--top-module $(VTARGET) \
		-MAKEFLAGS "CXX=$(CXX)" \
		$(addprefix -CFLAGS , $(CXXFLAGS)) $(addprefix -LDFLAGS , $(LDFLAGS)) \
		$(addprefix -I, $(INC_PATH)) \
		$(SIM_VFLAGS) \
		--Mdir $(OBJ_DIR) --exe -o $(abspath $(MODEL_BIN))

.PHONY: sim-publish-force
sim-publish-force:

$(BIN): $(MODEL_BIN) sim-publish-force
	@python3 "$(NSIM_HOME)/scripts/build_cache.py" publish "$(MODEL_BIN)" "$@"

ifeq ($(ISA64),1)
NEMU_REF_DEFCONFIG := riscv64_ref_defconfig
NEMU_REF_SO := $(abspath $(NEMU_HOME)/build/riscv64-nemu-interpreter-so)
else
NEMU_REF_DEFCONFIG := riscv32_ref_defconfig
NEMU_REF_SO := $(abspath $(NEMU_HOME)/build/riscv32-nemu-interpreter-so)
endif

# Default difftest runs need a matching NEMU reference. Leave an explicit
# DIFF_REF_SO override, including DIFF_REF_SO= to disable difftest, untouched.
ifeq ($(SIM_PLATFORM),ysyxsoc)
DIFF_REF_SO ?=
endif

ifeq ($(DIFFTEST),0)
override DIFF_REF_SO :=
endif

ifeq ($(origin DIFF_REF_SO), undefined)
DIFF_REF_SO := -d $(NEMU_REF_SO)
NEMU_REF_DEP := nemu-reference
endif

.PHONY: nemu-reference
nemu-reference:
	+$(MAKE) -C $(NEMU_HOME) $(NEMU_REF_DEFCONFIG)
	+$(MAKE) -C $(NEMU_HOME) $(SUBMAKE_JOBS)

SIM_RANDOM_DELAY ?= 0
SIM_RANDOM_SEED ?= 1
SIM_RANDOM_ARGS = $(if $(filter-out 0,$(strip $(SIM_RANDOM_DELAY))),--mem-random-delay=$(strip $(SIM_RANDOM_DELAY)) --mem-random-seed=$(strip $(SIM_RANDOM_SEED)),)

IMG ?= ## Custom image to load
DISK ?= ## Virtio block disk image to load with --disk
SDCARD ?= ## LiteX SPI SD-card image to load with --sdcard
NPC_EXEC = $(abspath $(MODEL_BIN)) $(ARGS) $(SIM_RANDOM_ARGS) $(if $(DISK),--disk $(abspath $(DISK)),) $(if $(SDCARD),--sdcard $(abspath $(SDCARD)),) $(DIFF_REF_SO) -r $(abspath $(MROM_IMG)) $(if $(IMG),$(abspath $(IMG)))

verilog: ## Generate SystemVerilog from Chisel
	$(MAKE) -C $(RAPTOR_HOME)/hdl/chisel verilog

run: $(BIN) $(MROM_IMG) $(NEMU_REF_DEP) ## Run NPC simulation
	@mkdir -p "$(RUN_DIR)/data"
	cd "$(RUN_DIR)" && $(NPC_EXEC)


print-npc-exec: $(BIN) $(MROM_IMG) $(NEMU_REF_DEP) ## Print NPC run command (without ARGS/IMG/DISK, for parallel callers)
	@echo $(abspath $(BIN)) $(SIM_RANDOM_ARGS) $(DIFF_REF_SO) -r $(abspath $(MROM_IMG))

run_log: $(BIN) $(MROM_IMG) $(NEMU_REF_DEP) ## Run NPC and log output
	@mkdir -p "$(RUN_DIR)/data" "$(DATA_DIR)"
	cd "$(RUN_DIR)" && $(NPC_EXEC) 2>&1 | tee "$(DATA_DIR)/npc.log"

sim: $(BIN) ## Run NPC binary directly
	@$^

jtag-selftest: ## Build and run JTAG TAP/DTM/DM self-test (no NEMU needed)
	$(MAKE) all
	$(BIN) --jtag-selftest

# JTAG OpenOCD bridge: spins the live RTL TAP and serves OpenOCD over its
# `remote_bitbang` TCP protocol on 127.0.0.1:9824. Pair with
# `openocd -f verify/jtag/openocd.cfg` in another shell.
JTAG_PORT ?= 9824
jtag-server: ## Build & launch sim as an OpenOCD remote_bitbang server
	$(MAKE) all
	$(BIN) --jtag-server --jtag-port=$(JTAG_PORT)

perf: ## Run MicroBench with reproducible random sim memory delays
	$(MAKE) -C $(RAPTOR_HOME) microbench-rv32 SIM_RANDOM_DELAY=31

YOSYS_OPENSTA = $(RAPTOR_HOME)/third_party/yosys-opensta
YOSYS_SLANG = $(YOSYS_OPENSTA)/yosys-slang

YOSYS_OPENSTA:
	git clone https://github.com/Kingfish404/yosys-opensta $(YOSYS_OPENSTA)
	make -C $(YOSYS_OPENSTA) setup-opensta setup-sv-elab setup-nangate45 setup-sky130hd

# Normal STA consumes installed tools. Network updates and installation belong
# to the explicit setup target: do not mutate a working toolchain mid-analysis.
.PHONY: sta-deps sta-setup synth-frontend-check
synth-frontend-check: ## Check the installed Yosys/slang frontend without installing tools
	@command -v yosys >/dev/null || { echo "ERROR: yosys is not installed." >&2; exit 1; }
	@yosys -Q -T -m slang -p 'slang_version' >/dev/null 2>&1 || { \
		echo "ERROR: $$(command -v yosys) cannot load its slang frontend." >&2; \
		yosys -V >&2; \
		echo "After a Yosys upgrade, rebuild/install slang for the new Yosys ABI and plugin directory." >&2; \
		echo "Run: make -C $(NSIM_HOME) sta-setup STA_PLATFORM=$(STA_PLATFORM)" >&2; \
		exit 1; }

sta-deps: synth-frontend-check
	@$(MAKE) -s -C "$(RAPTOR_HOME)/lspd/syn" doctor \
		PDK=$(if $(filter sky130hd,$(STA_PLATFORM)),sky130,$(STA_PLATFORM)) \
		SRAM_MODE=flops OPENSTA="$(YOSYS_OPENSTA)/third_party/OpenSTA/build/sta" \
		FLOW_ROOT="$(YOSYS_OPENSTA)" || { \
		  echo "STA dependencies unavailable; run 'make -C sim sta-setup STA_PLATFORM=$(STA_PLATFORM)' explicitly."; \
		  exit 1; }
	@test -f "$(YOSYS_OPENSTA)/platforms/$(STA_PLATFORM)/config.tcl" || { \
		  echo "missing STA platform config for $(STA_PLATFORM)"; exit 1; }
	@if [ "$(STA_PLATFORM)" = nangate45 ]; then \
		  test -f "$(YOSYS_OPENSTA)/third_party/lib/nangate45/lib/NangateOpenCellLibrary_typical.lib" || { \
		    echo "missing NanGate45 STA Liberty; run 'make -C sim sta-setup'"; exit 1; }; \
		fi

# Explicit provisioning may fetch/update repositories and install tools.
sta-setup: ## Install/update the STA toolchain and fetch selected PDK data (network required)
	@if [ ! -d $(YOSYS_OPENSTA) ]; then \
	  echo ">>> [sta] cloning yosys-opensta ..."; \
	  git clone https://github.com/Kingfish404/yosys-opensta $(YOSYS_OPENSTA); \
	fi
	@if [ ! -x $(YOSYS_OPENSTA)/third_party/OpenSTA/build/sta ]; then \
	  echo ">>> [sta] building OpenSTA (CUDD) ..."; \
	  $(MAKE) -C $(YOSYS_OPENSTA) setup-opensta; \
	fi
	@set -e; \
	if [ ! -d $(YOSYS_SLANG)/.git ]; then \
	  echo ">>> [sta] cloning yosys-slang ..."; \
	  git clone --recursive https://github.com/povik/yosys-slang $(YOSYS_SLANG); \
	fi
	@set -e; \
	if [ -n "$$(git -C $(YOSYS_SLANG) status --porcelain --untracked-files=no)" ]; then \
	  echo ">>> [sta] ERROR: $(YOSYS_SLANG) has local changes; update it manually."; \
	  exit 1; \
	fi; \
	if ! git -C $(YOSYS_SLANG) fetch origin master; then \
	  echo ">>> [sta] WARNING: could not refresh yosys-slang; using cached origin/master."; \
	fi; \
	if [ "$$(git -C $(YOSYS_SLANG) rev-parse HEAD)" != \
	     "$$(git -C $(YOSYS_SLANG) rev-parse origin/master)" ]; then \
	  echo ">>> [sta] updating yosys-slang to latest origin/master ..."; \
	  git -C $(YOSYS_SLANG) merge --ff-only origin/master; \
	  git -C $(YOSYS_SLANG) submodule update --init --recursive; \
	fi; \
	current_rev=$$(git -C $(YOSYS_SLANG) rev-parse HEAD); \
	installed_rev=$$(yosys -m slang -p "slang_version" 2>/dev/null | \
	  awk '/^(yosys-slang|sv-elab) revision/{print $$3}'); \
	if [ "$$installed_rev" != "$$current_rev" ]; then \
	  echo ">>> [sta] building yosys-slang plugin ..."; \
	  cmake -S $(YOSYS_SLANG) -B $(YOSYS_SLANG)/build; \
	  cmake --build $(YOSYS_SLANG)/build --parallel $(NPROC); \
	  cmake --install $(YOSYS_SLANG)/build; \
	fi
	@if [ ! -d $(YOSYS_OPENSTA)/third_party/lib/$(STA_PLATFORM) ]; then \
	  echo ">>> [sta] fetching PDK data for $(STA_PLATFORM) ..."; \
	  $(MAKE) -C $(YOSYS_OPENSTA) setup-$(STA_PLATFORM); \
	fi

# A CPU export contains the adapter, but no upstream SoC or pin-level models.
PACK_VSRCS = $(filter-out $(SOC_SOURCE),$(VSRCS))
pack: $(PACK_VSRCS) $(VHSRCS) ## Pack all SV files into one
	mkdir -p $(BUILD_DIR)
	verilator -E -P -DSYNTHESIS $(VFLAGS) $(PLATFORM_VFLAGS) $(addprefix -I, $(INC_PATH)) $(PACK_VSRCS) > $(BUILD_DIR)/rapt_pack.sv
	verilator -E -P --dump-defines -DSYNTHESIS $(VFLAGS) $(PLATFORM_VFLAGS) $(addprefix -I, $(INC_PATH)) $(PACK_VSRCS) > $(BUILD_DIR)/rapt_pack.svh

STA_PLATFORM ?= nangate45 ## STA platform: nangate45, asap7, sky130hd (alias: sky130)
CLK_FREQ_MHZ ?= 50 ## Target clock frequency for STA (MHz)
# The flow calls SkyWater HD sky130hd; LSPD calls the same PDK sky130.
# Override is required here because ordinary assignments cannot normalize a
# command-line STA_PLATFORM, including values forwarded by the root Makefile.
override STA_PLATFORM := $(patsubst sky130,sky130hd,$(strip $(STA_PLATFORM)))
CLK_FREQ_MHZ := $(strip $(CLK_FREQ_MHZ))

# Keep this gate independent of sta-deps: checking installed tools must not
# fetch tool repositories or install dependencies. No frontend relaxation flags.
.PHONY: pack-synth-check pack-sram-synth-check
pack-synth-check: synth-frontend-check pack ## Check packed RTL with native Slang semantics and default loop limits
	yosys -Q -T -m slang -l $(BUILD_DIR)/pack-synth-check.log -p \
		'read_slang --top rapt $(abspath $(BUILD_DIR)/rapt_pack.sv); hierarchy -check -top rapt; select -assert-none t:$$check t:$$assert t:$$assume t:$$cover'

MEMORY ?= sram
MEMORY := $(strip $(MEMORY))
ifeq ($(filter $(MEMORY),sram dff),)
$(error MEMORY must be sram or dff)
endif
STA_WORK_DIR ?= $(abspath $(BUILD_DIR))/sta/$(MEMORY)/$(RAPT_CONFIG)/$(ISA_NAME)/$(STA_PLATFORM)/$(CLK_FREQ_MHZ)MHz
STA_PACK_NAME = $(if $(filter sram,$(MEMORY)),rapt_pack_sram.sv,rapt_pack.sv)
.PHONY: sta sta-detail sta-check
sta-check: ## Elaborate the selected memory implementation (MEMORY=sram|dff)
	$(MAKE) $(if $(filter sram,$(MEMORY)),pack-sram-synth-check,pack-synth-check) BUILD_DIR="$(STA_WORK_DIR)/rtl" VFLAGS="$(VFLAGS) $(if $(filter dff,$(MEMORY)),-URAPT_USE_SRAM_MACRO,)"

sta sta-detail: sta-check sta-deps $(if $(filter sram,$(MEMORY)),sram-ensure-libs,) ## Isolated STA (MEMORY=sram|dff XLEN=32|64)
	python3 "$(NSIM_HOME)/scripts/sta.py" --backend "$(YOSYS_OPENSTA)" \
		--work-dir "$(STA_WORK_DIR)/backend" --rtl "$(STA_WORK_DIR)/rtl/$(STA_PACK_NAME)" \
		--platform "$(STA_PLATFORM)" --frequency "$(CLK_FREQ_MHZ)" --memory "$(MEMORY)" \
		$(if $(filter sram,$(MEMORY)),$(foreach lib,$(RAPT_SRAM_LIBS),--lib "$(lib)"),) \
		$(if $(filter sta-detail,$@),--detail,)

# =====================================================================
#  STA with OpenRAM SRAM macros (rapt_sram_1rw -> OpenRAM 1RW blackbox)
#  Workflow: see sim/sram/README.md
# =====================================================================
RAPT_SRAM_DIR    := $(abspath $(NSIM_HOME)/sram)
SRAM_PLATFORM    ?= $(STA_PLATFORM) ## SRAM timing model platform; defaults to the standard-cell platform
RAPT_SRAM_LIBS    = $(shell $(MAKE) --no-print-directory -s -C $(RAPT_SRAM_DIR) print-libs PLATFORM=$(SRAM_PLATFORM))
RAPT_SRAM_BB_V    = $(shell $(MAKE) --no-print-directory -s -C $(RAPT_SRAM_DIR) print-blackbox)

sram-macros: ## Compile OpenRAM SRAM macros (see sim/sram/README.md)
	$(MAKE) -C $(RAPT_SRAM_DIR) all PLATFORM=$(SRAM_PLATFORM)

sram-stubs: ## Generate behavioural .lib/.v stubs (no OpenRAM/PDK needed)
	$(MAKE) -C $(RAPT_SRAM_DIR) stubs PLATFORM=$(SRAM_PLATFORM)

sram-ensure-libs: ## Generate conservative SRAM timing stubs when selected libraries are absent
	@missing=0; \
	for lib in $(RAPT_SRAM_LIBS); do \
	  if [ ! -f "$$lib" ]; then missing=1; break; fi; \
	done; \
	if [ $$missing -eq 1 ]; then \
	  echo ">>> SRAM libraries missing for $(SRAM_PLATFORM); generating conservative placeholder timing"; \
	  $(MAKE) -C $(RAPT_SRAM_DIR) stubs PLATFORM=$(SRAM_PLATFORM); \
	fi

sram-doctor: ## Diagnose OpenRAM / PDK / docker prerequisites
	$(MAKE) -C $(RAPT_SRAM_DIR) doctor PLATFORM=$(SRAM_PLATFORM)

sram-test: ## Validate SRAM macro integration consistency (no external deps)
	$(MAKE) -C $(RAPT_SRAM_DIR) test

sram-test-sta: ## Opt-in SRAM STA smoke (needs yosys+slang+OpenSTA)
	$(MAKE) -C $(RAPT_SRAM_DIR) test-sta

# Pack RTL with RAPT_USE_SRAM_MACRO so rapt_sram_1rw instantiates the
# OpenRAM 1RW blackbox declared in sim/sram/wrappers/rapt_sram_blackbox.v.
pack-sram: $(PACK_VSRCS) $(VHSRCS)
	mkdir -p $(BUILD_DIR)
	verilator -E -P -DSYNTHESIS $(VFLAGS) $(PLATFORM_VFLAGS) -DRAPT_USE_SRAM_MACRO $(addprefix -I, $(INC_PATH)) $(PACK_VSRCS) > $(BUILD_DIR)/rapt_pack_sram.sv

pack-sram-synth-check: synth-frontend-check pack-sram ## Check packed RTL against SRAM blackbox port contracts
	yosys -Q -T -m slang -l $(BUILD_DIR)/pack-sram-synth-check.log -p \
		'read_slang --top rapt $(abspath $(BUILD_DIR)/rapt_pack_sram.sv) $(RAPT_SRAM_BB_V); hierarchy -check -top rapt; select -assert-none t:$$check t:$$assert t:$$assume t:$$cover'

lint: ## Lint RTL with Verilator
	$(VERILATOR) --lint-only -Wall $(LINT_EXTRA) $(SIM_ASSERT_FLAGS) $(VSRCS) $(INCFLAGS) $(SIM_VFLAGS) --top-module $(VTARGET)

VSRCS_LINT = $(filter-out $(abspath $(VSRC_PATH)/generated/%), $(VSRCS))

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
clean mostlyclean distclean maintainer-clean:: ## Explicitly clean only the selected build profile
	@case "$(abspath $(BUILD_DIR))" in "$(abspath $(BUILD_ROOT))"/*) ;; *) echo "Refusing to clean outside BUILD_ROOT" >&2; exit 1;; esac
	@test "$(abspath $(BUILD_DIR))" != / && test "$(abspath $(BUILD_DIR))" != "$(NSIM_HOME)" && test "$(abspath $(BUILD_DIR))" != "$(RAPTOR_HOME)" && test "$(abspath $(BUILD_DIR))" != "$(HOME)"
	rm -rf -- "$(abspath $(BUILD_DIR))"

include ./scripts/config.mk

all: $(BINARY)
.DEFAULT_GOAL = all

.PHONY: print-jtag-bin
print-jtag-bin: ## Print selected simulator path for JTAG runners
	@printf "%s\n" "$(abspath $(BIN))"
