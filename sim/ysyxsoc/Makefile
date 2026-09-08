# Local pin-level memory models, tested with the unmodified upstream controllers.
ROOT := $(abspath ../..)
SOC_HOME ?= $(ROOT)/third_party/OSCPU/ysyxSoC
BUILD_DIR ?= $(ROOT)/sim/build/ysyxsoc-memory-test
VERILATOR ?= verilator
SOURCES := $(ROOT)/verify/xsim/tb_ysyxsoc_memories.sv sdram.sv psram.sv \
  $(SOC_HOME)/perip/sdram/sdram_top_apb.v \
  $(SOC_HOME)/perip/sdram/core_sdram_axi4/sdram_axi_core.v \
  $(SOC_HOME)/perip/psram/psram_top_apb.v \
  $(wildcard $(SOC_HOME)/perip/psram/efabless/*.v)
.PHONY: test
test:
	$(VERILATOR) --binary --timing --top-module tb_ysyxsoc_memories \
	  -Wno-fatal --Mdir $(BUILD_DIR) -j 4 $(SOURCES)
	$(BUILD_DIR)/Vtb_ysyxsoc_memories
