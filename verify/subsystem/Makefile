RAPTOR_HOME := $(abspath ../..)
SHELL := /bin/bash
.DEFAULT_GOAL := all
HDL_HOME := $(RAPTOR_HOME)/hdl
NEMU_HOME := $(RAPTOR_HOME)/nemu
BUILD_DIR ?= $(RAPTOR_HOME)/verify/build/subsystem
CONFIG ?= default
XLEN ?= 32
TRACE_INSTS ?= 20000
IMG ?= $(RAPTOR_HOME)/abstract-machine/app/am-kernels/benchmarks/coremark_eembc/build/coremark-riscv$(XLEN)-npc.bin
TRACE_PREFIX ?= $(BUILD_DIR)/coremark-rv$(XLEN)-$(TRACE_INSTS)
VERILATOR ?= verilator
VERILATOR_JOBS ?= 2
FE_MAX_CYCLES ?= 1000000

ifeq ($(XLEN),64)
RV_DEFINE := -DRAPT_RV64
endif

PKG := $(HDL_HOME)/rapt_pkg.sv
RTL := $(shell find $(HDL_HOME) -name '*.sv' ! -name rapt_pkg.sv)
INCLUDES := -I$(HDL_HOME)/configs/$(CONFIG) -I$(HDL_HOME)/include \
            -I$(HDL_HOME)/include/dpic_mock -I$(HDL_HOME)/include/npc \
            -I$(RAPTOR_HOME)/verify/xsim
SV_FLAGS := --binary --timing --assert -Wno-fatal -j $(VERILATOR_JOBS) \
            --timescale 1ns/1ps $(RV_DEFINE) $(INCLUDES)

.PHONY: trace fe be mem structure all
trace:
	@mkdir -p $(dir $(TRACE_PREFIX))
	@cd $(NEMU_HOME) && \
	  RAPT_SUBSYSTEM_TRACE_PREFIX=$(abspath $(TRACE_PREFIX)) \
	  ./build/riscv$(XLEN)-nemu-interpreter -b -m $(TRACE_INSTS) $(abspath $(IMG)) \
	  > $(abspath $(TRACE_PREFIX)).nemu.log 2>&1
	@test -s $(TRACE_PREFIX).inst && test -s $(TRACE_PREFIX).mem
	@python3 check_trace.py --image $(abspath $(IMG)) \
	  --inst $(TRACE_PREFIX).inst --mem $(TRACE_PREFIX).mem \
	  --output $(TRACE_PREFIX).meta.json
	@echo "Trace: $(TRACE_PREFIX).inst $(TRACE_PREFIX).mem"

$(BUILD_DIR)/fe/Vtb_frontend_trace: $(PKG) $(RTL) tb_frontend_trace.sv
	@mkdir -p $(BUILD_DIR)/fe
	@$(VERILATOR) $(SV_FLAGS) --top-module tb_frontend_trace \
	  $(PKG) $(RTL) tb_frontend_trace.sv --Mdir $(BUILD_DIR)/fe \
	  > $(BUILD_DIR)/fe/build.log 2>&1 || { tail -70 $(BUILD_DIR)/fe/build.log; exit 1; }

fe: $(BUILD_DIR)/fe/Vtb_frontend_trace
	@set -e -o pipefail; $(BUILD_DIR)/fe/Vtb_frontend_trace +IMG=$(abspath $(IMG)) \
	  +TRACE=$(abspath $(TRACE_PREFIX)).inst +MAX_CYCLES=$(FE_MAX_CYCLES) \
	  $(FE_ARGS) | tee $(BUILD_DIR)/fe/run.log

$(BUILD_DIR)/mem/Vtb_memory_trace: $(PKG) $(RTL) tb_memory_trace.sv tb_axi_image.sv $(RAPTOR_HOME)/sim/tb/rapt_tb_mem.sv
	@mkdir -p $(BUILD_DIR)/mem
	@$(VERILATOR) $(SV_FLAGS) --top-module tb_memory_trace \
	  $(PKG) $(RTL) $(RAPTOR_HOME)/sim/tb/rapt_tb_mem.sv tb_axi_image.sv tb_memory_trace.sv \
	  --Mdir $(BUILD_DIR)/mem > $(BUILD_DIR)/mem/build.log 2>&1 || \
	  { tail -70 $(BUILD_DIR)/mem/build.log; exit 1; }

mem: $(BUILD_DIR)/mem/Vtb_memory_trace
	@set -e -o pipefail; $(BUILD_DIR)/mem/Vtb_memory_trace +IMG=$(abspath $(IMG)) \
	  +TRACE=$(abspath $(TRACE_PREFIX)).inst \
	  +MEM_TRACE=$(abspath $(TRACE_PREFIX)).mem $(MEM_ARGS) \
	  | tee $(BUILD_DIR)/mem/run.log

$(BUILD_DIR)/be/Vtb_backend_trace: $(PKG) $(RTL) tb_backend_trace.sv tb_axi_image.sv $(RAPTOR_HOME)/sim/tb/rapt_tb_mem.sv
	@mkdir -p $(BUILD_DIR)/be
	@$(VERILATOR) $(SV_FLAGS) --top-module tb_backend_trace \
	  $(PKG) $(RTL) $(RAPTOR_HOME)/sim/tb/rapt_tb_mem.sv tb_axi_image.sv tb_backend_trace.sv \
	  --Mdir $(BUILD_DIR)/be > $(BUILD_DIR)/be/build.log 2>&1 || \
	  { tail -70 $(BUILD_DIR)/be/build.log; exit 1; }

be: $(BUILD_DIR)/be/Vtb_backend_trace
	@set -e -o pipefail; $(BUILD_DIR)/be/Vtb_backend_trace +IMG=$(abspath $(IMG)) \
	  +TRACE=$(abspath $(TRACE_PREFIX)).inst $(BE_ARGS) \
	  | tee $(BUILD_DIR)/be/run.log

all: trace
	+$(MAKE) fe
	+$(MAKE) be
	+$(MAKE) mem

structure:
	@set -e; for module in frontend backend memory; do \
	  $(MAKE) -C $(RAPTOR_HOME)/lspd/syn structure-check MODULE=$$module \
	    RAPT_CONFIG=$(CONFIG) EXTRA_DEFINES=$(if $(filter 64,$(XLEN)),-DRAPT_RV64); \
	done
