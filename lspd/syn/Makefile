SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c

RAPT_HOME := $(abspath ../..)
LSPD_DIR := $(RAPT_HOME)/lspd
HDL_ROOT := $(RAPT_HOME)/hdl
FLOW_ROOT ?= $(RAPT_HOME)/third_party/yosys-opensta
PLATFORM_ROOT := $(FLOW_ROOT)/third_party/lib

include $(LSPD_DIR)/modules.mk

MODULE ?= core
PDK ?= nangate45
RAPT_CONFIG ?= default
CLK_FREQ_MHZ ?= 100
IO_DELAY_FRAC ?= 0.20
OUTPUT_LOAD_FF ?= 5.0
EXTRA_DEFINES ?=
SRAM_MODE ?= macro
SRAM_PLATFORM ?= sky130
PYTHON ?= python3
TIME ?= /usr/bin/time

NPROC := $(shell nproc 2>/dev/null || echo 1)
MEM_AVAILABLE_MB := $(shell awk '/MemAvailable:/ { print int($$2 / 1024) }' /proc/meminfo 2>/dev/null || echo 0)
JOB_MEMORY_MB ?= 6144
AUTO_PARALLEL_JOBS := $(shell awk 'BEGIN { \
	cpu = $(NPROC); mem = int($(MEM_AVAILABLE_MB) / $(JOB_MEMORY_MB)); \
	if (cpu < 1) cpu = 1; if (mem < 1) mem = 1; \
	print (cpu < mem) ? cpu : mem; \
}')
PARALLEL_JOBS ?= $(AUTO_PARALLEL_JOBS)
PARALLEL_MAKE_FLAGS = $(if $(filter --jobserver-auth=% --jobserver-fds=%,$(MAKEFLAGS)),,-j$(PARALLEL_JOBS))

SUPPORTED_PDKS := asap7 nangate45 sky130
PLATFORM_asap7 := asap7
PLATFORM_nangate45 := nangate45
PLATFORM_sky130 := sky130hd
PLATFORM := $(PLATFORM_$(PDK))

TOP := $(TOP_$(MODULE))
CLOCK_PORT := $(CLOCK_$(MODULE))
PERIOD_NS := $(shell awk 'BEGIN { printf "%.6f", 1000.0 / $(CLK_FREQ_MHZ) }')

YOSYS ?= yosys
OPENSTA ?= $(shell command -v sta 2>/dev/null || echo $(FLOW_ROOT)/third_party/OpenSTA/build/sta)

BUILD_DIR := $(abspath build/$(RAPT_CONFIG)/$(PDK)/$(MODULE)/$(CLK_FREQ_MHZ)MHz)
NETLIST := $(BUILD_DIR)/$(TOP).netlist.v
SRAM_DIR := $(RAPT_HOME)/sim/sram
SRAM_BLACKBOX := $(SRAM_DIR)/wrappers/rapt_sram_blackbox.v
SRAM_STAMP := $(SRAM_DIR)/build/$(SRAM_PLATFORM)/.lspd-stubs.ok
SRAM_LIB_FILES := $(shell $(MAKE) -s -C $(SRAM_DIR) print-libs PLATFORM=$(SRAM_PLATFORM))

HDL_SV := $(HDL_ROOT)/rapt_pkg.sv \
          $(filter-out $(HDL_ROOT)/rapt_pkg.sv,$(shell find $(HDL_ROOT) -path '$(HDL_ROOT)/chisel' -prune -o -path '$(HDL_ROOT)/generated' -prune -o -name '*.sv' -print | sort)) \
          $(HDL_ROOT)/generated/rapt_idu_decoder.sv \
          $(HDL_ROOT)/generated/rapt_idu_decoder_c.sv
INCLUDE_DIRS := $(HDL_ROOT)/configs/$(RAPT_CONFIG) \
                $(HDL_ROOT) \
                $(HDL_ROOT)/include \
                $(HDL_ROOT)/include/npc \
                $(HDL_ROOT)/include/dpic_mock
SLANG_FLAGS := --single-unit --allow-use-before-declare --allow-toplevel-iface-ports \
			   -DSYNTHESIS $(EXTRA_DEFINES) \
               $(addprefix -I,$(INCLUDE_DIRS))

ifeq ($(SRAM_MODE),macro)
SLANG_FLAGS += -DRAPT_USE_SRAM_MACRO
SYNTH_SV_FILES := $(SRAM_BLACKBOX) $(HDL_SV)
STA_LIB_FILES = $(LIB_FILES) $(SRAM_LIB_FILES)
SRAM_PREREQUISITES := $(SRAM_STAMP)
else ifeq ($(SRAM_MODE),flops)
SYNTH_SV_FILES := $(HDL_SV)
STA_LIB_FILES = $(LIB_FILES)
SRAM_PREREQUISITES :=
else
$(error Unsupported SRAM_MODE=$(SRAM_MODE). Use one of: macro flops)
endif

