# sim/sram/Makefile — drive OpenRAM to compile cache SRAM macros for the
# raptor-chip STA flow. Outputs land in build/<PLATFORM>/macro/<name>/ and
# are picked up by `make -C sim sta-sram` (see ../Makefile).

ifneq ($(words $(CURDIR)),1)
  $(error Unsupported: GNU Make cannot build in directories containing spaces, build elsewhere: '$(CURDIR)')
endif

RAPTOR_HOME ?= $(abspath $(CURDIR)/../..)
SRAM_DIR    := $(abspath $(CURDIR))
OPENRAM_DIR ?= $(RAPTOR_HOME)/third_party/OpenRAM
CONFIG_DIR  := $(SRAM_DIR)/configs

# ---------------------------------------------------------------------------
# Platform selection. `sky130` matches the sky130hd STA platform under
# third_party/yosys-opensta/platforms/sky130hd/.
# ---------------------------------------------------------------------------
PLATFORM    ?= sky130
BUILD_DIR   := $(SRAM_DIR)/build/$(PLATFORM)
MACRO_DIR   := $(BUILD_DIR)/macro

# SRAM configurations to compile for this platform. The naming convention is
# `<basename>_1rw_<PLATFORM>.py`; each must produce a macro under
# $(MACRO_DIR)/$(MACRO_NAME)/$(MACRO_NAME).{v,lib,lef,gds,sp}.
# All macros are single-port (1RW) — the port shape the RTL instantiates.
PORTS := 1rw
CONFIGS := \
  rapt_sram_32x32_1rw \
  rapt_sram_16x32_1rw \
  rapt_sram_16x64_1rw

CONFIG_FILES := $(foreach c,$(CONFIGS),$(CONFIG_DIR)/$(c)_$(PLATFORM).py)
# rapt_sram_32x32_1rw -> rapt_openram_1rw_32x32
MACRO_NAMES  := $(foreach c,$(CONFIGS),rapt_openram_1rw_$(subst rapt_sram_,,$(subst _1rw,,$(c))))
STAMPS       := $(foreach m,$(MACRO_NAMES),$(BUILD_DIR)/$(m).ok)

# ---------------------------------------------------------------------------
# OpenRAM compiler entry point. Default to the in-tree clone; allow override.
# ---------------------------------------------------------------------------
SRAM_COMPILER ?= $(OPENRAM_DIR)/sram_compiler.py
PYTHON        ?= python3

# OpenRAM expects PDK_ROOT to be the *parent* of the per-PDK directory, so
# that $(PDK_ROOT)/sky130A is a valid install. Volare's default layout is
# $HOME/.volare/sky130A, so PDK_ROOT=$HOME/.volare is correct.
PDK_ROOT      ?= $(HOME)/.volare

# Docker fallback for users without a local PDK/Klayout/Ngspice install.
# Set USE_DOCKER=1 to route compilation through the vlsida/openram-ubuntu
# image (this mirrors third_party/OpenRAM/openram.mk).
USE_DOCKER    ?= 0

UID := $(shell id -u)
GID := $(shell id -g)
OPENRAM_IMAGE ?= vlsida/openram-ubuntu:latest

ifeq ($(USE_DOCKER),1)
# Non-interactive docker run. Mounts OpenRAM + PDK + this directory; invokes
# sram_compiler.py directly. The vlsida/openram-ubuntu image bundles the
# python deps but NOT the PDK — user must still supply $(PDK_ROOT) pointing
# at a sky130A install.
RUN_OPENRAM = docker run --rm               	\
    -v $(OPENRAM_DIR):/openram              	\
    -v $(SRAM_DIR):/sram                    	\
    -v $(PDK_ROOT):/pdk                     	\
    -e PDK_ROOT=/pdk -e PDKPATH=/pdk/sky130A	\
    -e OPENRAM_HOME=/openram/compiler       	\
    -e OPENRAM_TECH=/openram/technology     	\
    -e PYTHONPATH=/openram/compiler         	\
    --user $(UID):$(GID)                    	\
    $(OPENRAM_IMAGE)                        	\
    python3 -u /openram/sram_compiler.py    	\
      -o /sram/build/$(PLATFORM)/macro      	\
      -v /sram/configs/$(notdir $<)
