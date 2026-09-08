ROOT := ../../..
XLEN ?= 64
.PHONY: run-rv32 run-rv64 run
run-rv32: XLEN=32
run-rv32: run
run-rv64: XLEN=64
run-rv64: run
run:
	+verilator --binary --timing --assert -j 2 -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-ASCRANGE -Wno-UNSIGNED \
		--top-module tb_fd_decode_slot $(if $(filter 64,$(XLEN)),-DRAPT_RV64,) \
		-I$(ROOT)/hdl/include -I$(ROOT)/hdl/configs/default \
		$(ROOT)/hdl/rapt_pkg.sv $(ROOT)/hdl/frontend/rapt_decode_slot.sv \
		$(ROOT)/hdl/generated/rapt_idu_decoder.sv $(ROOT)/hdl/generated/rapt_idu_decoder_c.sv \
		../tb_fd_decode_slot.sv --Mdir obj$(XLEN) -o tb
	./obj$(XLEN)/tb

.PHONY: compressed-rv32 compressed-rv64 compressed
compressed-rv32: XLEN=32
compressed-rv32: compressed
compressed-rv64: XLEN=64
compressed-rv64: compressed
compressed:
	+verilator --binary --timing --assert -j 2 -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-ASCRANGE -Wno-UNSIGNED \
		--top-module tb_fp_compressed_slot $(if $(filter 64,$(XLEN)),-DRAPT_RV64,) \
		-I$(ROOT)/hdl/include -I$(ROOT)/hdl/configs/default \
		$(ROOT)/hdl/rapt_pkg.sv $(ROOT)/hdl/frontend/rapt_decode_slot.sv \
		$(ROOT)/hdl/generated/rapt_idu_decoder.sv $(ROOT)/hdl/generated/rapt_idu_decoder_c.sv \
		../tb_fp_compressed_slot.sv --Mdir obj_compressed$(XLEN) -o tb
	./obj_compressed$(XLEN)/tb
