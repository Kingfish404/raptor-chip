# Raptor integration for upstream CoreMark®-PRO

This port builds all nine upstream workloads for RV32 and RV64, with F/D enabled
and `ilp32d` / `lp64d` ABIs. The default is GCC `-O2`, one context, one worker, one
iteration, and reference validation enabled. The source revision is pinned to
`4832cc67b0926c7a80a4b7ce0ce00f4640ea6bec` in
[EEMBC's repository](https://github.com/eembc/coremark-pro).

The upstream checkout lives in ignored `app/build/src/coremark-pro`. Its kernels,
datasets, workload definitions, and MITH core are compiled unchanged. The local
build files and `portme/` implement the permitted platform adaptation: RISC-V
timing, single-context execution, console output, heap, startup, and normal MITH
command-line arguments. Upstream supplies the workload source lists and kernel
build rules. All workloads use the same compiler and linker options.

## Build and run

From the repository root:

```sh
# Build only; ISA64=1 selects RV64 (default RV32).
make -C app coremark-pro-build ISA64=1
make -C app coremark-pro-baremetal-build ISA64=1

# Build the simulator and run all nine workloads; these can take many hours.
make coremark-pro-rv32 ARGS="-b -n"
make coremark-pro-rv64 ARGS="-b -n"
make app-coremark-pro-rv32 ARGS="-b -n"  # via pk/MMU
make app-coremark-pro-rv64 ARGS="-b -n"

# Full-workload reference validation on the faster software interpreter.
make coremark-pro-nemu32 ARGS="-b"
make coremark-pro-nemu64 ARGS="-b"

# Limit the selected workloads without changing their code or datasets.
make -C app coremark-pro-baremetal-sim CMP_WORKLOADS=linear_alg-mid-100x100-sp
```

`make -C app coremark-pro-sim`, `coremark-pro-nemu`,
`coremark-pro-baremetal-sim`, and `coremark-pro-baremetal-nemu` use existing
simulator/interpreter builds. `CMP_JOBS` defaults to 2 and `CMP_TIMEOUT` to 7200
host seconds per workload. `CMP_LOG_DIR` overrides the log/report destination;
the NEMU runner appends `-nemu`. `coremark-pro-report` regenerates Markdown from
an existing `CMP_LOG_DIR/results.json`. The report rejects missing results,
reference mismatches, simulator errors, and truncated runs, even if the guest
returns zero.

The runner prints progress every 60 seconds (`run.py --progress-interval`),
distinguishing initialization from the timed workload. NEMU runs use a separate
`NEMU_STATUS_DIR` for each workload, so concurrent runs retain their own periodic
instruction count, PC, registers, and instruction trace. Timeout results include
the last observed phase and snapshot; a timeout never counts as a pass. Rebuild
NEMU after pulling changes to enable these separate status directories.

`zip-test` initializes approximately 1 MiB of text with repeated `strcat` calls.
The Picolibc implementation in this toolchain scans the growing destination one
byte at a time, so initialization alone executes tens of billions of guest
instructions. Keep the full dataset and allow enough host time:

```sh
make coremark-pro-nemu32 CMP_WORKLOADS=zip-test CMP_TIMEOUT=7200 ARGS="-b -n"
make coremark-pro-nemu64 CMP_WORKLOADS=zip-test CMP_TIMEOUT=7200 ARGS="-b -n"
```

The limit includes initialization, reference checking, and reporting; it is
not a benchmark duration or a guarantee that every host finishes within it.
Inspect progress before choosing a larger limit.

The bare-metal port currently requires Picolibc, the same libc shipped with the
Ubuntu toolchain used by `app/`. It reserves 128 MiB of NPC RAM, with a 1 MiB
stack and the remaining space available to the heap. The pk port reserves a
64 MiB heap with anonymous `mmap`, because the embedded-ELF loader does not
provide a `brk` growth range. Both initialize libc TLS. F/D require an RTL preset supporting
floating point.

## Validation and performance are separate runs

`CMP_VERIFY=1` enables upstream reference checks. MITH limits validation to one
iteration and includes checking in its timed region. For performance, first
validate the same compiler configuration, then rebuild with `CMP_VERIFY=0`:

```sh
make -C app coremark-pro-baremetal-nemu CMP_VERIFY=1 CMP_LOG_DIR=/tmp/cmp-check
make -C app coremark-pro-baremetal-sim CMP_VERIFY=0 CMP_ITERATIONS=1 \
    CMP_LOG_DIR=/tmp/cmp-perf
```

Changing flags, iteration count, validation mode, or port sources invalidates
the cached build. `CMP_OPT_FLAGS` defaults to `-O2`; keep any override identical
for all nine workloads and for both implementations in a comparison.

The timer reads `time` at `CMP_TIMEBASE_HZ=10000000`, matching the default NPC
timer. Change this value with the platform timer. `cycle` and `instret` are
recorded over the same MITH region. On RV32 all counters use a stable high/low
read. The report records whether the measured interval meets the upstream
1000-timer-tick minimum. The upstream label `time(ns)` remains untouched; its
integer is actually the configured timer's tick count, so use the explicit
`RAPTOR ROI` record and timebase.

`run.py --baseline-command '...before simulator and flags...' --command
'...after simulator and flags...'` compares the same images and requires equal
retired instruction counts. It records commands and binary hashes. Full program
runs and sampled execution windows must be reported separately. Neither a
partial suite nor a short simulation is an aggregate or certified score, and
cycle improvements alone do not establish Fmax or performance on an FPGA.

For an RTL comparison that is practical on a slow simulator,
`verify/scripts/coremark_pro_performance.py` samples the four floating-point
workloads. It requires complete NEMU reference-validation runs (`CMP_VERIFY=1`)
and complete NEMU runs of the measured images (`CMP_VERIFY=0`). It fast-forwards
those unchanged images to 10%, 50%, and 90% of the timed instruction stream,
then restores the same architectural checkpoint into each RTL implementation.
Each window warms for 4096 instructions and measures about 16384 instructions,
using exactly matching retirement boundaries. Assertions and NEMU differential
checking remain enabled. The default 250000-cycle run budget can be increased
with `--cycle-limit`; an insufficient budget is a failure, not an estimated
result. `--help` lists the required simulator, image, and reference-report paths.
These windows characterize local execution phases, not whole-workload speedup.

Integration checks on 2026-10-09 built all nine workloads in RV32/RV64 and
pk/bare-metal modes. All 18 bare-metal reference checks passed on QEMU 8.2.2's
`virt` machine with a 10 MHz timer. The NEMU interpreter also checked the four
floating-point workloads in both validation and performance modes. QEMU
user-mode has a different counter timebase and is not supported by this port's
default timer settings. Validation logs are kept under
`verify/build/coremark-pro-qemu-system-validation` and
`verify/build/coremark-pro-check-rv{32,64}-nemu`.
The initial NEMU check passed 16/18 workloads with an explicit 1800-second timeout;
both `zip-test` runs timed out during string-based initialization. Profiling found
an additional host bottleneck: NEMU queried an environment variable on every
guest instruction. Moving that lookup outside the instruction loop preserved
architectural state and allowed the same zip images to finish in 837.331 seconds
(RV32) and 791.343 seconds (RV64), each with `fails=0`. Both execute approximately
40.1 billion total instructions, with only about 85 million in the timed region.
These are host validation runtimes, not RTL performance results.

After the fix, all 18 full NEMU reference checks pass. The original timeout logs
remain intact; the consolidated repair report is
`verify/build/coremark-pro-fixes/{report.md,results.json,manifest.json}`. Raw logs
are in `coremark-pro-zip-fixed-rv{32,64}`, `coremark-pro-regression-rv{32,64}`,
and `coremark-pro-rebuilt-rv64` under `verify/build`. The runner's default timeout
remains 7200 seconds and is configurable.

## License and attribution

CoreMark is a registered trademark of EEMBC. The upstream distribution includes
the Apache License 2.0 and the CoreMark-PRO Acceptable Use Agreement; the exact
text is retained in [LICENSE.upstream.md](LICENSE.upstream.md). The fetched
checkout retains all original notices, including component notices. This port
does not relicense upstream code. `portme/th_al.c` retains its upstream header
and identifies the local changes. Binary redistribution must include the
applicable upstream and component notices as well as the toolchain library
licenses; fetching/building is not publication.

The acceptable-use agreement restricts use of the mark with modified benchmark
software. The official
[porting instructions](https://github.com/eembc/coremark-pro/blob/main/README.md)
describe the adaptation-layer boundary. The build rejects changes to tracked
upstream sources. Embedded datasets are used; the upstream `FAKE_FILEIO=1`
platform option is enabled, so external input files are unsupported.

Article 4.1 of the upstream agreement requires a Commercial COREMARK-PRO License
for disclosure, reference, or publication of results in marketing materials for
commercially available products. These targets produce local engineering logs
and per-workload cycle reports, calculate no headline suite score, and do not
upload or publish results. Do not copy these internal measurements into product
marketing without satisfying the upstream requirements.
