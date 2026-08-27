RAPTOR_HOME ?= $(abspath ../../..)
APP_HOME := $(RAPTOR_HOME)/app
NEMU_HOME := $(RAPTOR_HOME)/nemu
export NEMU_HOME
BUILD_DIR := $(APP_HOME)/build/$(ISA)/tests/fp
LINKER := $(RAPTOR_HOME)/verify/scripts/fuzz_link.ld
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
	NPC_NEMU_F_DEFCONFIG := riscv32_difftest_defconfig
	NPC_NEMU_D_DEFCONFIG := riscv32_difftest_defconfig
	NPC_DIFF_REF_SO := $(NEMU_HOME)/build/riscv32-nemu-interpreter-so
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
	NPC_NEMU_F_DEFCONFIG := riscv64_difftest_defconfig
	NPC_NEMU_D_DEFCONFIG := riscv64_difftest_defconfig
	NPC_DIFF_REF_SO := $(NEMU_HOME)/build/riscv64-nemu-interpreter-so
	NPC_VFLAGS := -DRAPT_RV64 -DRAPT_ASSERT_EN
endif

ELF := $(BUILD_DIR)/$(TEST_NAME).elf
BIN := $(BUILD_DIR)/$(TEST_NAME).bin
LOG := $(BUILD_DIR)/$(TEST_NAME).nemu.log

.PHONY: all build fp-config spike-config run arith arith-spike fcsr fcsr-spike rm-illegal-spike fs-spike fs-mem-spike d-arith d-arith-spike minmax-spike compare-spike convert-spike fma-spike divsqrt-spike double double-unaligned npc-arith npc-fcsr npc-rm-illegal npc-fs npc-fs-mem npc-d-arith npc-minmax npc-compare npc-convert npc-fma npc-divsqrt npc-matrix clean

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

arith: fp-config
	$(MAKE) -C $(NEMU_HOME) $(NEMU_DEFCONFIG)
	$(MAKE) -C $(NEMU_HOME) -j$$(nproc)
	mkdir -p $(BUILD_DIR)
	$(CC) -march=$(MARCH) -mabi=$(MABI) -nostdlib -nostartfiles \
		-T $(LINKER) -o $(BUILD_DIR)/fp_arith_$(ISA).elf fp_arith.S
	$(OBJCOPY) -O binary $(BUILD_DIR)/fp_arith_$(ISA).elf $(BUILD_DIR)/fp_arith_$(ISA).bin
	cd $(NEMU_HOME) && ./build/$$(basename $(NEMU_BIN)) -b -n \
		--log=$(BUILD_DIR)/fp_arith_$(ISA).nemu.log $(BUILD_DIR)/fp_arith_$(ISA).bin

arith-spike: fp-config
	$(MAKE) -C $(NEMU_HOME) $(NEMU_SPIKE_DEFCONFIG)
	$(MAKE) -C $(NEMU_HOME) -j$$(nproc)
	$(MAKE) -C $(NEMU_HOME)/tools/spike-diff \
		CONFIG_RV64=$(SPIKE_RV64) GUEST_ISA=riscv -j$$(nproc)
	mkdir -p $(BUILD_DIR)
	$(CC) -march=$(MARCH) -mabi=$(MABI) -nostdlib -nostartfiles \
		-T $(LINKER) -o $(BUILD_DIR)/fp_arith_$(ISA).elf fp_arith.S
	$(OBJCOPY) -O binary $(BUILD_DIR)/fp_arith_$(ISA).elf $(BUILD_DIR)/fp_arith_$(ISA).bin
	cd $(NEMU_HOME) && ./build/$$(basename $(NEMU_BIN)) -b -n \
		--diff=$(SPIKE_SO) $(BUILD_DIR)/fp_arith_$(ISA).bin

