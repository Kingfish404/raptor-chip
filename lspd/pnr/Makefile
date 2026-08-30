SHELL := /bin/bash
.SHELLFLAGS := -o pipefail -c

RAPT_HOME := $(abspath ../..)
LSPD_DIR := $(RAPT_HOME)/lspd
SYN_DIR := $(LSPD_DIR)/syn
FLOW_ROOT ?= $(RAPT_HOME)/third_party/yosys-opensta

include $(LSPD_DIR)/modules.mk

MODULE ?= fqu
PDK ?= nangate45
RAPT_CONFIG ?= default
CLK_FREQ_MHZ ?= 100
CORE_UTILIZATION ?= 40
CORE_ASPECT_RATIO ?= 1.0
PLACE_DENSITY ?= 0.60
PNR_MODE ?= standard
IMG_WIDTH ?= 1600
IMG_HEIGHT ?= 1600
PYTHON ?= python3
TIME ?= /usr/bin/time

NPROC := $(shell nproc 2>/dev/null || echo 1)
MEM_AVAILABLE_MB := $(shell awk '/MemAvailable:/ { print int($$2 / 1024) }' /proc/meminfo 2>/dev/null || echo 0)
JOB_MEMORY_MB ?= 8192
AUTO_PARALLEL_JOBS := $(shell awk 'BEGIN { \
	cpu = $(NPROC); mem = int($(MEM_AVAILABLE_MB) / $(JOB_MEMORY_MB)); \
	if (cpu < 1) cpu = 1; if (mem < 1) mem = 1; \
	print (cpu < mem) ? cpu : mem; \
}')
PARALLEL_JOBS ?= $(AUTO_PARALLEL_JOBS)
PARALLEL_MAKE_FLAGS = $(if $(filter --jobserver-auth=% --jobserver-fds=%,$(MAKEFLAGS)),,-j$(PARALLEL_JOBS))

# Only platforms with a complete OpenROAD LEF/Liberty/RC/GDS setup belong here.
SUPPORTED_PDKS := nangate45
PLATFORM_nangate45 := nangate45
PLATFORM := $(PLATFORM_$(PDK))

TOP := $(TOP_$(MODULE))
CLOCK_PORT := $(CLOCK_$(MODULE))
PERIOD_NS := $(shell awk 'BEGIN { printf "%.6f", 1000.0 / $(CLK_FREQ_MHZ) }')

OPENROAD ?= $(FLOW_ROOT)/third_party/OpenROAD/build/bin/openroad
XVFB_RUN ?= xvfb-run
KLAYOUT ?= klayout

SYN_BUILD_DIR := $(SYN_DIR)/build/$(RAPT_CONFIG)/$(PDK)/$(MODULE)/$(CLK_FREQ_MHZ)MHz
SYN_NETLIST := $(SYN_BUILD_DIR)/$(TOP).netlist.v
BUILD_DIR := $(abspath build/$(RAPT_CONFIG)/$(PDK)/$(MODULE)/$(CLK_FREQ_MHZ)MHz)
INPUT_DIR := $(BUILD_DIR)/input
STAGED_NETLIST := $(INPUT_DIR)/$(TOP).netlist.v
STAGED_SDC := $(STAGED_NETLIST).sdc
FINAL_ODB := $(BUILD_DIR)/$(TOP)_final.odb
FINAL_DEF := $(BUILD_DIR)/$(TOP)_final.def
FINAL_PNG := $(BUILD_DIR)/images/$(TOP)_layout.png
FLOORPLAN_ODB := $(BUILD_DIR)/1_floorplan.odb
PLACE_ODB := $(BUILD_DIR)/2_place.odb
CTS_ODB := $(BUILD_DIR)/3_cts.odb
ROUTE_ODB := $(BUILD_DIR)/4_route.odb
PNR_SUMMARY := $(abspath build/$(RAPT_CONFIG)/$(PDK)/pnr_summary.md)
MODULES_TO_RUN ?= $(MODULES)

PNR_SCRIPT_standard := openroad_pnr.tcl
PNR_SCRIPT_fast := openroad_pnr_fast.tcl
PNR_SCRIPT := $(PNR_SCRIPT_$(PNR_MODE))

FLOW_INPUT_DIR := $(shell realpath -m --relative-to='$(FLOW_ROOT)' '$(INPUT_DIR)')
FLOW_BUILD_DIR := $(shell realpath -m --relative-to='$(FLOW_ROOT)' '$(BUILD_DIR)')

ifeq ($(filter $(MODULE),$(MODULES)),)
$(error Unsupported MODULE=$(MODULE). Run 'make list')
endif
ifeq ($(filter $(PDK),$(SUPPORTED_PDKS)),)
$(error Unsupported physical-design PDK=$(PDK). Use one of: $(SUPPORTED_PDKS))
endif
ifeq ($(PNR_SCRIPT),)
$(error Unsupported PNR_MODE=$(PNR_MODE). Use one of: standard fast)
endif

.DEFAULT_GOAL := help

MODULE_PNR_TARGETS := $(addprefix pnr-module-,$(MODULES))

