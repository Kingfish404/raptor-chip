# Microarchitectural Security Examples

Example proof-of-concept implementations of speculative-execution and cache side-channel attacks for a RISC-V out-of-order core. Each test exercises a specific attack class and reports whether the underlying microarchitectural behavior is observable, using a positive control, a null arm, and a significance test so that a negative result is distinguishable from a broken measurement. Several tests recover a full secret string (multi-bit leakage) rather than a single byte.

The programs run both under `riscv-pk` (U-mode, picolibc) and as static Linux userspace ELFs. They are self-contained examples intended for studying and verifying microarchitectural behavior on a target core.

## Attack taxonomy

The examples fall into three classes.

**Transient-execution attacks** abuse speculation past a mispredicted branch or an unresolved dependency. The transient instructions leave a microarchitectural trace (usually a cache line) that is read back architecturally. They are mitigated by predictor isolation, speculation barriers, and permission checks before cache allocation.

**Cache side-channel attacks** observe cache occupancy or access latency to infer a victim's memory accesses. No speculation is required. They are mitigated by cache partitioning, timer restriction, and constant-time code.

**Covert channels** deliberately transmit data through a shared microarchitectural resource between a sender and a receiver. They are a subset of side channels used for communication and are relevant to cross-context isolation.

## CVE / reference mapping

| Test | Attack | Class | CVE / reference |
|---|---|---|---|
| `spectre-v1` | Bounds Check Bypass (Spectre v1) | transient | CVE-2017-5753 |
| `spectre-v2` | Branch Target Injection (Spectre v2) | transient | CVE-2017-5715 |
| `spectre-v3-meltdown` | Meltdown / Rogue Data Load (v3) | transient | CVE-2017-5754 |
| `spectre-v4` | Speculative Store Bypass (v4) | transient | CVE-2018-3639 |
| `spec-store-bypass` | Speculative Store Bypass (single-byte) | transient | CVE-2018-3639 |
| `spectre-v5` | SpectreRSB / ret2spec (v5) | transient | Kocher et al. 2018; no single CVE |
| `spectre-bhi` | Branch History Injection (Spectre-BHB) | transient | CVE-2022-0001 / -0002 / -23960 |
| `spectre-bse` | Branch Status Eviction (Spectre-BSE) | transient | Zhu & Biondi 2025 (arXiv:2506.07263) |
| `spectre-v2-xctx` | Cross-context predictor residue | transient | related to CVE-2017-5715 / BHI |
| `bpu-collision` | Branch-predictor aliasing | transient | prerequisite for v2 / BHI |
| `l2-residue` | Transient L1D/L2 allocation residue | transient | mechanism behind v1/v2 |
| `tlb-residue` | Speculative page-walk TLB residue | transient | TLB side channel |
| `fence-timing` | Barrier cost and efficacy | mitigation | — |
| `prime-probe` | Prime+Probe cache occupancy | side channel | Yarom & Falkner 2014 |
| `flush-reload` | Flush+Reload cache line | side channel | Yarom & Falkner 2014 |
| `ghostcache` | Weak-coherence instruction cache (Modify+Recall) | side / covert | Jin et al., CCS 2025 |
| `cache-timing` | Latency-ladder calibration canary | primitive | — |

Spectre v3a (Rogue System Register Read, CVE-2018-3640) and LazyFP (CVE-2018-3665) are not implemented because they target x86-specific system-register and FPU-state behavior with no RISC-V analogue.

## Test inventory

| Test | Description | Multi-bit |
|---|---|---|
| `cache-timing` | Measures the L1/L2/DRAM latency ladder and gates the suite | — |
| `spectre-v1` | Bounds-check bypass with a cold bound to widen the window; asm gadget | yes |
| `spectre-v2` | Indirect-target-table cross-site injection via an exact PC alias | yes |
| `spectre-v3-meltdown` | Rogue load of a permission-denied page under a SIGSEGV guard | yes |
| `spectre-v4` | Store bypass with an unresolved store address | yes |
| `spec-store-bypass` | Single-byte store bypass with a live control | no |
| `spectre-v5` | Return-stack-buffer poisoning | yes |
| `spectre-bhi` | Branch-history injection across a syscall boundary | yes |
| `spectre-bse` | Bias-free branch-status-table eviction probe | no |
| `spectre-v2-xctx` | Predictor residue across syscall / fence / fork boundaries | yes |
| `bpu-collision` | Predictor aliasing stride sweep | no |
| `l2-residue` | Transient line installed in L1D and allocated in the inclusive L2 | no |
| `tlb-residue` | Speculative page-table-walk fill surviving a flush | no |
| `fence-timing` | fence/fence.i cost; shows whether a fence clears cache state | no |
| `prime-probe` | Cache-set occupancy channel with self-calibrated geometry | yes |
| `flush-reload` | Shared-line flush, victim access, reload | yes |
| `ghostcache` | Timer-free instruction-cache Modify+Recall and covert channel | yes |

