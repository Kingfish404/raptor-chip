# Raptor LiteX SoC — minimal C microbenchmarks

Small self-contained C programs that boot directly from `main_ram`
(`0x80000000`) on the Raptor LiteX SoC. No AM, no OpenSBI, no device tree
— just a `start.S` crt0 plus a single `.c` file with `main()`.

## Why these exist

The standard `am-kernels/microbench` bundle contains stale pre-built
object files that target the *old* NPC MMIO RTC address
(`0x02000048`). On LiteX that address is unmapped, so the very first
call to `uptime()` hangs the AXI bus and looks like a CPU stall.

These tests:

- Use only the **LiteX sim UART** (`0xf0001800`) for I/O.
- Use only the **CLINT mtime register** (`0x0200BFF8`) or the
  `rdcycle` CSR for timing — both are intercepted in `ysyx_bus.sv`
  and never touch AXI.
- Are short enough to run to completion on Verilator sim within the
  default `SIM_TIMEOUT=30s` budget.

## Available tests

| Target          | What it does                                       |
| --------------- | -------------------------------------------------- |
| `test-hello`    | Prints "Hello from Raptor LiteX SoC!" and halts.   |
| `test-fib`      | Iteratively computes fib(40). Exercises the ALU.   |
| `test-prime`    | Counts primes < 2000. Exercises div/mod + branches.|
| `test-memcpy`   | Copies a 64 KiB buffer byte-by-byte.               |
| `test-mul`      | Multiplies 10000 u32 pairs. Exercises MUL unit.    |
| `tests`         | Build all test binaries.                           |
| `tests-run`     | Build + run every test in sequence.                |

## Usage

```bash
cd fpga/litex

# Build + run one test:
make test-hello

# Build + run all:
make tests-run

# Override timeout:
make test-prime SIM_TIMEOUT=60

# Override Verilator threads:
make test-memcpy SIM_THREADS=8
```

Each test prints:

1. A header line identifying the test.
2. Its result (or a short summary).
3. The elapsed cycle count (via `rdcycle`).
4. A terminating `[PASS]` line.

A run is considered successful when the `[PASS]` line appears.