fcsr: fp-config
	$(MAKE) -C $(NEMU_HOME) $(NEMU_DEFCONFIG)
	$(MAKE) -C $(NEMU_HOME) -j$$(nproc)
	mkdir -p $(BUILD_DIR)
	$(CC) -march=$(MARCH) -mabi=$(MABI) -nostdlib -nostartfiles \
		-T $(LINKER) -o $(BUILD_DIR)/fp_fcsr_$(ISA).elf fp_fcsr.S
	$(OBJCOPY) -O binary $(BUILD_DIR)/fp_fcsr_$(ISA).elf $(BUILD_DIR)/fp_fcsr_$(ISA).bin
	cd $(NEMU_HOME) && ./build/$$(basename $(NEMU_BIN)) -b -n \
		$(BUILD_DIR)/fp_fcsr_$(ISA).bin

fcsr-spike: fp-config
	$(MAKE) -C $(NEMU_HOME) $(NEMU_SPIKE_DEFCONFIG)
	$(MAKE) -C $(NEMU_HOME) -j$$(nproc)
	$(MAKE) -C $(NEMU_HOME)/tools/spike-diff \
		CONFIG_RV64=$(SPIKE_RV64) GUEST_ISA=riscv -j$$(nproc)
	mkdir -p $(BUILD_DIR)
	$(CC) -march=$(MARCH) -mabi=$(MABI) -nostdlib -nostartfiles \
		-T $(LINKER) -o $(BUILD_DIR)/fp_fcsr_$(ISA).elf fp_fcsr.S
	$(OBJCOPY) -O binary $(BUILD_DIR)/fp_fcsr_$(ISA).elf $(BUILD_DIR)/fp_fcsr_$(ISA).bin
	cd $(NEMU_HOME) && ./build/$$(basename $(NEMU_BIN)) -b -n \
		--diff=$(SPIKE_SO) $(BUILD_DIR)/fp_fcsr_$(ISA).bin

rm-illegal-spike: fp-config
	$(MAKE) -C $(NEMU_HOME) $(NEMU_SPIKE_DEFCONFIG)
	$(MAKE) -C $(NEMU_HOME) -j$$(nproc)
	$(MAKE) -C $(NEMU_HOME)/tools/spike-diff \
		CONFIG_RV64=$(SPIKE_RV64) GUEST_ISA=riscv -j$$(nproc)
	mkdir -p $(BUILD_DIR)
	$(CC) -march=$(MARCH) -mabi=$(MABI) -nostdlib -nostartfiles \
		-T $(LINKER) -o $(BUILD_DIR)/fp_rm_illegal_$(ISA).elf fp_rm_illegal.S
	$(OBJCOPY) -O binary $(BUILD_DIR)/fp_rm_illegal_$(ISA).elf $(BUILD_DIR)/fp_rm_illegal_$(ISA).bin
	cd $(NEMU_HOME) && ./build/$$(basename $(NEMU_BIN)) -b -n \
		--diff=$(SPIKE_SO) $(BUILD_DIR)/fp_rm_illegal_$(ISA).bin

fs-spike: fp-config
	$(MAKE) -C $(NEMU_HOME) $(NEMU_SPIKE_DEFCONFIG)
	$(MAKE) -C $(NEMU_HOME) -j$$(nproc)
	$(MAKE) -C $(NEMU_HOME)/tools/spike-diff \
		CONFIG_RV64=$(SPIKE_RV64) GUEST_ISA=riscv -j$$(nproc)
	mkdir -p $(BUILD_DIR)
	$(CC) -march=$(MARCH) -mabi=$(MABI) -nostdlib -nostartfiles \
		-T $(LINKER) -o $(BUILD_DIR)/fp_fs_$(ISA).elf fp_fs.S
	$(OBJCOPY) -O binary $(BUILD_DIR)/fp_fs_$(ISA).elf $(BUILD_DIR)/fp_fs_$(ISA).bin
	cd $(NEMU_HOME) && ./build/$$(basename $(NEMU_BIN)) -b -n \
		--diff=$(SPIKE_SO) $(BUILD_DIR)/fp_fs_$(ISA).bin

