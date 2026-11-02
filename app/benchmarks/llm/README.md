# RLLMBench

RLLMBench is a fixed-point RISC-V LLM workload benchmark. Its operator mix is
inspired by `karpathy/llama2.c` and `karpathy/llm.c`. It uses static data and
integer arithmetic, with ports for native hosts, pk/NPC, NEMU and LiteX/FPGA.

See [application commands and shared build rules](../../README.md#rllmbench) for
build, run and report targets. The same source produces three modes:

| Binary | Workload |
| --- | --- |
| `llm-ops` | q8 matmul, causal attention, RMSNorm, AdamW-style update |
| `llm-infer` | Tiny decoder-only Transformer inference with KV cache |
| `llm-train` | Tiny next-token training step with softmax and SGD |

## Profiles

| Setting | Meaning |
| --- | --- |
| `LLM_OP_ITERS` | Operator benchmark repetitions |
| `LLM_GEN_TOKENS` | Inference token count, capped at `SEQ_LEN` (16) |
| `LLM_INFER_REPEATS` | Inference repetitions; use this to extend timed work |
| `LLM_TRAIN_STEPS` | Training/update steps |

The profile tag is
`ops<LLM_OP_ITERS>-gen<LLM_GEN_TOKENS>x<LLM_INFER_REPEATS>-train<LLM_TRAIN_STEPS>`.
Each profile has its own build directory. Top-level `app/Makefile` targets select
backend defaults; the leaf Makefile declares defaults for direct builds. Pin all
four settings when comparing backends, since their default workload sizes differ:

```sh
make -C app llm-bench-report-nemu \
    LLM_OP_ITERS=512 LLM_GEN_TOKENS=16 LLM_INFER_REPEATS=64 LLM_TRAIN_STEPS=128
make -C app llm-native-test \
    LLM_OP_ITERS=512 LLM_GEN_TOKENS=16 LLM_INFER_REPEATS=64 LLM_TRAIN_STEPS=128
```

`HOST_CC` and `NATIVE_CFLAGS` select the native compiler and flags. Use a small
explicit profile for portability smoke tests and a larger one for measurements.
Reports live below `app/build/{rv32,rv64,native}/benchmarks/llm/<profile>/reports/`
unless output directories are overridden. Each backend emits Markdown, CSV and
JSON through the shared [report script](../report.py).

## Result contract

Runs emit records with the `RLLMBENCH_` prefix:

```text
RLLMBENCH_INFO version=0.1 profile=ops8-gen12x1-train4 arch=... xlen=... target=... time_unit=s score=score_per_sec
RLLMBENCH_RESULT name=q8_matmul class=kernel unit=mac work=65536 seconds=... score_per_sec=... checksum=0x...
RLLMBENCH_SCORE mode=ops work=... seconds=... score_per_sec=... checksum=0x...
RLLMBENCH_END mode=ops status=PASS sink=0x...
```

`score_per_sec` measures work per physical second. Checksums identify the workload
result across ports. Reports can also derive
`score_per_mhz = score_per_sec / core_clock_mhz`, equivalent to work per million
core cycles. Record profile, architecture, XLEN, compiler/flags and clock with
published comparisons. Runners require the ending `status=PASS` marker.

## Port layer

[rllmbench_port.h](rllmbench_port.h) supplies monotonic physical microseconds via
`rllmbench_get_time_us()`. Native hosts use `CLOCK_MONOTONIC`; RISC-V uses `rdtime`.
Set `RLLMBENCH_TIMEBASE_HZ` to the actual `time` CSR frequency, or override
`RLLMBENCH_READ_TIME_US()` for a different platform clock interface.
`RLLMBENCH_CORE_CLOCK_MHZ` is separate report metadata for score/MHz.

LiteX uses the shared `litex-build` rules. From `fpga/litex`, `app-llm-ops`,
`app-llm-infer` and `app-llm-train` run simulation payloads; the corresponding
`*-fpga` targets upload via BIOS serialboot with `UART_PORT` selected. Pass the
board's timebase explicitly. Copied serial logs use the same result contract and
can be parsed with `app/benchmarks/report.py --suite RLLMBench`.
