# ============================================================================
# app/benchmarks/embench/Makefile: Build Embench-IoT as standard ELFs
# ============================================================================

_THIS_DIR   := $(dir $(lastword $(MAKEFILE_LIST)))
APP_HOME    := $(abspath $(_THIS_DIR)/../..)
SUPPORT_DIR := $(_THIS_DIR)support
include $(APP_HOME)/common.mk

# ---- Directories ----
EMBENCH_DIR := $(APP_HOME)/build/src/embench-iot
BUILD_DIR   := $(APP_HOME)/build/rv$(XLEN)/embench
BARE_BUILD_DIR := $(APP_HOME)/build/rv$(XLEN)/embench-baremetal

# ---- Embench benchmark list ----
BENCHMARKS := aha-mont64 crc32 depthconv edn huffbench matmult-int \
              md5sum nettle-aes nettle-sha256 nsichneu picojpeg \
              qrduino sglib-combined slre statemate tarfind ud \
              wikisort xgboost

CFLAGS := $(CFLAGS_COMMON) -std=gnu99 \
          -DHAVE_BOARDSUPPORT_H -DGLOBAL_SCALE_FACTOR=1 -DWARMUP_HEAT=1 \
          -Wno-unused-variable

# ---- Source fetching ----
$(EMBENCH_DIR)/support/main.c:
	@mkdir -p $(dir $(EMBENCH_DIR))
	git clone --depth 1 https://github.com/embench/embench-iot.git $(EMBENCH_DIR)

# ---- Build rules (gated on source existence) ----
ifneq ($(wildcard $(EMBENCH_DIR)/support/main.c),)

# Common support objects
SUPPORT_SRCS := $(SUPPORT_DIR)/main.c $(SUPPORT_DIR)/boardsupport.c
UPSTREAM_SRCS := $(EMBENCH_DIR)/support/beebsc.c
SUPPORT_OBJS := $(patsubst $(SUPPORT_DIR)/%.c,$(BUILD_DIR)/support/%.o,$(SUPPORT_SRCS)) \
                $(BUILD_DIR)/support/beebsc.o

SUPPORT_CFLAGS := $(CFLAGS) -I$(EMBENCH_DIR)/support -I$(SUPPORT_DIR)

BARE_CFLAGS := -march=$(ARCH) -mabi=$(ABI) -mcmodel=medany -O2 -Wall -g \
			   -std=gnu99 -ffreestanding -fno-builtin -fno-stack-protector \
			   -fno-common -fno-asynchronous-unwind-tables -static \
			   -DHAVE_BOARDSUPPORT_H -DGLOBAL_SCALE_FACTOR=1 -DWARMUP_HEAT=1 \
			   -DNDEBUG -Wno-unused-variable \
			   -I$(EMBENCH_DIR)/support -I$(SUPPORT_DIR)
BARE_HEADER_FLAGS := $(if $(_PICOLIBC_SPECS),--specs=picolibc.specs,)
BARE_LDFLAGS := -march=$(ARCH) -mabi=$(ABI) -mcmodel=medany \
				-nostdlib -nostartfiles -static -T$(SUPPORT_DIR)/link.ld \
				-Wl,--gc-sections -Wl,--no-relax
BARE_RUNTIME := $(SUPPORT_DIR)/start.S $(SUPPORT_DIR)/baremetal.c
BARE_LIBGCC := $(shell $(CC) -march=$(ARCH) -mabi=$(ABI) -print-libgcc-file-name)

$(BUILD_DIR)/support/%.o: $(SUPPORT_DIR)/%.c
	@mkdir -p $(dir $@)
	$(CC) $(SUPPORT_CFLAGS) -c $< -o $@

$(BUILD_DIR)/support/beebsc.o: $(EMBENCH_DIR)/support/beebsc.c
	@mkdir -p $(dir $@)
	$(CC) $(SUPPORT_CFLAGS) -c $< -o $@

