# ============================================================================
# app/benchmarks/llm/Makefile: LLM-style fixed-point benchmarks
# ============================================================================

_THIS_DIR := $(dir $(lastword $(MAKEFILE_LIST)))
APP_HOME  := $(abspath $(_THIS_DIR)/../..)
include $(APP_HOME)/common.mk

BENCHES := ops infer train

# Profile-tagged build dir: prevents stale ELFs when LLM_* knobs change between
# invocations (e.g. switching from NPC to native profile).
LLM_PROFILE_TAG := ops$(LLM_OP_ITERS)-gen$(LLM_GEN_TOKENS)x$(LLM_INFER_REPEATS)-train$(LLM_TRAIN_STEPS)
BUILD_DIR      := $(APP_HOME)/build/rv$(XLEN)/benchmarks/llm/$(LLM_PROFILE_TAG)
LITEX_BUILD_DIR := $(APP_HOME)/build/rv32/benchmarks/llm-litex/$(LLM_PROFILE_TAG)
NATIVE_BUILD_DIR := $(APP_HOME)/build/native/benchmarks/llm/$(LLM_PROFILE_TAG)
NATIVE_LOG_DIR   := $(NATIVE_BUILD_DIR)/logs/native
NATIVE_REPORT_DIR := $(NATIVE_BUILD_DIR)/reports
SRC            := $(_THIS_DIR)llm_bench.c
PORT_HDR       := $(_THIS_DIR)rllmbench_port.h
REPORT_SCRIPT  := $(_THIS_DIR)report.py

LLM_OP_ITERS     ?= 8## Operator benchmark repeat count
LLM_GEN_TOKENS   ?= 12## E2E inference generated token count (max 16)
LLM_INFER_REPEATS ?= 1## E2E inference outer repeat count (extends infer wall-time beyond SEQ_LEN cap)
LLM_TRAIN_STEPS  ?= 4## E2E training SGD steps
RLLMBENCH_TIMEBASE_HZ ?= 10000000## RISC-V time CSR frequency in Hz
RLLMBENCH_CORE_CLOCK_MHZ ?= 0## Core clock in MHz for score/MHz reports (0=omit)
PYTHON           ?= python3## Python interpreter for native report generation
HOST_CC          ?= cc## Native C compiler
NATIVE_CFLAGS    ?= -O2 -Wall -g -std=gnu99 -Wno-unused-function## Native compiler flags
NATIVE_LDFLAGS   ?=## Native linker flags
NATIVE_ARCH_STRING ?= $(shell uname -m 2>/dev/null || echo native)-$(shell uname -s 2>/dev/null | tr A-Z a-z || echo host)## Native report arch string

MODE_ops   := 1
MODE_infer := 2
MODE_train := 3

CFLAGS := $(CFLAGS_COMMON) -std=gnu99 -I$(_THIS_DIR) \
          -DLLM_ARCH_STRING=\"$(ARCH)\" \
          -DLLM_OP_ITERS=$(LLM_OP_ITERS) \
          -DLLM_GEN_TOKENS=$(LLM_GEN_TOKENS) \
          -DLLM_INFER_REPEATS=$(LLM_INFER_REPEATS) \
          -DLLM_TRAIN_STEPS=$(LLM_TRAIN_STEPS) \
		  -DRLLMBENCH_TIMEBASE_HZ=$(RLLMBENCH_TIMEBASE_HZ) \
          -Wno-unused-function

PK_ELFS   := $(foreach bench,$(BENCHES),$(BUILD_DIR)/llm-$(bench).elf)
LITEX_ELFS := $(foreach bench,$(BENCHES),$(LITEX_BUILD_DIR)/llm-$(bench).elf)
LITEX_BINS := $(foreach bench,$(BENCHES),$(LITEX_BUILD_DIR)/llm-$(bench).bin)
NATIVE_BINS := $(foreach bench,$(BENCHES),$(NATIVE_BUILD_DIR)/llm-$(bench))

