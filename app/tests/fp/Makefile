RAPTOR_HOME ?= $(abspath ../../..)
APP_HOME := $(RAPTOR_HOME)/app
NEMU_HOME := $(RAPTOR_HOME)/nemu
export NEMU_HOME
BUILD_DIR := $(APP_HOME)/build/$(ISA)/tests/fp
LINKER := $(RAPTOR_HOME)/verification/scripts/fuzz_link.ld
CC := riscv64-unknown-elf-gcc
OBJCOPY := riscv64-unknown-elf-objcopy
SIM_HOME := $(RAPTOR_HOME)/sim
NPC_NPROC ?= 4
NPC_ARGS ?= -b -n --no-lightsss

ISA ?= rv64
DIFFTEST ?= 0
ifeq ($(ISA),rv32)
	NEMU_DEFCONFIG := riscv32$(if $(filter 1,$(DIFFTEST)),_difftest,)_defconfig
	NEMU_SPIKE_DEFCONFIG := riscv32_difftest_defconfig
  NEMU_BIN := $(NEMU_HOME)/build/riscv32-nemu-interpreter
	SPIKE_SO := $(NEMU_HOME)/tools/spike-diff/build/riscv32-spike-so
	SPIKE_RV64 :=
  MARCH := rv32imafc
  MABI := ilp32f
  TEST_NAME := fp_moves_rv32
	NPC_NEMU_F_DEFCONFIG := riscv32_ref_defconfig
	NPC_NEMU_D_DEFCONFIG := riscv32_ref_defconfig
	NPC_DIFF_REF_SO := $(NEMU_HOME)/build/ref/riscv32_ref_defconfig/riscv32-nemu-interpreter-so
	NPC_VFLAGS := -DRAPT_ASSERT_EN
else
	NEMU_DEFCONFIG := riscv64$(if $(filter 1,$(DIFFTEST)),_difftest,)_defconfig
	NEMU_SPIKE_DEFCONFIG := riscv64_difftest_defconfig
  NEMU_BIN := $(NEMU_HOME)/build/riscv64-nemu-interpreter
	SPIKE_SO := $(NEMU_HOME)/tools/spike-diff/build/riscv64-spike-so
	SPIKE_RV64 := y
  MARCH := rv64imafc
  MABI := lp64f
  TEST_NAME := fp_moves
	NPC_NEMU_F_DEFCONFIG := riscv64_ref_defconfig
	NPC_NEMU_D_DEFCONFIG := riscv64_ref_defconfig
	NPC_DIFF_REF_SO := $(NEMU_HOME)/build/ref/riscv64_ref_defconfig/riscv64-nemu-interpreter-so
	NPC_VFLAGS := -DRAPT_RV64 -DRAPT_ASSERT_EN
endif

ELF := $(BUILD_DIR)/$(TEST_NAME).elf
BIN := $(BUILD_DIR)/$(TEST_NAME).bin
LOG := $(BUILD_DIR)/$(TEST_NAME).nemu.log

.PHONY: all build fp-config spike-config run arith arith-spike fcsr fcsr-spike rm-illegal-spike fs-spike fs-mem-spike compressed-mem-spike d-arith d-arith-spike minmax-spike compare-spike convert-spike fma-spike divsqrt-spike double double-unaligned npc-arith npc-fcsr npc-rm-illegal npc-fs npc-fs-mem npc-compressed-mem npc-d-arith npc-minmax npc-compare npc-convert npc-fma npc-divsqrt npc-coverage npc-matrix clean

all: run

fp-config:
	$(MAKE) -C $(NEMU_HOME) $(NEMU_DEFCONFIG)
	$(MAKE) -C $(NEMU_HOME) -j$$(nproc)
	$(if $(filter 1,$(DIFFTEST)),$(MAKE) -C $(NEMU_HOME)/tools/spike-diff CONFIG_RV64=$(SPIKE_RV64) GUEST_ISA=riscv -j$$(nproc),)

build: fp-config $(BIN)

$(ELF): fp_moves.S $(LINKER) | fp-config
	mkdir -p $(BUILD_DIR)
	$(CC) -march=$(MARCH) -mabi=$(MABI) -nostdlib -nostartfiles \
		-T $(LINKER) -o $@ $<

$(BIN): $(ELF)
	$(OBJCOPY) -O binary $< $@

run: fp-config $(BIN)
	cd $(NEMU_HOME) && ./build/$$(basename $(NEMU_BIN)) -b -n \
		--log=$(LOG) $(if $(filter 1,$(DIFFTEST)),--diff=$(SPIKE_SO),) $(BIN)

