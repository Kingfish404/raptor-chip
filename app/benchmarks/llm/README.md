# RLLMBench

RLLMBench is a fixed-point, self-contained RISC-V LLM benchmark suite. It is
inspired by the operator mix in `karpathy/llama2.c` and
`karpathy/llm.c`, but avoids model files, malloc, and
floating point so the same workload can run through host-native builds, pk/NPC,
NEMU, LiteX simulation, and FPGA serialboot payloads.

The profile name directly encodes the workload knobs as
`ops<LLM_OP_ITERS>-gen<LLM_GEN_TOKENS>-train<LLM_TRAIN_STEPS>`. The default
profile is `ops8-gen12-train4`:

| Knob              | Default | Meaning                         |
| ----------------- | ------: | ------------------------------- |
| `LLM_OP_ITERS`    |       8 | operator benchmark repeat count |
| `LLM_GEN_TOKENS`  |      12 | generated tokens for inference  |
| `LLM_TRAIN_STEPS` |       4 | training/update steps           |

Changing any knob is allowed for stress testing and automatically changes the
reported profile string, for example `ops8192-gen16-train4096`. Use identical
profile strings for published comparisons.

## Benchmarks

| Binary      | Coverage                                                   |
| ----------- | ---------------------------------------------------------- |
| `llm-ops`   | q8 matmul, causal attention, RMSNorm, AdamW-style update   |
| `llm-infer` | tiny decoder-only Transformer inference with KV cache      |
| `llm-train` | tiny GPT-style next-token training step with softmax + SGD |

## Result Contract

Every run prints stable, machine-readable records with a `RLLMBENCH_` prefix:

```text
RLLMBENCH_INFO version=0.1 profile=ops8-gen12-train4 arch=... xlen=... target=... time_unit=s score=score_per_sec
RLLMBENCH_RESULT name=q8_matmul class=kernel unit=mac work=65536 seconds=... score_per_sec=... checksum=0x...
RLLMBENCH_SCORE mode=ops work=... seconds=... score_per_sec=... checksum=0x...
RLLMBENCH_END mode=ops status=PASS sink=0x...
```

`score_per_sec` is benchmark work items per physical second. Higher is better,
and this is the headline metric for reports and published comparisons. The
benchmark reports elapsed physical seconds only; it does not print cycles,
implementation-specific ticks, IPC, or cycle-derived scores. Checksums make runs
easy to recognize and compare across platforms.

Reports can also derive a CoreMark/MHz-style normalized score when the core
clock is known:

```text
score_per_mhz = score_per_sec / core_clock_mhz
```

This is equivalent to benchmark work items per million core cycles. Use it for
microarchitecture comparisons where frequency should be factored out, and keep
`score_per_sec` as the real delivered-throughput headline.

## Port Layer

The port boundary is the single header `rllmbench_port.h`. It is intentionally
small: the port returns monotonic physical microseconds, and the benchmark turns
that into `seconds` and `score_per_sec`.

```c
rllmbench_time_us_t rllmbench_get_time_us(void);
```

The default header covers host-native `CLOCK_MONOTONIC` and RISC-V `rdtime`.
For bare-metal RISC-V systems, set `RLLMBENCH_TIMEBASE_HZ` to the actual `time`
CSR frequency. On LiteX/FPGA payloads this should match the SoC timer timebase;
on NPC the app Makefile defaults to 10 MHz to match the current RTL time model.
For unusual platforms,
define `RLLMBENCH_READ_TIME_US()` to return monotonic physical microseconds.
Do not confuse `RLLMBENCH_TIMEBASE_HZ` with `RLLMBENCH_CORE_CLOCK_MHZ`: the
former converts `rdtime` to physical seconds, while the latter is only report
metadata for `score_per_mhz`.

## Commands

The top-level convenience targets below run from `app/`:

```shell
# Build only
make llm-bench-build

# Individual pk/NPC runs
make llm-ops-npc
make llm-infer-npc
make llm-train-npc

# Individual NEMU runs
make llm-ops-nemu
make llm-infer-nemu
make llm-train-nemu

# Full suite: run, keep logs, emit Markdown/CSV/JSON reports
make llm-bench-report-npc
make llm-bench-report-nemu

# Host-native build/run/report for portability smoke testing
make llm-native-test
```

Report artifacts are written under `app/build/rv32/benchmarks/llm/reports/` by
default:

| File                 | Purpose                        |
| -------------------- | ------------------------------ |
| `rllmbench-npc.md`   | human-readable summary table   |
| `rllmbench-npc.csv`  | spreadsheet / dashboard import |
| `rllmbench-npc.json` | machine-readable archive       |

Recommended RISC-V comparison headline:

```text
RLLMBench <profile>: geomean score/sec = <score>, geomean score/MHz = <score>, seconds = physical wall time, target = <arch>, XLEN = <xlen>
```

Recommended native/portable headline:

```text
RLLMBench <profile>: geomean score/sec = <score>, seconds = physical wall time, target = <target>, arch = <arch>
```

## Native Host Port

```shell
# From app/
make llm-native-build
make llm-native-test

# Or from this directory
make native-build
make native-test
```

Native builds use `cc` by default and write reports to
`app/build/native/benchmarks/llm/reports/`. Override the host toolchain and
profile knobs when comparing machines:

```shell
make llm-native-test HOST_CC=clang NATIVE_CFLAGS="-O3 -Wall -std=gnu99 -Wno-unused-function"
make llm-native-test LLM_OP_ITERS=8192 LLM_GEN_TOKENS=16 LLM_TRAIN_STEPS=4096
```

Keep `ops8-gen12-train4` for checksum/portability smoke tests. Use a larger
profile such as `ops8192-gen16-train4096` for native performance comparisons,
because the default profile can finish in only tens of microseconds on modern
hosts.

## LiteX / FPGA

```shell
# LiteX-native flat binaries
make -C app/benchmarks/llm litex-build

# LiteX simulation from fpga/litex
make app-llm-ops
make app-llm-infer
make app-llm-train

# Override if the SoC time CSR is not 1 MHz
make app-llm-infer RLLMBENCH_TIMEBASE_HZ=50000000

# FPGA upload via BIOS serialboot
make app-llm-infer-fpga UART_PORT=/dev/tty.usbserial-...
```

The same `RLLMBENCH_` lines appear on the LiteX console, so copied serial logs
can be parsed with `report.py` as long as they contain the benchmark output.
Pass `--core-clock-mhz <MHz>` to `report.py` when generating a frequency-normalized
score from copied logs.
