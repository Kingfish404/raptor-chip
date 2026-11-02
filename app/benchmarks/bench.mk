# Shared pk, LiteX and host builds for the LLM/agent benchmark families.
APP_HOME := $(abspath $(dir $(lastword $(MAKEFILE_LIST)))/..)
include $(APP_HOME)/common.mk
BENCH_DIR := $(APP_HOME)/benchmarks/$(APP_BENCHMARK)
BUILD_DIR := $(APP_HOME)/build/rv$(XLEN)/benchmarks/$(APP_BENCHMARK)$(BENCH_SUBDIR)
LITEX_BUILD_DIR := $(APP_HOME)/build/rv32/benchmarks/$(APP_BENCHMARK)-litex$(BENCH_SUBDIR)
NATIVE_BUILD_DIR := $(APP_HOME)/build/native/benchmarks/$(APP_BENCHMARK)$(BENCH_SUBDIR)
NATIVE_LOG_DIR := $(NATIVE_BUILD_DIR)/logs/native
NATIVE_REPORT_DIR := $(NATIVE_BUILD_DIR)/reports
SRC := $(BENCH_DIR)/$(APP_BENCHMARK)_bench.c
PORT_HDR := $(BENCH_DIR)/$(BENCH_REPORT_STEM)_port.h
REPORT_SCRIPT := $(APP_HOME)/benchmarks/report.py
PYTHON ?= python3
HOST_CC ?= cc
NATIVE_CFLAGS ?= -O2 -Wall -g -std=gnu99 -Wno-unused-function
NATIVE_LDFLAGS ?=
native_machine := $(shell uname -m 2>/dev/null || echo native)
native_system := $(shell uname -s 2>/dev/null | tr A-Z a-z || echo host)
NATIVE_ARCH_STRING ?= $(native_machine)-$(native_system)
BENCH_CLEAN_DIRS ?= $(BUILD_DIR) $(LITEX_BUILD_DIR) $(NATIVE_BUILD_DIR)
bench_knob = -D$(1)=$($(1))
BENCH_KNOB_FLAGS = $(foreach knob,$(BENCH_KNOBS),$(call bench_knob,$(knob)))
BENCH_TIMEBASE = -D$(BENCH_PUBLIC_PREFIX)_TIMEBASE_HZ=$($(BENCH_PUBLIC_PREFIX)_TIMEBASE_HZ)
CFLAGS := $(CFLAGS_COMMON) -std=gnu99 -I$(BENCH_DIR) \
	-D$(BENCH_DEFINE_PREFIX)_ARCH_STRING=\"$(ARCH)\" $(BENCH_KNOB_FLAGS) \
	$(BENCH_TIMEBASE) -Wno-unused-function
LITEX_ARCH := rv32imac_zicntr_zicond_zicsr_zifencei_zcb_zba_zbb_zbc_zbs
LITEX_ABI := ilp32
LITEX_RUNTIME := $(APP_HOME)/lib/litex/runtime.c
LITEX_START := $(APP_HOME)/lib/litex/start.S
LITEX_LINKER := $(APP_HOME)/lib/litex/link.ld
LITEX_RUNTIME_DEPS := $(APP_HOME)/lib/runtime/runtime.c $(APP_HOME)/lib/runtime/libc_min.c
LITEX_CFLAGS := -march=$(LITEX_ARCH) -mabi=$(LITEX_ABI) -mcmodel=medany \
	-O2 -Wall -g -std=gnu99 -ffreestanding -fno-builtin -fno-stack-protector \
	-fno-common -fno-asynchronous-unwind-tables -static -I$(BENCH_DIR) \
	-DRAPT_LITEX_BAREMETAL=1 -D$(BENCH_DEFINE_PREFIX)_ARCH_STRING=\"$(LITEX_ARCH)\" \
	$(BENCH_KNOB_FLAGS) $(BENCH_TIMEBASE) -Wno-unused-function
LITEX_LDFLAGS := -march=$(LITEX_ARCH) -mabi=$(LITEX_ABI) -mcmodel=medany \
	-nostdlib -nostartfiles -static -T$(LITEX_LINKER) -Wl,--gc-sections -Wl,--no-relax
LITEX_LIBGCC := $(shell $(CC) -march=$(LITEX_ARCH) -mabi=$(LITEX_ABI) -print-libgcc-file-name)
NATIVE_DEFINES = -D$(BENCH_PUBLIC_PREFIX)_NATIVE=1 \
	-D$(BENCH_PUBLIC_PREFIX)_TARGET_STRING=\"native\" \
	-D$(BENCH_DEFINE_PREFIX)_ARCH_STRING=\"$(NATIVE_ARCH_STRING)\" $(BENCH_KNOB_FLAGS)
bench_mode = $(1)=$(MODE_$(1))
BENCH_MODE_SIGNATURE = $(foreach mode,$(BENCHES),$(call bench_mode,$(mode)))
$(BUILD_DIR)/.build-args: APP_BUILD_COMMAND = $(CC) $(CFLAGS) $(BENCH_MODE_SIGNATURE)
$(LITEX_BUILD_DIR)/.build-args: APP_BUILD_COMMAND = $(CC) $(LITEX_CFLAGS) \
	$(LITEX_LDFLAGS) $(LITEX_LIBGCC) $(OBJCOPY) $(BENCH_MODE_SIGNATURE)
