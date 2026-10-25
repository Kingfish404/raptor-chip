ROOT := ../../..
XLEN ?= 64
BUILD_DIR ?= $(ROOT)/verify/build/fd_decode
DECODE_OBJ_DIR := $(BUILD_DIR)/obj$(XLEN)
COMPRESSED_OBJ_DIR := $(BUILD_DIR)/obj_compressed$(XLEN)
.PHONY: run-rv32 run-rv64 run
run-rv32:
	$(MAKE) run XLEN=32
run-rv64:
	$(MAKE) run XLEN=64
run:
	@mkdir -p "$(DECODE_OBJ_DIR)"
	+verilator --binary --timing --assert -j 2 -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-ASCRANGE -Wno-UNSIGNED \
		--top-module tb_fd_decode_slot $(if $(filter 64,$(XLEN)),-DRAPT_RV64,) \
		-I$(ROOT)/hdl/include -I$(ROOT)/hdl/configs/default \
		$(ROOT)/hdl/rapt_pkg.sv $(ROOT)/hdl/frontend/rapt_decode_slot.sv \
		$(ROOT)/hdl/generated/rapt_idu_decoder.sv $(ROOT)/hdl/generated/rapt_idu_decoder_c.sv \
		../tb_fd_decode_slot.sv --Mdir "$(DECODE_OBJ_DIR)" -o tb
	"$(DECODE_OBJ_DIR)/tb"

.PHONY: compressed-rv32 compressed-rv64 compressed
compressed-rv32:
	$(MAKE) compressed XLEN=32
compressed-rv64:
	$(MAKE) compressed XLEN=64
compressed:
	@mkdir -p "$(COMPRESSED_OBJ_DIR)"
	+verilator --binary --timing --assert -j 2 -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-ASCRANGE -Wno-UNSIGNED \
		--top-module tb_fp_compressed_slot $(if $(filter 64,$(XLEN)),-DRAPT_RV64,) \
		-I$(ROOT)/hdl/include -I$(ROOT)/hdl/configs/default \
		$(ROOT)/hdl/rapt_pkg.sv $(ROOT)/hdl/frontend/rapt_decode_slot.sv \
		$(ROOT)/hdl/generated/rapt_idu_decoder.sv $(ROOT)/hdl/generated/rapt_idu_decoder_c.sv \
		../tb_fp_compressed_slot.sv --Mdir "$(COMPRESSED_OBJ_DIR)" -o tb
	"$(COMPRESSED_OBJ_DIR)/tb"
