ROOT := ../../../..
N ?= 200000
OBJ_DIR := obj_dir
TOP := rapt_fpu_fp_to_int_tb

.PHONY: run clean

run:
	+verilator --cc --exe --build -Wall -Wno-fatal -Wno-DECLFILENAME \
		--top-module $(TOP) -I$(ROOT)/hdl/include -I$(ROOT)/hdl/configs/small \
		$(ROOT)/hdl/backend/feu/fpu/rapt_fpu_single_to_int_w.sv \
		rapt_fpu_fp_to_int_tb.sv test_fp_to_int.cpp --Mdir $(OBJ_DIR)
	./$(OBJ_DIR)/V$(TOP) $(N)

clean:
	rm -rf $(OBJ_DIR)

SOFTFLOAT_DIR ?=
.PHONY: run-softfloat
run-softfloat:
	@test -f "$(SOFTFLOAT_DIR)/include/softfloat.h" -a -f "$(SOFTFLOAT_DIR)/softfloat.a"
	+verilator --cc --exe --build -j 2 --assert -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
		--top-module $(TOP) $(ROOT)/hdl/backend/feu/fpu/rapt_fpu_single_to_int_w.sv \
		rapt_fpu_fp_to_int_tb.sv tb_softfloat.cpp --Mdir obj_softfloat \
		-CFLAGS "-I$(abspath $(SOFTFLOAT_DIR))/include" -LDFLAGS "$(abspath $(SOFTFLOAT_DIR))/softfloat.a" -o tb
	./obj_softfloat/tb
