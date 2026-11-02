# RLLMBench workload settings; shared pk/LiteX/native rules live in bench.mk.
APP_BENCHMARK := llm
BENCH_DEFINE_PREFIX := LLM
BENCH_SUITE := RLLMBench
BENCH_PUBLIC_PREFIX := RLLMBENCH
BENCH_REPORT_STEM := rllmbench
BENCHES := ops infer train
BENCH_KNOBS := LLM_OP_ITERS LLM_GEN_TOKENS LLM_INFER_REPEATS LLM_TRAIN_STEPS
LLM_OP_ITERS     ?= 8## Operator benchmark repeat count
LLM_GEN_TOKENS   ?= 12## E2E inference generated token count (max 16)
LLM_INFER_REPEATS ?= 1## E2E inference outer repeat count (extends infer wall-time beyond SEQ_LEN cap)
LLM_TRAIN_STEPS  ?= 4## E2E training SGD steps
RLLMBENCH_TIMEBASE_HZ ?= 10000000## RISC-V time CSR frequency in Hz
RLLMBENCH_CORE_CLOCK_MHZ ?= 0## Core clock in MHz for score/MHz reports (0=omit)
BENCH_PROFILE = ops$(LLM_OP_ITERS)-gen$(LLM_GEN_TOKENS)x$(LLM_INFER_REPEATS)-train$(LLM_TRAIN_STEPS)
BENCH_SUBDIR = /$(BENCH_PROFILE)
BENCH_CLEAN_DIRS = $(APP_HOME)/build/rv$(XLEN)/benchmarks/llm \
	$(APP_HOME)/build/rv32/benchmarks/llm-litex $(APP_HOME)/build/native/benchmarks/llm
.DEFAULT_GOAL := build
MODE_ops := 1
MODE_infer := 2
MODE_train := 3
include $(dir $(lastword $(MAKEFILE_LIST)))../bench.mk