fs-mem-spike: fp-config
	$(MAKE) -C $(NEMU_HOME) $(NEMU_SPIKE_DEFCONFIG)
	$(MAKE) -C $(NEMU_HOME) -j$$(nproc)
	$(MAKE) -C $(NEMU_HOME)/tools/spike-diff \
		CONFIG_RV64=$(SPIKE_RV64) GUEST_ISA=riscv -j$$(nproc)
	mkdir -p $(BUILD_DIR)
	$(CC) -march=$(if $(filter rv32,$(ISA)),rv32imafdc,rv64imafdc) \
		-mabi=$(if $(filter rv32,$(ISA)),ilp32d,lp64d) -nostdlib -nostartfiles \
		-T $(LINKER) -o $(BUILD_DIR)/fp_fs_mem_$(ISA).elf fp_fs_mem.S
	$(OBJCOPY) -O binary $(BUILD_DIR)/fp_fs_mem_$(ISA).elf $(BUILD_DIR)/fp_fs_mem_$(ISA).bin
	cd $(NEMU_HOME) && ./build/$(if $(filter rv32,$(ISA)),riscv32-nemu-interpreter,riscv64-nemu-interpreter) \
		-b -n --diff=$(SPIKE_SO) $(BUILD_DIR)/fp_fs_mem_$(ISA).bin

d-arith: fp-config
	$(MAKE) -C $(NEMU_HOME) $(NEMU_DEFCONFIG)
	$(MAKE) -C $(NEMU_HOME) -j$$(nproc)
	mkdir -p $(BUILD_DIR)
	$(CC) -march=$(if $(filter rv32,$(ISA)),rv32imafdc,rv64imafdc) \
		-mabi=$(if $(filter rv32,$(ISA)),ilp32d,lp64d) -nostdlib -nostartfiles \
		-T $(LINKER) -o $(BUILD_DIR)/fp_d_arith_$(ISA).elf fp_d_arith.S
	$(OBJCOPY) -O binary $(BUILD_DIR)/fp_d_arith_$(ISA).elf $(BUILD_DIR)/fp_d_arith_$(ISA).bin
	cd $(NEMU_HOME) && ./build/$(if $(filter rv32,$(ISA)),riscv32-nemu-interpreter,riscv64-nemu-interpreter) \
		-b -n $(BUILD_DIR)/fp_d_arith_$(ISA).bin

d-arith-spike: fp-config
	$(MAKE) -C $(NEMU_HOME) $(NEMU_SPIKE_DEFCONFIG)
	$(MAKE) -C $(NEMU_HOME) -j$$(nproc)
	$(MAKE) -C $(NEMU_HOME)/tools/spike-diff \
		CONFIG_RV64=$(SPIKE_RV64) GUEST_ISA=riscv -j$$(nproc)
	mkdir -p $(BUILD_DIR)
	$(CC) -march=$(if $(filter rv32,$(ISA)),rv32imafdc,rv64imafdc) \
		-mabi=$(if $(filter rv32,$(ISA)),ilp32d,lp64d) -nostdlib -nostartfiles \
		-T $(LINKER) -o $(BUILD_DIR)/fp_d_arith_$(ISA).elf fp_d_arith.S
	$(OBJCOPY) -O binary $(BUILD_DIR)/fp_d_arith_$(ISA).elf $(BUILD_DIR)/fp_d_arith_$(ISA).bin
	cd $(NEMU_HOME) && ./build/$(if $(filter rv32,$(ISA)),riscv32-nemu-interpreter,riscv64-nemu-interpreter) \
		-b -n --diff=$(SPIKE_SO) $(BUILD_DIR)/fp_d_arith_$(ISA).bin

minmax-spike: fp-config
	$(MAKE) -C $(NEMU_HOME) $(NEMU_SPIKE_DEFCONFIG)
	$(MAKE) -C $(NEMU_HOME) -j$$(nproc)
	$(MAKE) -C $(NEMU_HOME)/tools/spike-diff \
		CONFIG_RV64=$(SPIKE_RV64) GUEST_ISA=riscv -j$$(nproc)
	mkdir -p $(BUILD_DIR)
	$(CC) -march=$(if $(filter rv32,$(ISA)),rv32imafdc,rv64imafdc) \
		-mabi=$(if $(filter rv32,$(ISA)),ilp32d,lp64d) -nostdlib -nostartfiles \
		-T $(LINKER) -o $(BUILD_DIR)/fp_minmax_$(ISA).elf fp_minmax.S
	$(OBJCOPY) -O binary $(BUILD_DIR)/fp_minmax_$(ISA).elf $(BUILD_DIR)/fp_minmax_$(ISA).bin
	cd $(NEMU_HOME) && ./build/$(if $(filter rv32,$(ISA)),riscv32-nemu-interpreter,riscv64-nemu-interpreter) \
		-b -n --diff=$(SPIKE_SO) $(BUILD_DIR)/fp_minmax_$(ISA).bin

