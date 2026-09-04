AS        = $(CROSS_COMPILE)gcc
CC        = $(CROSS_COMPILE)gcc
CXX       = $(CROSS_COMPILE)g++
LD        = $(CROSS_COMPILE)ld
AR        = $(CROSS_COMPILE)ar
OBJDUMP   = $(CROSS_COMPILE)objdump
OBJCOPY   = $(CROSS_COMPILE)objcopy
READELF   = $(CROSS_COMPILE)readelf

# ISA64=1 to build for RV64, default RV32
# Canonical device-tree sources live in linux/dts (single source of truth for
# both sim and nemu). DT_SOURCE names a file under linux/dts (e.g.
# spike-rv32gc.dts for F/D); an absolute path may also be given to override.
# This Makefile lives at sim/csrc/mem/mrom-data, four levels below the root.
RAPTOR_HOME ?= $(abspath ../../../..)
DTS_DIR     := $(RAPTOR_HOME)/linux/dts
ifeq ($(ISA64),1)
COMMON_CFLAGS = -march=rv64im_zicsr_zifencei -mabi=lp64
DT_SOURCE ?= spike-rv64ima.dts
else
COMMON_CFLAGS = -march=rv32im_zicsr_zifencei -mabi=ilp32
DT_SOURCE ?= spike-rv32ima.dts
endif
# Resolve a bare filename against linux/dts; leave absolute paths untouched.
DT_SOURCE_PATH := $(if $(filter /%,$(DT_SOURCE)),$(DT_SOURCE),$(DTS_DIR)/$(DT_SOURCE))
LDFLAGS       =

BUILD_DIR ?= ./build
IMAGE = $(BUILD_DIR)/mrom-data
SOURCE = rom.c $(BUILD_DIR)/dtb.c

# Auto-invalidate build when ISA64 or the DT source changes (e.g. switching
# RV32<->RV64, or spike-rv32ima.dts <-> spike-rv32gc.dts). Keying the stamp on
# DT_SOURCE forces a clean rebuild (and recompiled dtb.c) when the ISA string
# baked into the embedded DTB changes.
ISA64 ?= 0
DT_STAMP_KEY := $(ISA64):$(DT_SOURCE)
ISA_STAMP := $(BUILD_DIR)/.isa_stamp
ISA_PREV  := $(shell cat $(ISA_STAMP) 2>/dev/null)
ifneq ($(DT_STAMP_KEY),$(ISA_PREV))
$(shell rm -rf $(BUILD_DIR))
$(shell mkdir -p $(BUILD_DIR) && printf '%s' '$(DT_STAMP_KEY)' > $(ISA_STAMP))
endif

CFLAGS = -g -O2 -MMD -Wall -fno-pie \
	-fno-asynchronous-unwind-tables -fno-builtin -fno-stack-protector \
	-nostartfiles -ffreestanding $(COMMON_CFLAGS) -nostdlib
LDFLAGS = -no-pie -Wl,-Ttext=0 -Wl,-e,_start

all: $(IMAGE).elf $(IMAGE).bin ## Build MROM data (elf + bin)

$(BUILD_DIR)/dtb.c: $(DT_SOURCE_PATH) ## Generate DTB C source
	# brew install dtc
	mkdir -p $(BUILD_DIR)
	@set -eu; \
	  dtb_tmp="$(BUILD_DIR)/.raptor.dtb.$$$$"; \
	  c_tmp="$@.$$$$"; \
	  trap 'rm -f "$$dtb_tmp" "$$c_tmp"' EXIT HUP INT TERM; \
	  dtc $(DT_SOURCE_PATH) -o "$$dtb_tmp"; \
	  xxd -i -n raptor_dtb "$$dtb_tmp" > "$$c_tmp"; \
	  mv "$$dtb_tmp" $(BUILD_DIR)/raptor.dtb; \
	  mv "$$c_tmp" $@; \
	  trap - EXIT HUP INT TERM

$(IMAGE).elf: $(SOURCE)
	mkdir -p $(dir $(IMAGE))
	@set -eu; \
	  tmp="$@.$$$$"; \
	  trap 'rm -f "$$tmp"' EXIT HUP INT TERM; \
	  $(CC) -o "$$tmp" $(CFLAGS) $(LINKAGE) $(SOURCE) $(LDFLAGS); \
	  mv "$$tmp" $@; \
	  trap - EXIT HUP INT TERM

$(IMAGE).bin: $(IMAGE).elf
	@set -eu; \
	  txt_tmp="$(IMAGE).txt.$$$$"; \
	  bin_tmp="$@.$$$$"; \
	  trap 'rm -f "$$txt_tmp" "$$bin_tmp"' EXIT HUP INT TERM; \
	  $(OBJDUMP) -d $(IMAGE).elf > "$$txt_tmp"; \
	  $(OBJCOPY) -S --set-section-flags .bss=alloc,contents -O binary $(IMAGE).elf "$$bin_tmp"; \
	  mv "$$txt_tmp" $(IMAGE).txt; \
	  mv "$$bin_tmp" $@; \
	  trap - EXIT HUP INT TERM

clean: ## Clean build artifacts
	rm -rf $(BUILD_DIR)/