LITEX_RUNTIME := $(APP_HOME)/lib/litex/runtime.c
LITEX_START   := $(APP_HOME)/lib/litex/start.S
LITEX_LINKER  := $(APP_HOME)/lib/litex/link.ld
LITEX_ARCH    := rv32imac_zicntr_zicond_zicsr_zifencei_zcb_zba_zbb_zbc_zbs
LITEX_ABI     := ilp32
LITEX_CFLAGS  := -march=$(LITEX_ARCH) -mabi=$(LITEX_ABI) -mcmodel=medany \
                 -O2 -Wall -g -std=gnu99 -ffreestanding -fno-builtin \
                 -fno-stack-protector -fno-common \
                 -fno-asynchronous-unwind-tables -static \
                 -I$(_THIS_DIR) -DRAPT_LITEX_BAREMETAL=1 \
                 -DLLM_ARCH_STRING=\"$(LITEX_ARCH)\" \
                 -DLLM_OP_ITERS=$(LLM_OP_ITERS) \
                 -DLLM_GEN_TOKENS=$(LLM_GEN_TOKENS) \
                 -DLLM_INFER_REPEATS=$(LLM_INFER_REPEATS) \
                 -DLLM_TRAIN_STEPS=$(LLM_TRAIN_STEPS) \
				 -DRLLMBENCH_TIMEBASE_HZ=$(RLLMBENCH_TIMEBASE_HZ) \
                 -Wno-unused-function
LITEX_LDFLAGS := -march=$(LITEX_ARCH) -mabi=$(LITEX_ABI) -mcmodel=medany \
                 -nostdlib -nostartfiles -static -T$(LITEX_LINKER) \
                 -Wl,--gc-sections -Wl,--no-relax
LITEX_LIBGCC  := $(shell $(CC) -march=$(LITEX_ARCH) -mabi=$(LITEX_ABI) -print-libgcc-file-name)

define PK_RULE
$(BUILD_DIR)/llm-$(1).elf: $(SRC) $(PORT_HDR) $(_PICOLIBC_IO)
	@mkdir -p $$(dir $$@)
	$$(CC) $$(CFLAGS) -DLLM_BENCH_MODE=$$(MODE_$(1)) $$(SRC) $$(_PICOLIBC_IO) -o $$@
	@$$(SIZE) $$@
endef

define LITEX_RULE
$(LITEX_BUILD_DIR)/llm-$(1).elf: $(SRC) $(PORT_HDR) $(LITEX_RUNTIME) $(LITEX_START) $(LITEX_LINKER)
	@mkdir -p $$(dir $$@)
	$$(CC) $$(LITEX_CFLAGS) -DLLM_BENCH_MODE=$$(MODE_$(1)) $$(LITEX_LDFLAGS) \
		$$(LITEX_START) $$(SRC) $$(LITEX_RUNTIME) $$(LITEX_LIBGCC) -o $$@
	@$$(SIZE) $$@

$(LITEX_BUILD_DIR)/llm-$(1).bin: $(LITEX_BUILD_DIR)/llm-$(1).elf
	$$(OBJCOPY) -O binary $$< $$@
endef

define NATIVE_RULE
$(NATIVE_BUILD_DIR)/llm-$(1): $(SRC) $(PORT_HDR)
	@mkdir -p $$(dir $$@)
	$$(HOST_CC) $$(NATIVE_CFLAGS) \
		-DRLLMBENCH_NATIVE=1 \
		-DRLLMBENCH_TARGET_STRING=\"native\" \
		-DLLM_ARCH_STRING=\"$$(NATIVE_ARCH_STRING)\" \
		-DLLM_OP_ITERS=$$(LLM_OP_ITERS) \
		-DLLM_GEN_TOKENS=$$(LLM_GEN_TOKENS) \
		-DLLM_INFER_REPEATS=$$(LLM_INFER_REPEATS) \
		-DLLM_TRAIN_STEPS=$$(LLM_TRAIN_STEPS) \
		-DLLM_BENCH_MODE=$$(MODE_$(1)) \
		$$(SRC) $$(NATIVE_LDFLAGS) -o $$@
