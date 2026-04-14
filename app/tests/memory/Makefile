# app/tests/memory/Makefile: Build memory subsystem tests as standard Linux ELFs

_THIS_DIR := $(dir $(lastword $(MAKEFILE_LIST)))
APP_HOME  := $(abspath $(_THIS_DIR)/../..)
include $(APP_HOME)/common.mk

BUILD_DIR := $(APP_HOME)/build/rv$(XLEN)/tests/memory

CFLAGS := $(CFLAGS_COMMON)
SRCS   := $(wildcard $(_THIS_DIR)*.c)
ELFS   := $(patsubst $(_THIS_DIR)%.c,$(BUILD_DIR)/%.elf,$(SRCS))

$(BUILD_DIR)/%.elf: $(_THIS_DIR)%.c $(_PICOLIBC_IO)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) $^ -o $@

build: $(ELFS)
	@echo "Built $(words $(ELFS)) memory tests in $(BUILD_DIR)/"

clean:
	rm -rf $(BUILD_DIR)

.PHONY: build clean