compare-spike: fp-config
	$(MAKE) -C $(NEMU_HOME) $(NEMU_SPIKE_DEFCONFIG)
	$(MAKE) -C $(NEMU_HOME) -j$$(nproc)
	$(MAKE) -C $(NEMU_HOME)/tools/spike-diff \
		CONFIG_RV64=$(SPIKE_RV64) GUEST_ISA=riscv -j$$(nproc)
	mkdir -p $(BUILD_DIR)
	$(CC) -march=$(if $(filter rv32,$(ISA)),rv32imafdc,rv64imafdc) \
		-mabi=$(if $(filter rv32,$(ISA)),ilp32d,lp64d) -nostdlib -nostartfiles \
		-T $(LINKER) -o $(BUILD_DIR)/fp_compare_$(ISA).elf fp_compare.S
	$(OBJCOPY) -O binary $(BUILD_DIR)/fp_compare_$(ISA).elf $(BUILD_DIR)/fp_compare_$(ISA).bin
	cd $(NEMU_HOME) && ./build/$(if $(filter rv32,$(ISA)),riscv32-nemu-interpreter,riscv64-nemu-interpreter) \
		-b -n --diff=$(SPIKE_SO) $(BUILD_DIR)/fp_compare_$(ISA).bin

convert-spike: fp-config
	$(MAKE) -C $(NEMU_HOME) $(NEMU_SPIKE_DEFCONFIG)
	$(MAKE) -C $(NEMU_HOME) -j$$(nproc)
	$(MAKE) -C $(NEMU_HOME)/tools/spike-diff \
		CONFIG_RV64=$(SPIKE_RV64) GUEST_ISA=riscv -j$$(nproc)
	mkdir -p $(BUILD_DIR)
	$(CC) -march=$(if $(filter rv32,$(ISA)),rv32imafdc,rv64imafdc) \
		-mabi=$(if $(filter rv32,$(ISA)),ilp32d,lp64d) -nostdlib -nostartfiles \
		-T $(LINKER) -o $(BUILD_DIR)/fp_convert_$(ISA).elf fp_convert.S
	$(OBJCOPY) -O binary $(BUILD_DIR)/fp_convert_$(ISA).elf $(BUILD_DIR)/fp_convert_$(ISA).bin
	cd $(NEMU_HOME) && ./build/$(if $(filter rv32,$(ISA)),riscv32-nemu-interpreter,riscv64-nemu-interpreter) \
		-b -n --diff=$(SPIKE_SO) $(BUILD_DIR)/fp_convert_$(ISA).bin

fma-spike: fp-config
	$(MAKE) -C $(NEMU_HOME) $(NEMU_SPIKE_DEFCONFIG)
	$(MAKE) -C $(NEMU_HOME) -j$$(nproc)
	$(MAKE) -C $(NEMU_HOME)/tools/spike-diff \
		CONFIG_RV64=$(SPIKE_RV64) GUEST_ISA=riscv -j$$(nproc)
	mkdir -p $(BUILD_DIR)
	$(CC) -march=$(if $(filter rv32,$(ISA)),rv32imafdc,rv64imafdc) \
		-mabi=$(if $(filter rv32,$(ISA)),ilp32d,lp64d) -nostdlib -nostartfiles \
		-T $(LINKER) -o $(BUILD_DIR)/fp_fma_$(ISA).elf fp_fma.S
	$(OBJCOPY) -O binary $(BUILD_DIR)/fp_fma_$(ISA).elf $(BUILD_DIR)/fp_fma_$(ISA).bin
	cd $(NEMU_HOME) && ./build/$(if $(filter rv32,$(ISA)),riscv32-nemu-interpreter,riscv64-nemu-interpreter) \
		-b -n --diff=$(SPIKE_SO) $(BUILD_DIR)/fp_fma_$(ISA).bin