# Shared build/run recipes; each row preserves the source and F/D ISA choice.
FP_D_MARCH = $(if $(filter rv32,$(ISA)),rv32imafdc,rv64imafdc)
FP_D_MABI = $(if $(filter rv32,$(ISA)),ilp32d,lp64d)
FP_F_RUNNER = ./build/$$(basename $(NEMU_BIN))
FP_D_RUNNER = ./build/$(if $(filter rv32,$(ISA)),riscv32-nemu-interpreter,riscv64-nemu-interpreter)
FP_IMAGE = $(BUILD_DIR)/fp_$(subst -,_,$(1))_$(ISA)

# $(1): source stem, $(2): F or D. Expand at recipe execution time.
define FP_COMPILE
	mkdir -p $(BUILD_DIR)
	$(CC) -march=$(if $(filter D,$(2)),$(FP_D_MARCH),$(MARCH)) \
		-mabi=$(if $(filter D,$(2)),$(FP_D_MABI),$(MABI)) -nostdlib -nostartfiles \
		-T $(LINKER) -o $(call FP_IMAGE,$(1)).elf fp_$(subst -,_,$(1)).S
	$(OBJCOPY) -O binary $(call FP_IMAGE,$(1)).elf $(call FP_IMAGE,$(1)).bin
endef

# $(1): target, $(2): source stem, $(3): F/D, $(4): spike or log (optional).
define FP_NEMU_TEST
$(1): fp-config
	$$(MAKE) -C $$(NEMU_HOME) $$(if $$(filter spike,$(4)),$$(NEMU_SPIKE_DEFCONFIG),$$(NEMU_DEFCONFIG))
	$$(MAKE) -C $$(NEMU_HOME) -j$$$$(nproc)
	$$(if $$(filter spike,$(4)),$$(MAKE) -C $$(NEMU_HOME)/tools/spike-diff CONFIG_RV64=$$(SPIKE_RV64) GUEST_ISA=riscv -j$$$$(nproc))
	$$(call FP_COMPILE,$(2),$(3))
	cd $$(NEMU_HOME) && $$(FP_$(3)_RUNNER) -b -n \
		$$(if $$(filter spike,$(4)),--diff=$$(SPIKE_SO),$$(if $$(filter log,$(4)),--log=$$(call FP_IMAGE,$(2)).nemu.log)) $$(call FP_IMAGE,$(2)).bin
endef

# $(1): source stem, $(2): compiler F/D, $(3): NEMU reference F/D.
# rm-illegal deliberately uses the F compiler flags and D reference profile.
define FP_NPC_TEST
npc-$(1):
	$$(MAKE) -C $$(NEMU_HOME) $$(NPC_NEMU_$(3)_DEFCONFIG)
	$$(MAKE) -C $$(NEMU_HOME) -j$$$$(nproc)
	$$(call FP_COMPILE,$(1),$(2))
	$$(MAKE) -C $$(SIM_HOME) run NPROC=$$(NPC_NPROC) \
		VFLAGS='$$(NPC_VFLAGS)' DIFF_REF_SO='-d $$(NPC_DIFF_REF_SO)' \
		IMG=$$(call FP_IMAGE,$(1)).bin ARGS='$$(NPC_ARGS)'
endef

$(eval $(call FP_NEMU_TEST,arith,arith,F,log))
$(eval $(call FP_NEMU_TEST,fcsr,fcsr,F))
# Compatibility entry point after merging fp_double.S into fp_d_arith.S.
double: d-arith
$(foreach test,d-arith double-unaligned,$(eval $(call FP_NEMU_TEST,$(test),$(test),D)))
$(foreach test,arith fcsr rm-illegal fs,$(eval $(call FP_NEMU_TEST,$(test)-spike,$(test),F,spike)))
$(foreach test,fs-mem compressed-mem d-arith minmax compare convert fma divsqrt,$(eval $(call FP_NEMU_TEST,$(test)-spike,$(test),D,spike)))
$(foreach test,arith fcsr fs,$(eval $(call FP_NPC_TEST,$(test),F,F)))
$(eval $(call FP_NPC_TEST,rm-illegal,F,D))
$(foreach test,fs-mem compressed-mem d-arith minmax compare convert fma divsqrt,$(eval $(call FP_NPC_TEST,$(test),D,D)))

