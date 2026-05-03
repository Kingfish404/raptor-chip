# app/ — RISC-V User-Space Programs

Standalone RISC-V programs that compile to standard ELFs and run on any RISC-V Linux environment (real hardware, QEMU user-mode, or via Raptor's riscv-pk proxy kernel).

## Quick Start

```bash
# Build everything
make all

# Build and run specific test suites via pk on NPC/nsim
make isa-tests-npc        # ISA correctness verification
make memory-tests-npc     # Memory subsystem tests
make algo-tests-npc       # Algorithm correctness tests
make demos-npc            # Demo programs
make coremark-npc         # CoreMark benchmark
make embench-npc          # Embench-IoT benchmarks
make llm-bench-report-npc # RLLMBench: LLM operator/infer/train benchmark + report
make llm-native-test  # RLLMBench host-native build/run/report smoke test

# Run on NEMU
make isa-tests-nemu
make tests-nemu
make demos-nemu

# Build only (no run)
make tests-build
make demos-build

# Run with QEMU user-mode (after build)
qemu-riscv32 build/rv32/tests/isa/rv_add.elf
qemu-riscv64 build/rv64/tests/isa/rv_add.elf

# Build for RV64
make tests-build ISA64=1
```

## Directory Structure

```
app/
├── Makefile          # Top-level build orchestrator
├── common.mk         # Shared toolchain / flag definitions
├── README.md         # This file
├── tests/            # Correctness verification tests
│   ├── isa/          #   ISA instruction-level tests
│   ├── memory/       #   Memory access pattern tests
│   ├── algo/         #   Algorithm correctness tests
│   └── hello/        #   Minimal hello world
├── demos/            # Interactive demo programs
├── benchmarks/       # Performance benchmarks
│   ├── coremark/     #   CoreMark (auto-cloned from EEMBC)
│   ├── embench/      #   Embench-IoT (auto-cloned)
│   └── llm/          #   Fixed-point LLM operator/infer/train benchmarks
├── lib/              # Picolibc I/O stubs (Linux toolchain only)
├── pk/               # riscv-pk proxy kernel (for running on NPC)
└── build/            # Build outputs (rv32/ or rv64/)
```

## Test Suites

### ISA Verification (`tests/isa/`)

Instruction-level tests using inline assembly. Each test verifies correct behavior of specific ISA instructions, including edge cases.

| Test            | Description                                                                   |
| --------------- | ----------------------------------------------------------------------------- |
| `rv_add`        | ADD/ADDI/SUB, overflow, RV64 ADDW/SUBW                                        |
| `rv_shift`      | SLL/SRL/SRA, shift amount masking, RV64 SLLW/SRAW                             |
| `rv_logic`      | AND/OR/XOR/LUI/AUIPC, bitwise identities                                      |
| `rv_mul_div`    | MUL/MULH/DIV/REM, div-by-zero, overflow (M extension)                         |
| `rv_branch`     | BEQ/BNE/BLT/BGE/BLTU/BGEU, JAL/JALR return address                            |
| `rv_slt`        | SLT/SLTU/SLTI/SLTIU, SEQZ/SNEZ pseudo-instructions                            |
| `rv_bitmanip`   | Zba (sh*add), Zbb (clz/ctz/cpop/min/max/rev8/sext), Zbs (bset/bclr/binv/bext) |
| `rv_compressed` | C extension: patterns that emit compressed instructions                       |
| `rv_zicond`     | Zicond: CZERO.EQZ/CZERO.NEZ, branchless conditional move                      |

### Memory Tests (`tests/memory/`)

| Test             | Description                                                               |
| ---------------- | ------------------------------------------------------------------------- |
| `load_store`     | LB/LH/LW/LD, SB/SH/SW/SD, sign-extension, store-to-load forwarding, fence |
| `memory_pattern` | Sequential, strided, pseudo-random access; memset/memcpy validation       |
| `stack_test`     | Deep recursion, large stack frames, register save/restore, SP alignment   |

### Algorithm Tests (`tests/algo/`)

| Test         | Description                                                            |
| ------------ | ---------------------------------------------------------------------- |
| `sorting`    | Bubble sort, selection sort, quicksort with various input patterns     |
| `crc32`      | CRC-32 table lookup, verified against known IEEE 802.3 test vectors    |
| `math_test`  | Fibonacci, prime sieve, GCD, 4×4 matrix multiply                       |
| `string_ops` | strlen, strcmp, strcpy, memset, memcpy, reverse, itoa, case conversion |

## Demo Programs (`demos/`)

Interactive terminal programs demonstrating various computational patterns.

| Demo         | Description                                                  |
| ------------ | ------------------------------------------------------------ |
| `donut`      | Spinning 3D ASCII donut (fixed-point trig, z-buffer)         |
| `cmatrix`    | Matrix digital rain animation (ANSI color)                   |
| `langton`    | Langton's Ant cellular automaton                             |
| `life`       | Conway's Game of Life (glider, R-pentomino, LWSS)            |
| `hanoi`      | Tower of Hanoi animated solver (8 disks, 255 moves)          |
| `mandelbrot` | Mandelbrot set ASCII renderer (fixed-point Q12)              |
| `sysinfo`    | Print RISC-V ISA info, performance counters, CPI measurement |

## Running with QEMU

All programs are standard static RISC-V ELFs. They can run on any RISC-V Linux userspace:

```bash
# Install QEMU user-mode (Ubuntu/Debian)
sudo apt install qemu-user qemu-user-binfmt

# RV32
qemu-riscv32 app/build/rv32/demos/mandelbrot.elf

# RV64
make demos-build ISA64=1
qemu-riscv64 app/build/rv64/demos/mandelbrot.elf
```

When using the newlib toolchain (`riscv64-unknown-elf-gcc`), programs link against riscv-pk syscall stubs. For the Linux toolchain (`riscv64-linux-gnu-gcc`), QEMU's Linux user-mode emulation handles syscalls natively.

## Running on NPC (via pk)

Programs run on the Raptor NPC simulator via riscv-pk proxy kernel:

```bash
# Run a single test on NPC
make pk-run USER_ELF=app/build/rv32/tests/isa/rv_add.elf

# Run all tests on NPC
make tests-npc ARGS="-b -n"

# Run all tests on NPC with difftest (from project root)
make app-tests-npc32-difftest ARGS="-b -n"
```

## Running on NEMU (via pk)

The same pk+ELF images can also run on NEMU (software ISS). Use the explicit `*-nemu` targets:

```bash
# Run a single test on NEMU
make nemu-run USER_ELF=app/build/rv32/tests/isa/rv_add.elf ARGS="-b"

# Run all tests on NEMU
make tests-nemu ARGS="-b"

# From project root (auto-configures and builds NEMU)
make app-tests-nemu32 ARGS="-b"
make app-demos-nemu32 ARGS="-b"
```

> **Note:** NEMU must be configured first (e.g., `make config-nemu32` from project root).
> Tests running on NEMU can optionally use Spike as a difftest reference (via NEMU's own Kconfig).

## RLLMBench

`benchmarks/llm` contains RLLMBench, a fixed-point AI benchmark suite inspired
by the operator mix in Karpathy's `llama2.c` and `llm.c`: q8 matmul, causal
attention, RMSNorm, AdamW-style updates, tiny decoder inference, and tiny
next-token training. It avoids model files, malloc, and floating point so RV32IMAC
and FPGA payload runs stay practical.

```bash
make llm-bench-build
make llm-ops-npc
make llm-infer-npc
make llm-train-npc
make llm-bench-report-npc
make llm-native-test

# Reports from the full suite
ls build/rv32/benchmarks/llm/reports/
ls build/native/benchmarks/llm/reports/

# Tune workload size
make llm-bench-report-npc LLM_OP_ITERS=16 LLM_GEN_TOKENS=16 LLM_TRAIN_STEPS=8
```

The profile name encodes the workload knobs as
`ops<LLM_OP_ITERS>-gen<LLM_GEN_TOKENS>-train<LLM_TRAIN_STEPS>`; the default
comparable profile is `ops8-gen12-train4`. `make llm-bench-report-npc` and
`make llm-bench-report-nemu` keep per-run logs
and emits Markdown/CSV/JSON reports. The headline metric is `score_per_sec`:
benchmark work items per physical second, higher is better. Reports use only
elapsed physical seconds and do not expose cycles, implementation-specific
ticks, or IPC. When a core clock is supplied, reports also include
`score_per_mhz = score_per_sec / core_clock_mhz`, a CoreMark/MHz-style metric
equivalent to work items per million core cycles. Deterministic checksums are emitted for each mode. The benchmark itself emits stable
`RLLMBENCH_RESULT` / `RLLMBENCH_SCORE` lines so results are easy to grep, paste
into issue reports, or compare with CoreMark and Embench dashboards.

For native host comparisons, use a larger profile so the timed regions are long
enough on modern CPUs:

```bash
make llm-native-test LLM_OP_ITERS=8192 LLM_GEN_TOKENS=16 LLM_TRAIN_STEPS=4096
```

The port layer is the single header `benchmarks/llm/rllmbench_port.h`. New
bare-metal RISC-V ports normally only set `RLLMBENCH_TIMEBASE_HZ` to the real
`time` CSR rate; unusual platforms can override `RLLMBENCH_READ_TIME_US()` to
return monotonic physical microseconds.
For NPC comparisons, `make llm-bench-report-npc` defaults to `RLLMBENCH_TIMEBASE_HZ=10000000`
and `RLLMBENCH_CORE_CLOCK_MHZ=1000`, matching the current RTL timer/core-clock
model. Override `RLLMBENCH_CORE_CLOCK_MHZ` for FPGA or ASIC reports when the
core frequency differs.

The same source can also be linked as a LiteX-native flat binary:

```bash
make llm-litex-build
```

From `fpga/litex`, use `make app-llm-infer` for LiteX simulation or
`make app-llm-infer-fpga UART_PORT=/dev/tty.usbserial-...` to upload via BIOS
serialboot.

## Toolchain

The build system auto-detects available toolchains:

1. `riscv64-unknown-elf-gcc` (newlib) — preferred for bare-metal/pk
2. `riscv64-linux-gnu-gcc` (glibc/picolibc) — works with QEMU user-mode

Install with:
```bash
# macOS
brew tap riscv-software-src/riscv
brew install riscv-software-src/riscv/riscv-gnu-toolchain

# Ubuntu/Debian
sudo apt install gcc-riscv64-unknown-elf  # newlib
sudo apt install gcc-riscv64-linux-gnu    # glibc
```

## Adding New Programs

1. Create a `.c` file in the appropriate directory (`tests/isa/`, `tests/memory/`, `tests/algo/`, or `demos/`)
2. The pattern Makefiles auto-discover `*.c` files — no Makefile edit needed for individual programs
3. For a new test category, add the ELF name to the list in `app/Makefile` and add a run loop
4. Programs should use only standard C library functions (`stdio.h`, `stdlib.h`, `string.h`, `stdint.h`)
5. Tests should print pass/fail summary and return `EXIT_FAILURE` on any failure

## LiteX-Native App Payloads

For FPGA-facing app code, prefer a dual-build pattern: keep the algorithm in
ordinary C, then add a Makefile path that links it with `app/lib/litex/start.S`,
`app/lib/litex/link.ld`, and `app/lib/litex/runtime.c`. That produces a flat
`.bin` loaded at `0x80000000`, avoiding pk/newlib and avoiding a bitstream
rebuild for every test. The LLM benchmark Makefile is the reference pattern.
