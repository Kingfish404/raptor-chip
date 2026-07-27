ROOT := $(abspath ../../..)
PLATFORM ?= sim
BUILD := build/$(PLATFORM)
PYTHON ?= python3
ARGS ?= -b -n
MAX_INST ?=
PAYLOAD ?= slub_freelist
MEM_RANDOM_DELAY ?= 32
MEM_RANDOM_SEED ?= 1
MEM_STRESS_SEEDS ?= 1 2 7
MEM_STRESS_PAYLOADS ?= amo_lrsc cache_refill_conflict page_sweep sq_overlap

CROSS ?= $(firstword $(foreach p,riscv64-unknown-elf- riscv64-elf- riscv64-linux-gnu-,$(if $(shell command -v $(p)gcc 2>/dev/null),$(p))))
CC := $(CROSS)gcc
OBJCOPY := $(CROSS)objcopy
OBJDUMP := $(CROSS)objdump
SIZE := $(CROSS)size

ARCH := rv32imac_zicsr_zifencei
CFLAGS := -march=$(ARCH) -mabi=ilp32 -mcmodel=medany -Os -g -Wall -Wextra \
	-ffreestanding -fno-builtin -fno-pic -fno-stack-protector \
	-ffunction-sections -fdata-sections -nostdlib -nostartfiles -Iinclude -Iuser -Ipayloads \
	$(if $(filter ku15p,$(PLATFORM)),-DRAPTOS_KU15P,)
LINKER_SCRIPT := arch/riscv/raptos.ld
LDFLAGS := -T $(LINKER_SCRIPT) -Wl,--gc-sections -Wl,--build-id=none -Wl,-Map,$(BUILD)/raptos.map
USER_OBJS := $(BUILD)/user.o $(BUILD)/user_runtime.o $(BUILD)/user_service.o \
	$(BUILD)/user_debug.o $(BUILD)/user_script.o $(BUILD)/user_payload.o $(BUILD)/user_init.o
