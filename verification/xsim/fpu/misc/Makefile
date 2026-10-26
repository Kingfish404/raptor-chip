ROOT := ../../../..

.PHONY: run clean

run:
	+verilator --binary -Wno-fatal -I$(ROOT)/rtl/include \
		-I$(ROOT)/rtl/configs/small --top-module misc_tb \
		$(ROOT)/rtl/backend/feu/fpu/rapt_fpu_compare.sv \
		$(ROOT)/rtl/backend/feu/fpu/rapt_fpu_classify.sv \
		$(ROOT)/rtl/backend/feu/fpu/rapt_fpu_sgnj.sv misc_tb.sv -o tb
	./obj_dir/tb

clean:
	rm -rf obj_dir
