# Differential unit test for rapt_fpu_divsqrt vs. host IEEE-754 FPU.
#
# The DUT (hdl/backend/feu/fpu/rapt_fpu_divsqrt.sv) is exercised with random
# operands across both precisions, both operations, and all four rounding
# modes supported by the host fenv (RNE/RTZ/RDN/RUP), plus subnormals,
# infinities, zeros and NaNs. Numeric results must match the host bit-exactly;
# NaN results only need to be NaN with the correct exception flags (RISC-V
# permits a canonical NaN for every NaN-producing operation).
#
# Usage:  make -C verify/xsim/fpu/divsqrt run [N=300000]

ROOT     := ../../../..
HDL_INC  := $(ROOT)/hdl/include
CONFIG   := $(ROOT)/hdl/configs/small
DUT      := $(ROOT)/hdl/backend/feu/fpu/rapt_fpu_divsqrt.sv
N        ?= 300000

VERILATOR ?= verilator
VFLAGS := --cc --exe --build -Wno-fatal -Wno-lint -Wno-WIDTH \
          -I$(HDL_INC) -I$(CONFIG) --top-module rapt_fpu_divsqrt_tb

obj_dir/tb: $(DUT) rapt_fpu_divsqrt_ref.sv rapt_fpu_divsqrt_tb.sv tb_host_diff.cpp
	+$(VERILATOR) $(VFLAGS) $(DUT) rapt_fpu_divsqrt_ref.sv \
	    rapt_fpu_divsqrt_tb.sv tb_host_diff.cpp -o tb

run: obj_dir/tb
	N=$(N) obj_dir/tb

clean:
	rm -rf obj_dir

.PHONY: run clean
