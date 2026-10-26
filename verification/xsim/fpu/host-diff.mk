# Shared host IEEE-754 differential build. Component Makefiles select only
# their DUTs, reference sources and host rounding policy.
ROOT := ../../../..
HDL_INC := $(ROOT)/rtl/include
CONFIG := $(ROOT)/rtl/configs/small
DUTS := $(addprefix $(ROOT)/rtl/backend/feu/fpu/rapt_fpu_,$(addsuffix .sv,$(UNITS)))
TOP := rapt_fpu_$(notdir $(CURDIR))_tb
N ?= 200000
VERILATOR ?= verilator
VFLAGS := --cc --exe --build -Wno-fatal -Wno-lint -Wno-WIDTH \
	$(HOST_FLAGS) -I$(HDL_INC) -I$(CONFIG) --top-module $(TOP)
SOURCES := $(DUTS) $(EXTRA_SOURCES) $(TOP).sv tb_host_diff.cpp

# Let Verilator and its generated Makefile track flags and transitive SV/C++
# headers. A second, partial dependency list here can silently reuse stale tests.
.PHONY: build run clean
build:
	+$(VERILATOR) $(VFLAGS) $(SOURCES) -o tb

run: build
	N=$(N) obj_dir/tb

clean:
	rm -rf obj_dir
