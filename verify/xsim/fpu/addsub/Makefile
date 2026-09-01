# Differential unit test for the pipelined rapt_fpu_addsub vs. host IEEE-754
# FPU. See tb_host_diff.cpp for the checking policy.
#
# Usage:  make -C verify/xsim/fpu/addsub run [N=200000]

ROOT     := ../../../..
HDL_INC  := $(ROOT)/hdl/include
CONFIG   := $(ROOT)/hdl/configs/small
DUT      := $(ROOT)/hdl/backend/feu/fpu/rapt_fpu_addsub.sv
N        ?= 200000

VERILATOR ?= verilator
VFLAGS := --cc --exe --build -j 8 -Wno-fatal -Wno-lint -Wno-WIDTH \
          -I$(HDL_INC) -I$(CONFIG) --top-module rapt_fpu_addsub_tb

obj_dir/tb: $(DUT) rapt_fpu_addsub_tb.sv tb_host_diff.cpp
	$(VERILATOR) $(VFLAGS) $(DUT) rapt_fpu_addsub_tb.sv tb_host_diff.cpp -o tb

run: obj_dir/tb
	N=$(N) obj_dir/tb

clean:
	rm -rf obj_dir

.PHONY: run clean
