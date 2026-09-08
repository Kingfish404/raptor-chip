ROOT := ../../../..
SOFTFLOAT_DIR ?=
.PHONY: run
run:
	@test -f "$(SOFTFLOAT_DIR)/include/softfloat.h" -a -f "$(SOFTFLOAT_DIR)/softfloat.a"
	+verilator --cc --exe --build -j 2 --assert -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
		--top-module tb -I$(ROOT)/hdl/include -I$(ROOT)/hdl/configs/default \
		$(ROOT)/hdl/backend/feu/fpu/rapt_fpu_compare.sv \
		$(ROOT)/hdl/backend/feu/fpu/rapt_fpu_sgnj.sv \
		$(ROOT)/hdl/backend/feu/fpu/rapt_fpu_classify.sv tb.sv test.cpp \
		--Mdir obj_softfloat -CFLAGS "-I$(abspath $(SOFTFLOAT_DIR))/include" \
		-LDFLAGS "$(abspath $(SOFTFLOAT_DIR))/softfloat.a" -o tb
	./obj_softfloat/tb