endef

$(foreach bench,$(BENCHES),$(eval $(call PK_RULE,$(bench))))
$(foreach bench,$(BENCHES),$(eval $(call LITEX_RULE,$(bench))))
$(foreach bench,$(BENCHES),$(eval $(call NATIVE_RULE,$(bench))))

build: $(PK_ELFS) ## Build pk-compatible LLM benchmark ELFs
	@echo "Built LLM pk ELFs in $(BUILD_DIR)/"

litex-build: $(LITEX_BINS) ## Build LiteX-native LLM benchmark flat binaries
	@echo "Built LLM LiteX bins in $(LITEX_BUILD_DIR)/"

litex-build-one: ## Build one LiteX-native binary (BENCH=ops|infer|train) {BENCH}
	@if [ -z "$(BENCH)" ]; then echo "[ERR] Set BENCH=ops|infer|train"; exit 1; fi
	@$(MAKE) $(Q) $(LITEX_BUILD_DIR)/llm-$(BENCH).bin

native-build: $(NATIVE_BINS) ## Build host-native RLLMBench executables
	@echo "Built native RLLMBench executables in $(NATIVE_BUILD_DIR)/"

native-run: native-build ## Run host-native RLLMBench without report files
	@echo "=== Running native RLLMBench ==="
	@fail=0; for bench in $(BENCHES); do \
		echo "--- llm-$$bench ---"; \
		$(NATIVE_BUILD_DIR)/llm-$$bench || fail=1; \
	done; \
	exit $$fail

native-report: native-build ## Run host-native RLLMBench and emit reports
	@mkdir -p $(NATIVE_LOG_DIR) $(NATIVE_REPORT_DIR)
	@find $(NATIVE_LOG_DIR) -type f -name '*.log' -delete
	@echo "=== Running native RLLMBench (profile=ops$(LLM_OP_ITERS)-gen$(LLM_GEN_TOKENS)x$(LLM_INFER_REPEATS)-train$(LLM_TRAIN_STEPS)) ==="
	@fail=0; for bench in $(BENCHES); do \
		exe=$(NATIVE_BUILD_DIR)/llm-$$bench; \
		log=$(NATIVE_LOG_DIR)/llm-$$bench.log; \
		echo "--- llm-$$bench ---"; \
		if $$exe > $$log 2>&1; then \
			cat $$log; \
		else \
			rc=$$?; cat $$log; echo "[RLLMBench native] llm-$$bench failed (exit $$rc)"; fail=1; \
		fi; \
	done; \
	$(PYTHON) $(REPORT_SCRIPT) \
		--log-dir $(NATIVE_LOG_DIR) \
		--markdown $(NATIVE_REPORT_DIR)/rllmbench-native.md \
		--csv $(NATIVE_REPORT_DIR)/rllmbench-native.csv \
		--json $(NATIVE_REPORT_DIR)/rllmbench-native.json \
		--core-clock-mhz $(RLLMBENCH_CORE_CLOCK_MHZ) \
		--suite RLLMBench; \
	report_rc=$$?; \
	if [ $$report_rc -ne 0 ]; then exit $$report_rc; fi; \
	exit $$fail

native-test: native-report ## Alias for host-native build/run/report smoke test

clean:
	rm -rf $(APP_HOME)/build/rv$(XLEN)/benchmarks/llm \
	       $(APP_HOME)/build/rv32/benchmarks/llm-litex \
	       $(APP_HOME)/build/native/benchmarks/llm

.PRECIOUS: $(PK_ELFS) $(LITEX_ELFS) $(NATIVE_BINS)
.PHONY: build litex-build litex-build-one native-build native-run native-report native-test clean