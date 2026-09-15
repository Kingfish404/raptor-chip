ADDSUB_N ?= 200000
MUL_N ?= 200000
FMA_N ?= 200000
CONVERT_N ?= 200000
INT_TO_FP_N ?= 200000
FP_TO_INT_N ?= 200000
DIVSQRT_N ?= 300000

RESET_BUILD_DIR ?= $(CURDIR)/obj_result_reset
RESET_XLEN ?= 64
.PHONY: result-reset-rv32 result-reset-rv64 result-reset
result-reset-rv32:
	$(MAKE) result-reset RESET_XLEN=32
result-reset-rv64:
	$(MAKE) result-reset RESET_XLEN=64
result-reset:
	mkdir -p $(RESET_BUILD_DIR)/rv$(RESET_XLEN)
	verilator --binary --timing --assert -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC \
		-I../../../hdl/include -I../../../hdl/configs/default \
		$(if $(filter 64,$(RESET_XLEN)),-DRAPT_RV64) \
		--top-module tb_fpu_result_reset \
		$(addprefix ../../../hdl/backend/feu/fpu/rapt_fpu_,$(addsuffix .sv,addsub mul fma convert_narrow convert_widen int_to_fp single_to_int_w fp_to_half half_to_fp)) \
		tb_result_reset.sv --Mdir $(RESET_BUILD_DIR)/rv$(RESET_XLEN) -j 2 -o test
	$(RESET_BUILD_DIR)/rv$(RESET_XLEN)/test

.PHONY: all addsub mul fma convert int_to_fp fp_to_int half misc divsqrt clean

all: addsub mul fma convert int_to_fp fp_to_int half misc divsqrt

half:
	$(MAKE) -C half run

addsub:
	$(MAKE) -C addsub run N=$(ADDSUB_N)

mul:
	$(MAKE) -C mul run N=$(MUL_N)

fma:
	$(MAKE) -C fma run N=$(FMA_N)

convert:
	$(MAKE) -C convert run N=$(CONVERT_N)

int_to_fp:
	$(MAKE) -C int_to_fp run N=$(INT_TO_FP_N)

fp_to_int:
	$(MAKE) -C fp_to_int run N=$(FP_TO_INT_N)

misc:
	$(MAKE) -C misc run

divsqrt:
	$(MAKE) -C divsqrt run N=$(DIVSQRT_N)

clean:
	$(MAKE) -C addsub clean
	$(MAKE) -C mul clean
	$(MAKE) -C fma clean
	$(MAKE) -C convert clean
	$(MAKE) -C int_to_fp clean
	$(MAKE) -C fp_to_int clean
	$(MAKE) -C misc clean
	$(MAKE) -C divsqrt clean
	$(MAKE) -C half clean