## Methodology

Every detection test follows the same flow:

1. **Timer gate** (`sc_time_selfcheck`): reject a coarse or frozen counter so a broken timer cannot produce a false negative.
2. **Calibration** (`sc_calibrate`): measure the L1/L2/DRAM latency ladder with a random dependent pointer chase, and pre-fault measurement pages so demand paging cannot inject latency spikes.
3. **Eviction self-test** (`sc_evict_selftest`): confirm a warm line really moves to the slowest class before any verdict is trusted.
4. **Positive control**: architecturally exercise the leak path; it must register, otherwise the verdict is INCONCLUSIVE.
5. **Null arm**: an identical window without the secret-dependent access, measuring the false-positive base rate.
6. **Attack arm and decision** (`sc_decide`): the attack argmax over all probe indices (including 0) must equal the expected secret index, pass a Bonferroni-corrected two-proportion z-test (α = 0.01/256), and exceed a practical effect floor.

Implementation notes that matter on real hardware:

- Eviction uses a dependent pointer chase over a buffer larger than the target cache; independent random-load sweeps and plain conflict-set loads can leave the target resident.
- The probe stride is an odd multiple of the line size (4160 = 64×65) so the probe entries spread across all cache sets instead of collapsing into one set and evicting their own evidence.
- Class latencies are derived from the amortized chase plus the measured per-access counter overhead, matching the probe loop's single-access timing.
- Timing uses the cycle counter (`rdcycle`), which ticks every core clock; the time counter (`rdtime`) is typically a much slower fixed-frequency clock and is unusable for fine resolution.
- Where no cache or predictor event counters are exposed, detection is statistical timing rather than counter-based.
- Stride prefetchers usually cannot be disabled in software, so sweeps use random permutations of dependent loads that neither train nor benefit from them.

## Verdict semantics

Each test prints `SCRESULT <name> <verdict> key=value ...`:

- `VULNERABLE` — the secret-index argmax matches, the z-test passes the Bonferroni threshold, and the effect exceeds the floor, with a passing positive control.
- `NOT_VULNERABLE` — no significant signal with a passing positive control (a meaningful negative).
- `INCONCLUSIVE` — the positive control failed, so the channel was not validated and no negative claim is made.
- `ERROR` / `SKIP` — the measurement is broken, or the variant is unsupported in this environment.

The default exit code is 0 (informational). `SC_STRICT=1` (or `--strict`) makes a confirmed `VULNERABLE` exit non-zero for CI gating; `ERROR`/`INCONCLUSIVE` always exit non-zero via the runner.

## Shared layer (header-only)

`app/common.mk` compiles every `*.c` in this directory into its own ELF, so shared code is header-only:

- `sc_common.h` — counters, timer gate, Zicbom probe, executable arenas.
- `sc_probe.h` — runtime cache calibration and dependent-chase eviction.
- `sc_stats.h` — three-class scoring, controls, z-test, and `SCRESULT` output.
- `sc_alias.h` — exact branch-site aliasing independent of ASLR and link layout.
- `bench.h` — compatibility shim including the four modules.

`run_suite.py` is Python so it is not picked up by the `*.c` wildcard.

## Build and run

```bash
# Build (pk / bare-metal)
make -C app security-tests-build ISA64=1
# Build Linux userspace ELFs
make -C app security-tests-build ISA64=1 APP_LINUX=1
# Fast smoke build (reduced rounds and quick calibration)
make -C app security-tests-build ISA64=1 SECURITY_SIM_FAST=1

# Run on a simulator via pk
make -C app security-tests-sim ISA64=1
make -C app security-tests-nemu ISA64=1

# Hardening matrix from a build directory
make -C app security-tests-report ISA64=1
python3 app/security/run_suite.py --build-dir app/build/linux-rv64/security --strict

# Install into a target rootfs and run there (generic wrapper)
make -C app fpga-ubuntu-install -j16
python3 app/security/run_suite.py --build-dir app/build/linux-rv64/security --exec-prefix "<target-wrapper>"
```

`SC_CALIB_DEBUG=1` builds print calibration internals for tuning.

## Adding tests

Drop a `.c` file in this directory (auto-discovered). Include `bench.h`, run `sc_time_selfcheck` → `sc_calibrate` → `sc_evict_selftest`, then a positive control, a null arm, and an attack arm, and emit `SCRESULT` via `sc_result`. For multi-bit leakage, walk a secret string with a per-byte `leak_index` and recover each byte from the probe argmax (see `spectre-v1.c`).