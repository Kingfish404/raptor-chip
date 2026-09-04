ROOT := $(abspath ../../../..)
VERILATOR ?= verilator
DUTS := $(ROOT)/hdl/backend/feu/fpu/rapt_fpu_half_to_fp.sv \
	$(ROOT)/hdl/backend/feu/fpu/rapt_fpu_fp_to_half.sv
VFLAGS := --cc --exe --build --timing -Wall -Wno-fatal \
	-I$(ROOT)/hdl/include -I$(ROOT)/hdl/configs/default \
	--top-module rapt_fpu_half_tb

.PHONY: run clean
run: obj_dir/tb
	./obj_dir/tb

obj_dir/tb: $(DUTS) rapt_fpu_half_tb.sv tb_main.cpp
	+$(VERILATOR) $(VFLAGS) $(DUTS) rapt_fpu_half_tb.sv tb_main.cpp -o tb

clean:
	rm -rf obj_dir
