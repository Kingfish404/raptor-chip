APP_HOME ?= $(abspath $(CURDIR)/../..)
include $(APP_HOME)/common.mk

CXX := $(CROSS_COMPILE)g++

MICROBENCH_SRC := $(abspath $(APP_HOME)/../abstract-machine/app/am-kernels/benchmarks/microbench/src)
BUILD_DIR := $(APP_HOME)/build/rv$(XLEN)/microbench
TARGET := $(BUILD_DIR)/microbench.elf

SRCS := $(shell find $(MICROBENCH_SRC) -type f \( -name '*.c' -o -name '*.cc' \)) se_main.c
OBJS := $(patsubst $(MICROBENCH_SRC)/%.c,$(BUILD_DIR)/%.o,$(filter $(MICROBENCH_SRC)/%.c,$(SRCS))) \
        $(patsubst $(MICROBENCH_SRC)/%.cc,$(BUILD_DIR)/%.o,$(filter $(MICROBENCH_SRC)/%.cc,$(SRCS))) \
        $(BUILD_DIR)/se_main.o

CPPFLAGS := -Iinclude -I$(MICROBENCH_SRC)/../include
CFLAGS := $(CFLAGS_COMMON) -std=gnu99 -Wno-main -Wno-unused-parameter
CXXFLAGS := $(CFLAGS_COMMON) -fno-exceptions -fno-rtti

.PHONY: build clean

build: $(TARGET)

$(TARGET): $(OBJS)
	@mkdir -p $(@D)
	$(CXX) $(CXXFLAGS) -o $@ $(OBJS) $(_PICOLIBC_IO)

$(BUILD_DIR)/%.o: $(MICROBENCH_SRC)/%.c
	@mkdir -p $(@D)
	$(CC) $(CPPFLAGS) $(CFLAGS) $(if $(filter $(MICROBENCH_SRC)/bench.c,$<),-Dmain=microbench_am_main) -c $< -o $@

$(BUILD_DIR)/%.o: $(MICROBENCH_SRC)/%.cc
	@mkdir -p $(@D)
	$(CXX) $(CPPFLAGS) $(CXXFLAGS) -c $< -o $@

$(BUILD_DIR)/se_main.o: se_main.c
	@mkdir -p $(@D)
	$(CC) $(CPPFLAGS) $(CFLAGS) -c $< -o $@

clean:
	rm -rf $(BUILD_DIR)
