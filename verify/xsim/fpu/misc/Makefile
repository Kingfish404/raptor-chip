ROOT := ../../../..

.PHONY: run clean

run:
	verilator --binary -j 8 -Wno-fatal -I$(ROOT)/hdl/include \
		-I$(ROOT)/hdl/configs/small --top-module misc_tb \
		$(ROOT)/hdl/backend/feu/fpu/rapt_fpu_compare.sv \
		$(ROOT)/hdl/backend/feu/fpu/rapt_fpu_classify.sv \
		$(ROOT)/hdl/backend/feu/fpu/rapt_fpu_sgnj.sv misc_tb.sv -o tb
	./obj_dir/tb

clean:
	rm -rf obj_dir
