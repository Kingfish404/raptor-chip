# ============================================================================
# app/benchmarks/agent/Makefile: agentic-workload CPU benchmarks (RAgentBench)
# ============================================================================

_THIS_DIR := $(dir $(lastword $(MAKEFILE_LIST)))
APP_HOME  := $(abspath $(_THIS_DIR)/../..)
include $(APP_HOME)/common.mk

BENCHES := tools rag workflow

BUILD_DIR        := $(APP_HOME)/build/rv$(XLEN)/benchmarks/agent
LITEX_BUILD_DIR  := $(APP_HOME)/build/rv32/benchmarks/agent-litex
NATIVE_BUILD_DIR := $(APP_HOME)/build/native/benchmarks/agent
NATIVE_LOG_DIR   := $(NATIVE_BUILD_DIR)/logs/native
NATIVE_REPORT_DIR := $(NATIVE_BUILD_DIR)/reports
SRC              := $(_THIS_DIR)agent_bench.c
PORT_HDR         := $(_THIS_DIR)ragentbench_port.h
REPORT_SCRIPT    := $(_THIS_DIR)report.py

.DEFAULT_GOAL := help

help: ## Show this help
	@echo "Usage: make -C app/benchmarks/agent <target> [VAR=value ...]"
	@awk '\
		/^[a-zA-Z0-9_-]+:.*## / { \
			t=$$0; sub(/:.*/, "", t); \
			d=$$0; sub(/.*## /, "", d); \
			printf "  %-20s %s\n", t, d }' $(MAKEFILE_LIST)
	@echo ""
	@echo "Variables:"
	@grep -hE '^[A-Z_][A-Z_0-9]*\s*\?=' $(MAKEFILE_LIST) | \
		awk '!seen[$$1]++ { \
			if (match($$0, /## /)) { \
				name=$$0; sub(/\s*\?=.*/, "", name); \
				desc=substr($$0, RSTART+3); \
				printf "  %-26s %s\n", name, desc } \
			else { \
				split($$0, a, "\\?="); \
				gsub(/^[ \t]+|[ \t]+$$/, "", a[1]); gsub(/^[ \t]+|[ \t]+$$/, "", a[2]); \
				if (a[2] != "") printf "  %-26s (default: %s)\n", a[1], a[2] } }'

AGENT_TOOL_ITERS    ?= 16## Tool dispatch iterations (32 calls per iteration)
AGENT_RAG_QUERIES   ?= 16## RAG queries scored over the synthetic corpus
AGENT_FLOW_TURNS    ?= 16## Workflow agent loop turns
RAGENTBENCH_TIMEBASE_HZ ?= 10000000## RISC-V time CSR frequency in Hz
RAGENTBENCH_CORE_CLOCK_MHZ ?= 0## Core clock in MHz for score/MHz reports (0=omit)
PYTHON              ?= python3## Python interpreter for native report generation
HOST_CC             ?= cc## Native C compiler
NATIVE_CFLAGS       ?= -O2 -Wall -g -std=gnu99 -Wno-unused-function## Native compiler flags
NATIVE_LDFLAGS      ?=## Native linker flags
NATIVE_ARCH_STRING  ?= $(shell uname -m 2>/dev/null || echo native)-$(shell uname -s 2>/dev/null | tr A-Z a-z || echo host)## Native report arch string

MODE_tools    := 1
MODE_rag      := 2
MODE_workflow := 3

CFLAGS := $(CFLAGS_COMMON) -std=gnu99 -I$(_THIS_DIR) \
          -DAGENT_ARCH_STRING=\"$(ARCH)\" \
          -DAGENT_TOOL_ITERS=$(AGENT_TOOL_ITERS) \
          -DAGENT_RAG_QUERIES=$(AGENT_RAG_QUERIES) \
          -DAGENT_FLOW_TURNS=$(AGENT_FLOW_TURNS) \
          -DRAGENTBENCH_TIMEBASE_HZ=$(RAGENTBENCH_TIMEBASE_HZ) \
          -Wno-unused-function

PK_ELFS    := $(foreach bench,$(BENCHES),$(BUILD_DIR)/agent-$(bench).elf)
LITEX_ELFS := $(foreach bench,$(BENCHES),$(LITEX_BUILD_DIR)/agent-$(bench).elf)
LITEX_BINS := $(foreach bench,$(BENCHES),$(LITEX_BUILD_DIR)/agent-$(bench).bin)
NATIVE_BINS := $(foreach bench,$(BENCHES),$(NATIVE_BUILD_DIR)/agent-$(bench))

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
                 -DAGENT_ARCH_STRING=\"$(LITEX_ARCH)\" \
                 -DAGENT_TOOL_ITERS=$(AGENT_TOOL_ITERS) \
                 -DAGENT_RAG_QUERIES=$(AGENT_RAG_QUERIES) \
                 -DAGENT_FLOW_TURNS=$(AGENT_FLOW_TURNS) \
                 -DRAGENTBENCH_TIMEBASE_HZ=$(RAGENTBENCH_TIMEBASE_HZ) \
                 -Wno-unused-function
LITEX_LDFLAGS := -march=$(LITEX_ARCH) -mabi=$(LITEX_ABI) -mcmodel=medany \
                 -nostdlib -nostartfiles -static -T$(LITEX_LINKER) \
                 -Wl,--gc-sections -Wl,--no-relax
LITEX_LIBGCC  := $(shell $(CC) -march=$(LITEX_ARCH) -mabi=$(LITEX_ABI) -print-libgcc-file-name)

