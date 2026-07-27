# RAgentBench — agentic-workload CPU benchmark

RAgentBench measures how well the Raptor RISC-V core (and any other RV32/RV64
target reachable via pk, NEMU, LiteX BIOS, or host-native) executes the
*compute pattern* that LLM-agent runtimes spend most of their wall time on:
function-call dispatch, retrieval scoring, and multi-turn policy loops.

> **Scope.** RAgentBench evaluates the **CPU/SoC**, not the LLM. There is no
> language model, no tokenizer, no network. All inputs are deterministic and
> synthesized from fixed seeds. The benchmark does not claim to predict how
> well a real LLM agent would behave on this hardware.

## Why a separate benchmark from RLLMBench

| dimension              | RLLMBench (`app/benchmarks/llm`) | RAgentBench (this dir)         |
| ---------------------- | -------------------------------- | ------------------------------ |
| pressure on            | dense int8/int16 GEMM, softmax   | branch-heavy dispatch, top-k   |
| dominant kernel        | matvec, RMSNorm, attention       | switch tables, BM25-lite, FSM  |
| ILP profile            | regular, loop-friendly           | irregular, mispredict-heavy    |
| memory pattern         | contiguous tensor sweeps         | scattered small-state mutation |
| representative of      | model inference / training       | tool-calling agent runtime     |

The two benchmarks are complementary; a core that wins on RLLMBench can still
lose on RAgentBench (and vice versa) because the bottlenecks differ.

## Modes

| mode       | what it stresses                                    | inspired by                               |
| ---------- | --------------------------------------------------- | ----------------------------------------- |
| `tools`    | switch-table dispatch, small-state mutation, error path | Berkeley Function Calling Leaderboard v3 |
| `rag`      | term-frequency scoring + heap-free top-k selection  | tau-bench domain knowledge / GAIA file Q&A |
| `workflow` | multi-turn policy loop with subcheckpoint validation | tau-bench / TheAgentCompany subchecks     |

All three include intentional "augmented" branches (missing tool, missing
parameter, force-termination on step cap) modelled after BFCL v3's augmented
categories so branch-predictor pressure matches a real agent runtime.

## Log contract

Each run emits a fixed set of grep-friendly lines (one log file per mode):

```
RAGENTBENCH_INFO    version=0.1 profile=... arch=... xlen=... target=... time_unit=s score=score_per_sec
RAGENTBENCH_BEGIN   mode=<tools|rag|workflow> kind=... profile=...
RAGENTBENCH_CONFIG  mode=... arch=... xlen=... target=... tool_iters=... rag_queries=... flow_turns=... ...
RAGENTBENCH_RESULT  name=... class=... unit=... work=... seconds=... score_per_sec=... checksum=0x...
RAGENTBENCH_SCORE   mode=... work=... seconds=... score_per_sec=... checksum=0x...
RAGENTBENCH_END     mode=... status=PASS sink=0x...
```

Headline metric: **`score_per_sec`** (work units per physical second).
Frequency-normalized metric: `score_per_mhz = score_per_sec / core_clock_mhz`.

The deterministic `checksum` lets you cross-check that a port did not silently
change behavior — e.g. RV32 vs RV64, NPC vs NEMU, native vs LiteX.

## Profile knobs

| variable             | default | meaning                                |
| -------------------- | ------- | -------------------------------------- |
| `AGENT_TOOL_ITERS`   | 16      | tool-mode iterations (32 calls each)   |
| `AGENT_RAG_QUERIES`  | 16      | retrieval queries scored over the corpus |
| `AGENT_FLOW_TURNS`   | 16      | workflow agent loop turns              |
| `RAGENTBENCH_TIMEBASE_HZ` | depends | RV `time` CSR Hz (NPC default 10 MHz) |
| `RAGENTBENCH_CORE_CLOCK_MHZ` | 0 | report core clock (0 = omit score/MHz) |

Profile string format: `tools<N>-rag<N>-flow<N>` (e.g. `tools16-rag16-flow16`).

## Commands (from project root)

```shell
# host-native smoke test — fast, build/run/report end-to-end
make -C app/benchmarks/agent native-test

# pk-on-NPC and NEMU full reports (markdown/csv/json)
make -C app agent-bench-report-rv32
make -C app agent-bench-report-nemu

# single mode
make -C app agent-tools-rv32
make -C app agent-rag-rv32
make -C app agent-workflow-rv32

# LiteX flat binaries for FPGA bring-up
make -C app/benchmarks/agent litex-build
```

Reports land under `app/build/rv$XLEN/benchmarks/agent/{logs,reports}/`.

## Determinism guarantees

- No `malloc`, no floating point, no syscalls beyond `printf`.
- All state arrays are statically sized and zero-initialized at mode entry.
- Seeds are fixed compile-time constants in `agent_bench.c`.
- The `RAGENTBENCH_RESULT` `checksum` field is FNV-style mixed over every state
  mutation; identical builds on identical XLEN must produce identical checksums.

## Non-goals

- Not an LLM agent capability benchmark (use BFCL / tau-bench / SWE-bench /
  WebArena for that).
- Not a replacement for CoreMark or MicroBench — RAgentBench specifically
  targets the irregular-control-flow regime that those two miss.
- Not a marketing claim that Raptor is AI-infrastructure silicon.
