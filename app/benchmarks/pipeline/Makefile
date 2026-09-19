# Standalone bare metal: no libc, pk, AM, or shared simulator configuration.
XLEN ?= 64
CROSS_COMPILE ?= riscv64-elf-
BUILD_DIR ?= ../../../app/build/rv$(XLEN)/pipeline
ROUNDS ?= 16
SAMPLES ?= 3
ABI = $(if $(filter 64,$(XLEN)),lp64,ilp32)
FLAGS = -march=rv$(XLEN)ima_zicsr -mabi=$(ABI) -mcmodel=medany -mno-relax \
        -O2 -g -ffreestanding -fno-builtin -fno-pic -msmall-data-limit=0 \
        -Wall -Wextra -Werror -DROUNDS=$(ROUNDS) -DSAMPLES=$(SAMPLES)
.PHONY: build run-rv32 run-rv64 FORCE
build: $(BUILD_DIR)/pipeline.bin $(BUILD_DIR)/pipeline.dis
$(BUILD_DIR)/pipeline.elf: start.S kernels.S main.c link.ld FORCE
	@mkdir -p $(BUILD_DIR)
	$(CROSS_COMPILE)gcc $(FLAGS) -nostdlib -nostartfiles -static -Wl,--no-relax \
		-Wl,-T,link.ld -Wl,-Map,$(BUILD_DIR)/pipeline.map start.S kernels.S main.c -o $@
$(BUILD_DIR)/pipeline.bin: $(BUILD_DIR)/pipeline.elf
	$(CROSS_COMPILE)objcopy -O binary $< $@
$(BUILD_DIR)/pipeline.dis: $(BUILD_DIR)/pipeline.elf
	$(CROSS_COMPILE)objdump -d $< > $@
# NPC and MROM must be existing, matching artifacts. Never rewrites sim/.config.
run-rv32 run-rv64:
	@test -n "$(NPC)" -a -n "$(MROM)" -a -n "$(OUTPUT)" || \
		{ echo 'Set NPC=... MROM=... OUTPUT=/tmp/...'; exit 1; }
	python3 run.py --xlen $(subst run-rv,,$@) --npc "$(NPC)" --mrom "$(MROM)" \
		--output "$(OUTPUT)" --cross-compile "$(CROSS_COMPILE)" --rounds $(ROUNDS) --samples $(SAMPLES) $(RUN_ARGS)
