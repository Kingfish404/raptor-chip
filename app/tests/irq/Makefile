# app/tests/irq/Makefile: bare-metal PLIC IRQ tests for sim.
#
# Each .c file becomes one test: `_start` (crt0.S) -> main() -> finisher.
# Output: build/rv32/tests/irq/<name>.bin (raw, loaded at 0x80000000 by sim).
#
# Bare-metal (NOT pk) — runs in M-mode with full PLIC/CSR access.

_THIS_DIR := $(dir $(lastword $(MAKEFILE_LIST)))
APP_HOME  := $(abspath $(_THIS_DIR)/../..)
include $(APP_HOME)/common.mk

BUILD_DIR ?= $(APP_HOME)/build/rv$(XLEN)/tests/irq
EXTRA_CFLAGS ?=
NPC_ARGS ?= -b -n -t 30 --no-lightsss --trap-on-ebreak
IRQ_REPEATS ?= 1
IRQ_LOG_DIR ?= $(BUILD_DIR)/logs
MROM_IMG ?= $(NSIM_HOME)/csrc/mem/mrom-data/build/rv$(XLEN)-spike-rv$(XLEN)ima/mrom-data.bin

# Bare-metal: bypass picolibc, freestanding, no stdlib, custom linker.
BM_CFLAGS := -march=$(ARCH) -mabi=$(ABI) -mcmodel=medany -O2 -g -Wall $(EXTRA_CFLAGS) \
             -ffreestanding -fno-builtin -fno-stack-protector \
             -nostdlib -nostartfiles \
             -fno-asynchronous-unwind-tables -static
BM_LDFLAGS := -T$(_THIS_DIR)link.ld -Wl,--no-relax -nostdlib -nostartfiles

CRT0 := $(_THIS_DIR)crt0.S
SRCS := $(wildcard $(_THIS_DIR)*.c)
NAMES := $(patsubst $(_THIS_DIR)%.c,%,$(SRCS))
ELFS := $(patsubst %,$(BUILD_DIR)/%.elf,$(NAMES))
BINS := $(patsubst %,$(BUILD_DIR)/%.bin,$(NAMES))

.PRECIOUS: $(ELFS)

OBJCOPY ?= $(CROSS_COMPILE)objcopy

$(BUILD_DIR)/%.elf: $(_THIS_DIR)%.c $(CRT0) $(_THIS_DIR)link.ld
	@mkdir -p $(dir $@)
	$(CC) $(BM_CFLAGS) $(BM_LDFLAGS) $(CRT0) $< -o $@

$(BUILD_DIR)/%.bin: $(BUILD_DIR)/%.elf
	$(OBJCOPY) -O binary $< $@

build: $(BINS)
	@echo "Built $(words $(BINS)) IRQ tests in $(BUILD_DIR)/"

npc-run: build
	@set -e; \
		npc_cmd="$(NPC_BIN)"; \
		if [ -n "$$npc_cmd" ]; then \
			npc_cmd="$$npc_cmd -r $(MROM_IMG)"; \
		else \
			npc_cmd="$$( $(MAKE) --no-print-directory -C $(NSIM_HOME) \
				ISA=riscv$(XLEN) print-npc-exec 2>/dev/null | tail -1 )"; \
		fi; \
		npc_bin="$${npc_cmd%% *}"; \
		if [ ! -x "$$npc_bin" ]; then \
			echo "ERROR: invalid NPC binary: $$npc_bin"; exit 1; \
		fi; \
		mkdir -p "$(IRQ_LOG_DIR)"; \
		repeat=1; \
		while [ $$repeat -le $(IRQ_REPEATS) ]; do \
			for bin in $(BINS); do \
				name="$$(basename "$$bin" .bin)"; \
				log="$(IRQ_LOG_DIR)/$${name}-$${repeat}.log"; \
				echo "[irq] run $$repeat/$(IRQ_REPEATS): $$name"; \
				if ! (cd "$(NSIM_HOME)" && $$npc_cmd $(NPC_ARGS) "$$bin") >"$$log" 2>&1; then \
					cat "$$log"; exit 1; \
				fi; \
				cat "$$log"; \
				grep -q "PASS" "$$log" && grep -q "HIT GOOD TRAP" "$$log" || \
					{ echo "[irq] FAIL: $$name"; exit 1; }; \
			done; \
			repeat=$$((repeat + 1)); \
		done

npc-coverage: npc-run

clean:
	rm -rf $(BUILD_DIR)

.PHONY: build npc-run npc-coverage clean