divsqrt-spike: fp-config
	$(MAKE) -C $(NEMU_HOME) $(NEMU_SPIKE_DEFCONFIG)
	$(MAKE) -C $(NEMU_HOME) -j$$(nproc)
	$(MAKE) -C $(NEMU_HOME)/tools/spike-diff \
		CONFIG_RV64=$(SPIKE_RV64) GUEST_ISA=riscv -j$$(nproc)
	mkdir -p $(BUILD_DIR)
	$(CC) -march=$(if $(filter rv32,$(ISA)),rv32imafdc,rv64imafdc) \
		-mabi=$(if $(filter rv32,$(ISA)),ilp32d,lp64d) -nostdlib -nostartfiles \
		-T $(LINKER) -o $(BUILD_DIR)/fp_divsqrt_$(ISA).elf fp_divsqrt.S
	$(OBJCOPY) -O binary $(BUILD_DIR)/fp_divsqrt_$(ISA).elf $(BUILD_DIR)/fp_divsqrt_$(ISA).bin
	cd $(NEMU_HOME) && ./build/$(if $(filter rv32,$(ISA)),riscv32-nemu-interpreter,riscv64-nemu-interpreter) \
		-b -n --diff=$(SPIKE_SO) $(BUILD_DIR)/fp_divsqrt_$(ISA).bin

npc-arith:
	$(MAKE) -C $(NEMU_HOME) $(NPC_NEMU_F_DEFCONFIG)
	$(MAKE) -C $(NEMU_HOME) -j$$(nproc)
	mkdir -p $(BUILD_DIR)
	$(CC) -march=$(MARCH) -mabi=$(MABI) -nostdlib -nostartfiles \
		-T $(LINKER) -o $(BUILD_DIR)/fp_arith_$(ISA).elf fp_arith.S
	$(OBJCOPY) -O binary $(BUILD_DIR)/fp_arith_$(ISA).elf $(BUILD_DIR)/fp_arith_$(ISA).bin
	$(MAKE) -B -C $(SIM_HOME) run NPROC=$(NPC_NPROC) \
		VFLAGS='$(NPC_VFLAGS)' \
		DIFF_REF_SO='-d $(NPC_DIFF_REF_SO)' \
		IMG=$(BUILD_DIR)/fp_arith_$(ISA).bin ARGS='$(NPC_ARGS)'

npc-fcsr:
	$(MAKE) -C $(NEMU_HOME) $(NPC_NEMU_F_DEFCONFIG)
	$(MAKE) -C $(NEMU_HOME) -j$$(nproc)
	mkdir -p $(BUILD_DIR)
	$(CC) -march=$(MARCH) -mabi=$(MABI) -nostdlib -nostartfiles \
		-T $(LINKER) -o $(BUILD_DIR)/fp_fcsr_$(ISA).elf fp_fcsr.S
	$(OBJCOPY) -O binary $(BUILD_DIR)/fp_fcsr_$(ISA).elf $(BUILD_DIR)/fp_fcsr_$(ISA).bin
	$(MAKE) -B -C $(SIM_HOME) run NPROC=$(NPC_NPROC) \
		VFLAGS='$(NPC_VFLAGS)' \
		DIFF_REF_SO='-d $(NPC_DIFF_REF_SO)' \
		IMG=$(BUILD_DIR)/fp_fcsr_$(ISA).bin ARGS='$(NPC_ARGS)'