PLATFORM_DIR := $(FLOW_ROOT)/platforms/$(PLATFORM)
FOUNDRY_PATH := $(PLATFORM_ROOT)/$(PLATFORM)

ifeq ($(PDK),asap7)
LIB_FILES := $(FOUNDRY_PATH)/lib/NLDM/asap7sc7p5t_AO_RVT_TT_nldm_211120.lib \
             $(FOUNDRY_PATH)/lib/NLDM/asap7sc7p5t_INVBUF_RVT_TT_nldm_220122.lib \
             $(FOUNDRY_PATH)/lib/NLDM/asap7sc7p5t_OA_RVT_TT_nldm_211120.lib \
             $(FOUNDRY_PATH)/lib/NLDM/asap7sc7p5t_SIMPLE_RVT_TT_nldm_211120.lib \
             $(FOUNDRY_PATH)/lib/NLDM/asap7sc7p5t_SEQ_RVT_TT_nldm_220123.lib
else ifeq ($(PDK),nangate45)
LIB_FILES := $(FOUNDRY_PATH)/lib/merged.lib
else ifeq ($(PDK),sky130)
LIB_FILES := $(FOUNDRY_PATH)/lib/sky130_fd_sc_hd__tt_025C_1v80.lib
endif

ifeq ($(filter $(MODULE),$(MODULES)),)
$(error Unsupported MODULE=$(MODULE). Run 'make list')
endif
ifeq ($(filter $(PDK),$(SUPPORTED_PDKS)),)
$(error Unsupported PDK=$(PDK). Use one of: $(SUPPORTED_PDKS))
endif
ifeq ($(wildcard $(HDL_ROOT)/configs/$(RAPT_CONFIG)/rapt_config.svh),)
$(error Unsupported RAPT_CONFIG=$(RAPT_CONFIG))
endif

.DEFAULT_GOAL := help

MODULE_PPA_TARGETS := $(addprefix ppa-module-,$(MODULES))
PDK_PPA_TARGETS := $(addprefix ppa-pdk-,$(SUPPORTED_PDKS))
PDK_MATRIX_TARGETS := $(addprefix ppa-matrix-pdk-,$(SUPPORTED_PDKS))
PDK_SUMMARY_TARGETS := $(addprefix ppa-summary-pdk-,$(SUPPORTED_PDKS))
PPA_SUMMARY := $(abspath build/$(RAPT_CONFIG)/$(PDK)/ppa_summary.md)
PROFILE_SUMMARY := $(abspath build/$(RAPT_CONFIG)/$(PDK)/profile_summary.md)
GENERATE_PROFILE_SUMMARY ?= 1
MODULES_TO_RUN ?= $(MODULES)

.PHONY: help list parallel-info doctor sram-model syn sta ppa ppa-all ppa-all-pdks ppa-matrix ppa-summary ppa-summary-all-pdks profile-summary clean FORCE

FORCE:

help: ## Show this help message
	@echo "Standalone core-module PPA flow"
	@echo
	@awk 'BEGIN { FS = ":.*## "; printf "Usage: make <target> [VARIABLE=value ...]\n\nTargets:\n" } \
		/^[a-zA-Z0-9_-]+:.*## / { printf "  %-24s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@echo
	@echo "Results: build/<config>/<pdk>/<module>/<frequency>MHz/"
	@echo "Summaries: build/<config>/<pdk>/{ppa,profile}_summary.md"
	@echo "SRAM_MODE: macro (abstract macro PPA, default) or flops (logic baseline)"

list: ## List supported modules, top modules, and clock ports
	@$(foreach module,$(MODULES),printf '%-8s top=%-20s clock=%s\n' '$(module)' '$(TOP_$(module))' '$(CLOCK_$(module))';)

parallel-info: ## Show detected resources and automatic parallelism
	@echo "logical CPUs       : $(NPROC)"
	@echo "available memory MB: $(MEM_AVAILABLE_MB)"
	@echo "memory per job MB  : $(JOB_MEMORY_MB)"
	@echo "parallel jobs      : $(PARALLEL_JOBS)"