.PHONY: help list parallel-info doctor syn stage floorplan place cts route finish pnr viz summary pnr-all clean FORCE

FORCE:

help: ## Show this help message
	@echo "Standalone module physical-design flow"
	@echo
	@awk 'BEGIN { FS = ":.*## "; printf "Usage: make <target> [VARIABLE=value ...]\n\nTargets:\n" } \
		/^[a-zA-Z0-9_-]+:.*## / { printf "  %-20s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@echo
	@echo "Results: build/<config>/<pdk>/<module>/<frequency>MHz/"
	@echo "Supported PD PDKs: $(SUPPORTED_PDKS)"

list: ## List supported modules, top modules, and clock ports
	@$(foreach module,$(MODULES),printf '%-8s top=%-20s clock=%s\n' '$(module)' '$(TOP_$(module))' '$(CLOCK_$(module))';)

parallel-info: ## Show detected resources and automatic parallelism
	@echo "logical CPUs       : $(NPROC)"
	@echo "available memory MB: $(MEM_AVAILABLE_MB)"
	@echo "memory per job MB  : $(JOB_MEMORY_MB)"
	@echo "parallel jobs      : $(PARALLEL_JOBS)"

doctor: ## Check OpenROAD, rendering tools, and selected platform files
	@test -x "$(OPENROAD)" || { echo "missing OpenROAD: $(OPENROAD)"; exit 1; }
	@command -v $(KLAYOUT) >/dev/null || { echo "missing layout renderer: $(KLAYOUT)"; exit 1; }
	@test -x "$(TIME)" || { echo "missing GNU time: $(TIME)"; exit 1; }
	@test -f "$(FLOW_ROOT)/platforms/$(PLATFORM)/config.tcl" || { echo "missing platform config"; exit 1; }
	@test -f "$(FLOW_ROOT)/third_party/lib/$(PLATFORM)/lef/NangateOpenCellLibrary.tech.lef" || { echo "missing technology LEF"; exit 1; }
	@test -f "$(FLOW_ROOT)/third_party/lib/$(PLATFORM)/lef/NangateOpenCellLibrary.macro.mod.lef" || { echo "missing standard-cell LEF"; exit 1; }
	@test -f "$(FLOW_ROOT)/third_party/lib/$(PLATFORM)/lib/NangateOpenCellLibrary_typical.lib" || { echo "missing Liberty"; exit 1; }
	@test -f "$(FLOW_ROOT)/third_party/lib/$(PLATFORM)/klayout.lyt" || { echo "missing KLayout technology"; exit 1; }
	@test -f "$(FLOW_ROOT)/third_party/lib/$(PLATFORM)/klayout.lyp" || { echo "missing KLayout layer properties"; exit 1; }
	@$(OPENROAD) -version
	@echo "OpenROAD and $(PDK) physical-design data are ready"

syn: ## Build the mapped netlist with the LSPD synthesis flow
	+$(MAKE) -C $(SYN_DIR) syn MODULE=$(MODULE) PDK=$(PDK) \
		RAPT_CONFIG=$(RAPT_CONFIG) CLK_FREQ_MHZ=$(CLK_FREQ_MHZ) SRAM_MODE=flops

stage: $(STAGED_NETLIST) $(STAGED_SDC) ## Stage netlist and physical timing constraints

$(STAGED_NETLIST): $(SYN_NETLIST)
	@mkdir -p $(INPUT_DIR)
	@cp $< $@

$(SYN_NETLIST):
	+$(MAKE) -C $(SYN_DIR) syn MODULE=$(MODULE) PDK=$(PDK) \
		RAPT_CONFIG=$(RAPT_CONFIG) CLK_FREQ_MHZ=$(CLK_FREQ_MHZ) SRAM_MODE=flops

$(STAGED_SDC): scripts/write_sdc.py Makefile
	@mkdir -p $(INPUT_DIR)
	@$(PYTHON) scripts/write_sdc.py --output '$@' --clock-port '$(CLOCK_PORT)' \
		--period-ns '$(PERIOD_NS)'

floorplan: stage ## Run through floorplan and PDN generation
	@$(MAKE) --no-print-directory ensure-checkpoint CHECKPOINT='$(FLOORPLAN_ODB)' STAGE=floorplan

place: stage ## Run or resume through detailed placement
	@$(MAKE) --no-print-directory ensure-checkpoint CHECKPOINT='$(PLACE_ODB)' STAGE=place

cts: stage ## Run or resume through clock-tree synthesis
	@$(MAKE) --no-print-directory ensure-checkpoint CHECKPOINT='$(CTS_ODB)' STAGE=cts

route: stage ## Run or resume through detailed routing
	@$(MAKE) --no-print-directory ensure-checkpoint CHECKPOINT='$(ROUTE_ODB)' STAGE=route

finish: stage ## Resume from routing and generate final outputs and reports
	@$(MAKE) --no-print-directory pnr

