# Standalone VPU verification. No sim/.config, generated scalar decoder, or
# root Makefile is loaded. All outputs are isolated under verification/build/vpu.
SHELL := /bin/bash
.SHELLFLAGS := -e -o pipefail -c
ROOT := $(abspath ../..)
BUILD_DIR ?= $(ROOT)/verification/build/vpu
FORMAL_RESULTS_DIR ?= $(or $(TMPDIR),/tmp)/raptor-vpu-formal
VERILATOR ?= verilator
JOBS ?= 2
XLEN ?= 64
VLEN ?= 128
ELEN ?= 64
BANK_BITS ?= 64
BANKS ?= 2
TAG_BITS ?= 4
CORE_ADAPTER ?= 0
OPT_READS ?= 1
CACHE_PREDICATE ?= 1
SHARE_INT_FP ?= 1
REDUCE_MASK_CACHE ?= 1
MULDIV_EARLY_OUT ?= 1
SPIKE_BUILD ?=
DIFF ?= 0
TOP_SUITE ?= full
MATRIX_SHARDS ?= 16
MATRIX_SEED ?= 0x243f6a8885a308d3
MATRIX_POLICY ?= 0
GEOMETRY_SHARDS ?= 32
TOP_SUITES := full fp-mixed fp-divsqrt fp-misc fp-wide fp-convert int-fp estimate transfer \
  fp-reduce encoding config-encoding memory-encoding geometry geometry-overlap catalog \
  catalog-matrix indexed-geometry context \
  store-completion \
  predicate-cache predicate-semantics packed-logic memory move zvkt
ifeq ($(filter $(TOP_SUITE),$(TOP_SUITES)),)
$(error unsupported TOP_SUITE=$(TOP_SUITE))
endif
DIFF_FLAGS :=
ifeq ($(DIFF),1)
ifeq ($(strip $(SPIKE_BUILD)),)
$(error DIFF=1 requires SPIKE_BUILD pointing to a separately built Spike source/build tree)
endif
DIFF_FLAGS := -CFLAGS '-DVPU_SPIKE -I$(SPIKE_BUILD) -I$(SPIKE_BUILD)/riscv -I$(SPIKE_BUILD)/fesvr -I$(SPIKE_BUILD)/softfloat' \
  -LDFLAGS '-Wl,--start-group $(SPIKE_BUILD)/libriscv.a $(SPIKE_BUILD)/libdisasm.a $(SPIKE_BUILD)/libsoftfloat.a $(SPIKE_BUILD)/libfesvr.a $(SPIKE_BUILD)/libfdt.a -Wl,--end-group -lboost_regex -lboost_system -ldl'
