# Standalone C++ Verilator L2 cache golden-model fuzzer build & smoke targets.

REPO_ROOT := $(abspath ../..)
VERILATOR ?= verilator
OUT_DIR   ?= $(REPO_ROOT)/verification/build/l2_fuzz
JOBS      ?= 16

RTL_SRCS := \
	$(REPO_ROOT)/rtl/rapt_pkg.sv \
	$(REPO_ROOT)/rtl/sram/rapt_sram_1rw.sv \
	$(REPO_ROOT)/rtl/uncore/l2cache/rapt_l2_bypass_ctrl.sv \
	$(REPO_ROOT)/rtl/uncore/l2cache/rapt_l2_data_array.sv \
	$(REPO_ROOT)/rtl/uncore/l2cache/rapt_l2_directory.sv \
	$(REPO_ROOT)/rtl/uncore/l2cache/rapt_l2_evict_ctrl.sv \
	$(REPO_ROOT)/rtl/uncore/l2cache/rapt_l2_hit_ctrl.sv \
	$(REPO_ROOT)/rtl/uncore/l2cache/rapt_l2_mshr_frontend.sv \
	$(REPO_ROOT)/rtl/uncore/l2cache/rapt_l2_mshr_scheduler.sv \
	$(REPO_ROOT)/rtl/uncore/l2cache/rapt_l2_put_buffer.sv \
	$(REPO_ROOT)/rtl/uncore/l2cache/rapt_l2_refill_ctrl.sv \
	$(REPO_ROOT)/rtl/uncore/l2cache/rapt_l2_refill_mshrs.sv \
	$(REPO_ROOT)/rtl/uncore/l2cache/rapt_l2_release_buffer.sv \
	$(REPO_ROOT)/rtl/uncore/l2cache/rapt_l2_secondary_buffer.sv \
	$(REPO_ROOT)/rtl/uncore/l2cache/rapt_l2.sv \
	$(REPO_ROOT)/verification/l2_fuzz/tb_l2_fuzz_top.sv

CPP_SRC := $(REPO_ROOT)/verification/l2_fuzz/l2_fuzz_main.cc

VL_COMMON := --cc --exe --build -j $(JOBS) --top-module tb_l2_fuzz_top \
	--no-timing -Wno-WIDTHEXPAND -Wno-WIDTHTRUNC -Wno-ASCRANGE -Wno-UNSIGNED \
	-Wno-UNOPTFLAT -Wno-fatal --assert \
	-I$(REPO_ROOT)/rtl/include -I$(REPO_ROOT)/rtl/include/npc \
	-DRAPT_ASSERT_EN -DRAPT_L2_EN -CFLAGS -O3 -CFLAGS -std=c++17

define fuzz_cflags
-CFLAGS -DL2_FUZZ_XLEN=$(1) -CFLAGS -DL2_FUZZ_LEN=$(2) \
-CFLAGS -DL2_FUZZ_LINE_LEN=$(3) -CFLAGS -DL2_FUZZ_N_WAYS=$(4) \
-CFLAGS -DL2_FUZZ_PADDR_BITS=$(5)
endef

VARIANTS := w4_l2_rv64_4g l2_rv64_512k l2_rv32_512k legacy_rv64 legacy_rv32

.PHONY: all build-all smoke clean $(VARIANTS)

all: build-all

build-all: $(VARIANTS)

w4_l2_rv64_4g:
	@mkdir -p $(OUT_DIR)/$@
	$(VERILATOR) $(VL_COMMON) -I$(REPO_ROOT)/rtl/configs/default-w4-l2 \
		-DRAPT_RV64 -DRAPT_PADDR_BITS=34 -DRAPT_PMEM_MB=4096 \
		-GL2_LEN=9 -GL2_LINE_LEN=3 -GL2_N_WAYS=8 -GPADDR_BITS=34 \
		$(call fuzz_cflags,64,9,3,8,34) \
		--Mdir $(OUT_DIR)/$@ -o l2_fuzz $(RTL_SRCS) $(CPP_SRC)

l2_rv64_512k:
	@mkdir -p $(OUT_DIR)/$@
	$(VERILATOR) $(VL_COMMON) -I$(REPO_ROOT)/rtl/configs/default-l2 \
		-DRAPT_RV64 \
		-GL2_LEN=10 -GL2_LINE_LEN=3 -GL2_N_WAYS=8 -GPADDR_BITS=32 \
		$(call fuzz_cflags,64,10,3,8,32) \
		--Mdir $(OUT_DIR)/$@ -o l2_fuzz $(RTL_SRCS) $(CPP_SRC)

l2_rv32_512k:
	@mkdir -p $(OUT_DIR)/$@
	$(VERILATOR) $(VL_COMMON) -I$(REPO_ROOT)/rtl/configs/default-l2 \
		-GL2_LEN=10 -GL2_LINE_LEN=4 -GL2_N_WAYS=8 -GPADDR_BITS=32 \
		$(call fuzz_cflags,32,10,4,8,32) \
		--Mdir $(OUT_DIR)/$@ -o l2_fuzz $(RTL_SRCS) $(CPP_SRC)

legacy_rv64:
	@mkdir -p $(OUT_DIR)/$@
	$(VERILATOR) $(VL_COMMON) -I$(REPO_ROOT)/rtl/configs/default \
		-DRAPT_RV64 \
		-GL2_LEN=5 -GL2_LINE_LEN=3 -GL2_N_WAYS=4 -GPADDR_BITS=32 \
		$(call fuzz_cflags,64,5,3,4,32) \
		--Mdir $(OUT_DIR)/$@ -o l2_fuzz $(RTL_SRCS) $(CPP_SRC)

legacy_rv32:
	@mkdir -p $(OUT_DIR)/$@
	$(VERILATOR) $(VL_COMMON) -I$(REPO_ROOT)/rtl/configs/default \
		-GL2_LEN=5 -GL2_LINE_LEN=3 -GL2_N_WAYS=4 -GPADDR_BITS=32 \
		$(call fuzz_cflags,32,5,3,4,32) \
		--Mdir $(OUT_DIR)/$@ -o l2_fuzz $(RTL_SRCS) $(CPP_SRC)

smoke: w4_l2_rv64_4g
	@for p in 0 1 2 3 4 5 6; do \
		$(OUT_DIR)/w4_l2_rv64_4g/l2_fuzz --seed=$$((100 + p)) --profile=$$p --cycles=200000 || exit 1; \
	done

clean:
	rm -rf $(OUT_DIR)