pnr: stage ## Run floorplan, placement, CTS, routing, extraction, and reports
	@echo "[pnr] module=$(MODULE) top=$(TOP) pdk=$(PDK) config=$(RAPT_CONFIG) target=$(CLK_FREQ_MHZ)MHz mode=$(PNR_MODE)"
	@cd '$(FLOW_ROOT)' && \
		PROJ_PATH='$(FLOW_ROOT)' PLATFORM='$(PLATFORM)' DESIGN='$(TOP)' \
		RESULT_DIR='$(FLOW_INPUT_DIR)' NETLIST_SYN_V='$(TOP).netlist.v' \
		PNR_RESULT_DIR='$(FLOW_BUILD_DIR)' CLK_FREQ_MHZ='$(CLK_FREQ_MHZ)' \
		CLK_PORT_NAME='$(CLOCK_PORT)' CORE_UTILIZATION='$(CORE_UTILIZATION)' \
		CORE_ASPECT_RATIO='$(CORE_ASPECT_RATIO)' PLACE_DENSITY='$(PLACE_DENSITY)' \
		$(TIME) -o '$(BUILD_DIR)/pnr.profile' \
			-f 'status=%x\nelapsed_sec=%e\nuser_sec=%U\nsystem_sec=%S\nmax_rss_kb=%M' \
			'$(OPENROAD)' -exit 'scripts/$(PNR_SCRIPT)' 2>&1 | tee '$(BUILD_DIR)/pnr.log'
	@test -f '$(FINAL_ODB)'
	@$(PYTHON) scripts/collect_metrics.py --result-dir '$(BUILD_DIR)' \
		--top '$(TOP)' --period-ns '$(PERIOD_NS)' --output '$(BUILD_DIR)/pnr_metrics.txt'
	@echo "Physical-design outputs: $(BUILD_DIR)"

ensure-checkpoint:
	@if [ ! -f "$(CHECKPOINT)" ]; then \
		$(MAKE) --no-print-directory pnr; \
	fi
	@test -f "$(CHECKPOINT)"
	@echo "$(STAGE) checkpoint: $(CHECKPOINT)"

viz: $(FINAL_ODB) ## Generate headless PNG views for the final and intermediate layouts
	@mkdir -p '$(BUILD_DIR)/images'
	@IMG_WIDTH='$(IMG_WIDTH)' IMG_HEIGHT='$(IMG_HEIGHT)' QT_QPA_PLATFORM=offscreen \
		$(KLAYOUT) -z -r '$(FLOW_ROOT)/scripts/viz_layout_klayout.py' \
		-rd def_file='$(FINAL_DEF)' \
		-rd tech_lef='$(FLOW_ROOT)/third_party/lib/$(PLATFORM)/lef/NangateOpenCellLibrary.tech.lef' \
		-rd cell_lef='$(FLOW_ROOT)/third_party/lib/$(PLATFORM)/lef/NangateOpenCellLibrary.macro.mod.lef' \
		-rd tech_file='$(FLOW_ROOT)/third_party/lib/$(PLATFORM)/klayout.lyt' \
		-rd lyp_file='$(FLOW_ROOT)/third_party/lib/$(PLATFORM)/klayout.lyp' \
		-rd out_dir='$(BUILD_DIR)/images' -rd design='$(TOP)' \
		2>&1 | tee '$(BUILD_DIR)/viz.log'
	@test -f '$(FINAL_PNG)'
	@echo "Layout images: $(BUILD_DIR)/images"

$(FINAL_ODB):
	+$(MAKE) --no-print-directory pnr MODULE=$(MODULE) PDK=$(PDK) \
		RAPT_CONFIG=$(RAPT_CONFIG) CLK_FREQ_MHZ=$(CLK_FREQ_MHZ)

summary: ## Summarize existing physical-design results for one PDK
	@$(PYTHON) scripts/summarize_pnr.py --build-root '$(abspath build)' \
		--config '$(RAPT_CONFIG)' --pdk '$(PDK)' --frequency-mhz '$(CLK_FREQ_MHZ)' \
		--modules $(MODULES_TO_RUN) --output '$(PNR_SUMMARY)'

pnr-all: ## Run physical design for MODULES_TO_RUN in parallel, then summarize
	@echo "[parallel] pdk=$(PDK) modules='$(MODULES_TO_RUN)' jobs=$(PARALLEL_JOBS)"
	+$(MAKE) --no-print-directory --output-sync=target $(PARALLEL_MAKE_FLAGS) \
		$(addprefix pnr-module-,$(MODULES_TO_RUN))
	+$(MAKE) --no-print-directory summary PDK=$(PDK) RAPT_CONFIG=$(RAPT_CONFIG) \
		CLK_FREQ_MHZ=$(CLK_FREQ_MHZ) MODULES_TO_RUN='$(MODULES_TO_RUN)'

pnr-module-%: FORCE
	+$(MAKE) --no-print-directory pnr viz MODULE=$* PDK=$(PDK) \
		RAPT_CONFIG=$(RAPT_CONFIG) CLK_FREQ_MHZ=$(CLK_FREQ_MHZ)

clean: ## Remove all LSPD physical-design outputs
	rm -rf build