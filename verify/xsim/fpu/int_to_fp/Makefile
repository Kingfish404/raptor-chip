# Differential unit test for pipelined integer-to-floating conversion.
# Usage:  make -C verify/xsim/fpu/int_to_fp run [N=200000]

ROOT     := ../../../..
HDL_INC  := $(ROOT)/hdl/include
CONFIG   := $(ROOT)/hdl/configs/small
DUT      := $(ROOT)/hdl/backend/feu/fpu/rapt_fpu_int_to_fp.sv
N        ?= 200000

VERILATOR ?= verilator
VFLAGS := --cc --exe --build -Wno-fatal -Wno-lint -Wno-WIDTH \
          -CFLAGS -frounding-math -I$(HDL_INC) -I$(CONFIG) \
          --top-module rapt_fpu_int_to_fp_tb

obj_dir/tb: $(DUT) rapt_fpu_int_to_fp_tb.sv tb_host_diff.cpp
	+$(VERILATOR) $(VFLAGS) $(DUT) rapt_fpu_int_to_fp_tb.sv tb_host_diff.cpp -o tb

run: obj_dir/tb
	N=$(N) obj_dir/tb

clean:
	rm -rf obj_dir

.PHONY: run clean

# Independent reference for all five RISC-V rounding modes, including RMM.
# SOFTFLOAT_DIR must contain include/softfloat.h and softfloat.a.
SOFTFLOAT_DIR ?=
.PHONY: run-softfloat
run-softfloat:
	@test -f "$(SOFTFLOAT_DIR)/include/softfloat.h" -a -f "$(SOFTFLOAT_DIR)/softfloat.a"
	+$(VERILATOR) --cc --exe --build -j 2 --assert -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
		--top-module rapt_fpu_int_to_fp_tb $(DUT) rapt_fpu_int_to_fp_tb.sv tb_softfloat.cpp \
		--Mdir obj_softfloat -CFLAGS "-I$(abspath $(SOFTFLOAT_DIR))/include" \
		-LDFLAGS "$(abspath $(SOFTFLOAT_DIR))/softfloat.a" -o tb
	./obj_softfloat/tb