endif
VPU_INCLUDES := -I$(ROOT)/rtl/include -I$(ROOT)/rtl/configs/default
TOP_EXTENSION_FLAGS := $(if $(filter zvkt,$(TOP_SUITE)),-GZvkt=1 -GZvbb=1,)
FLAGS := --binary --timing --assert -Wall -DRAPT_ASSERT_EN $(VPU_INCLUDES) -j $(JOBS)
VPU := $(ROOT)/rtl/core/backend/vpu
# Generate this narrow warning policy from tracked code in each build folder.
define write_fma_waiver
python3 $(CURDIR)/export_rtl.py --write-fma-waiver $(1)/fma_legacy.vlt
endef
VPU_FORMAT_CONVERTERS := convert_narrow half_to_fp fp_to_half
VPU_SCALAR_FPU := fma divsqrt $(VPU_FORMAT_CONVERTERS) int_to_fp integer_to_fp single_to_int_w fp_to_int
VPU_TOP_SOURCES := $(ROOT)/rtl/rapt_pkg.sv $(ROOT)/rtl/sram/rapt_sram_1rw.sv \
  $(addprefix $(ROOT)/rtl/core/backend/fpu/rapt_fpu_,$(addsuffix .sv,$(VPU_SCALAR_FPU))) \
  $(wildcard $(VPU)/*.sv) $(CURDIR)/test_vpu.cpp
TYPE_BUILD := $(BUILD_DIR)/vtype-$(XLEN)-$(VLEN)-$(ELEN)
VRF_BUILD := $(BUILD_DIR)/vrf-$(VLEN)-$(BANK_BITS)-$(BANKS)
CSR_BUILD := $(BUILD_DIR)/csr-$(XLEN)-$(VLEN)-$(ELEN)
TOP_PREFIX := $(BUILD_DIR)/$(if $(filter 1,$(CORE_ADAPTER)),core-top,top)
TOP_MODULE := $(if $(filter 1,$(CORE_ADAPTER)),rapt_vpu_core,rapt_vpu)
TOP_CONFIG := $(XLEN)-$(VLEN)-$(ELEN)-$(BANK_BITS)-$(BANKS)-opt$(OPT_READS)
TOP_BUILD := $(TOP_PREFIX)-$(TOP_CONFIG)$(if $(filter 0,$(CACHE_PREDICATE)),-pred0,)
TOP_BUILD := $(TOP_BUILD)$(if $(filter 0,$(SHARE_INT_FP)),-unshared,)
TOP_BUILD := $(TOP_BUILD)$(if $(filter 1,$(DIFF)),-spike,)
TOP_BUILD := $(TOP_BUILD)$(if $(filter-out full,$(TOP_SUITE)),-$(TOP_SUITE),)
OWNER_BUILD := $(BUILD_DIR)/owner-$(TAG_BITS)
PREDICATE_PREFIX := $(TOP_PREFIX)-$(TOP_CONFIG)
PREDICATE_SUFFIX := $(if $(filter 0,$(SHARE_INT_FP)),-unshared,)
PREDICATE_SUFFIX := $(PREDICATE_SUFFIX)$(if $(filter 1,$(DIFF)),-spike,)-predicate-cache
CONVERT_PREFIX := $(PREDICATE_PREFIX)$(if $(filter 0,$(CACHE_PREDICATE)),-pred0,)
CONVERT_SUFFIX := $(if $(filter 1,$(DIFF)),-spike,)-int-fp
OPT_PREFIX := $(TOP_PREFIX)-$(XLEN)-$(VLEN)-$(ELEN)-$(BANK_BITS)-$(BANKS)
OPT_SUFFIX := $(if $(filter 0,$(CACHE_PREDICATE)),-pred0,)
OPT_SUFFIX := $(OPT_SUFFIX)$(if $(filter 0,$(SHARE_INT_FP)),-unshared,)
OPT_SUFFIX := $(OPT_SUFFIX)$(if $(filter 1,$(DIFF)),-spike,)

.PHONY: test leaves vtype vrf csr top top-build owner matrix top-matrix opt-check synth
test: leaves core-adapter owner muldiv mask-write fixed move mask-scan slide fp-decode int-fp-decode fp-reduce-control fp-reduce-decode fp-reduce-engine top
leaves: vtype vrf csr

vtype:
	@mkdir -p $(TYPE_BUILD)
	$(VERILATOR) $(FLAGS) --top-module tb_vpu_vtype --Mdir $(TYPE_BUILD) \
	  -GXLEN=$(XLEN) -GVLEN=$(VLEN) -GELEN=$(ELEN) \
	  $(VPU)/rapt_vpu_vtype.sv $(CURDIR)/tb_vpu_vtype.sv >$(TYPE_BUILD)/build.log 2>&1 \
	  || { cat $(TYPE_BUILD)/build.log; exit 1; }
	$(TYPE_BUILD)/Vtb_vpu_vtype | tee $(TYPE_BUILD)/run.log

vrf:
	@mkdir -p $(VRF_BUILD)
	$(VERILATOR) $(FLAGS) --top-module tb_vpu_vrf --Mdir $(VRF_BUILD) \
	  -GVLEN=$(VLEN) -GBankBits=$(BANK_BITS) -GBanks=$(BANKS) \
	  $(ROOT)/rtl/rapt_pkg.sv $(ROOT)/rtl/sram/rapt_sram_1rw.sv $(VPU)/rapt_vpu_vrf.sv \
	  $(CURDIR)/tb_vpu_vrf.sv >$(VRF_BUILD)/build.log 2>&1 \
	  || { cat $(VRF_BUILD)/build.log; exit 1; }
	$(VRF_BUILD)/Vtb_vpu_vrf | tee $(VRF_BUILD)/run.log

csr:
	@mkdir -p $(CSR_BUILD)
	$(VERILATOR) $(FLAGS) --top-module tb_vpu_csr --Mdir $(CSR_BUILD) \
	  -GXLEN=$(XLEN) -GVLEN=$(VLEN) -GELEN=$(ELEN) \
	  $(VPU)/rapt_vpu_vtype.sv $(VPU)/rapt_vpu_csr.sv \
	  $(CURDIR)/tb_vpu_csr.sv >$(CSR_BUILD)/build.log 2>&1 \
	  || { cat $(CSR_BUILD)/build.log; exit 1; }
	$(CSR_BUILD)/Vtb_vpu_csr | tee $(CSR_BUILD)/run.log

matrix:
	$(MAKE) leaves XLEN=64 VLEN=128 ELEN=64 BANK_BITS=64 BANKS=2
	$(MAKE) leaves XLEN=32 VLEN=128 ELEN=64 BANK_BITS=64 BANKS=2
	$(MAKE) leaves XLEN=32 VLEN=256 ELEN=64 BANK_BITS=32 BANKS=4
	$(MAKE) leaves XLEN=32 VLEN=128 ELEN=32 BANK_BITS=64 BANKS=1
	$(MAKE) leaves XLEN=64 VLEN=512 ELEN=64 BANK_BITS=128 BANKS=4
	$(MAKE) vtype XLEN=32 VLEN=65536 ELEN=64

synth:
	python3 $(CURDIR)/synth_check.py --build-dir $(BUILD_DIR)/synth

top-build:
	@mkdir -p $(TOP_BUILD)
	$(call write_fma_waiver,$(TOP_BUILD))
	python3 $(CURDIR)/record_run.py top $(TOP_BUILD)/sources.json $(XLEN) $(VLEN) $(ELEN) \
		$(BANK_BITS) $(BANKS) $(OPT_READS) $(CACHE_PREDICATE) $(SHARE_INT_FP) \
		$(DIFF) $(CORE_ADAPTER) $(TOP_SUITE)
ifeq ($(DIFF),1)
	python3 $(CURDIR)/reference_manifest.py $(SPIKE_BUILD) $(TOP_BUILD)/reference.json
endif
	$(VERILATOR) --cc --exe --build --assert -Wall -Wno-PINCONNECTEMPTY -DRAPT_ASSERT_EN \
	  $(VPU_INCLUDES) -j $(JOBS) \
	  $(TOP_BUILD)/fma_legacy.vlt --top-module $(TOP_MODULE) \
	  --prefix Vrapt_vpu --Mdir $(TOP_BUILD) \
	  -GXLEN=$(XLEN) -GVLEN=$(VLEN) -GELEN=$(ELEN) -GBankBits=$(BANK_BITS) -GBanks=$(BANKS) \
	  -GOptimizeOperandReads=$(OPT_READS) \
	  -GCachePredicate=$(CACHE_PREDICATE) \
	  -GShareIntFpConverters=$(SHARE_INT_FP) \
	  $(TOP_EXTENSION_FLAGS) \
	  -CFLAGS '-DTEST_XLEN=$(XLEN) -DTEST_VLEN=$(VLEN) -DTEST_ELEN=$(ELEN) -DTEST_OPT_READS=$(OPT_READS) -DTEST_CORE_ADAPTER=$(CORE_ADAPTER)' \
	  $(DIFF_FLAGS) \
	  $(VPU_TOP_SOURCES) \
	  >$(TOP_BUILD)/build.log 2>&1 || { cat $(TOP_BUILD)/build.log; exit 1; }

top: top-build
	$(TOP_BUILD)/Vrapt_vpu $(if $(filter-out full,$(TOP_SUITE)),--$(TOP_SUITE),) | tee $(TOP_BUILD)/run.log

.PHONY: catalog-matrix
catalog-matrix: top-build
	@test "$(TOP_SUITE)" = catalog-matrix && test "$(DIFF)" = 1 \
	  && test "$(CORE_ADAPTER)" = 1 && test "$(MATRIX_SHARDS)" -gt 0 \
	  || { echo 'catalog-matrix requires TOP_SUITE=catalog-matrix DIFF=1 CORE_ADAPTER=1'; exit 1; }
	@set -e; for ((shard=0; shard<$(MATRIX_SHARDS); shard++)); do \
	  printf -v shard_id '%02d' "$$shard"; \
	  log="$(TOP_BUILD)/matrix-shard-$$shard_id.log"; \
	  VPU_MATRIX_SHARDS=$(MATRIX_SHARDS) VPU_MATRIX_SHARD=$$shard \
	    VPU_MATRIX_SEED=$(MATRIX_SEED) VPU_MATRIX_POLICY=$(MATRIX_POLICY) \
	    "$(TOP_BUILD)/Vrapt_vpu" --catalog-matrix >"$$log" 2>&1 \
	    || { cat "$$log"; exit 1; }; \
	  tail -n 1 "$$log"; \
	done
	python3 $(CURDIR)/check_catalog.py --matrix $(TOP_BUILD)

.PHONY: indexed-geometry
indexed-geometry: top-build
	@test "$(TOP_SUITE)" = indexed-geometry && test "$(DIFF)" = 1 \
	  && test "$(CORE_ADAPTER)" = 1 && test "$(GEOMETRY_SHARDS)" -ge 1 \
	  && test "$(GEOMETRY_SHARDS)" -le 32 \
	  || { echo 'indexed-geometry requires DIFF=1 CORE_ADAPTER=1 and 1-32 shards'; exit 1; }
	@set -e; for ((shard=0; shard<$(GEOMETRY_SHARDS); shard++)); do \
	  printf -v shard_id '%02d' "$$shard"; \
	  log="$(TOP_BUILD)/indexed-geometry-shard-$$shard_id.log"; \
	  VPU_GEOMETRY_SHARDS=$(GEOMETRY_SHARDS) VPU_GEOMETRY_SHARD=$$shard \
	    "$(TOP_BUILD)/Vrapt_vpu" --indexed-geometry >"$$log" 2>&1 \
	    || { cat "$$log"; exit 1; }; \
	  tail -n 1 "$$log"; \
	done
	python3 $(CURDIR)/check_catalog.py --indexed-geometry $(TOP_BUILD)

owner:
	@mkdir -p $(OWNER_BUILD)
	$(VERILATOR) $(FLAGS) --top-module tb_vpu_owner --Mdir $(OWNER_BUILD) -GTagBits=$(TAG_BITS) \
	  $(VPU)/rapt_vpu_owner.sv $(CURDIR)/tb_vpu_owner.sv >$(OWNER_BUILD)/build.log 2>&1 \
	  || { cat $(OWNER_BUILD)/build.log; exit 1; }
	$(OWNER_BUILD)/Vtb_vpu_owner | tee $(OWNER_BUILD)/run.log

top-matrix:
	$(MAKE) owner TAG_BITS=1
	$(MAKE) owner TAG_BITS=10
	$(MAKE) top XLEN=64 VLEN=128 ELEN=64 BANK_BITS=64 BANKS=2
	$(MAKE) top XLEN=32 VLEN=128 ELEN=64 BANK_BITS=64 BANKS=2
	$(MAKE) top XLEN=32 VLEN=256 ELEN=64 BANK_BITS=64 BANKS=4
	$(MAKE) top XLEN=32 VLEN=128 ELEN=32 BANK_BITS=64 BANKS=1
	$(MAKE) top XLEN=64 VLEN=512 ELEN=64 BANK_BITS=128 BANKS=4

opt-check:
	@test "$(TOP_SUITE)" = full || { echo "opt-check requires TOP_SUITE=full"; exit 1; }
	$(MAKE) top OPT_READS=0
	$(MAKE) top OPT_READS=1
	python3 $(CURDIR)/compare_optimization.py \
	  $(OPT_PREFIX)-opt0$(OPT_SUFFIX) $(OPT_PREFIX)-opt1$(OPT_SUFFIX) \
	  $(BUILD_DIR)/optimization-$(XLEN)-$(VLEN)-$(ELEN)-$(BANK_BITS)-$(BANKS)$(if $(filter 1,$(DIFF)),-spike,).json

.PHONY: predicate-cache-check
predicate-cache-check:
	$(MAKE) top TOP_SUITE=predicate-cache CACHE_PREDICATE=0
	$(MAKE) top TOP_SUITE=predicate-cache CACHE_PREDICATE=1
	python3 $(CURDIR)/compare_optimization.py --kind predicate-cache \
	  $(PREDICATE_PREFIX)-pred0$(PREDICATE_SUFFIX) $(PREDICATE_PREFIX)$(PREDICATE_SUFFIX) \
	  $(BUILD_DIR)/predicate-cache-$(XLEN)-$(VLEN)-$(ELEN)-$(BANK_BITS)-$(BANKS).json

.PHONY: int-fp-share-check
int-fp-share-check:
	$(MAKE) top TOP_SUITE=int-fp SHARE_INT_FP=0
	$(MAKE) top TOP_SUITE=int-fp SHARE_INT_FP=1
	python3 $(CURDIR)/compare_optimization.py --kind int-fp-sharing \
	  $(CONVERT_PREFIX)-unshared$(CONVERT_SUFFIX) $(CONVERT_PREFIX)$(CONVERT_SUFFIX) \
	  $(BUILD_DIR)/int-fp-sharing-$(XLEN)-$(VLEN)-$(ELEN)-$(BANK_BITS)-$(BANKS).json

.PHONY: muldiv
muldiv:
	@mkdir -p $(BUILD_DIR)/muldiv-$(MULDIV_EARLY_OUT)
	python3 $(CURDIR)/record_run.py leaf $(BUILD_DIR)/muldiv-$(MULDIV_EARLY_OUT)/sources.json \
		rapt_vpu_muldiv EarlyOut=$(MULDIV_EARLY_OUT)
	$(VERILATOR) --cc --exe --build --assert -Wall -DRAPT_ASSERT_EN -I$(ROOT)/rtl/include -j $(JOBS) \
	  --top-module rapt_vpu_muldiv -GEarlyOut=$(MULDIV_EARLY_OUT) --Mdir $(BUILD_DIR)/muldiv-$(MULDIV_EARLY_OUT) \
	  $(VPU)/rapt_vpu_muldiv.sv $(CURDIR)/test_muldiv.cpp \
	  >$(BUILD_DIR)/muldiv-$(MULDIV_EARLY_OUT)/build.log 2>&1 || { cat $(BUILD_DIR)/muldiv-$(MULDIV_EARLY_OUT)/build.log; exit 1; }
	$(BUILD_DIR)/muldiv-$(MULDIV_EARLY_OUT)/Vrapt_vpu_muldiv | tee $(BUILD_DIR)/muldiv-$(MULDIV_EARLY_OUT)/run.log

.PHONY: muldiv-opt-check
muldiv-opt-check:
	$(MAKE) muldiv MULDIV_EARLY_OUT=0
	$(MAKE) muldiv MULDIV_EARLY_OUT=1
	python3 $(CURDIR)/compare_optimization.py --kind muldiv \
	  $(BUILD_DIR)/muldiv-0 $(BUILD_DIR)/muldiv-1 $(BUILD_DIR)/muldiv-optimization.json

.PHONY: fp-reduce-cache-check
fp-reduce-cache-check:
	@for config in '64 128 64' '32 128 32' '32 256 64' '64 512 64'; do \
	  read -r test_xlen test_vlen test_elen <<< "$$config"; \
	  for cache in 0 1; do \
	    $(MAKE) fp-reduce-engine XLEN=$$test_xlen VLEN=$$test_vlen ELEN=$$test_elen \
	      REDUCE_MASK_CACHE=$$cache; \
	  done; \
	done
	python3 $(CURDIR)/compare_optimization.py --kind fp-reduce-cache-matrix \
	  --build-dir $(BUILD_DIR) >$(BUILD_DIR)/fp-reduce-cache-matrix.json
	@echo 'PASS fp-reduce-cache matrix: $(BUILD_DIR)/fp-reduce-cache-matrix.json'

.PHONY: mask-write
mask-write:
	@mkdir -p $(BUILD_DIR)/mask-write
	python3 $(CURDIR)/record_run.py leaf $(BUILD_DIR)/mask-write/sources.json \
		rapt_vpu_mask_write AddrBits=9
	$(VERILATOR) --cc --exe --build --assert -Wall -DRAPT_ASSERT_EN -I$(ROOT)/rtl/include -j $(JOBS) \
	  --top-module rapt_vpu_mask_write --Mdir $(BUILD_DIR)/mask-write \
	  $(VPU)/rapt_vpu_mask_write.sv $(CURDIR)/test_mask_write.cpp \
	  >$(BUILD_DIR)/mask-write/build.log 2>&1 || { cat $(BUILD_DIR)/mask-write/build.log; exit 1; }
	$(BUILD_DIR)/mask-write/Vrapt_vpu_mask_write | tee $(BUILD_DIR)/mask-write/run.log

.PHONY: fixed
fixed:
	@mkdir -p $(BUILD_DIR)/fixed
	python3 $(CURDIR)/record_run.py leaf $(BUILD_DIR)/fixed/sources.json rapt_vpu_fixed
	$(VERILATOR) --cc --exe --build --assert -Wall -DRAPT_ASSERT_EN -I$(ROOT)/rtl/include -j $(JOBS) \
	  --top-module rapt_vpu_fixed --Mdir $(BUILD_DIR)/fixed \
	  $(VPU)/rapt_vpu_fixed.sv $(CURDIR)/test_fixed.cpp \
	  >$(BUILD_DIR)/fixed/build.log 2>&1 || { cat $(BUILD_DIR)/fixed/build.log; exit 1; }
	$(BUILD_DIR)/fixed/Vrapt_vpu_fixed | tee $(BUILD_DIR)/fixed/run.log

.PHONY: move
move:
	@mkdir -p $(BUILD_DIR)/move-$(VLEN)
	python3 $(CURDIR)/record_run.py leaf $(BUILD_DIR)/move-$(VLEN)/sources.json rapt_vpu_move \
		VLEN=$(VLEN)
	$(VERILATOR) --cc --exe --build --assert -Wall -DRAPT_ASSERT_EN -I$(ROOT)/rtl/include -j $(JOBS) \
	  --top-module rapt_vpu_move -GVLEN=$(VLEN) --Mdir $(BUILD_DIR)/move-$(VLEN) \
	  -CFLAGS '-DTEST_VLEN=$(VLEN)' $(VPU)/rapt_vpu_move.sv $(CURDIR)/test_move.cpp \
	  >$(BUILD_DIR)/move-$(VLEN)/build.log 2>&1 || { cat $(BUILD_DIR)/move-$(VLEN)/build.log; exit 1; }
	$(BUILD_DIR)/move-$(VLEN)/Vrapt_vpu_move | tee $(BUILD_DIR)/move-$(VLEN)/run.log

.PHONY: mask-scan
mask-scan:
	@mkdir -p $(BUILD_DIR)/mask-scan-$(XLEN)-$(VLEN)
	python3 $(CURDIR)/record_run.py leaf $(BUILD_DIR)/mask-scan-$(XLEN)-$(VLEN)/sources.json \
		rapt_vpu_mask_scan XLEN=$(XLEN) VLEN=$(VLEN)
	$(VERILATOR) --cc --exe --build --assert -Wall -DRAPT_ASSERT_EN -I$(ROOT)/rtl/include -j $(JOBS) \
	  --top-module rapt_vpu_mask_scan -GXLEN=$(XLEN) -GVLEN=$(VLEN) --Mdir $(BUILD_DIR)/mask-scan-$(XLEN)-$(VLEN) \
	  -CFLAGS '-DTEST_XLEN=$(XLEN) -DTEST_VLEN=$(VLEN)' $(VPU)/rapt_vpu_mask_scan.sv $(CURDIR)/test_mask_scan.cpp \
	  >$(BUILD_DIR)/mask-scan-$(XLEN)-$(VLEN)/build.log 2>&1 || { cat $(BUILD_DIR)/mask-scan-$(XLEN)-$(VLEN)/build.log; exit 1; }
	$(BUILD_DIR)/mask-scan-$(XLEN)-$(VLEN)/Vrapt_vpu_mask_scan | tee $(BUILD_DIR)/mask-scan-$(XLEN)-$(VLEN)/run.log

.PHONY: owner-formal
owner-formal:
	python3 $(CURDIR)/owner_formal.py --build-dir $(BUILD_DIR)/formal-owner

.PHONY: memory-response-formal
memory-response-formal:
	python3 $(CURDIR)/memory_response_formal.py \
	  --build-dir $(FORMAL_RESULTS_DIR)/memory-response

.PHONY: slide
slide:
	@mkdir -p $(BUILD_DIR)/slide-$(XLEN)-$(VLEN)
	python3 $(CURDIR)/record_run.py leaf $(BUILD_DIR)/slide-$(XLEN)-$(VLEN)/sources.json \
		rapt_vpu_slide XLEN=$(XLEN) VLEN=$(VLEN)
	$(VERILATOR) --cc --exe --build --assert -Wall -j $(JOBS) \
	  --top-module rapt_vpu_slide -GXLEN=$(XLEN) -GVLEN=$(VLEN) --Mdir $(BUILD_DIR)/slide-$(XLEN)-$(VLEN) \
	  -CFLAGS '-DTEST_XLEN=$(XLEN) -DTEST_VLEN=$(VLEN)' $(VPU)/rapt_vpu_slide.sv $(CURDIR)/test_slide.cpp \
	  >$(BUILD_DIR)/slide-$(XLEN)-$(VLEN)/build.log 2>&1 || { cat $(BUILD_DIR)/slide-$(XLEN)-$(VLEN)/build.log; exit 1; }
	$(BUILD_DIR)/slide-$(XLEN)-$(VLEN)/Vrapt_vpu_slide | tee $(BUILD_DIR)/slide-$(XLEN)-$(VLEN)/run.log

FMA_DOUBLE ?= 1
FMA_BUILD := $(BUILD_DIR)/fma-$(FMA_DOUBLE)
.PHONY: fma
fma:
	@test -n "$(SPIKE_BUILD)" || { echo 'fma requires SPIKE_BUILD for independent SoftFloat'; exit 1; }
	@mkdir -p $(FMA_BUILD)
	$(call write_fma_waiver,$(FMA_BUILD))
	python3 $(CURDIR)/record_run.py leaf $(FMA_BUILD)/sources.json rapt_vpu_fma Double=$(FMA_DOUBLE)
	python3 $(CURDIR)/reference_manifest.py $(SPIKE_BUILD) $(FMA_BUILD)/reference.json
	$(VERILATOR) --cc --exe --build --assert -Wall -DRAPT_ASSERT_EN -I$(ROOT)/rtl/include -j $(JOBS) \
	  $(FMA_BUILD)/fma_legacy.vlt --top-module rapt_vpu_fma -GDouble=$(FMA_DOUBLE) --Mdir $(FMA_BUILD) \
	  -CFLAGS '-DTEST_DOUBLE=$(FMA_DOUBLE) -I$(SPIKE_BUILD)/softfloat' -LDFLAGS '$(SPIKE_BUILD)/libsoftfloat.a' \
	  $(ROOT)/rtl/core/backend/fpu/rapt_fpu_fma.sv $(VPU)/rapt_vpu_fma.sv $(CURDIR)/test_fma.cpp \
	  >$(FMA_BUILD)/build.log 2>&1 || { cat $(FMA_BUILD)/build.log; exit 1; }
	$(FMA_BUILD)/Vrapt_vpu_fma | tee $(FMA_BUILD)/run.log

FP_ARITH_BUILD := $(BUILD_DIR)/fp-arith-$(FMA_DOUBLE)
.PHONY: fp-arith
fp-arith:
	@test -n "$(SPIKE_BUILD)" || { echo 'fp-arith requires SPIKE_BUILD for independent SoftFloat'; exit 1; }
	@mkdir -p $(FP_ARITH_BUILD)
	$(call write_fma_waiver,$(FP_ARITH_BUILD))
	python3 $(CURDIR)/record_run.py leaf $(FP_ARITH_BUILD)/sources.json rapt_vpu_fp_arith \
		Double=$(FMA_DOUBLE)
	python3 $(CURDIR)/reference_manifest.py $(SPIKE_BUILD) $(FP_ARITH_BUILD)/reference.json
	$(VERILATOR) --cc --exe --build --assert -Wall -DRAPT_ASSERT_EN -I$(ROOT)/rtl/include -j $(JOBS) \
	  $(FP_ARITH_BUILD)/fma_legacy.vlt --top-module rapt_vpu_fp_arith -GDouble=$(FMA_DOUBLE) --Mdir $(FP_ARITH_BUILD) \
	  -CFLAGS '-DTEST_DOUBLE=$(FMA_DOUBLE) -I$(SPIKE_BUILD)/softfloat' -LDFLAGS '$(SPIKE_BUILD)/libsoftfloat.a' \
	  $(ROOT)/rtl/core/backend/fpu/rapt_fpu_fma.sv $(VPU)/rapt_vpu_fma.sv $(VPU)/rapt_vpu_fp_arith.sv $(CURDIR)/test_fp_arith.cpp \
	  >$(FP_ARITH_BUILD)/build.log 2>&1 || { cat $(FP_ARITH_BUILD)/build.log; exit 1; }
	$(FP_ARITH_BUILD)/Vrapt_vpu_fp_arith | tee $(FP_ARITH_BUILD)/run.log

.PHONY: fp-decode
fp-decode:
	@mkdir -p $(BUILD_DIR)/fp-decode-$(ELEN)
	python3 $(CURDIR)/record_run.py leaf $(BUILD_DIR)/fp-decode-$(ELEN)/sources.json \
		rapt_vpu_fp_decode ELEN=$(ELEN)
	$(VERILATOR) --cc --exe --build -Wall -j $(JOBS) --top-module rapt_vpu_fp_decode -GELEN=$(ELEN) \
	  --Mdir $(BUILD_DIR)/fp-decode-$(ELEN) -CFLAGS '-DTEST_ELEN=$(ELEN)' \
	  $(VPU)/rapt_vpu_fp_decode.sv $(CURDIR)/test_fp_decode.cpp \
	  >$(BUILD_DIR)/fp-decode-$(ELEN)/build.log 2>&1 || { cat $(BUILD_DIR)/fp-decode-$(ELEN)/build.log; exit 1; }
	$(BUILD_DIR)/fp-decode-$(ELEN)/Vrapt_vpu_fp_decode | tee $(BUILD_DIR)/fp-decode-$(ELEN)/run.log

.PHONY: divsqrt
divsqrt:
	@test -n "$(SPIKE_BUILD)" || { echo 'divsqrt requires SPIKE_BUILD for independent SoftFloat'; exit 1; }
	@mkdir -p $(BUILD_DIR)/divsqrt-$(ELEN)
	python3 $(CURDIR)/record_run.py leaf $(BUILD_DIR)/divsqrt-$(ELEN)/sources.json \
		rapt_vpu_divsqrt ELEN=$(ELEN)
	python3 $(CURDIR)/reference_manifest.py $(SPIKE_BUILD) $(BUILD_DIR)/divsqrt-$(ELEN)/reference.json
	$(VERILATOR) --cc --exe --build --assert -Wall -DRAPT_ASSERT_EN -I$(ROOT)/rtl/include -j $(JOBS) \
	  --top-module rapt_vpu_divsqrt -GELEN=$(ELEN) --Mdir $(BUILD_DIR)/divsqrt-$(ELEN) \
	  -CFLAGS '-DTEST_ELEN=$(ELEN) -I$(SPIKE_BUILD)/softfloat' -LDFLAGS '$(SPIKE_BUILD)/libsoftfloat.a' \
	  $(ROOT)/rtl/core/backend/fpu/rapt_fpu_divsqrt.sv $(VPU)/rapt_vpu_divsqrt.sv $(CURDIR)/test_divsqrt.cpp \
	  >$(BUILD_DIR)/divsqrt-$(ELEN)/build.log 2>&1 || { cat $(BUILD_DIR)/divsqrt-$(ELEN)/build.log; exit 1; }
	$(BUILD_DIR)/divsqrt-$(ELEN)/Vrapt_vpu_divsqrt | tee $(BUILD_DIR)/divsqrt-$(ELEN)/run.log

FP_MISC_BUILD := $(BUILD_DIR)/fp-misc-$(FMA_DOUBLE)
.PHONY: fp-misc
fp-misc:
	@test -n "$(SPIKE_BUILD)" || { echo 'fp-misc requires SPIKE_BUILD for independent SoftFloat'; exit 1; }
	@mkdir -p $(FP_MISC_BUILD)
	python3 $(CURDIR)/record_run.py leaf $(FP_MISC_BUILD)/sources.json rapt_vpu_fp_misc \
		Double=$(FMA_DOUBLE)
	python3 $(CURDIR)/reference_manifest.py $(SPIKE_BUILD) $(FP_MISC_BUILD)/reference.json
	$(VERILATOR) --cc --exe --build -Wall -j $(JOBS) \
	  --top-module rapt_vpu_fp_misc -GDouble=$(FMA_DOUBLE) --Mdir $(FP_MISC_BUILD) \
	  -CFLAGS '-DTEST_DOUBLE=$(FMA_DOUBLE) -I$(SPIKE_BUILD)/softfloat' -LDFLAGS '$(SPIKE_BUILD)/libsoftfloat.a' \
	  $(VPU)/rapt_vpu_fp_misc.sv $(CURDIR)/test_fp_misc.cpp \
	  >$(FP_MISC_BUILD)/build.log 2>&1 || { cat $(FP_MISC_BUILD)/build.log; exit 1; }
	$(FP_MISC_BUILD)/Vrapt_vpu_fp_misc | tee $(FP_MISC_BUILD)/run.log

.PHONY: fp-widen
fp-widen:
	@test -n "$(SPIKE_BUILD)" || { echo 'fp-widen requires SPIKE_BUILD for independent SoftFloat'; exit 1; }
	@mkdir -p $(BUILD_DIR)/fp-widen
	python3 $(CURDIR)/record_run.py leaf $(BUILD_DIR)/fp-widen/sources.json rapt_vpu_fp_widen
	python3 $(CURDIR)/reference_manifest.py $(SPIKE_BUILD) $(BUILD_DIR)/fp-widen/reference.json
	$(VERILATOR) --cc --exe --build -Wall -j $(JOBS) \
	  --top-module rapt_vpu_fp_widen --Mdir $(BUILD_DIR)/fp-widen \
	  -CFLAGS '-I$(SPIKE_BUILD)/softfloat' -LDFLAGS '$(SPIKE_BUILD)/libsoftfloat.a' \
	  $(VPU)/rapt_vpu_fp_widen.sv $(CURDIR)/test_fp_widen.cpp \
	  >$(BUILD_DIR)/fp-widen/build.log 2>&1 || { cat $(BUILD_DIR)/fp-widen/build.log; exit 1; }
	$(BUILD_DIR)/fp-widen/Vrapt_vpu_fp_widen | tee $(BUILD_DIR)/fp-widen/run.log

.PHONY: fp-wide-arith
fp-wide-arith:
	@test -n "$(SPIKE_BUILD)" || { echo 'fp-wide-arith requires SPIKE_BUILD for independent SoftFloat'; exit 1; }
	@mkdir -p $(BUILD_DIR)/fp-wide-arith
	$(call write_fma_waiver,$(BUILD_DIR)/fp-wide-arith)
	python3 $(CURDIR)/record_run.py leaf $(BUILD_DIR)/fp-wide-arith/sources.json rapt_vpu_fp_wide_arith
	python3 $(CURDIR)/reference_manifest.py $(SPIKE_BUILD) $(BUILD_DIR)/fp-wide-arith/reference.json
	$(VERILATOR) --cc --exe --build --assert -Wall -DRAPT_ASSERT_EN -I$(ROOT)/rtl/include -j $(JOBS) \
	  $(BUILD_DIR)/fp-wide-arith/fma_legacy.vlt --top-module rapt_vpu_fp_wide_arith --Mdir $(BUILD_DIR)/fp-wide-arith \
	  -CFLAGS '-I$(SPIKE_BUILD)/softfloat' -LDFLAGS '$(SPIKE_BUILD)/libsoftfloat.a' \
	  $(ROOT)/rtl/core/backend/fpu/rapt_fpu_fma.sv $(VPU)/rapt_vpu_fma.sv $(VPU)/rapt_vpu_fp_arith.sv $(VPU)/rapt_vpu_fp_widen.sv \
	  $(VPU)/rapt_vpu_fp_wide_arith.sv $(CURDIR)/test_fp_wide_arith.cpp \
	  >$(BUILD_DIR)/fp-wide-arith/build.log 2>&1 || { cat $(BUILD_DIR)/fp-wide-arith/build.log; exit 1; }
	$(BUILD_DIR)/fp-wide-arith/Vrapt_vpu_fp_wide_arith | tee $(BUILD_DIR)/fp-wide-arith/run.log

.PHONY: fp-convert
fp-convert:
	@test -n "$(SPIKE_BUILD)" || { echo 'fp-convert requires SPIKE_BUILD for independent SoftFloat'; exit 1; }
	@mkdir -p $(BUILD_DIR)/fp-convert
	python3 $(CURDIR)/record_run.py leaf $(BUILD_DIR)/fp-convert/sources.json rapt_vpu_fp_convert Zvfhmin=1
	python3 $(CURDIR)/reference_manifest.py $(SPIKE_BUILD) $(BUILD_DIR)/fp-convert/reference.json
	$(VERILATOR) --cc --exe --build --assert -Wall -DRAPT_ASSERT_EN $(VPU_INCLUDES) -j $(JOBS) \
	  --top-module rapt_vpu_fp_convert -GZvfhmin=1 --Mdir $(BUILD_DIR)/fp-convert \
	  -CFLAGS '-I$(SPIKE_BUILD)/softfloat' -LDFLAGS '$(SPIKE_BUILD)/libsoftfloat.a' \
	  $(addprefix $(ROOT)/rtl/core/backend/fpu/rapt_fpu_,$(addsuffix .sv,$(VPU_FORMAT_CONVERTERS))) \
	  $(VPU)/rapt_vpu_fp_widen.sv \
	  $(VPU)/rapt_vpu_fp_convert.sv $(CURDIR)/test_fp_convert.cpp \
	  >$(BUILD_DIR)/fp-convert/build.log 2>&1 || { cat $(BUILD_DIR)/fp-convert/build.log; exit 1; }
	$(BUILD_DIR)/fp-convert/Vrapt_vpu_fp_convert | tee $(BUILD_DIR)/fp-convert/run.log

INT_BITS ?= 32
INT_FP_SHARED ?= 0
INT_FP_MODULE := rapt_vpu_int_fp$(if $(filter 1,$(INT_FP_SHARED)),_shared,)
INT_FP_BUILD := $(BUILD_DIR)/int-fp$(if $(filter 1,$(INT_FP_SHARED)),-shared,)-$(FMA_DOUBLE)-$(INT_BITS)
INT_FP_WIDTH_PARAM := $(if $(filter 1,$(INT_FP_SHARED)),TestIntBits,IntBits)
INT_FP_WIDTH_FLAG := $(if $(filter 1,$(INT_FP_SHARED)),,-GIntBits=$(INT_BITS))
INT_FP_TEST_FLAG := $(if $(filter 1,$(INT_FP_SHARED)),-DTEST_SHARED,)
INT_FP_SCALAR_FPU := int_to_fp integer_to_fp single_to_int_w fp_to_int
.PHONY: int-fp
int-fp:
	@test -n "$(SPIKE_BUILD)" || { echo 'int-fp requires SPIKE_BUILD for independent SoftFloat'; exit 1; }
	@case "$(INT_FP_SHARED)" in 0|1) ;; *) echo 'INT_FP_SHARED must be 0 or 1'; exit 1 ;; esac
	@mkdir -p $(INT_FP_BUILD)
	python3 $(CURDIR)/record_run.py leaf $(INT_FP_BUILD)/sources.json $(INT_FP_MODULE) \
		FloatDouble=$(FMA_DOUBLE) $(INT_FP_WIDTH_PARAM)=$(INT_BITS)
	python3 $(CURDIR)/reference_manifest.py $(SPIKE_BUILD) $(INT_FP_BUILD)/reference.json
	$(VERILATOR) --cc --exe --build --assert -Wall -DRAPT_ASSERT_EN -I$(ROOT)/rtl/include -j $(JOBS) \
	  --top-module $(INT_FP_MODULE) -GFloatDouble=$(FMA_DOUBLE) $(INT_FP_WIDTH_FLAG) \
	  --Mdir $(INT_FP_BUILD) \
	  -CFLAGS '$(INT_FP_TEST_FLAG) -DTEST_DOUBLE=$(FMA_DOUBLE) -DTEST_INT_BITS=$(INT_BITS) -I$(SPIKE_BUILD)/softfloat' \
	  -LDFLAGS '$(SPIKE_BUILD)/libsoftfloat.a' \
	  $(addprefix $(ROOT)/rtl/core/backend/fpu/rapt_fpu_,$(addsuffix .sv,$(INT_FP_SCALAR_FPU))) \
	  $(VPU)/$(INT_FP_MODULE).sv $(CURDIR)/test_int_fp.cpp \
	  >$(INT_FP_BUILD)/build.log 2>&1 || { cat $(INT_FP_BUILD)/build.log; exit 1; }
	$(INT_FP_BUILD)/V$(INT_FP_MODULE) | tee $(INT_FP_BUILD)/run.log

.PHONY: int-fp-decode
int-fp-decode:
	@mkdir -p $(BUILD_DIR)/int-fp-decode-$(ELEN)
	python3 $(CURDIR)/record_run.py leaf $(BUILD_DIR)/int-fp-decode-$(ELEN)/sources.json \
		rapt_vpu_int_fp_decode ELEN=$(ELEN)
	$(VERILATOR) --cc --exe --build -Wall -j $(JOBS) --top-module rapt_vpu_int_fp_decode -GELEN=$(ELEN) \
	  --Mdir $(BUILD_DIR)/int-fp-decode-$(ELEN) -CFLAGS '-DTEST_ELEN=$(ELEN)' \
	  $(VPU)/rapt_vpu_int_fp_decode.sv $(CURDIR)/test_int_fp_decode.cpp \
	  >$(BUILD_DIR)/int-fp-decode-$(ELEN)/build.log 2>&1 || { cat $(BUILD_DIR)/int-fp-decode-$(ELEN)/build.log; exit 1; }
	$(BUILD_DIR)/int-fp-decode-$(ELEN)/Vrapt_vpu_int_fp_decode | tee $(BUILD_DIR)/int-fp-decode-$(ELEN)/run.log

.PHONY: fp-estimate
fp-estimate:
	@test -n "$(SPIKE_BUILD)" || { echo 'fp-estimate requires SPIKE_BUILD for independent SoftFloat'; exit 1; }
	@mkdir -p $(BUILD_DIR)/fp-estimate-$(FMA_DOUBLE)
	python3 $(CURDIR)/record_run.py leaf $(BUILD_DIR)/fp-estimate-$(FMA_DOUBLE)/sources.json \
		rapt_vpu_fp_estimate Double=$(FMA_DOUBLE)
	python3 $(CURDIR)/reference_manifest.py $(SPIKE_BUILD) $(BUILD_DIR)/fp-estimate-$(FMA_DOUBLE)/reference.json
	$(VERILATOR) --cc --exe --build -Wall -j $(JOBS) --top-module rapt_vpu_fp_estimate --Mdir $(BUILD_DIR)/fp-estimate-$(FMA_DOUBLE) \
	  -GDouble=$(FMA_DOUBLE) -CFLAGS '-DTEST_DOUBLE=$(FMA_DOUBLE) -I$(SPIKE_BUILD)/softfloat' -LDFLAGS '$(SPIKE_BUILD)/libsoftfloat.a' \
	  $(VPU)/rapt_vpu_fp_estimate.sv $(CURDIR)/test_fp_estimate.cpp \
	  >$(BUILD_DIR)/fp-estimate-$(FMA_DOUBLE)/build.log 2>&1 || { cat $(BUILD_DIR)/fp-estimate-$(FMA_DOUBLE)/build.log; exit 1; }
	$(BUILD_DIR)/fp-estimate-$(FMA_DOUBLE)/Vrapt_vpu_fp_estimate | tee $(BUILD_DIR)/fp-estimate-$(FMA_DOUBLE)/run.log

.PHONY: fp-transfer
fp-transfer:
	@mkdir -p $(BUILD_DIR)/fp-transfer-$(ELEN)-$(VLEN)
	python3 $(CURDIR)/record_run.py leaf \
		$(BUILD_DIR)/fp-transfer-$(ELEN)-$(VLEN)/sources.json rapt_vpu_fp_transfer \
		ELEN=$(ELEN) VLEN=$(VLEN)
	$(VERILATOR) --cc --exe --build -Wall -j $(JOBS) --top-module rapt_vpu_fp_transfer --Mdir $(BUILD_DIR)/fp-transfer-$(ELEN)-$(VLEN) \
	  -GELEN=$(ELEN) -GVLEN=$(VLEN) -CFLAGS '-DTEST_ELEN=$(ELEN) -DTEST_VLEN=$(VLEN)' \
	  $(VPU)/rapt_vpu_slide.sv $(VPU)/rapt_vpu_fp_transfer.sv $(CURDIR)/test_fp_transfer.cpp \
	  >$(BUILD_DIR)/fp-transfer-$(ELEN)-$(VLEN)/build.log 2>&1 || { cat $(BUILD_DIR)/fp-transfer-$(ELEN)-$(VLEN)/build.log; exit 1; }
	$(BUILD_DIR)/fp-transfer-$(ELEN)-$(VLEN)/Vrapt_vpu_fp_transfer | tee $(BUILD_DIR)/fp-transfer-$(ELEN)-$(VLEN)/run.log

.PHONY: fp-reduce
fp-reduce:
	@test -n "$(SPIKE_BUILD)" || { echo 'fp-reduce requires SPIKE_BUILD for independent SoftFloat'; exit 1; }
	@mkdir -p $(BUILD_DIR)/fp-reduce-$(ELEN)
	$(call write_fma_waiver,$(BUILD_DIR)/fp-reduce-$(ELEN))
	python3 $(CURDIR)/record_run.py leaf $(BUILD_DIR)/fp-reduce-$(ELEN)/sources.json \
		rapt_vpu_fp_reduce ELEN=$(ELEN) CountBits=10
	python3 $(CURDIR)/reference_manifest.py $(SPIKE_BUILD) $(BUILD_DIR)/fp-reduce-$(ELEN)/reference.json
	$(VERILATOR) --cc --exe --build --assert -Wall -DRAPT_ASSERT_EN -I$(ROOT)/rtl/include -j $(JOBS) \
	  $(BUILD_DIR)/fp-reduce-$(ELEN)/fma_legacy.vlt --top-module rapt_vpu_fp_reduce --Mdir $(BUILD_DIR)/fp-reduce-$(ELEN) \
	  -GELEN=$(ELEN) -CFLAGS '-DTEST_ELEN=$(ELEN) -I$(SPIKE_BUILD)/softfloat' -LDFLAGS '$(SPIKE_BUILD)/libsoftfloat.a' \
	  $(ROOT)/rtl/core/backend/fpu/rapt_fpu_fma.sv $(VPU)/rapt_vpu_fma.sv $(VPU)/rapt_vpu_fp_arith.sv $(VPU)/rapt_vpu_fp_misc.sv $(VPU)/rapt_vpu_fp_widen.sv \
	  $(VPU)/rapt_vpu_fp_reduce_control.sv $(VPU)/rapt_vpu_fp_reduce.sv $(CURDIR)/test_fp_reduce.cpp \
	  >$(BUILD_DIR)/fp-reduce-$(ELEN)/build.log 2>&1 || { cat $(BUILD_DIR)/fp-reduce-$(ELEN)/build.log; exit 1; }
	$(BUILD_DIR)/fp-reduce-$(ELEN)/Vrapt_vpu_fp_reduce | tee $(BUILD_DIR)/fp-reduce-$(ELEN)/run.log

.PHONY: fp-reduce-control
fp-reduce-control:
	@mkdir -p $(BUILD_DIR)/fp-reduce-control-$(ELEN)
	python3 $(CURDIR)/record_run.py leaf $(BUILD_DIR)/fp-reduce-control-$(ELEN)/sources.json \
		rapt_vpu_fp_reduce_control ELEN=$(ELEN) CountBits=10
	$(VERILATOR) --cc --exe --build --assert -Wall -DRAPT_ASSERT_EN -I$(ROOT)/rtl/include -j $(JOBS) \
	  --top-module rapt_vpu_fp_reduce_control --Mdir $(BUILD_DIR)/fp-reduce-control-$(ELEN) -GELEN=$(ELEN) \
	  $(VPU)/rapt_vpu_fp_widen.sv $(VPU)/rapt_vpu_fp_reduce_control.sv $(CURDIR)/test_fp_reduce_control.cpp \
	  >$(BUILD_DIR)/fp-reduce-control-$(ELEN)/build.log 2>&1 || { cat $(BUILD_DIR)/fp-reduce-control-$(ELEN)/build.log; exit 1; }
	$(BUILD_DIR)/fp-reduce-control-$(ELEN)/Vrapt_vpu_fp_reduce_control | tee $(BUILD_DIR)/fp-reduce-control-$(ELEN)/run.log

.PHONY: fp-reduce-decode
fp-reduce-decode:
	@mkdir -p $(BUILD_DIR)/fp-reduce-decode-$(ELEN)
	python3 $(CURDIR)/record_run.py leaf $(BUILD_DIR)/fp-reduce-decode-$(ELEN)/sources.json \
		rapt_vpu_fp_reduce_decode ELEN=$(ELEN)
	$(VERILATOR) --cc --exe --build -Wall -j $(JOBS) --top-module rapt_vpu_fp_reduce_decode \
	  --Mdir $(BUILD_DIR)/fp-reduce-decode-$(ELEN) -GELEN=$(ELEN) -CFLAGS '-DTEST_ELEN=$(ELEN)' \
	  $(VPU)/rapt_vpu_fp_reduce_decode.sv $(CURDIR)/test_fp_reduce_decode.cpp \
	  >$(BUILD_DIR)/fp-reduce-decode-$(ELEN)/build.log 2>&1 || { cat $(BUILD_DIR)/fp-reduce-decode-$(ELEN)/build.log; exit 1; }
	$(BUILD_DIR)/fp-reduce-decode-$(ELEN)/Vrapt_vpu_fp_reduce_decode | tee $(BUILD_DIR)/fp-reduce-decode-$(ELEN)/run.log

.PHONY: fp-reduce-engine
fp-reduce-engine:
	@mkdir -p $(BUILD_DIR)/fp-reduce-engine-$(XLEN)-$(VLEN)-$(ELEN)-cache$(REDUCE_MASK_CACHE)
	python3 $(CURDIR)/record_run.py leaf \
		$(BUILD_DIR)/fp-reduce-engine-$(XLEN)-$(VLEN)-$(ELEN)-cache$(REDUCE_MASK_CACHE)/sources.json \
		rapt_vpu_fp_reduce_engine XLEN=$(XLEN) VLEN=$(VLEN) ELEN=$(ELEN) \
		CacheMask=$(REDUCE_MASK_CACHE)
	$(VERILATOR) --cc --exe --build --assert -Wall -DRAPT_ASSERT_EN -I$(ROOT)/rtl/include -j $(JOBS) \
	  --top-module rapt_vpu_fp_reduce_engine --Mdir $(BUILD_DIR)/fp-reduce-engine-$(XLEN)-$(VLEN)-$(ELEN)-cache$(REDUCE_MASK_CACHE) \
	  -GXLEN=$(XLEN) -GVLEN=$(VLEN) -GELEN=$(ELEN) -GCacheMask=$(REDUCE_MASK_CACHE) -CFLAGS '-DTEST_XLEN=$(XLEN) -DTEST_VLEN=$(VLEN) -DTEST_ELEN=$(ELEN) -DTEST_CACHE_MASK=$(REDUCE_MASK_CACHE)' \
	  $(VPU)/rapt_vpu_vtype.sv $(VPU)/rapt_vpu_fp_widen.sv $(VPU)/rapt_vpu_fp_reduce_decode.sv \
	  $(VPU)/rapt_vpu_fp_reduce_control.sv $(VPU)/rapt_vpu_fp_reduce_engine.sv $(CURDIR)/test_fp_reduce_engine.cpp \
	  >$(BUILD_DIR)/fp-reduce-engine-$(XLEN)-$(VLEN)-$(ELEN)-cache$(REDUCE_MASK_CACHE)/build.log 2>&1 || { cat $(BUILD_DIR)/fp-reduce-engine-$(XLEN)-$(VLEN)-$(ELEN)-cache$(REDUCE_MASK_CACHE)/build.log; exit 1; }
	$(BUILD_DIR)/fp-reduce-engine-$(XLEN)-$(VLEN)-$(ELEN)-cache$(REDUCE_MASK_CACHE)/Vrapt_vpu_fp_reduce_engine | tee $(BUILD_DIR)/fp-reduce-engine-$(XLEN)-$(VLEN)-$(ELEN)-cache$(REDUCE_MASK_CACHE)/run.log

ADAPTER_ROB_BITS ?= 6
ADAPTER_GENERATION_BITS ?= 4
ADAPTER_BUILD := $(BUILD_DIR)/core-adapter-$(ADAPTER_ROB_BITS)-$(ADAPTER_GENERATION_BITS)
.PHONY: core-adapter
core-adapter:
	@mkdir -p $(ADAPTER_BUILD)
	python3 $(CURDIR)/record_run.py adapter $(ADAPTER_BUILD)/sources.json $(ADAPTER_ROB_BITS) \
		$(ADAPTER_GENERATION_BITS)
	$(VERILATOR) $(FLAGS) --top-module tb_vpu_core_adapter --Mdir $(ADAPTER_BUILD) \
	  -GRobBits=$(ADAPTER_ROB_BITS) -GGenerationBits=$(ADAPTER_GENERATION_BITS) $(VPU)/rapt_vpu_core_adapter.sv $(VPU)/rapt_vpu_owner.sv $(CURDIR)/tb_vpu_core_adapter.sv \
	  >$(ADAPTER_BUILD)/build.log 2>&1 \
	  || { cat $(ADAPTER_BUILD)/build.log; exit 1; }
	$(ADAPTER_BUILD)/Vtb_vpu_core_adapter | tee $(ADAPTER_BUILD)/run.log

.PHONY: core-adapter-formal
core-adapter-formal:
	python3 $(CURDIR)/core_adapter_formal.py --build-dir $(BUILD_DIR)/formal-core-adapter