PAYLOAD_SRCS := $(wildcard payloads/*/payload.c)
PAYLOAD_OBJS := $(patsubst payloads/%/payload.c,$(BUILD)/payload_%.o,$(PAYLOAD_SRCS))
PAYLOAD_NAMES := $(patsubst payloads/%/payload.c,%,$(PAYLOAD_SRCS))
OBJS := $(BUILD)/boot.o $(BUILD)/trap.o $(USER_OBJS) $(PAYLOAD_OBJS) \
	$(BUILD)/kernel.o $(BUILD)/disk_image.o
ROOTFS := fs/rootfs
ROOTFS_FILES := $(shell find $(ROOTFS) -mindepth 1 -print)

.DEFAULT_GOAL := help

help:
	@echo "RaptOS targets:"
	@echo "  build/all    Build PLATFORM=sim|ku15p (default: sim)"
	@echo "  nemu         Fast functional shell on NEMU (run first)"
	@echo "  sim          RTL shell on NPC (run after NEMU)"
	@echo "  payload-test Run one payload on NPC with randomized memory delay"
	@echo "  payload-test-all Run every payload on NPC with randomized memory delay"
	@echo "  memory-stress Run critical memory payloads across randomized seeds"
	@echo "  payloads     List auto-discovered payloads"
	@echo "  clean        Remove the selected PLATFORM output"
	@echo "  clean-all    Remove all generated outputs"
	@echo "Variables: PLATFORM ARGS MAX_INST PAYLOAD MEM_RANDOM_DELAY MEM_RANDOM_SEED"
	@echo "           MEM_STRESS_PAYLOADS MEM_STRESS_SEEDS CROSS"

payloads:
	@find payloads -mindepth 2 -maxdepth 2 -name payload.c -printf '%h\n' | sed 's|payloads/||' | sort

build all: $(BUILD)/raptos.bin

$(BUILD):
	mkdir -p $@

$(BUILD)/boot.o: arch/riscv/machine/boot.S | $(BUILD)
	$(CC) $(CFLAGS) -c -o $@ $<

$(BUILD)/trap.o: arch/riscv/machine/trap.S | $(BUILD)
	$(CC) $(CFLAGS) -c -o $@ $<

$(BUILD)/kernel.o: kernel/kernel.c include/raptos.h | $(BUILD)
	$(CC) $(CFLAGS) -c -o $@ $<

$(BUILD)/payload_%.o: payloads/%/payload.c payloads/payload.h user/user.h include/raptos.h | $(BUILD)
	$(CC) $(CFLAGS) -c -o $@ $<

$(BUILD)/user.o: user/user.c user/user.h include/raptos.h | $(BUILD)
	$(CC) $(CFLAGS) -c -o $@ $<

$(BUILD)/user_%.o: user/user_%.c user/user.h include/raptos.h | $(BUILD)
	$(CC) $(CFLAGS) -c -o $@ $<

$(BUILD)/disk.img $(BUILD)/disk_image.c &: tools/mkfs.py $(ROOTFS_FILES) | $(BUILD)
	$(PYTHON) tools/mkfs.py --root $(ROOTFS) --image $(BUILD)/disk.img --image-c $(BUILD)/disk_image.c

$(BUILD)/disk_image.o: $(BUILD)/disk_image.c
	$(CC) $(CFLAGS) -c -o $@ $<

$(BUILD)/raptos.elf: $(OBJS) $(LINKER_SCRIPT)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $@ $(OBJS) -lgcc
	$(SIZE) $@

$(BUILD)/raptos.bin: $(BUILD)/raptos.elf
	$(OBJCOPY) -O binary $< $@
	@bytes=$$(stat -c%s $@); \
	 test $$bytes -le 262144 || { echo "[ERR] RaptOS image is $$bytes bytes (limit: 262144)"; rm -f $@; exit 1; }; \
	 echo "[RaptOS] image: $@ ($$bytes bytes, limit 262144)"

disasm: $(BUILD)/raptos.elf
	$(OBJDUMP) -d -S $< > $(BUILD)/raptos.dis

sim:
	@$(MAKE) --no-print-directory all PLATFORM=sim
	@$(MAKE) --no-print-directory -C $(ROOT) run-rv32 \
		IMG=$(abspath build/sim/raptos.bin) \
		ARGS="$(ARGS) $(if $(MAX_INST),-m $(MAX_INST),)"

nemu:
	@$(MAKE) --no-print-directory all PLATFORM=sim
	@$(MAKE) --no-print-directory -C $(ROOT) run-nemu32 \
		IMG=$(abspath build/sim/raptos.bin) \
		ARGS="$(ARGS) $(if $(MAX_INST),-m $(MAX_INST),)"

payload-test: all
	@printf '$(if $(SMODE),smode\n,)$(if $(TICK),tick $(TICK)\n,)payload $(PAYLOAD)\n$(if $(TICK),tick 0\n,)halt\n' | $(MAKE) --no-print-directory -C $(ROOT) run-rv32 \
		IMG=$(abspath build/sim/raptos.bin) \
		ARGS="-b -n --mem-random-delay=$(MEM_RANDOM_DELAY) --mem-random-seed=$(MEM_RANDOM_SEED) $(if $(MAX_INST),-m $(MAX_INST),)"

payload-test-all: all
	@set -e; \
	for payload in $(PAYLOAD_NAMES); do \
		echo "[RaptOS] payload=$$payload delay=$(MEM_RANDOM_DELAY) seed=$(MEM_RANDOM_SEED)"; \
		printf '$(if $(SMODE),smode\n,)$(if $(TICK),tick $(TICK)\n,)payload %s\n$(if $(TICK),tick 0\n,)halt\n' "$$payload" | \
			$(MAKE) --no-print-directory -C $(ROOT) run-rv32 \
				IMG=$(abspath build/sim/raptos.bin) \
				ARGS="-b -n --mem-random-delay=$(MEM_RANDOM_DELAY) --mem-random-seed=$(MEM_RANDOM_SEED) $(if $(MAX_INST),-m $(MAX_INST),)"; \
	done

memory-stress: all
	@set -e; \
	for seed in $(MEM_STRESS_SEEDS); do \
		for payload in $(MEM_STRESS_PAYLOADS); do \
			echo "[RaptOS memory-stress] payload=$$payload delay=$(MEM_RANDOM_DELAY) seed=$$seed"; \
			$(MAKE) --no-print-directory payload-test \
				PAYLOAD=$$payload MEM_RANDOM_DELAY=$(MEM_RANDOM_DELAY) MEM_RANDOM_SEED=$$seed \
				$(if $(MAX_INST),MAX_INST=$(MAX_INST),); \
		done; \
	done

clean:
	rm -rf $(BUILD)

clean-all:
	rm -rf build

.PHONY: help build all clean clean-all disasm sim nemu payload-test payload-test-all memory-stress payloads
