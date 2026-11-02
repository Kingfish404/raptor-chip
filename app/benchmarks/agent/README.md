# RAgentBench

RAgentBench measures CPU execution of synthetic tool dispatch, retrieval scoring
and multi-turn policy loops. It uses deterministic static inputs and integer
arithmetic, with ports for native hosts, pk/NPC, NEMU and LiteX/FPGA. These are CPU
workloads; their scores do not measure an LLM agent's task-solving ability.

See [application commands and shared build rules](../../README.md#ragentbench) for
run targets. Builds use the same `bench.mk` backend rules as RLLMBench.

| Mode | Workload |
| --- | --- |
| `tools` | Switch-table dispatch, small-state mutation and error paths |
| `rag` | Term-frequency scoring and heap-free top-k selection |
| `workflow` | Multi-turn policy loops with subcheckpoint validation |

These patterns complement RLLMBench's dense arithmetic. Missing tools or
parameters and step-cap termination exercise alternate control-flow paths.

## Profiles and ports

| Setting | Meaning |
| --- | --- |
| `AGENT_TOOL_ITERS` | Tool-mode iterations, 32 calls each |
| `AGENT_RAG_QUERIES` | Queries scored over the synthetic corpus |
| `AGENT_FLOW_TURNS` | Workflow loop turns |

The profile string is `tools<N>-rag<N>-flow<N>`. Workload defaults live in the
Makefiles; select the same explicit values when comparing backends. For a small
native build/run/report check from the repository root:

```sh
make -C app/benchmarks/agent native-test \
    AGENT_TOOL_ITERS=1 AGENT_RAG_QUERIES=1 AGENT_FLOW_TURNS=1
```

[ragentbench_port.h](ragentbench_port.h) provides the timing interface. Set
`RAGENTBENCH_TIMEBASE_HZ` to the RISC-V `time` CSR rate.
`RAGENTBENCH_CORE_CLOCK_MHZ` supplies optional report metadata for score/MHz.
RISC-V reports live under `app/build/rv<XLEN>/benchmarks/agent/{logs,reports}/`;
native reports use `app/build/native/benchmarks/agent/reports/`. Output directories
and host compiler/flags can be overridden through the shared build rules.

## Result contract

Each mode emits these record types:

```text
RAGENTBENCH_INFO version=0.1 profile=... arch=... xlen=... target=... time_unit=s score=score_per_sec
RAGENTBENCH_BEGIN mode=tools kind=... profile=...
RAGENTBENCH_CONFIG mode=... tool_iters=... rag_queries=... flow_turns=... ...
RAGENTBENCH_RESULT name=... class=... unit=... work=... seconds=... score_per_sec=... checksum=0x...
RAGENTBENCH_SCORE mode=... work=... seconds=... score_per_sec=... checksum=0x...
RAGENTBENCH_END mode=... status=PASS sink=0x...
```

`score_per_sec` is work per physical second. Reports can derive
`score_per_mhz = score_per_sec / core_clock_mhz`. The shared
[report script](../report.py) writes Markdown, CSV and JSON; runners require the
ending `status=PASS` marker.

All state arrays are initialized at mode entry and seeds are fixed in
`agent_bench.c`. Checksums mix state mutations and can be compared across ports
using the same workload settings. The workloads use no dynamic allocation or
floating point.