# Template for each benchmark
define BENCH_TEMPLATE
$(1)_SRC_DIR := $$(EMBENCH_DIR)/src/$(1)
$(1)_SRCS    := $$(wildcard $$($(1)_SRC_DIR)/*.c)
$(1)_OBJS    := $$(patsubst $$($(1)_SRC_DIR)/%.c,$$(BUILD_DIR)/$(1)/%.o,$$($(1)_SRCS))
$(1)_ELF     := $$(BUILD_DIR)/$(1)/$(1).elf

$$(BUILD_DIR)/$(1)/%.o: $$($(1)_SRC_DIR)/%.c
	@mkdir -p $$(dir $$@)
	$$(CC) $$(CFLAGS) -I$$($(1)_SRC_DIR) -I$$(EMBENCH_DIR)/support -I$$(SUPPORT_DIR) -c $$< -o $$@

$$($(1)_ELF): $$($(1)_OBJS) $$(SUPPORT_OBJS)
	@mkdir -p $$(dir $$@)
	$$(CC) $$(CFLAGS) $$^ $$(_PICOLIBC_IO) -lm -o $$@
endef

define BARE_BENCH_TEMPLATE
$(1)_BARE_OBJS := $$(patsubst $$($(1)_SRC_DIR)/%.c,$$(BARE_BUILD_DIR)/$(1)/%.o,$$($(1)_SRCS))
$(1)_BARE_SUPPORT_OBJS := $$(BARE_BUILD_DIR)/$(1)/main.o \
                          $$(BARE_BUILD_DIR)/$(1)/beebsc.o \
                          $$(BARE_BUILD_DIR)/$(1)/baremetal.o \
                          $$(BARE_BUILD_DIR)/$(1)/start.o
$(1)_BARE_ELF  := $$(BARE_BUILD_DIR)/$(1)/$(1).elf
$(1)_BARE_BIN  := $$(BARE_BUILD_DIR)/$(1)/$(1).bin

$$(BARE_BUILD_DIR)/$(1)/%.o: $$($(1)_SRC_DIR)/%.c $$(SUPPORT_DIR)/ctype.h
	@mkdir -p $$(dir $$@)
	$$(CC) $$(BARE_HEADER_FLAGS) $$(BARE_CFLAGS) -I$$($(1)_SRC_DIR) -c $$< -o $$@

$$(BARE_BUILD_DIR)/$(1)/main.o: $$(SUPPORT_DIR)/main.c
	@mkdir -p $$(dir $$@)
	$$(CC) $$(BARE_HEADER_FLAGS) $$(BARE_CFLAGS) -I$$($(1)_SRC_DIR) -c $$< -o $$@

$$(BARE_BUILD_DIR)/$(1)/beebsc.o: $$(EMBENCH_DIR)/support/beebsc.c
	@mkdir -p $$(dir $$@)
	$$(CC) $$(BARE_HEADER_FLAGS) $$(BARE_CFLAGS) -I$$($(1)_SRC_DIR) -c $$< -o $$@

$$(BARE_BUILD_DIR)/$(1)/baremetal.o: $$(SUPPORT_DIR)/baremetal.c \
									$$(APP_HOME)/lib/runtime/runtime.c \
									$$(APP_HOME)/lib/runtime/libc_min.c
	@mkdir -p $$(dir $$@)
	$$(CC) $$(BARE_HEADER_FLAGS) $$(BARE_CFLAGS) -I$$($(1)_SRC_DIR) -c $$< -o $$@

$$(BARE_BUILD_DIR)/$(1)/start.o: $$(SUPPORT_DIR)/start.S
	@mkdir -p $$(dir $$@)
	$$(CC) $$(BARE_CFLAGS) -c $$< -o $$@

$$($(1)_BARE_ELF): $$($(1)_BARE_OBJS) $$($(1)_BARE_SUPPORT_OBJS) $$(SUPPORT_DIR)/link.ld
	@mkdir -p $$(dir $$@)
	$$(CC) $$(BARE_LDFLAGS) $$($(1)_BARE_SUPPORT_OBJS) $$($(1)_BARE_OBJS) $$(BARE_LIBGCC) -o $$@

$$($(1)_BARE_BIN): $$($(1)_BARE_ELF)
	$$(OBJCOPY) -O binary $$< $$@
endef

$(foreach b,$(BENCHMARKS),$(eval $(call BENCH_TEMPLATE,$(b))))
$(foreach b,$(BENCHMARKS),$(eval $(call BARE_BENCH_TEMPLATE,$(b))))

ALL_ELFS := $(foreach b,$(BENCHMARKS),$(BUILD_DIR)/$(b)/$(b).elf)
ALL_BARE_BINS := $(foreach b,$(BENCHMARKS),$(BARE_BUILD_DIR)/$(b)/$(b).bin)

_build: $(ALL_ELFS)
	@:
	@echo "Built $(words $(ALL_ELFS)) Embench benchmarks"

endif # embench source exists

# ---- Public targets ----
build: ## Build all Embench ELFs
	@$(MAKE) $(Q) $(EMBENCH_DIR)/support/main.c
	@$(MAKE) $(Q) _build

baremetal-build: ## Build all Embench flat binaries without pk
	@$(MAKE) $(Q) $(EMBENCH_DIR)/support/main.c
	@$(MAKE) $(Q) _baremetal-build

_baremetal-build: $(ALL_BARE_BINS)
	@echo "Built $(words $(ALL_BARE_BINS)) bare-metal Embench binaries"

baremetal-run: baremetal-build ## Run one bare-metal benchmark on NPC (BENCH=crc32)
	@test -n "$(BENCH)" || { echo "Usage: make baremetal-run BENCH=<benchmark>"; exit 1; }
	@case " $(BENCHMARKS) " in *" $(BENCH) "*) ;; *) echo "Unknown benchmark: $(BENCH)"; exit 1;; esac
	@$(MAKE) $(Q) -C $(NSIM_HOME) run IMG=$(BARE_BUILD_DIR)/$(BENCH)/$(BENCH).bin

clean:
	rm -rf $(BUILD_DIR) $(BARE_BUILD_DIR)

.PHONY: build _build baremetal-build _baremetal-build baremetal-run clean