npc-rm-illegal:
	$(MAKE) -C $(NEMU_HOME) $(NPC_NEMU_D_DEFCONFIG)
	$(MAKE) -C $(NEMU_HOME) -j$$(nproc)
	mkdir -p $(BUILD_DIR)
	$(CC) -march=$(MARCH) -mabi=$(MABI) -nostdlib -nostartfiles \
		-T $(LINKER) -o $(BUILD_DIR)/fp_rm_illegal_$(ISA).elf fp_rm_illegal.S
	$(OBJCOPY) -O binary $(BUILD_DIR)/fp_rm_illegal_$(ISA).elf $(BUILD_DIR)/fp_rm_illegal_$(ISA).bin
	$(MAKE) -B -C $(SIM_HOME) run NPROC=$(NPC_NPROC) \
		VFLAGS='$(NPC_VFLAGS)' \
		DIFF_REF_SO='-d $(NPC_DIFF_REF_SO)' \
		IMG=$(BUILD_DIR)/fp_rm_illegal_$(ISA).bin ARGS='$(NPC_ARGS)'

npc-fs:
	$(MAKE) -C $(NEMU_HOME) $(NPC_NEMU_F_DEFCONFIG)
	$(MAKE) -C $(NEMU_HOME) -j$$(nproc)
	mkdir -p $(BUILD_DIR)
	$(CC) -march=$(MARCH) -mabi=$(MABI) -nostdlib -nostartfiles \
		-T $(LINKER) -o $(BUILD_DIR)/fp_fs_$(ISA).elf fp_fs.S
	$(OBJCOPY) -O binary $(BUILD_DIR)/fp_fs_$(ISA).elf $(BUILD_DIR)/fp_fs_$(ISA).bin
	$(MAKE) -B -C $(SIM_HOME) run NPROC=$(NPC_NPROC) \
		VFLAGS='$(NPC_VFLAGS)' \
		DIFF_REF_SO='-d $(NPC_DIFF_REF_SO)' \
		IMG=$(BUILD_DIR)/fp_fs_$(ISA).bin ARGS='$(NPC_ARGS)'

npc-fs-mem:
	$(MAKE) -C $(NEMU_HOME) $(NPC_NEMU_D_DEFCONFIG)
	$(MAKE) -C $(NEMU_HOME) -j$$(nproc)
	mkdir -p $(BUILD_DIR)
	$(CC) -march=$(if $(filter rv32,$(ISA)),rv32imafdc,rv64imafdc) \
		-mabi=$(if $(filter rv32,$(ISA)),ilp32d,lp64d) -nostdlib -nostartfiles \
		-T $(LINKER) -o $(BUILD_DIR)/fp_fs_mem_$(ISA).elf fp_fs_mem.S
	$(OBJCOPY) -O binary $(BUILD_DIR)/fp_fs_mem_$(ISA).elf $(BUILD_DIR)/fp_fs_mem_$(ISA).bin
	$(MAKE) -B -C $(SIM_HOME) run NPROC=$(NPC_NPROC) \
		VFLAGS='$(NPC_VFLAGS)' \
		DIFF_REF_SO='-d $(NPC_DIFF_REF_SO)' \
		IMG=$(BUILD_DIR)/fp_fs_mem_$(ISA).bin ARGS='$(NPC_ARGS)'

npc-d-arith:
	$(MAKE) -C $(NEMU_HOME) $(NPC_NEMU_D_DEFCONFIG)
	$(MAKE) -C $(NEMU_HOME) -j$$(nproc)
	mkdir -p $(BUILD_DIR)
	$(CC) -march=$(if $(filter rv32,$(ISA)),rv32imafdc,rv64imafdc) \
		-mabi=$(if $(filter rv32,$(ISA)),ilp32d,lp64d) -nostdlib -nostartfiles \
		-T $(LINKER) -o $(BUILD_DIR)/fp_d_arith_$(ISA).elf fp_d_arith.S
	$(OBJCOPY) -O binary $(BUILD_DIR)/fp_d_arith_$(ISA).elf $(BUILD_DIR)/fp_d_arith_$(ISA).bin
	$(MAKE) -B -C $(SIM_HOME) run NPROC=$(NPC_NPROC) \
		VFLAGS='$(NPC_VFLAGS)' \
		DIFF_REF_SO='-d $(NPC_DIFF_REF_SO)' \
		IMG=$(BUILD_DIR)/fp_d_arith_$(ISA).bin ARGS='$(NPC_ARGS)'

