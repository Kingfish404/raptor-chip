# ============================================================================
# fpga/litex/benchmarks/coremark/Makefile: Build CoreMark for Raptor LiteX SoC
# ============================================================================
#
# Usage:
#   make build          # Clone coremark + build ELF/BIN
#   make clean          # Remove build artifacts
#
# Fully freestanding — no newlib/picolibc required.
# The port uses rdtime (RISC-V Zicntr) for timing at 1 MHz timebase.
# Output via LiteX UART CSR (memory-mapped).

SHELL := /bin/bash

_THIS_DIR   := $(dir $(lastword $(MAKEFILE_LIST)))
LITEX_DIR   := $(abspath $(_THIS_DIR)/../..)
RAPTOR_HOME := $(abspath $(LITEX_DIR)/../..)

# ---- Toolchain ----
CROSS_COMPILE ?= $(shell \
  if command -v riscv64-unknown-elf-gcc >/dev/null 2>&1; then echo riscv64-unknown-elf-; \
  elif command -v riscv64-elf-gcc >/dev/null 2>&1; then echo riscv64-elf-; \
  elif command -v riscv64-linux-gnu-gcc >/dev/null 2>&1; then echo riscv64-linux-gnu-; \
  else echo riscv64-unknown-elf-; fi)
CC      := $(CROSS_COMPILE)gcc
OBJCOPY := $(CROSS_COMPILE)objcopy
SIZE    := $(CROSS_COMPILE)size

# ---- Architecture ----
ARCH   := rv32imac_zicntr_zicond_zicsr_zifencei_zcb_zba_zbb_zbc_zbs
ABI    := ilp32

# ---- Directories ----
COREMARK_DIR := $(_THIS_DIR)coremark
BUILD_DIR    := $(_THIS_DIR)build
PORTME_DIR   := $(_THIS_DIR)portme

# ---- CoreMark config ----
# ITERATIONS: tuneable from parent (FPGA is fast — 1000+ is reasonable).
# SYS_CLK_HZ: must match the bitstream's sys_clk; rdtime ticks once per cycle
#   (rapt_clint.sv: mtime <= mtime + 1). Default 10 MHz for Tang Mega 138K Pro.
# Changing ITERATIONS or SYS_CLK_HZ triggers a full rebuild via the stamp.
ITERATIONS ?= 64
SYS_CLK_HZ ?= 10000000
ITER_STAMP := $(BUILD_DIR)/.iterations

# Optimization flags, tuned for the FPGA target. Unlike the NPC simulator
# (ideal memory model), the FPGA core fetches instructions from DDR, so it is
# code-size sensitive: -funroll-all-loops + function/jump alignment padding bloat
# the binary and slow fetch (measured 120 vs 131 CoreMark on this SoC). We keep
# -O3 with cheap, density-friendly wins. The freestanding portme/minilib.c
# provides memset/memcpy/memcmp, so -DSKIP_DEFAULT_MEMSET is safe. Override to
# customize.
COREMARK_OPTIM_CFLAGS ?= \
          -O3 -finline-functions -mbranch-cost=1 \
          -DSKIP_DEFAULT_MEMSET -mtune=sifive-3-series \
          -fipa-pta -fno-tree-vrp -fwrapv

CFLAGS := -march=$(ARCH) -mabi=$(ABI) -mcmodel=medany \
          $(COREMARK_OPTIM_CFLAGS) -Wall \
          -ffreestanding -nostdlib -nostdinc \
          -isystem $(shell $(CC) -print-file-name=include) \
          -I$(PORTME_DIR) -I$(COREMARK_DIR) \
          -DITERATIONS=$(ITERATIONS) -DPERFORMANCE_RUN=1 \
          -DHAS_STDIO=0 -DHAS_PRINTF=0 -DHAS_FLOAT=1 \
          -DEE_TICKS_PER_SEC=$(SYS_CLK_HZ)ULL \
          -DCOMPILER_FLAGS=\""$(ARCH)"\"

LDFLAGS := -march=$(ARCH) -mabi=$(ABI) -mcmodel=medany \
           -nostdlib -static \
           -T$(PORTME_DIR)/link.ld

# libgcc provides soft-float routines (__muldf3 etc.) for printf %f
LIBGCC := $(shell $(CC) -march=$(ARCH) -mabi=$(ABI) -print-libgcc-file-name)

# ---- Source fetching ----
$(COREMARK_DIR)/core_main.c:
	git clone --depth 1 https://github.com/eembc/coremark.git $(COREMARK_DIR)

# ---- Build rules ----
ifneq ($(wildcard $(COREMARK_DIR)/core_main.c),)

CORE_SRCS := core_list_join.c core_main.c core_matrix.c core_state.c core_util.c
PORT_SRCS := core_portme.c minilib.c

OBJS := $(patsubst %.c,$(BUILD_DIR)/%.o,$(CORE_SRCS) $(PORT_SRCS))
# crt0.S is assembled separately
OBJS += $(BUILD_DIR)/crt0.o
ELF  := $(BUILD_DIR)/coremark.elf
BIN  := $(BUILD_DIR)/coremark.bin

# Force-rebuild all objects when ITERATIONS changes. The stamp's content is
# the current value; if it differs from the requested ITERATIONS, the rule
# rewrites the stamp (which is a prereq of every object).
.PHONY: $(ITER_STAMP).check
$(ITER_STAMP).check:
	@mkdir -p $(BUILD_DIR)
	@cur=$$(cat $(ITER_STAMP) 2>/dev/null || echo ""); \
	 want="$(ITERATIONS):$(SYS_CLK_HZ)"; \
	 if [ "$$cur" != "$$want" ]; then \
	   echo "[INFO] coremark config changed ($$cur -> $$want); forcing rebuild."; \
	   echo "$$want" > $(ITER_STAMP); \
	 fi
$(ITER_STAMP): $(ITER_STAMP).check
	@test -f $@ || echo "$(ITERATIONS):$(SYS_CLK_HZ)" > $@

$(BUILD_DIR)/crt0.o: $(PORTME_DIR)/crt0.S $(ITER_STAMP)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/core_portme.o: $(PORTME_DIR)/core_portme.c $(ITER_STAMP)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/minilib.o: $(PORTME_DIR)/minilib.c $(ITER_STAMP)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@

$(BUILD_DIR)/%.o: $(COREMARK_DIR)/%.c $(ITER_STAMP)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) -c $< -o $@

$(ELF): $(OBJS)
	@mkdir -p $(dir $@)
	$(CC) $(LDFLAGS) $^ $(LIBGCC) -o $@
	@$(SIZE) $@

$(BIN): $(ELF)
	$(OBJCOPY) -O binary $< $@

_build: $(BIN)
	@echo "CoreMark ELF: $(ELF)"
	@echo "CoreMark BIN: $(BIN)"

endif # coremark source exists

# ---- Public targets ----
.PHONY: build _build clean clone

clone: $(COREMARK_DIR)/core_main.c ## Clone CoreMark repository

build: ## Build coremark ELF + BIN (override ITERATIONS=N, SYS_CLK_HZ=Hz)
	@$(MAKE) --no-print-directory $(COREMARK_DIR)/core_main.c
	@$(MAKE) --no-print-directory _build ITERATIONS=$(ITERATIONS) SYS_CLK_HZ=$(SYS_CLK_HZ)

clean: ## Remove build artifacts
	rm -rf $(BUILD_DIR)

.DEFAULT_GOAL := build
