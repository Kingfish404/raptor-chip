# CoreMark-PRO upstream workloads with a Raptor MITH adaptation layer.
_THIS_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
APP_HOME := $(abspath $(_THIS_DIR)/../..)
APP_ENABLE_FP := 1
include $(APP_HOME)/common.mk
.DEFAULT_GOAL := build
SHELL := /bin/bash

COREMARK_PRO_REV := 4832cc67b0926c7a80a4b7ce0ce00f4640ea6bec
COREMARK_PRO_DIR := $(APP_HOME)/build/src/coremark-pro
PORT_DIR := $(_THIS_DIR)/portme
MODE ?= pk
CMP_ITERATIONS ?= 1
CMP_VERIFY ?= 1
CMP_TIMEBASE_HZ ?= 10000000
CMP_OPT_FLAGS ?= -O2
WORKLOADS := cjpeg-rose7-preset core linear_alg-mid-100x100-sp loops-all-mid-10k-sp \
             nnet_test parser-125k radix2-big-64k sha-test zip-test
CMP_WORKLOADS ?= $(WORKLOADS)
ifneq ($(filter-out $(WORKLOADS),$(CMP_WORKLOADS)),)
$(error Unknown CMP_WORKLOADS: $(filter-out $(WORKLOADS),$(CMP_WORKLOADS)))
endif
BUILD_DIR := $(APP_HOME)/build/rv$(XLEN)/coremark-pro/$(MODE)
CONFIG_STAMP := $(BUILD_DIR)/.build-config
HEADER_FLAGS := $(if $(_PICOLIBC_SPECS),--specs=picolibc.specs,)
export CMP_CC := $(CC)
export CMP_AR := $(CROSS_COMPILE)ar
export CMP_SIZE := $(SIZE)
export CMP_CFLAGS := $(HEADER_FLAGS) -march=$(ARCH) -mabi=$(ABI) -mcmodel=medany \
    $(CMP_OPT_FLAGS) -g -std=gnu99 -ffunction-sections -fdata-sections \
    -DNDEBUG -DHOST_EXAMPLE_CODE=1 -DUSE_SINGLE_CONTEXT=1 -DFAKE_FILEIO=1 \
    -DHAVE_SYS_STAT_H=1 -DHAVE_DIRENT_H=0 -DHAVE_GETPID=0 \
    -DGCC_INLINE_MACRO=1 -DNO_RESTRICT_QUALIFIER=1 \
    -DEE_SIZEOF_INT=4 -DEE_SIZEOF_LONG=$(shell expr $(XLEN) / 8) \
    -DEE_SIZEOF_PTR=$(shell expr $(XLEN) / 8) -DEE_PTR_ALIGN=8 \
    -DCMP_ITERATIONS=$(CMP_ITERATIONS) -DCMP_VERIFY=$(CMP_VERIFY) \
    -DCMP_TIMEBASE_HZ=$(CMP_TIMEBASE_HZ)
PORT_SRCS := th_al.c launch.c
ifeq ($(MODE),baremetal)
ifeq ($(_PICOLIBC_SPECS),)
$(error The bare-metal port requires a Picolibc toolchain)
endif
PORT_SRCS += baremetal.c start.S
LINK_SCRIPT := $(PORT_DIR)/link.ld
else ifeq ($(MODE),pk)
PORT_SRCS += $(if $(_PICOLIBC_IO),pk_io.c pk_heap.c,)
LINK_SCRIPT := $(PORT_DIR)/pk.ld
else
$(error MODE must be pk or baremetal)
endif
comma := ,
export CMP_LDFLAGS := $(HEADER_FLAGS) -march=$(ARCH) -mabi=$(ABI) -mcmodel=medany \
    -static $(if $(_PICOLIBC_SPECS),-nostartfiles,) -T$(LINK_SCRIPT) \
    -Wl,--gc-sections -Wl,--no-relax -Wl,--wrap=main -Wl,-u,_start \
    $(if $(_PICOLIBC_SPECS),-Wl$(comma)-u$(comma)sbrk,)
