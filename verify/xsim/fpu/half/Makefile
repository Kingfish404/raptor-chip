ROOT := $(abspath ../../../..)
VERILATOR ?= verilator
BUILD_DIR ?= $(CURDIR)/obj_dir
XLEN ?= 64
SOFTFLOAT_DIR ?=
DUTS := $(ROOT)/hdl/backend/feu/fpu/rapt_fpu_half_to_fp.sv \
	$(ROOT)/hdl/backend/feu/fpu/rapt_fpu_fp_to_half.sv
VFLAGS := --cc --exe --build --timing -Wall -Wno-fatal \
	-I$(ROOT)/hdl/include -I$(ROOT)/hdl/configs/default \
	$(if $(filter 64,$(XLEN)),-DRAPT_RV64) \
	--top-module rapt_fpu_half_tb

.PHONY: run clean
run: $(BUILD_DIR)/tb
	$(BUILD_DIR)/tb

$(BUILD_DIR)/tb: $(DUTS) rapt_fpu_half_tb.sv tb_main.cpp
	mkdir -p $(BUILD_DIR)
	+$(VERILATOR) $(VFLAGS) $(DUTS) rapt_fpu_half_tb.sv tb_main.cpp --Mdir $(BUILD_DIR) -o tb

.PHONY: flush run-softfloat
flush:
	mkdir -p $(BUILD_DIR)/flush
	$(VERILATOR) --binary --timing --assert -Wall -Wno-DECLFILENAME \
		-I$(ROOT)/hdl/include -I$(ROOT)/hdl/configs/default \
		$(if $(filter 64,$(XLEN)),-DRAPT_RV64) \
		--top-module tb_half_flush $(DUTS) tb_flush.sv \
		--Mdir $(BUILD_DIR)/flush -o test
	$(BUILD_DIR)/flush/test

# Same reference layout as the int_to_fp and fp_to_int component targets.
run-softfloat:
	@test -f "$(SOFTFLOAT_DIR)/include/softfloat.h" -a -f "$(SOFTFLOAT_DIR)/softfloat.a"
	mkdir -p $(BUILD_DIR)/softfloat
	$(VERILATOR) --cc --exe --build -Wall \
		-I$(ROOT)/hdl/include -I$(ROOT)/hdl/configs/default \
		$(if $(filter 64,$(XLEN)),-DRAPT_RV64) \
		--top-module rapt_fpu_fp_to_half $(word 2,$(DUTS)) tb_softfloat.cpp \
		--Mdir $(BUILD_DIR)/softfloat -CFLAGS "-I$(abspath $(SOFTFLOAT_DIR))/include" \
		-LDFLAGS "$(abspath $(SOFTFLOAT_DIR))/softfloat.a" -o test
	$(BUILD_DIR)/softfloat/test

clean:
	rm -rf obj_dir
