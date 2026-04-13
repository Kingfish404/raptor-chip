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

# ---- Embench benchmark list ----
BENCHMARKS := aha-mont64 crc32 edn matmult-int \
              md5sum nettle-aes nettle-sha256 \
              nsichneu picojpeg qrduino \
              sglib-combined slre statemate tarfind

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
	$$(CC) $$(CFLAGS) $$^ $$(_PICOLIBC_IO) -o $$@
endef

$(foreach b,$(BENCHMARKS),$(eval $(call BENCH_TEMPLATE,$(b))))

ALL_ELFS := $(foreach b,$(BENCHMARKS),$(BUILD_DIR)/$(b)/$(b).elf)

_build: $(ALL_ELFS)
	@:
	@echo "Built $(words $(ALL_ELFS)) Embench benchmarks"

endif # embench source exists

# ---- Public targets ----
build: ## Build all Embench ELFs
	@$(MAKE) $(Q) $(EMBENCH_DIR)/support/main.c
	@$(MAKE) $(Q) _build

clean:
	rm -rf $(BUILD_DIR)

.PHONY: build _build clean
