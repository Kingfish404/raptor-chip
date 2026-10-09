ROOT := ../../..
XLEN ?= 64
.PHONY: run-rv32 run-rv64 run
run-rv32:
	$(MAKE) run XLEN=32
run-rv64:
	$(MAKE) run XLEN=64
run:
	+verilator --binary --timing --assert -j 2 -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-ASCRANGE -Wno-UNSIGNED \
		--top-module tb_fd_decode_slot $(if $(filter 64,$(XLEN)),-DRAPT_RV64,) \
		-I$(ROOT)/hdl/include -I$(ROOT)/hdl/configs/default \
		$(ROOT)/hdl/rapt_pkg.sv $(ROOT)/hdl/frontend/rapt_decode_slot.sv \
		$(ROOT)/hdl/generated/rapt_idu_decoder.sv $(ROOT)/hdl/generated/rapt_idu_decoder_c.sv \
		../tb_fd_decode_slot.sv --Mdir obj$(XLEN) -o tb
	./obj$(XLEN)/tb

.PHONY: compressed-rv32 compressed-rv64 compressed
compressed-rv32:
	$(MAKE) compressed XLEN=32
compressed-rv64:
	$(MAKE) compressed XLEN=64
compressed:
	+verilator --binary --timing --assert -j 2 -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-ASCRANGE -Wno-UNSIGNED \
		--top-module tb_fp_compressed_slot $(if $(filter 64,$(XLEN)),-DRAPT_RV64,) \
		-I$(ROOT)/hdl/include -I$(ROOT)/hdl/configs/default \
		$(ROOT)/hdl/rapt_pkg.sv $(ROOT)/hdl/frontend/rapt_decode_slot.sv \
		$(ROOT)/hdl/generated/rapt_idu_decoder.sv $(ROOT)/hdl/generated/rapt_idu_decoder_c.sv \
		../tb_fp_compressed_slot.sv --Mdir obj_compressed$(XLEN) -o tb
	./obj_compressed$(XLEN)/tb