doctor: ## Check synthesis tools and selected PDK libraries
	@command -v $(YOSYS) >/dev/null || { echo "missing yosys: $(YOSYS)"; exit 1; }
	@test -x "$(TIME)" || { echo "missing GNU time: $(TIME)"; exit 1; }
	@$(YOSYS) -m slang -Q -p 'help read_slang' >/dev/null || { echo "yosys slang plugin is unavailable"; exit 1; }
	@test -x "$(OPENSTA)" || { echo "missing OpenSTA: $(OPENSTA)"; exit 1; }
	@test -f "$(PLATFORM_DIR)/yosys_config.tcl" || { echo "missing platform config: $(PLATFORM_DIR)"; exit 1; }
	@for lib in $(LIB_FILES); do test -f "$$lib" || { echo "missing Liberty: $$lib"; exit 1; }; done
	@if [ "$(SRAM_MODE)" = "macro" ]; then test -f "$(SRAM_BLACKBOX)" || { echo "missing SRAM blackbox: $(SRAM_BLACKBOX)"; exit 1; }; fi
	@echo "tools and $(PDK) libraries are ready"

sram-model: $(SRAM_STAMP) ## Generate abstract SRAM macro models used by LSPD PPA

$(SRAM_STAMP): $(SRAM_DIR)/Makefile $(SRAM_DIR)/scripts/gen_stub_lib.py $(SRAM_BLACKBOX) $(wildcard $(SRAM_DIR)/configs/*.py)
	@$(MAKE) -C $(SRAM_DIR) stubs PLATFORM=$(SRAM_PLATFORM)
	@touch $@

syn: $(NETLIST) ## Synthesize MODULE and write its mapped netlist

$(NETLIST): $(HDL_SV) scripts/synth.tcl $(LSPD_DIR)/modules.mk Makefile $(SRAM_PREREQUISITES)
	@mkdir -p $(BUILD_DIR)
	@echo "[syn] module=$(MODULE) top=$(TOP) pdk=$(PDK) config=$(RAPT_CONFIG) target=$(CLK_FREQ_MHZ)MHz sram=$(SRAM_MODE)"
	@printf 'mode=%s\nmodel=%s\nplatform=%s\n' '$(SRAM_MODE)' '$(if $(filter macro,$(SRAM_MODE)),abstract-liberty,logic-mapped)' '$(if $(filter macro,$(SRAM_MODE)),$(SRAM_PLATFORM),none)' > $(BUILD_DIR)/sram_model.txt
	@YS_TOP='$(TOP)' \
	 YS_OUT='$(BUILD_DIR)' \
	 YS_SV_FILES='$(SYNTH_SV_FILES)' \
	 YS_SLANG_FLAGS='$(SLANG_FLAGS)' \
	 YS_SRAM_LIB_FILES='$(if $(filter macro,$(SRAM_MODE)),$(SRAM_LIB_FILES))' \
	 YS_PLATFORM_DIR='$(PLATFORM_DIR)' \
	 YS_FOUNDRY_PATH='$(FOUNDRY_PATH)' \
	 YS_PERIOD_NS='$(PERIOD_NS)' \
	 $(TIME) -o '$(BUILD_DIR)/synth.profile' \
	 	-f 'status=%x\nelapsed_sec=%e\nuser_sec=%U\nsystem_sec=%S\nmax_rss_kb=%M' \
	 	$(YOSYS) -m slang -p 'tcl scripts/synth.tcl' 2>&1 | tee $(BUILD_DIR)/synth.log

sta: $(NETLIST) ## Run static timing and vectorless power analysis
	@echo "[sta] module=$(MODULE) pdk=$(PDK) period=$(PERIOD_NS)ns"
	@STA_TOP='$(TOP)' \
	 STA_NETLIST='$(NETLIST)' \
	 STA_LIB_FILES='$(STA_LIB_FILES)' \
	 STA_OUT='$(BUILD_DIR)' \
	 STA_CLK='$(CLOCK_PORT)' \
	 STA_PERIOD='$(PERIOD_NS)' \
	 STA_IO_DELAY_FRAC='$(IO_DELAY_FRAC)' \
	 STA_OUTPUT_LOAD_FF='$(OUTPUT_LOAD_FF)' \
	 $(TIME) -o '$(BUILD_DIR)/sta.profile' \
	 	-f 'status=%x\nelapsed_sec=%e\nuser_sec=%U\nsystem_sec=%S\nmax_rss_kb=%M' \
	 	$(OPENSTA) -exit scripts/run_sta.tcl 2>&1 | tee $(BUILD_DIR)/sta.log

ppa: syn sta ## Run synthesis and STA for one module
	@echo "PPA reports: $(BUILD_DIR)"
	@if [ "$(GENERATE_PROFILE_SUMMARY)" = "1" ]; then \
		$(MAKE) --no-print-directory profile-summary \
			PDK=$(PDK) RAPT_CONFIG=$(RAPT_CONFIG) CLK_FREQ_MHZ=$(CLK_FREQ_MHZ) \
			MODULES_TO_RUN='$(MODULES)'; \
	fi

ppa-all: ## Evaluate MODULES_TO_RUN in parallel for one PDK
	@echo "[parallel] pdk=$(PDK) modules='$(MODULES_TO_RUN)' jobs=$(PARALLEL_JOBS)"
	+$(MAKE) --no-print-directory --output-sync=target $(PARALLEL_MAKE_FLAGS) \
		GENERATE_PROFILE_SUMMARY=0 $(addprefix ppa-module-,$(MODULES_TO_RUN))
	+$(MAKE) --no-print-directory profile-summary PDK=$(PDK) \
		RAPT_CONFIG=$(RAPT_CONFIG) CLK_FREQ_MHZ=$(CLK_FREQ_MHZ) \
		MODULES_TO_RUN='$(MODULES_TO_RUN)'

ppa-module-%: FORCE
	+$(MAKE) --no-print-directory ppa MODULE=$* PDK=$(PDK) \
		RAPT_CONFIG=$(RAPT_CONFIG) CLK_FREQ_MHZ=$(CLK_FREQ_MHZ) \
		GENERATE_PROFILE_SUMMARY=$(GENERATE_PROFILE_SUMMARY)

ppa-all-pdks: ## Evaluate one module across all supported PDKs
	@echo "[parallel] module=$(MODULE) pdks='$(SUPPORTED_PDKS)' jobs=$(PARALLEL_JOBS)"
	+$(MAKE) --no-print-directory --output-sync=target $(PARALLEL_MAKE_FLAGS) $(PDK_PPA_TARGETS)

ppa-pdk-%: FORCE
	+$(MAKE) --no-print-directory ppa MODULE=$(MODULE) PDK=$* \
		RAPT_CONFIG=$(RAPT_CONFIG) CLK_FREQ_MHZ=$(CLK_FREQ_MHZ) \
		GENERATE_PROFILE_SUMMARY=0
	+$(MAKE) --no-print-directory profile-summary PDK=$* \
		RAPT_CONFIG=$(RAPT_CONFIG) CLK_FREQ_MHZ=$(CLK_FREQ_MHZ) \
		MODULES_TO_RUN='$(MODULE)'

ppa-matrix: ## Evaluate MODULES_TO_RUN across all supported PDKs
	@echo "[parallel] pdks='$(SUPPORTED_PDKS)' modules='$(MODULES_TO_RUN)' jobs=$(PARALLEL_JOBS)"
	+$(MAKE) --no-print-directory --output-sync=target $(PARALLEL_MAKE_FLAGS) $(PDK_MATRIX_TARGETS)

ppa-matrix-pdk-%: FORCE
	+$(MAKE) --no-print-directory ppa-all PDK=$* \
		RAPT_CONFIG=$(RAPT_CONFIG) CLK_FREQ_MHZ=$(CLK_FREQ_MHZ) \
		MODULES_TO_RUN='$(MODULES_TO_RUN)'

ppa-summary: ## Summarize existing PPA reports for one PDK
	@$(PYTHON) scripts/summarize_ppa.py \
		--build-root '$(abspath build)' \
		--config '$(RAPT_CONFIG)' \
		--pdk '$(PDK)' \
		--frequency-mhz '$(CLK_FREQ_MHZ)' \
		--modules $(MODULES_TO_RUN) \
		--output '$(PPA_SUMMARY)'

ppa-summary-all-pdks: ## Generate PPA summaries for all supported PDKs
	@echo "[report] pdks='$(SUPPORTED_PDKS)' modules='$(MODULES_TO_RUN)'"
	+$(MAKE) --no-print-directory --output-sync=target $(PARALLEL_MAKE_FLAGS) $(PDK_SUMMARY_TARGETS)

ppa-summary-pdk-%: FORCE
	+$(MAKE) --no-print-directory ppa-summary PDK=$* \
		RAPT_CONFIG=$(RAPT_CONFIG) CLK_FREQ_MHZ=$(CLK_FREQ_MHZ) \
		MODULES_TO_RUN='$(MODULES_TO_RUN)'

profile-summary: ## Summarize evaluation time, resources, and RTL size
	@$(PYTHON) scripts/summarize_profile.py \
		--build-root '$(abspath build)' \
		--config '$(RAPT_CONFIG)' \
		--pdk '$(PDK)' \
		--frequency-mhz '$(CLK_FREQ_MHZ)' \
		--modules $(MODULES_TO_RUN) \
		--output '$(PROFILE_SUMMARY)'

clean: ## Remove all LSPD synthesis build outputs
	rm -rf build
