# Native Ubuntu benchmark profiling

These programs run CoreMark and the 19 benchmarks in the local Embench checkout
as native RV64 Linux/glibc applications. They do not use the bare-metal runtime
or proxy kernel. The benchmark algorithm sources remain unchanged.

`profile.c` measures only the benchmark region with `CLOCK_MONOTONIC`,
`getrusage`, and optional `cycle`/`instret` CSR reads. Optional software
`PERF_COUNT_SW_CPU_CLOCK` sampling records IP and time in a 2 MiB perf ring.
Sample export, symbolization, process startup, and Embench cache warmup are
outside the measured region. CoreMark uses its standard timed iteration loop.

## Build and run

From the repository root, with the benchmark sources already present:

```sh
bench_tools=fpga/common/tests/ubuntu_bench
bench_work=/tmp/raptor-ubuntu-bench-example
bench_root=/path/to/nfs-root
bench_guest=/var/tmp/raptor-bench-profile-example
bench_ssh=/path/to/board-ssh-config
python3 "$bench_tools/build_benchmarks.py" --output "$bench_work/bin"
mkdir -p "$bench_root$bench_guest/results"
cp "$bench_work/bin/"* "$bench_root$bench_guest/"
for stage in baseline profile baseline-long; do
  python3 "$bench_tools/run_stage.py" \
    --binaries "$bench_work/bin" --results "$bench_root$bench_guest/results" \
    --guest-dir "$bench_guest" --ssh-config "$bench_ssh" --stage "$stage" \
    --evidence "$bench_work" > "$bench_work/$stage-stage.log" 2>&1 || break
done
python3 "$bench_tools/analyze.py" --binaries "$bench_work/bin" \
  --results "$bench_root$bench_guest/results" --rootfs "$bench_root" \
  --output "$bench_work/analysis.json"
```

The host NFS-root path and SSH config must match the running board. Each stage
temporarily sets `/proc/sys/kernel/perf_user_access=2` to permit direct user CSR
reads, restoring the original value on exit. Run as root on the test board.
Run stages sequentially. These commands overwrite same-named result files;
choose a fresh directory when preserving an earlier experiment.

Use `--host` to select the board's SSH alias, including a KU15P alias. The first
stage uses CoreMark 8192 iterations and one Embench invocation. Override this with
`--coremark-iterations` when needed. The second estimates repeat counts targeting
about 12 seconds, and samples every
19 ms. The third uses exactly those counts without sampling. Use the third
stage for timing/CPI, and the second only for hotspot attribution. Fixed timer
sampling is approximate and may have skid or aliasing; it does not identify
the instruction responsible for an individual pipeline stall.

CoreMark must report at least 10 seconds and valid CRCs. The default compiled
iteration count is only 64, so use the runner or explicitly pass a sufficient
count (for example `8192`). Embench uses `GLOBAL_SCALE_FACTOR=1` and `warm_caches(1)`; it
reports per-case timings, not an official reference-normalized Embench score.

## Limits and validation

- CSR counts include every privilege mode and other activity on the hart;
  reported IPC/CPI are inclusive, not process-scoped hardware perf events.
- Without usable HPM cache/branch/stall events, PC samples cannot
  produce cache miss rates or branch misprediction rates.
- The parser rejects malformed/truncated samples. Check both perf's lost count
  and parsed lost records. Nonzero benchmark exit codes are rejected.
- Debug symbols resolve benchmark functions and source lines. Stripped shared
  libraries are labeled only when the IP falls within an exported symbol's
  size; unknown internal text remains unresolved. Kernel samples remain grouped.
- The current upstream `xgboost` verifier has a weak threshold at scale factor
  1. Check the returned result separately against a host reference built from
  the same sources and configuration.

Run parser tests with:

```sh
python3 -m unittest discover -s fpga/common/tests/ubuntu_bench -p 'test_*.py'
```

`memory_probe.c` is a separate diagnostic: randomized dependent pointer loads
over 1 KiB–1 MiB footprints, then repeated stores over 1 KiB. Compile with the
same RV64 flags and `profile.c`; run with `RAPTOR_SAMPLE_NS=0` and CSR access
enabled. The probe reports 4,194,304 accesses per case, warms and faults pages
before timing, and validates the pointer cycle and final stored values. Its
cycles/access include loop overhead and hart interruptions. Larger footprints
exercise both cache and translation effects; this is not a direct DDR latency
measurement or a substitute for benchmark hardware events.

Keep per-run reports, raw samples, logs and binary manifests outside the source
tree. Use a new output directory for each comparison, archive results before
temporary directories are removed, and record configuration and source identity.
This directory contains reusable tools and methodology only.
