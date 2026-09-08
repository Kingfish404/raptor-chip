# Differential unit test for pipelined single/double format conversions.
# Usage:  make -C verify/xsim/fpu/convert run [N=200000]

ROOT     := ../../../..
HDL_INC  := $(ROOT)/hdl/include
CONFIG   := $(ROOT)/hdl/configs/small
DUTS     := $(ROOT)/hdl/backend/feu/fpu/rapt_fpu_convert_widen.sv \
            $(ROOT)/hdl/backend/feu/fpu/rapt_fpu_convert_narrow.sv
N        ?= 200000

VERILATOR ?= verilator
VFLAGS := --cc --exe --build -Wno-fatal -Wno-lint -Wno-WIDTH \
          -CFLAGS -frounding-math -I$(HDL_INC) -I$(CONFIG) \
          --top-module rapt_fpu_convert_tb

obj_dir/tb: $(DUTS) rapt_fpu_convert_tb.sv tb_host_diff.cpp
	+$(VERILATOR) $(VFLAGS) $(DUTS) rapt_fpu_convert_tb.sv tb_host_diff.cpp -o tb

run: obj_dir/tb
	N=$(N) obj_dir/tb

clean:
	rm -rf obj_dir

.PHONY: run clean

.PHONY: run-widen-box
run-widen-box:
	+$(VERILATOR) --cc --exe --build -j 2 --assert -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
		--top-module rapt_fpu_convert_widen -I$(ROOT)/hdl/include -I$(ROOT)/hdl/configs/default \
		$(ROOT)/hdl/backend/feu/fpu/rapt_fpu_convert_widen.sv tb_widen_box.cpp --Mdir obj_widen_box -o tb
	./obj_widen_box/tb
