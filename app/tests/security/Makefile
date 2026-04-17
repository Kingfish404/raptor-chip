# app/tests/security/Makefile: Build security / side-channel tests as pk-compatible ELFs

_THIS_DIR := $(dir $(lastword $(MAKEFILE_LIST)))
APP_HOME  := $(abspath $(_THIS_DIR)/../..)
include $(APP_HOME)/common.mk

BUILD_DIR := $(APP_HOME)/build/rv$(XLEN)/tests/security

# Allow bench.h to be found via -I.
CFLAGS := $(CFLAGS_COMMON) -I$(_THIS_DIR)
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