export CMP_PORT_OBJS := $(addprefix $(BUILD_DIR)/port/,$(addsuffix .o,$(basename $(PORT_SRCS))))
PORT_INCLUDES := -I$(PORT_DIR) -I$(COREMARK_PRO_DIR)/mith/include -I$(COREMARK_PRO_DIR)/mith/al/include
shell_quote = '$(subst ','"'"',$(1))'

fetch:
	@mkdir -p $(dir $(COREMARK_PRO_DIR))
	@if [ ! -d "$(COREMARK_PRO_DIR)/.git" ]; then \
		git init -q "$(COREMARK_PRO_DIR)" && \
		git -C "$(COREMARK_PRO_DIR)" fetch --depth 1 https://github.com/eembc/coremark-pro.git $(COREMARK_PRO_REV) && \
		git -C "$(COREMARK_PRO_DIR)" checkout -q --detach FETCH_HEAD; \
	fi
	@test "$$(git -C $(COREMARK_PRO_DIR) rev-parse HEAD)" = "$(COREMARK_PRO_REV)" || \
		{ echo "Unexpected upstream revision; use a clean pinned source checkout."; exit 1; }
	@git -C $(COREMARK_PRO_DIR) diff --quiet HEAD -- || \
		{ echo "Upstream sources have local changes; refusing to use modified workloads."; exit 1; }

$(CONFIG_STAMP): FORCE
	@mkdir -p $(BUILD_DIR)
	@{ printf '%s\n' $(call shell_quote,$(COREMARK_PRO_REV) $(CMP_CC) $(CMP_CFLAGS) $(CMP_LDFLAGS)); \
		$(CC) --version; sha256sum $(sort $(MAKEFILE_LIST) $(wildcard $(PORT_DIR)/*)); } > $@.tmp
	@if ! cmp -s $@.tmp $@; then \
		rm -rf $(BUILD_DIR)/obj $(BUILD_DIR)/bin $(BUILD_DIR)/port; mv $@.tmp $@; \
	else rm $@.tmp; fi

$(BUILD_DIR)/port/%.o: $(PORT_DIR)/%.c $(CONFIG_STAMP)
	@mkdir -p $(dir $@)
	$(CC) $(CMP_CFLAGS) $(PORT_INCLUDES) -c $< -o $@
$(BUILD_DIR)/port/%.o: $(PORT_DIR)/%.S $(CONFIG_STAMP)
	@mkdir -p $(dir $@)
	$(CC) $(CMP_CFLAGS) -c $< -o $@
$(BUILD_DIR)/port/pk_io.o: $(APP_HOME)/lib/pk_io.c $(CONFIG_STAMP)
	@mkdir -p $(dir $@)
	$(CC) $(CMP_CFLAGS) -c $< -o $@

build: fetch
	@$(MAKE) $(Q) _build

_build: $(CMP_PORT_OBJS)
	+$(MAKE) $(Q) -C $(COREMARK_PRO_DIR) -f Makefile.mak \
		-I$(COREMARK_PRO_DIR)/util/make -I$(PORT_DIR) \
		TOPDIR=$(COREMARK_PRO_DIR)/ TARGET=raptor DIR_TARGET=$(BUILD_DIR) \
		$(addprefix wbuild-,$(CMP_WORKLOADS))
	@mkdir -p $(BUILD_DIR)/licenses
	@cp $(COREMARK_PRO_DIR)/LICENSE.md $(BUILD_DIR)/licenses/LICENSE.coremark-pro.md
	@cp $(COREMARK_PRO_DIR)/benchmarks/darkmark/zip/zlib-1.2.8/README $(BUILD_DIR)/licenses/README.zlib
	@for bench in $(CMP_WORKLOADS); do \
		test -f "$(BUILD_DIR)/bin/$$bench.elf" || exit 1; \
		$(OBJCOPY) -O binary "$(BUILD_DIR)/bin/$$bench.elf" "$(BUILD_DIR)/bin/$$bench.bin" || exit 1; \
	done

baremetal-build:
	@$(MAKE) $(Q) build MODE=baremetal
list:
	@printf '%s\n' $(WORKLOADS)
clean:
	rm -rf $(BUILD_DIR)
FORCE:
.PHONY: fetch build _build baremetal-build list clean FORCE