npc-coverage:
	mkdir -p $(BUILD_DIR)
	$(CC) -march=rv32imafdc_zfhmin -mabi=ilp32d -nostdlib -nostartfiles \
		-T $(LINKER) -o $(BUILD_DIR)/fp_coverage_rv32.elf fp_coverage.S
	$(OBJCOPY) -O binary $(BUILD_DIR)/fp_coverage_rv32.elf \
		$(BUILD_DIR)/fp_coverage_rv32.bin
	$(MAKE) -C $(SIM_HOME) run NPROC=$(NPC_NPROC) \
		VFLAGS='$(NPC_VFLAGS)' DIFF_REF_SO= \
		IMG=$(BUILD_DIR)/fp_coverage_rv32.bin ARGS='$(NPC_ARGS)'

npc-matrix:
	$(MAKE) ISA=rv32 NPC_NPROC=$(NPC_NPROC) NPC_ARGS='$(NPC_ARGS)' npc-arith
	$(MAKE) ISA=rv32 NPC_NPROC=$(NPC_NPROC) NPC_ARGS='$(NPC_ARGS)' npc-d-arith
	$(MAKE) ISA=rv32 NPC_NPROC=$(NPC_NPROC) NPC_ARGS='$(NPC_ARGS)' npc-minmax
	$(MAKE) ISA=rv32 NPC_NPROC=$(NPC_NPROC) NPC_ARGS='$(NPC_ARGS)' npc-compare
	$(MAKE) ISA=rv32 NPC_NPROC=$(NPC_NPROC) NPC_ARGS='$(NPC_ARGS)' npc-convert
	$(MAKE) ISA=rv32 NPC_NPROC=$(NPC_NPROC) NPC_ARGS='$(NPC_ARGS)' npc-fma
	$(MAKE) ISA=rv32 NPC_NPROC=$(NPC_NPROC) NPC_ARGS='$(NPC_ARGS)' npc-divsqrt
	$(MAKE) ISA=rv32 NPC_NPROC=$(NPC_NPROC) NPC_ARGS='$(NPC_ARGS)' npc-fcsr
	$(MAKE) ISA=rv32 NPC_NPROC=$(NPC_NPROC) NPC_ARGS='$(NPC_ARGS)' npc-rm-illegal
	$(MAKE) ISA=rv32 NPC_NPROC=$(NPC_NPROC) NPC_ARGS='$(NPC_ARGS)' npc-fs
	$(MAKE) ISA=rv32 NPC_NPROC=$(NPC_NPROC) NPC_ARGS='$(NPC_ARGS)' npc-fs-mem
	$(MAKE) ISA=rv32 NPC_NPROC=$(NPC_NPROC) NPC_ARGS='$(NPC_ARGS)' npc-compressed-mem
	$(MAKE) ISA=rv64 NPC_NPROC=$(NPC_NPROC) NPC_ARGS='$(NPC_ARGS)' npc-arith
	$(MAKE) ISA=rv64 NPC_NPROC=$(NPC_NPROC) NPC_ARGS='$(NPC_ARGS)' npc-d-arith
	$(MAKE) ISA=rv64 NPC_NPROC=$(NPC_NPROC) NPC_ARGS='$(NPC_ARGS)' npc-minmax
	$(MAKE) ISA=rv64 NPC_NPROC=$(NPC_NPROC) NPC_ARGS='$(NPC_ARGS)' npc-compare
	$(MAKE) ISA=rv64 NPC_NPROC=$(NPC_NPROC) NPC_ARGS='$(NPC_ARGS)' npc-convert
	$(MAKE) ISA=rv64 NPC_NPROC=$(NPC_NPROC) NPC_ARGS='$(NPC_ARGS)' npc-fma
	$(MAKE) ISA=rv64 NPC_NPROC=$(NPC_NPROC) NPC_ARGS='$(NPC_ARGS)' npc-divsqrt
	$(MAKE) ISA=rv64 NPC_NPROC=$(NPC_NPROC) NPC_ARGS='$(NPC_ARGS)' npc-fcsr
	$(MAKE) ISA=rv64 NPC_NPROC=$(NPC_NPROC) NPC_ARGS='$(NPC_ARGS)' npc-rm-illegal
	$(MAKE) ISA=rv64 NPC_NPROC=$(NPC_NPROC) NPC_ARGS='$(NPC_ARGS)' npc-fs
	$(MAKE) ISA=rv64 NPC_NPROC=$(NPC_NPROC) NPC_ARGS='$(NPC_ARGS)' npc-fs-mem
	$(MAKE) ISA=rv64 NPC_NPROC=$(NPC_NPROC) NPC_ARGS='$(NPC_ARGS)' npc-compressed-mem

clean:
	rm -f $(ELF) $(BIN) $(LOG) $(BUILD_DIR)/fp_moves_rv32.elf \
		$(BUILD_DIR)/fp_moves_rv32.bin $(BUILD_DIR)/fp_moves_rv32.nemu.log
