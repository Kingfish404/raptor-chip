ROOT := $(abspath ../../..)
MEM_STRESS_FAST ?= 0
PLATFORM ?= $(if $(filter 1,$(MEM_STRESS_FAST)),sim-memory-fast,sim)
BUILD := build/$(PLATFORM)
XLEN ?= $(if $(filter %-rv64,$(PLATFORM)),64,32)
PYTHON ?= python3
ARGS ?= -b -n
MAX_INST ?=
TIMEOUT ?=
PAYLOAD ?= slub_freelist
NPC_EXEC_PREFIX ?=
MEM_RANDOM_DELAY ?= 32
MEM_RANDOM_SEED ?= 1
MEM_STRESS_SEEDS ?= 1 2 7
MEM_STRESS_PAYLOADS ?= amo_lrsc cache_refill_conflict page_sweep sq_overlap
MEM_STRESS_LOG_DIR ?= $(BUILD)/logs/memory-stress
MATRIX_JOBS ?= $(if $(JOBS),$(JOBS),$(shell n=$$(nproc 2>/dev/null || echo 2); echo $$((n > 1 ? n / 2 : 1))))
SUBMAKE_JOBS = $(if $(filter --jobserver-auth=% --jobserver-fds=%,$(MAKEFLAGS)),,-j$(MATRIX_JOBS))

CROSS ?= $(firstword $(foreach p,riscv64-unknown-elf- riscv64-elf- riscv64-linux-gnu-,$(if $(shell command -v $(p)gcc 2>/dev/null),$(p))))
CC := $(CROSS)gcc
OBJCOPY := $(CROSS)objcopy
OBJDUMP := $(CROSS)objdump
SIZE := $(CROSS)size

ARCH ?= $(if $(filter 64,$(XLEN)),rv64imac_zicsr_zifencei,rv32imac_zicsr_zifencei)
MABI ?= $(if $(filter 64,$(XLEN)),lp64,ilp32)
CFLAGS := -march=$(ARCH) -mabi=$(MABI) -mcmodel=medany -Os -g -Wall -Wextra \
	-ffreestanding -fno-builtin -fno-pic -fno-stack-protector \
	-ffunction-sections -fdata-sections -nostdlib -nostartfiles -Iinclude -Iuser -Ipayloads \
	$(if $(findstring ku15p,$(PLATFORM)),-DRAPTOS_KU15P,) \
	$(if $(filter 1,$(MEM_STRESS_FAST)),-DRAPTOS_CACHE_REFILL_ROUNDS=2000 -DRAPTOS_PAGE_SWEEP_ROUNDS=30,)
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
ROOTFS_FILES := $(shell test ! -d $(ROOTFS) || find $(ROOTFS) -mindepth 1 -print)

.DEFAULT_GOAL := help

help:
	@echo "RaptOS targets:"
	@echo "  build/all    Build PLATFORM=sim|ku15p-rv32|ku15p-rv64 (default: sim)"
	@echo "  nemu         Fast functional shell on NEMU (run first)"
	@echo "  sim          RTL shell on NPC (run after NEMU)"
	@echo "  payload-test Run one payload on NPC with randomized memory delay"
	@echo "  payload-test-all Run every payload on NPC with randomized memory delay"
	@echo "  memory-stress Run critical memory payloads across randomized seeds"
	@echo "  payloads     List auto-discovered payloads"
	@echo "  clean        Remove the selected PLATFORM output"
	@echo "  clean-all    Remove all generated outputs"
	@echo "Variables: PLATFORM XLEN ARCH MABI ARGS MAX_INST TIMEOUT PAYLOAD MEM_RANDOM_DELAY MEM_RANDOM_SEED"
	@echo "           MEM_STRESS_PAYLOADS MEM_STRESS_SEEDS MEM_STRESS_FAST MEM_STRESS_LOG_DIR MATRIX_JOBS CROSS"

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
ifeq ($(strip $(NPC_EXEC_PREFIX)),)
	@printf '$(if $(SMODE),smode\n,)$(if $(TICK),tick $(TICK)\n,)payload $(PAYLOAD)\n$(if $(TICK),tick 0\n,)halt\n' | $(MAKE) --no-print-directory -C $(ROOT) run-rv32 \
		IMG=$(abspath $(BUILD)/raptos.bin) \
		ARGS="-b -n --mem-random-delay=$(MEM_RANDOM_DELAY) --mem-random-seed=$(MEM_RANDOM_SEED) $(if $(MAX_INST),-m $(MAX_INST),) $(if $(TIMEOUT),-t $(TIMEOUT),)"