npc-minmax:
	$(MAKE) -C $(NEMU_HOME) $(NPC_NEMU_D_DEFCONFIG)
	$(MAKE) -C $(NEMU_HOME) -j$$(nproc)
	mkdir -p $(BUILD_DIR)
	$(CC) -march=$(if $(filter rv32,$(ISA)),rv32imafdc,rv64imafdc) \
		-mabi=$(if $(filter rv32,$(ISA)),ilp32d,lp64d) -nostdlib -nostartfiles \
		-T $(LINKER) -o $(BUILD_DIR)/fp_minmax_$(ISA).elf fp_minmax.S
	$(OBJCOPY) -O binary $(BUILD_DIR)/fp_minmax_$(ISA).elf $(BUILD_DIR)/fp_minmax_$(ISA).bin
	$(MAKE) -B -C $(SIM_HOME) run NPROC=$(NPC_NPROC) \
		VFLAGS='$(NPC_VFLAGS)' \
		DIFF_REF_SO='-d $(NPC_DIFF_REF_SO)' \
		IMG=$(BUILD_DIR)/fp_minmax_$(ISA).bin ARGS='$(NPC_ARGS)'

npc-compare:
	$(MAKE) -C $(NEMU_HOME) $(NPC_NEMU_D_DEFCONFIG)
	$(MAKE) -C $(NEMU_HOME) -j$$(nproc)
	mkdir -p $(BUILD_DIR)
	$(CC) -march=$(if $(filter rv32,$(ISA)),rv32imafdc,rv64imafdc) \
		-mabi=$(if $(filter rv32,$(ISA)),ilp32d,lp64d) -nostdlib -nostartfiles \
		-T $(LINKER) -o $(BUILD_DIR)/fp_compare_$(ISA).elf fp_compare.S
	$(OBJCOPY) -O binary $(BUILD_DIR)/fp_compare_$(ISA).elf $(BUILD_DIR)/fp_compare_$(ISA).bin
	$(MAKE) -B -C $(SIM_HOME) run NPROC=$(NPC_NPROC) \
		VFLAGS='$(NPC_VFLAGS)' \
		DIFF_REF_SO='-d $(NPC_DIFF_REF_SO)' \
		IMG=$(BUILD_DIR)/fp_compare_$(ISA).bin ARGS='$(NPC_ARGS)'

npc-convert:
	$(MAKE) -C $(NEMU_HOME) $(NPC_NEMU_D_DEFCONFIG)
	$(MAKE) -C $(NEMU_HOME) -j$$(nproc)
	mkdir -p $(BUILD_DIR)
	$(CC) -march=$(if $(filter rv32,$(ISA)),rv32imafdc,rv64imafdc) \
		-mabi=$(if $(filter rv32,$(ISA)),ilp32d,lp64d) -nostdlib -nostartfiles \
		-T $(LINKER) -o $(BUILD_DIR)/fp_convert_$(ISA).elf fp_convert.S
	$(OBJCOPY) -O binary $(BUILD_DIR)/fp_convert_$(ISA).elf $(BUILD_DIR)/fp_convert_$(ISA).bin
	$(MAKE) -B -C $(SIM_HOME) run NPROC=$(NPC_NPROC) \
		VFLAGS='$(NPC_VFLAGS)' \
		DIFF_REF_SO='-d $(NPC_DIFF_REF_SO)' \
		IMG=$(BUILD_DIR)/fp_convert_$(ISA).bin ARGS='$(NPC_ARGS)'

npc-fma:
	$(MAKE) -C $(NEMU_HOME) $(NPC_NEMU_D_DEFCONFIG)
	$(MAKE) -C $(NEMU_HOME) -j$$(nproc)
	mkdir -p $(BUILD_DIR)
	$(CC) -march=$(if $(filter rv32,$(ISA)),rv32imafdc,rv64imafdc) \
		-mabi=$(if $(filter rv32,$(ISA)),ilp32d,lp64d) -nostdlib -nostartfiles \
		-T $(LINKER) -o $(BUILD_DIR)/fp_fma_$(ISA).elf fp_fma.S
	$(OBJCOPY) -O binary $(BUILD_DIR)/fp_fma_$(ISA).elf $(BUILD_DIR)/fp_fma_$(ISA).bin
	$(MAKE) -B -C $(SIM_HOME) run NPROC=$(NPC_NPROC) \
		VFLAGS='$(NPC_VFLAGS)' \
		DIFF_REF_SO='-d $(NPC_DIFF_REF_SO)' \
		IMG=$(BUILD_DIR)/fp_fma_$(ISA).bin ARGS='$(NPC_ARGS)'

