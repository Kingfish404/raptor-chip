# Differential unit test for pipelined integer-to-floating conversion.
# Usage:  make -C verify/xsim/fpu/int_to_fp run [N=200000]

UNITS := int_to_fp
EXTRA_SOURCES = $(ROOT)/hdl/backend/feu/fpu/rapt_fpu_integer_to_fp.sv
HOST_FLAGS := -CFLAGS -frounding-math
include ../host-diff.mk

# Independent reference for all five RISC-V rounding modes, including RMM.
# SOFTFLOAT_DIR must contain include/softfloat.h and softfloat.a.
SOFTFLOAT_DIR ?=
.PHONY: run-softfloat
run-softfloat:
	@test -f "$(SOFTFLOAT_DIR)/include/softfloat.h" -a -f "$(SOFTFLOAT_DIR)/softfloat.a"
	+$(VERILATOR) --cc --exe --build -j 2 --assert -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
		--top-module rapt_fpu_int_to_fp_tb $(DUTS) $(EXTRA_SOURCES) rapt_fpu_int_to_fp_tb.sv tb_softfloat.cpp \
		--Mdir obj_softfloat -CFLAGS "-I$(abspath $(SOFTFLOAT_DIR))/include" \
		-LDFLAGS "$(abspath $(SOFTFLOAT_DIR))/softfloat.a" -o tb
	./obj_softfloat/tb