define PK_RULE
$(BUILD_DIR)/agent-$(1).elf: $(SRC) $(PORT_HDR) $(_PICOLIBC_IO)
	@mkdir -p $$(dir $$@)
	$$(CC) $$(CFLAGS) -DAGENT_BENCH_MODE=$$(MODE_$(1)) $$(SRC) $$(_PICOLIBC_IO) -o $$@
	@$$(SIZE) $$@
endef

define LITEX_RULE
$(LITEX_BUILD_DIR)/agent-$(1).elf: $(SRC) $(PORT_HDR) $(LITEX_RUNTIME) $(LITEX_START) $(LITEX_LINKER)
	@mkdir -p $$(dir $$@)
	$$(CC) $$(LITEX_CFLAGS) -DAGENT_BENCH_MODE=$$(MODE_$(1)) $$(LITEX_LDFLAGS) \
		$$(LITEX_START) $$(SRC) $$(LITEX_RUNTIME) $$(LITEX_LIBGCC) -o $$@
	@$$(SIZE) $$@

$(LITEX_BUILD_DIR)/agent-$(1).bin: $(LITEX_BUILD_DIR)/agent-$(1).elf
	$$(OBJCOPY) -O binary $$< $$@
endef

define NATIVE_RULE
$(NATIVE_BUILD_DIR)/agent-$(1): $(SRC) $(PORT_HDR)
	@mkdir -p $$(dir $$@)
	$$(HOST_CC) $$(NATIVE_CFLAGS) \
		-DRAGENTBENCH_NATIVE=1 \
		-DRAGENTBENCH_TARGET_STRING=\"native\" \
		-DAGENT_ARCH_STRING=\"$$(NATIVE_ARCH_STRING)\" \
		-DAGENT_TOOL_ITERS=$$(AGENT_TOOL_ITERS) \
		-DAGENT_RAG_QUERIES=$$(AGENT_RAG_QUERIES) \
		-DAGENT_FLOW_TURNS=$$(AGENT_FLOW_TURNS) \
		-DAGENT_BENCH_MODE=$$(MODE_$(1)) \
		$$(SRC) $$(NATIVE_LDFLAGS) -o $$@
endef

$(foreach bench,$(BENCHES),$(eval $(call PK_RULE,$(bench))))
$(foreach bench,$(BENCHES),$(eval $(call LITEX_RULE,$(bench))))
$(foreach bench,$(BENCHES),$(eval $(call NATIVE_RULE,$(bench))))

build: $(PK_ELFS) ## Build pk-compatible RAgentBench ELFs
	@echo "Built RAgentBench pk ELFs in $(BUILD_DIR)/"

litex-build: $(LITEX_BINS) ## Build LiteX-native RAgentBench flat binaries
	@echo "Built RAgentBench LiteX bins in $(LITEX_BUILD_DIR)/"

litex-build-one: ## Build one LiteX-native binary (BENCH=tools|rag|workflow) {BENCH}
	@if [ -z "$(BENCH)" ]; then echo "[ERR] Set BENCH=tools|rag|workflow"; exit 1; fi
	@$(MAKE) $(Q) $(LITEX_BUILD_DIR)/agent-$(BENCH).bin

native-build: $(NATIVE_BINS) ## Build host-native RAgentBench executables
	@echo "Built native RAgentBench executables in $(NATIVE_BUILD_DIR)/"

native-run: native-build ## Run host-native RAgentBench without report files
	@echo "=== Running native RAgentBench ==="
	@fail=0; for bench in $(BENCHES); do \
		echo "--- agent-$$bench ---"; \
		$(NATIVE_BUILD_DIR)/agent-$$bench || fail=1; \
	done; \
	exit $$fail

native-report: native-build ## Run host-native RAgentBench and emit reports
	@mkdir -p $(NATIVE_LOG_DIR) $(NATIVE_REPORT_DIR)
	@find $(NATIVE_LOG_DIR) -type f -name '*.log' -delete
	@echo "=== Running native RAgentBench (profile=tools$(AGENT_TOOL_ITERS)-rag$(AGENT_RAG_QUERIES)-flow$(AGENT_FLOW_TURNS)) ==="
	@fail=0; for bench in $(BENCHES); do \
		exe=$(NATIVE_BUILD_DIR)/agent-$$bench; \
		log=$(NATIVE_LOG_DIR)/agent-$$bench.log; \
		echo "--- agent-$$bench ---"; \
		if $$exe > $$log 2>&1; then \
			cat $$log; \
		else \
			rc=$$?; cat $$log; echo "[RAgentBench native] agent-$$bench failed (exit $$rc)"; fail=1; \
		fi; \
	done; \
	$(PYTHON) $(REPORT_SCRIPT) \
		--log-dir $(NATIVE_LOG_DIR) \
		--markdown $(NATIVE_REPORT_DIR)/ragentbench-native.md \
		--csv $(NATIVE_REPORT_DIR)/ragentbench-native.csv \
		--json $(NATIVE_REPORT_DIR)/ragentbench-native.json \
		--core-clock-mhz $(RAGENTBENCH_CORE_CLOCK_MHZ) \
		--suite RAgentBench; \
	report_rc=$$?; \
	if [ $$report_rc -ne 0 ]; then exit $$report_rc; fi; \
	exit $$fail

native-test: native-report ## Alias for host-native build/run/report smoke test

clean:
	rm -rf $(BUILD_DIR) $(LITEX_BUILD_DIR) $(NATIVE_BUILD_DIR)

.PRECIOUS: $(PK_ELFS) $(LITEX_ELFS) $(NATIVE_BINS)
.PHONY: build litex-build litex-build-one native-build native-run native-report native-test clean help
