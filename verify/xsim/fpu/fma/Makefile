# Directed regression for rapt_fpu_fma subnormal / zero / rounding corners.
#
# Covers the bugs that made every RISCOF fmadd/fmsub/fnmadd/fnmsub test fail:
#   - normalize_subnormal dropping the MinExp exponent base
#   - zero multiplicand dragging the alignment base down (addend lost)
#   - total-underflow producing +0 without NX|UF
#
# Usage:  make -C verify/xsim/fpu/fma run

ROOT     := ../../../..
HDL_INC  := $(ROOT)/hdl/include
CONFIG   := $(ROOT)/hdl/configs/small
DUT      := $(ROOT)/hdl/backend/feu/fpu/rapt_fpu_fma.sv

VERILATOR ?= verilator
N ?= 200000
VFLAGS := --binary -Wno-fatal -Wno-lint -Wno-WIDTH \
          -I$(HDL_INC) -I$(CONFIG) --top-module tb

obj_dir/tb: $(DUT) fma_tb.sv
	+$(VERILATOR) $(VFLAGS) $(DUT) fma_tb.sv -o tb

obj_diff/tb: $(DUT) rapt_fpu_fma_tb.sv tb_host_diff.cpp
	+$(VERILATOR) --cc --exe --build -Wno-fatal -Wno-lint -Wno-WIDTH \
		-CFLAGS -frounding-math -I$(HDL_INC) -I$(CONFIG) \
		--top-module rapt_fpu_fma_tb $(DUT) rapt_fpu_fma_tb.sv \
		tb_host_diff.cpp --Mdir obj_diff -o tb

run: obj_dir/tb obj_diff/tb
	obj_dir/tb
	N=$(N) obj_diff/tb

clean:
	rm -rf obj_dir obj_diff

.PHONY: run clean
