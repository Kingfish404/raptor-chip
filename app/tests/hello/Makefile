# app/tests/hello/Makefile — Build hello world as standard ELF

_THIS_DIR := $(dir $(lastword $(MAKEFILE_LIST)))
APP_HOME  := $(abspath $(_THIS_DIR)/../..)
include $(APP_HOME)/common.mk

BUILD_DIR := $(APP_HOME)/build/rv$(XLEN)/tests/hello
ELF       := $(BUILD_DIR)/hello.elf

CFLAGS := $(CFLAGS_COMMON)
SRCS   := $(_THIS_DIR)hello.c $(_PICOLIBC_IO)

$(ELF): $(SRCS)
	@mkdir -p $(dir $@)
	$(CC) $(CFLAGS) $(SRCS) -o $@

build: $(ELF)
	@:

clean:
	rm -rf $(BUILD_DIR)

.PHONY: build clean
