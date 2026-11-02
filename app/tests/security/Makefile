APP_HOME := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/../..)
APP_SUITE := tests/security
SECURITY_SIM_FAST ?= 0
APP_BUILD_SUFFIX = $(if $(filter 1,$(SECURITY_SIM_FAST)),-sim-fast)
APP_EXTRA_CFLAGS = -I$(APP_HOME)/tests/security
ifeq ($(SECURITY_SIM_FAST),1)
APP_EXTRA_CFLAGS += -DSECURITY_PROBE_STRIDE=256 \
	-DSECURITY_CACHE_ROUNDS=16 -DSECURITY_ATTACK_ROUNDS=10
endif
include $(APP_HOME)/common.mk
