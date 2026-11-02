# RAgentBench workload settings; shared pk/LiteX/native rules live in bench.mk.
APP_BENCHMARK := agent
BENCH_DEFINE_PREFIX := AGENT
BENCH_SUITE := RAgentBench
BENCH_PUBLIC_PREFIX := RAGENTBENCH
BENCH_REPORT_STEM := ragentbench
BENCHES := tools rag workflow
BENCH_KNOBS := AGENT_TOOL_ITERS AGENT_RAG_QUERIES AGENT_FLOW_TURNS
AGENT_TOOL_ITERS    ?= 16## Tool dispatch iterations (32 calls per iteration)
AGENT_RAG_QUERIES   ?= 16## RAG queries scored over the synthetic corpus
AGENT_FLOW_TURNS    ?= 16## Workflow agent loop turns
RAGENTBENCH_TIMEBASE_HZ ?= 10000000## RISC-V time CSR frequency in Hz
RAGENTBENCH_CORE_CLOCK_MHZ ?= 0## Core clock in MHz for score/MHz reports (0=omit)
BENCH_PROFILE = tools$(AGENT_TOOL_ITERS)-rag$(AGENT_RAG_QUERIES)-flow$(AGENT_FLOW_TURNS)
.DEFAULT_GOAL := help
MODE_tools := 1
MODE_rag := 2
MODE_workflow := 3
include $(dir $(lastword $(MAKEFILE_LIST)))../bench.mk