npc-divsqrt:
	$(MAKE) -C $(NEMU_HOME) $(NPC_NEMU_D_DEFCONFIG)
	$(MAKE) -C $(NEMU_HOME) -j$$(nproc)
	mkdir -p $(BUILD_DIR)
	$(CC) -march=$(if $(filter rv32,$(ISA)),rv32imafdc,rv64imafdc) \
		-mabi=$(if $(filter rv32,$(ISA)),ilp32d,lp64d) -nostdlib -nostartfiles \
		-T $(LINKER) -o $(BUILD_DIR)/fp_divsqrt_$(ISA).elf fp_divsqrt.S
	$(OBJCOPY) -O binary $(BUILD_DIR)/fp_divsqrt_$(ISA).elf $(BUILD_DIR)/fp_divsqrt_$(ISA).bin
	$(MAKE) -B -C $(SIM_HOME) run NPROC=$(NPC_NPROC) \
		VFLAGS='$(NPC_VFLAGS)' \
		DIFF_REF_SO='-d $(NPC_DIFF_REF_SO)' \
		IMG=$(BUILD_DIR)/fp_divsqrt_$(ISA).bin ARGS='$(NPC_ARGS)'

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

double: fp-config
	$(MAKE) -C $(NEMU_HOME) $(NEMU_DEFCONFIG)
	$(MAKE) -C $(NEMU_HOME) -j$$(nproc)
	mkdir -p $(BUILD_DIR)
	$(CC) -march=$(if $(filter rv32,$(ISA)),rv32imafdc,rv64imafdc) \
		-mabi=$(if $(filter rv32,$(ISA)),ilp32d,lp64d) -nostdlib -nostartfiles \
		-T $(LINKER) -o $(BUILD_DIR)/fp_double_$(ISA).elf fp_double.S
	$(OBJCOPY) -O binary $(BUILD_DIR)/fp_double_$(ISA).elf $(BUILD_DIR)/fp_double_$(ISA).bin
	cd $(NEMU_HOME) && ./build/$(if $(filter rv32,$(ISA)),riscv32-nemu-interpreter,riscv64-nemu-interpreter) \
		-b -n $(BUILD_DIR)/fp_double_$(ISA).bin

double-unaligned: fp-config
	$(MAKE) -C $(NEMU_HOME) $(NEMU_DEFCONFIG)
	$(MAKE) -C $(NEMU_HOME) -j$$(nproc)
	mkdir -p $(BUILD_DIR)
	$(CC) -march=$(if $(filter rv32,$(ISA)),rv32imafdc,rv64imafdc) \
		-mabi=$(if $(filter rv32,$(ISA)),ilp32d,lp64d) -nostdlib -nostartfiles \
		-T $(LINKER) -o $(BUILD_DIR)/fp_double_unaligned_$(ISA).elf fp_double_unaligned.S
	$(OBJCOPY) -O binary $(BUILD_DIR)/fp_double_unaligned_$(ISA).elf $(BUILD_DIR)/fp_double_unaligned_$(ISA).bin
	cd $(NEMU_HOME) && ./build/$(if $(filter rv32,$(ISA)),riscv32-nemu-interpreter,riscv64-nemu-interpreter) \
		-b -n $(BUILD_DIR)/fp_double_unaligned_$(ISA).bin

clean:
	rm -f $(ELF) $(BIN) $(LOG) $(BUILD_DIR)/fp_moves_rv32.elf \
		$(BUILD_DIR)/fp_moves_rv32.bin $(BUILD_DIR)/fp_moves_rv32.nemu.log
