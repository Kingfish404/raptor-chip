# Security Tests: Side-Channel & Speculative Execution Benchmarks

Standard-ELF micro-benchmarks targeting cache side-channel and speculative
execution vulnerabilities on the Raptor Chip RISC-V core. Built with the
pk-based toolchain under `app/` — no abstract-machine dependency.

## Tests

| Test                | Attack Class      | Description                                                           |
| ------------------- | ----------------- | --------------------------------------------------------------------- |
| `cache-timing`      | Side-channel      | Measures cache hit vs. miss latency: the fundamental timing primitive |
| `spectre-v1`        | Spectre Variant 1 | Bounds-check bypass via branch predictor mistraining                  |
| `spectre-v2`        | Spectre Variant 2 | Branch target injection via indirect branch predictor pollution       |
| `spec-store-bypass` | Spectre Variant 4 | Speculative store bypass: stale load from store queue                 |
| `bpu-collision`     | BPU aliasing      | PHT/BTB collision detection between different branch sites            |
| `fence-timing`      | Mitigation cost   | Cycle cost of `fence` / `fence.i` instructions                        |

## Usage

From the project root:

```bash
# Build + run all security tests on NPC (RV32) via pk
make -C app security-tests

# RV64 mode
make -C app security-tests ISA64=1

# Run on NEMU instead of NPC
make -C app security-tests RUN_ON=nemu

# Just build (no run)
make -C app security-tests-build

# Run a single test
make -C app security-tests-build
make -C app pk-run USER_ELF=app/build/rv32/tests/security/spectre-v1.elf
```

## Interpreting Results

These are **detection benchmarks**, not pass/fail correctness tests.

- **VULNERABLE**: the test successfully extracted a secret byte via the
  targeted speculative/side-channel vector. This indicates the
  microarchitecture does not mitigate (or insufficiently mitigates) that
  attack class.
- **NOT VULNERABLE**: the side channel signal was too weak to extract the
  secret. This may mean the core has effective mitigations, or that the
  test parameters need tuning for the specific microarchitecture.
- **cache-timing** and **fence-timing** are informational: they report
  raw cycle counts for reference.

## Adding New Tests

Drop a `.c` file into this directory — it is auto-discovered by the Makefile.
Use `#include "bench.h"` for timing helpers and the `check()` assertion.
Only standard libc (stdio, stdint, stdlib, string) + RISC-V `rdcycle` CSRs
are available; no AM / OS runtime.