else
RUN_OPENRAM = OPENRAM_HOME=$(OPENRAM_DIR)/compiler  	\
              OPENRAM_TECH=$(OPENRAM_DIR)/technology	\
              PDK_ROOT=$(PDK_ROOT)                  	\
              PYTHONPATH=$(OPENRAM_DIR)/compiler    	\
              $(PYTHON) $(SRAM_COMPILER)            	\
              -o $(MACRO_DIR) -v $<
endif

# ---------------------------------------------------------------------------
# Top-level targets
# ---------------------------------------------------------------------------
.PHONY: all setup clean print configs stubs doctor test test-sta

all: $(STAMPS) ## Compile all SRAM macros for $(PLATFORM) via OpenRAM

# ---------------------------------------------------------------------------
# `stubs` — hand-written behavioural Liberty + Verilog placeholders so the
# STA flow can close the loop *without* a working OpenRAM/PDK install. The
# numbers are conservative single-cycle estimates, NOT silicon-grade. Swap
# in real OpenRAM output (`make all`) before quoting final timing.
# ---------------------------------------------------------------------------
STUB_SCRIPT := $(SRAM_DIR)/scripts/gen_stub_lib.py

# (name, depth, width, write_size) -- all single-port (1RW).
STUB_SHAPES := \
  rapt_openram_1rw_32x32,32,32,8 \
  rapt_openram_1rw_16x32,16,32,8 \
  rapt_openram_1rw_16x64,16,64,8

stubs: ## Generate behavioural Liberty/Verilog stubs (no OpenRAM/PDK needed)
	@mkdir -p $(MACRO_DIR)
	@for s in $(STUB_SHAPES); do                                  	\
	  name=$$(echo $$s | cut -d, -f1);                            	\
	  d=$$(echo $$s | cut -d, -f2);                               	\
	  w=$$(echo $$s | cut -d, -f3);                               	\
	  m=$$(echo $$s | cut -d, -f4);                               	\
	  echo ">>> stub: $$name ($$d x $$w, write_size=$$m)";        	\
	  out=$(MACRO_DIR)/$$name;                                    	\
	  $(PYTHON) $(STUB_SCRIPT) $$name $$d $$w $$m $$out || exit 1;\
	  touch $(BUILD_DIR)/$$name.ok;                               	\
	done
	@echo ">>> stubs ready under $(MACRO_DIR) (placeholder timing!)"

doctor: ## Diagnose OpenRAM / PDK / docker prerequisites
	@echo ">>> OpenRAM compiler:"; \
	  if [ -f $(SRAM_COMPILER) ]; then echo "    OK: $(SRAM_COMPILER)"; \
	  else echo "    MISSING: $(SRAM_COMPILER) (git clone https://github.com/VLSIDA/OpenRAM)"; fi
	@echo ">>> PDK_ROOT:"; \
	  if [ -d $(PDK_ROOT)/sky130A ]; then echo "    OK: $(PDK_ROOT)/sky130A"; \
	  else echo "    MISSING: $(PDK_ROOT)/sky130A (install via volare or pdk fetch)"; fi
	@echo ">>> docker (for USE_DOCKER=1):"; \
	  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then \
	    echo "    OK: docker daemon reachable"; \
	  else echo "    UNAVAILABLE (start colima / Docker Desktop)"; fi
	@echo ">>> python3 native deps (klayout/ngspice for non-docker path):"; \
	  command -v klayout >/dev/null && echo "    klayout: OK" || echo "    klayout: MISSING"; \
	  command -v ngspice >/dev/null && echo "    ngspice: OK" || echo "    ngspice: MISSING"

configs: ## List configured SRAM shapes
	@echo "PLATFORM     = $(PLATFORM)"
	@echo "BUILD_DIR    = $(BUILD_DIR)"
	@echo "CONFIGS:"
	@for c in $(CONFIGS); do echo "  - $$c"; done
	@echo "MACROS:"
	@for m in $(MACRO_NAMES); do echo "  - $$m"; done

