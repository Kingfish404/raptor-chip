# RLLMBench

RLLMBench is a fixed-point, self-contained RISC-V LLM benchmark suite. It is
inspired by the operator mix in `karpathy/llama2.c` and
`karpathy/llm.c`, but avoids model files, malloc, and
floating point so the same workload can run through host-native builds, pk/NPC,
NEMU, LiteX simulation, and FPGA serialboot payloads.

The profile name directly encodes the workload knobs as
`ops<LLM_OP_ITERS>-gen<LLM_GEN_TOKENS>x<LLM_INFER_REPEATS>-train<LLM_TRAIN_STEPS>`.

| Knob                | Meaning                                              |
| ------------------- | ---------------------------------------------------- |
| `LLM_OP_ITERS`      | operator benchmark repeat count                      |
| `LLM_GEN_TOKENS`    | generated tokens for inference (max `SEQ_LEN`=16)    |
| `LLM_INFER_REPEATS` | inference outer repeat count (extends infer wall)    |
| `LLM_TRAIN_STEPS`   | training/update steps                                |

Because `LLM_GEN_TOKENS` is capped at `SEQ_LEN`, scale infer wall-time via
`LLM_INFER_REPEATS` rather than `LLM_GEN_TOKENS`.

### Per-platform default profiles

The top-level `app/Makefile` selects a different default profile per platform
to keep each backend within an Embench-style ~1–5s wall-clock window. Per-mode
defaults are picked automatically by target group; override any knob on the
command line to force a fixed profile across platforms (recommended for
published comparisons).

| Backend                 | OP_ITERS | GEN_TOKENS | INFER_REPEATS | TRAIN_STEPS | Target wall  |
| ----------------------- | -------: | ---------: | ------------: | ----------: | ------------ |
| NPC RTL sim (`*-sim`)   |        8 |         12 |             1 |           4 | a few s      |
| NEMU ISS (`*-nemu`)     |       64 |         16 |             2 |          16 | ~1–3 s       |
| Native host             |  524 288 |         16 |       131 072 |     262 144 | ~3–5 s/mode  |
| LiteX FPGA (`litex-build`) |     8 |         12 |             1 |           4 | (uses fallback; override per-board) |

Example: force the legacy small profile on every backend for a quick smoke
test, or pin a published profile across platforms:

```shell
# Quick smoke (fastest possible) on native:
make -C app llm-native-test \
    LLM_NATIVE_OP_ITERS=8 LLM_NATIVE_INFER_REPEATS=1 LLM_NATIVE_TRAIN_STEPS=4

# Pin the same profile on NEMU and native (recommended for published numbers):
make -C app llm-bench-report-nemu \
    LLM_OP_ITERS=512 LLM_GEN_TOKENS=16 LLM_INFER_REPEATS=64 LLM_TRAIN_STEPS=128
make -C app llm-native-test \
    LLM_OP_ITERS=512 LLM_GEN_TOKENS=16 LLM_INFER_REPEATS=64 LLM_TRAIN_STEPS=128
```

Each profile gets its own build sub-directory
(`build/.../llm/<profile-tag>/`), so switching profiles never reuses stale
ELFs from a previous run.

## Benchmarks

| Binary      | Coverage                                                   |
| ----------- | ---------------------------------------------------------- |
| `llm-ops`   | q8 matmul, causal attention, RMSNorm, AdamW-style update   |
| `llm-infer` | tiny decoder-only Transformer inference with KV cache      |
| `llm-train` | tiny GPT-style next-token training step with softmax + SGD |

## Result Contract

Every run prints stable, machine-readable records with a `RLLMBENCH_` prefix:

```text
RLLMBENCH_INFO version=0.1 profile=ops8-gen12x1-train4 arch=... xlen=... target=... time_unit=s score=score_per_sec
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
make llm-ops-rv32
make llm-infer-rv32
make llm-train-rv32

# Individual NEMU runs
make llm-ops-nemu
make llm-infer-nemu
make llm-train-nemu

# Full suite: run, keep logs, emit Markdown/CSV/JSON reports
make llm-bench-report-rv32
make llm-bench-report-nemu

# Host-native build/run/report for portability smoke testing
make llm-native-test
```

Report artifacts are written under `app/build/rv32/benchmarks/llm/reports/` by
default:

| File                 | Purpose                        |
| -------------------- | ------------------------------ |
| `rllmbench-rv32.md`   | human-readable summary table   |
| `rllmbench-rv32.csv`  | spreadsheet / dashboard import |
| `rllmbench-rv32.json` | machine-readable archive       |

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
make llm-native-test \
    LLM_OP_ITERS=8192 LLM_GEN_TOKENS=16 LLM_INFER_REPEATS=64 LLM_TRAIN_STEPS=4096
```

The native target's per-platform default
(`ops524288-gen16x131072-train262144`) is calibrated for ~3–5s wall-clock per
mode on modern x86/Apple cores. Drop to a smaller profile (e.g.
`LLM_NATIVE_OP_ITERS=8 LLM_NATIVE_INFER_REPEATS=1 LLM_NATIVE_TRAIN_STEPS=4`) to
match the NPC checksum/portability smoke profile. Use the same explicit knobs
on every backend when publishing comparisons.

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
