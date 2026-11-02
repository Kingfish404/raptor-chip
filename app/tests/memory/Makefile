APP_HOME := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../..)
APP_SUITE := tests/memory
APP_BUILD_SUFFIX = $(if $(strip $(MEMTEST_WORDS)),-words$(MEMTEST_WORDS))
APP_EXTRA_CFLAGS = $(if $(strip $(MEMTEST_WORDS)),-DMEMTEST_WORDS=$(MEMTEST_WORDS))
include $(APP_HOME)/common.mk