setup: ## Show OpenRAM dependency setup hints
	@echo ">>> OpenRAM requires:"
	@echo "    - python3 + numpy + scipy"
	@echo "    - klayout (LVS/DRC)"
	@echo "    - ngspice (timing characterisation)"
	@echo "    - sky130A PDK at PDK_ROOT (current: $(PDK_ROOT))"
	@echo ">>> Quickest path: USE_DOCKER=1 (uses vlsida/openram-ubuntu)"
	@if [ ! -f $(SRAM_COMPILER) ]; then \
	  echo ">>> sram_compiler.py not found at $(SRAM_COMPILER)"; \
	  echo ">>>   git clone https://github.com/VLSIDA/OpenRAM $(OPENRAM_DIR)"; \
	fi

# Per-config rule. `$*` is the macro name (rapt_openram_1rw_<WxD>);
# the matching config file is rapt_sram_<WxD>_1rw_<PLATFORM>.py.
$(BUILD_DIR)/%.ok:
	@if [ ! -f $(SRAM_COMPILER) ]; then \
	  echo "ERROR: OpenRAM compiler missing at $(SRAM_COMPILER)"; \
	  echo "       Run: make -C $(SRAM_DIR) setup"; exit 1; \
	fi
	mkdir -p $(MACRO_DIR)
	$(eval CFG := $(CONFIG_DIR)/rapt_sram_$(subst rapt_openram_1rw_,,$*)_1rw_$(PLATFORM).py)
	@echo ">>> OpenRAM: compiling $* from $(CFG)"
	$(eval $< := $(CFG))
	$(RUN_OPENRAM)
	touch $@

print: ## Print resolved variables (debugging)
	@echo "RAPTOR_HOME   = $(RAPTOR_HOME)"
	@echo "OPENRAM_DIR   = $(OPENRAM_DIR)"
	@echo "SRAM_COMPILER = $(SRAM_COMPILER)"
	@echo "PDK_ROOT      = $(PDK_ROOT)"
	@echo "PLATFORM      = $(PLATFORM)"
	@echo "BUILD_DIR     = $(BUILD_DIR)"
	@echo "MACRO_DIR     = $(MACRO_DIR)"
	@echo "CONFIG_FILES  = $(CONFIG_FILES)"
	@echo "MACRO_NAMES   = $(MACRO_NAMES)"

clean: ## Remove generated macros for $(PLATFORM)
	rm -rf $(BUILD_DIR)
	@$(MAKE) -C $(SRAM_DIR)/test clean

# ---------------------------------------------------------------------------
# Test hooks (delegate to sram/test).
# ---------------------------------------------------------------------------
test: ## Run SRAM integration consistency tests (no external deps)
	@$(MAKE) -C $(SRAM_DIR)/test check

test-sta: ## Opt-in: yosys+OpenSTA smoke against the stub macros (needs slang)
	@$(MAKE) -C $(SRAM_DIR)/test sta-smoke

# ---------------------------------------------------------------------------
# Aggregate liberty / verilog lists for the STA flow to ingest.
# ---------------------------------------------------------------------------
LIB_FILES := $(foreach m,$(MACRO_NAMES),$(MACRO_DIR)/$(m)/$(m).lib)
V_FILES   := $(foreach m,$(MACRO_NAMES),$(MACRO_DIR)/$(m)/$(m).v)

print-libs: ## Print space-separated list of Liberty files (for sta-sram)
	@echo "$(LIB_FILES)"

print-vs: ## Print space-separated list of macro Verilog files
	@echo "$(V_FILES)"

print-blackbox: ## Print the path of the consolidated blackbox stub
	@echo "$(SRAM_DIR)/wrappers/rapt_sram_blackbox.v"

help: ## Show this help
	@awk 'BEGIN{FS=":.*##"} /^[a-zA-Z0-9_-]+:.*##/ {printf "  %-15s %s\n", $$1, $$2}' $(MAKEFILE_LIST)
