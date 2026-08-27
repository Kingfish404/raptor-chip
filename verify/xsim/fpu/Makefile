ADDSUB_N ?= 200000
MUL_N ?= 200000
FMA_N ?= 200000
CONVERT_N ?= 200000
INT_TO_FP_N ?= 200000
FP_TO_INT_N ?= 200000
DIVSQRT_N ?= 300000

.PHONY: all addsub mul fma convert int_to_fp fp_to_int misc divsqrt clean

all: addsub mul fma convert int_to_fp fp_to_int misc divsqrt

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