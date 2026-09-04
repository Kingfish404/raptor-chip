# app/tests/security/Makefile: Build security / side-channel tests as pk-compatible ELFs

_THIS_DIR := $(dir $(lastword $(MAKEFILE_LIST)))
APP_HOME  := $(abspath $(_THIS_DIR)/../..)
include $(APP_HOME)/common.mk

SECURITY_SIM_FAST ?= 0
BUILD_SUFFIX := $(if $(filter 1,$(SECURITY_SIM_FAST)),-sim-fast,)
BUILD_DIR := $(APP_HOME)/build/rv$(XLEN)/tests/security$(BUILD_SUFFIX)

# Allow bench.h to be found via -I.
CFLAGS := $(CFLAGS_COMMON) -I$(_THIS_DIR)
ifeq ($(SECURITY_SIM_FAST),1)
# Preserve every benchmark and all 256 distinguishable probe slots, while
# using a cache-line-separated RTL profile with fewer statistical samples.
CFLAGS += -DSECURITY_PROBE_STRIDE=256 \
	-DSECURITY_CACHE_ROUNDS=16 -DSECURITY_ATTACK_ROUNDS=10
endif
SRCS   := $(wildcard $(_THIS_DIR)*.c)
ELFS   := $(patsubst $(_THIS_DIR)%.c,$(BUILD_DIR)/%.elf,$(SRCS))

$(BUILD_DIR)/%.elf: $(_THIS_DIR)%.c $(_PICOLIBC_IO)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) $^ -o $@

build: $(ELFS)
	@echo "Built $(words $(ELFS)) security tests in $(BUILD_DIR)/"

clean:
	rm -rf $(BUILD_DIR)

.PHONY: build clean