else
	@cd $(ROOT)/sim && \
		printf '$(if $(SMODE),smode\n,)$(if $(TICK),tick $(TICK)\n,)payload $(PAYLOAD)\n$(if $(TICK),tick 0\n,)halt\n' | \
		$(NPC_EXEC_PREFIX) -b -n \
		--mem-random-delay=$(MEM_RANDOM_DELAY) --mem-random-seed=$(MEM_RANDOM_SEED) \
		$(if $(MAX_INST),-m $(MAX_INST),) $(if $(TIMEOUT),-t $(TIMEOUT),) \
		$(abspath $(BUILD)/raptos.bin)
endif

payload-test-all: all
	@set -e; \
	for payload in $(PAYLOAD_NAMES); do \
		echo "[RaptOS] payload=$$payload delay=$(MEM_RANDOM_DELAY) seed=$(MEM_RANDOM_SEED)"; \
		printf '$(if $(SMODE),smode\n,)$(if $(TICK),tick $(TICK)\n,)payload %s\n$(if $(TICK),tick 0\n,)halt\n' "$$payload" | \
			$(MAKE) --no-print-directory -C $(ROOT) run-rv32 \
				IMG=$(abspath $(BUILD)/raptos.bin) \
				ARGS="-b -n --mem-random-delay=$(MEM_RANDOM_DELAY) --mem-random-seed=$(MEM_RANDOM_SEED) $(if $(MAX_INST),-m $(MAX_INST),) $(if $(TIMEOUT),-t $(TIMEOUT),)"; \
	done

MEM_STRESS_CASES := $(foreach seed,$(MEM_STRESS_SEEDS),$(foreach payload,$(MEM_STRESS_PAYLOADS),memory-stress-$(payload)-seed$(seed)))

define memory_stress_case
memory-stress-$(2)-seed$(1):
	@mkdir -p $(abspath $(MEM_STRESS_LOG_DIR))
	@log="$(abspath $(MEM_STRESS_LOG_DIR))/$(2)-delay$(MEM_RANDOM_DELAY)-seed$(1).log"; \
	 echo "[RaptOS memory-stress] START payload=$(2) delay=$(MEM_RANDOM_DELAY) seed=$(1)"; \
	 test -n "$(NPC_EXEC_PREFIX)" || { echo "[RaptOS memory-stress] ERROR: missing NPC_EXEC_PREFIX"; exit 1; }; \
	 if cd $(ROOT)/sim && \
	    printf '$(if $(SMODE),smode\n,)$(if $(TICK),tick $(TICK)\n,)payload $(2)\n$(if $(TICK),tick 0\n,)halt\n' | \
	    $(NPC_EXEC_PREFIX) -b -n \
	      --mem-random-delay=$(MEM_RANDOM_DELAY) --mem-random-seed=$(1) \
	      $(if $(MAX_INST),-m $(MAX_INST),) $(if $(TIMEOUT),-t $(TIMEOUT),) \
	      $(abspath $(BUILD)/raptos.bin) >"$$$$log" 2>&1; then \
	   echo "[RaptOS memory-stress] PASS payload=$(2) delay=$(MEM_RANDOM_DELAY) seed=$(1) log=$$$$log"; \
	 else \
	   status=$$$$?; \
	   echo "[RaptOS memory-stress] FAIL payload=$(2) delay=$(MEM_RANDOM_DELAY) seed=$(1) status=$$$$status log=$$$$log"; \
	   tail -n 40 "$$$$log"; \
	   exit $$$$status; \
	 fi
endef
$(foreach seed,$(MEM_STRESS_SEEDS),$(foreach payload,$(MEM_STRESS_PAYLOADS),$(eval $(call memory_stress_case,$(seed),$(payload)))))

memory-stress: all
	+@$(MAKE) --no-print-directory -C $(ROOT) build-rv32
	+@npc_exec="$$( $(MAKE) --no-print-directory -s -C $(ROOT)/sim print-npc-exec )"; \
		test -n "$$npc_exec"; \
		$(MAKE) --no-print-directory $(SUBMAKE_JOBS) $(MEM_STRESS_CASES) NPC_EXEC_PREFIX="$$npc_exec"

clean:
	rm -rf $(BUILD)

clean-all:
	rm -rf build

.PHONY: help build all clean clean-all disasm sim nemu payload-test payload-test-all memory-stress payloads $(MEM_STRESS_CASES)
