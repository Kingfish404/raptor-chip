ROOT := ../../../..
N ?= 200000
OBJ_DIR := obj_dir
TOP := rapt_fpu_fp_to_int_tb

.PHONY: run clean

run:
	verilator --cc --exe --build -Wall -Wno-fatal -Wno-DECLFILENAME \
		--top-module $(TOP) -I$(ROOT)/hdl/include -I$(ROOT)/hdl/configs/small \
		$(ROOT)/hdl/backend/fpu/rapt_fpu_single_to_int_w.sv \
		rapt_fpu_fp_to_int_tb.sv test_fp_to_int.cpp --Mdir $(OBJ_DIR)
	./$(OBJ_DIR)/V$(TOP) $(N)

clean:
	rm -rf $(OBJ_DIR)