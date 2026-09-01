# Directed regression for rapt_fpu_fma subnormal / zero / rounding corners.
#
# Covers the bugs that made every RISCOF fmadd/fmsub/fnmadd/fnmsub test fail:
#   - normalize_subnormal dropping the MinExp exponent base
#   - zero multiplicand dragging the alignment base down (addend lost)
#   - total-underflow producing +0 without NX|UF
#
# Usage:  make -C verify/unit/fpu/fma run

ROOT     := ../../../..
HDL_INC  := $(ROOT)/hdl/include
CONFIG   := $(ROOT)/hdl/configs/small
DUT      := $(ROOT)/hdl/backend/feu/fpu/rapt_fpu_fma.sv

VERILATOR ?= verilator
VFLAGS := --binary -j 8 -Wno-fatal -Wno-lint -Wno-WIDTH \
          -I$(HDL_INC) -I$(CONFIG) --top-module tb

obj_dir/tb: $(DUT) fma_tb.sv
	$(VERILATOR) $(VFLAGS) $(DUT) fma_tb.sv -o tb

run: obj_dir/tb
	obj_dir/tb

clean:
	rm -rf obj_dir

.PHONY: run clean
