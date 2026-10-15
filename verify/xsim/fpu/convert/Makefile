# Differential unit test for pipelined single/double format conversions.
# Usage:  make -C verify/xsim/fpu/convert run [N=200000]

UNITS := convert_widen convert_narrow
HOST_FLAGS := -CFLAGS -frounding-math
include ../host-diff.mk

.PHONY: run-widen-box
run-widen-box:
	+$(VERILATOR) --cc --exe --build -j 2 --assert -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
		--top-module rapt_fpu_convert_widen -I$(ROOT)/hdl/include -I$(ROOT)/hdl/configs/default \
		$(ROOT)/hdl/backend/feu/fpu/rapt_fpu_convert_widen.sv tb_widen_box.cpp --Mdir obj_widen_box -o tb
	./obj_widen_box/tb