$(NATIVE_BUILD_DIR)/.build-args: APP_BUILD_COMMAND = $(HOST_CC) $(NATIVE_CFLAGS) \
	$(NATIVE_DEFINES) $(NATIVE_LDFLAGS) $(BENCH_MODE_SIGNATURE)
define BENCH_BUILD_RULE
$(BUILD_DIR)/$(APP_BENCHMARK)-$(1).elf: $(SRC) $(PORT_HDR) $(_PICOLIBC_IO) \
	$(APP_HOME)/lib/pk-user.ld $(BUILD_DIR)/.build-args
	@mkdir -p $$(dir $$@)
	$$(CC) $$(CFLAGS) -D$(BENCH_DEFINE_PREFIX)_BENCH_MODE=$$(MODE_$(1)) \
		$$(SRC) $$(_PICOLIBC_IO) -o $$@
	@$$(SIZE) $$@
$(LITEX_BUILD_DIR)/$(APP_BENCHMARK)-$(1).elf: $(SRC) $(PORT_HDR) $(LITEX_RUNTIME) \
	$(LITEX_RUNTIME_DEPS) $(LITEX_START) $(LITEX_LINKER) $(LITEX_BUILD_DIR)/.build-args
	@mkdir -p $$(dir $$@)
	$$(CC) $$(LITEX_CFLAGS) -D$(BENCH_DEFINE_PREFIX)_BENCH_MODE=$$(MODE_$(1)) \
		$$(LITEX_LDFLAGS) $$(LITEX_START) $$(SRC) $$(LITEX_RUNTIME) $$(LITEX_LIBGCC) -o $$@
	@$$(SIZE) $$@
$(LITEX_BUILD_DIR)/$(APP_BENCHMARK)-$(1).bin: $(LITEX_BUILD_DIR)/$(APP_BENCHMARK)-$(1).elf
	$$(OBJCOPY) -O binary $$< $$@
$(NATIVE_BUILD_DIR)/$(APP_BENCHMARK)-$(1): $(SRC) $(PORT_HDR) $(NATIVE_BUILD_DIR)/.build-args
	@mkdir -p $$(dir $$@)
	$$(HOST_CC) $$(NATIVE_CFLAGS) $$(NATIVE_DEFINES) \
		-D$(BENCH_DEFINE_PREFIX)_BENCH_MODE=$$(MODE_$(1)) $$(SRC) $$(NATIVE_LDFLAGS) -o $$@
endef
bench_build_rule = $(eval $(call BENCH_BUILD_RULE,$(1)))
$(foreach mode,$(BENCHES),$(call bench_build_rule,$(mode)))
PK_ELFS := $(addprefix $(BUILD_DIR)/$(APP_BENCHMARK)-,$(addsuffix .elf,$(BENCHES)))
LITEX_ELFS := $(addprefix $(LITEX_BUILD_DIR)/$(APP_BENCHMARK)-,$(addsuffix .elf,$(BENCHES)))
LITEX_BINS := $(LITEX_ELFS:.elf=.bin)
NATIVE_BINS := $(addprefix $(NATIVE_BUILD_DIR)/$(APP_BENCHMARK)-,$(BENCHES))
.PHONY: help build litex-build litex-build-one native-build native-run native-report native-test clean
help:
	@echo 'Targets: build litex-build litex-build-one native-build native-run native-test clean'
	@echo 'Modes: $(BENCHES); workload settings: $(BENCH_KNOBS)'
build: $(PK_ELFS)
litex-build: $(LITEX_BINS)
litex-build-one:
	@case ' $(BENCHES) ' in *' $(BENCH) '*) ;; *) echo 'Select BENCH from $(BENCHES)'; exit 1;; esac
	+$(MAKE) $(Q) $(LITEX_BUILD_DIR)/$(APP_BENCHMARK)-$(BENCH).bin
native-build: $(NATIVE_BINS)
native-run: native-build
	@fail=0; for mode in $(BENCHES); do \
		$(NATIVE_BUILD_DIR)/$(APP_BENCHMARK)-$$mode || fail=1; done; exit $$fail
native-report: native-build
	@mkdir -p $(NATIVE_LOG_DIR) $(NATIVE_REPORT_DIR)
	@find $(NATIVE_LOG_DIR) -type f -name '*.log' -delete
	@fail=0; for mode in $(BENCHES); do \
		log=$(NATIVE_LOG_DIR)/$(APP_BENCHMARK)-$$mode.log; \
		$(NATIVE_BUILD_DIR)/$(APP_BENCHMARK)-$$mode > $$log 2>&1 || fail=1; cat $$log; \
		grep -q '^$(BENCH_PUBLIC_PREFIX)_END .*status=PASS' $$log || fail=1; \
	done; \
	$(PYTHON) $(REPORT_SCRIPT) --log-dir $(NATIVE_LOG_DIR) \
		--markdown $(NATIVE_REPORT_DIR)/$(BENCH_REPORT_STEM)-native.md \
		--csv $(NATIVE_REPORT_DIR)/$(BENCH_REPORT_STEM)-native.csv \
		--json $(NATIVE_REPORT_DIR)/$(BENCH_REPORT_STEM)-native.json \
		--core-clock-mhz $($(BENCH_PUBLIC_PREFIX)_CORE_CLOCK_MHZ) --suite $(BENCH_SUITE) || exit $$?; \
	exit $$fail
native-test: native-report
clean:
	rm -rf $(BENCH_CLEAN_DIRS)
.PRECIOUS: $(PK_ELFS) $(LITEX_ELFS) $(NATIVE_BINS)
