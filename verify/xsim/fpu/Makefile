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

COMPONENTS := addsub mul fma convert int_to_fp fp_to_int half misc divsqrt
.PHONY: all $(COMPONENTS) clean
all: $(COMPONENTS)

addsub: N = $(ADDSUB_N)
mul: N = $(MUL_N)
fma: N = $(FMA_N)
convert: N = $(CONVERT_N)
int_to_fp: N = $(INT_TO_FP_N)
fp_to_int: N = $(FP_TO_INT_N)
divsqrt: N = $(DIVSQRT_N)
$(COMPONENTS):
	$(MAKE) -C $@ run $(if $(N),N=$(N))

CLEAN_TARGETS := $(addprefix clean-,$(COMPONENTS))
.PHONY: $(CLEAN_TARGETS)
clean: $(CLEAN_TARGETS)
$(CLEAN_TARGETS):
	$(MAKE) -C $(patsubst clean-%,%,$@) clean
