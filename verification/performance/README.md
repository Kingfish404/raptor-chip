# Sampled performance evaluation

This flow profiles an unchanged workload once, selects representative instruction
intervals, captures architectural checkpoints during profiling or in a second NEMU pass, and compares
archived RTL models on matched windows. It avoids booting Linux and executing the
entire benchmark for every RTL change. Outputs are estimates for the selected ROI;
they are not official Geekbench scores or whole-program correctness results.

Keep every run outside the checkout and use a new output directory. Manifests
record executable, firmware, DTB, profile and checkpoint hashes. A failed or partial
run is never promoted to a complete comparison.

## Build the functional frontend

The sampling presets implement the scalar Raptor ISA/PMP configuration with F/D,
single-hart instruction-based time, UART, CLINT and PLIC. Network, disk, SD and RNG
devices are omitted. RV32 uses 256 MiB RAM; RV64 uses the contiguous 2 GiB layout.

```sh
sampling_root=$(mktemp -d /tmp/raptor-sampling.XXXXXX)
make -C nemu O="$sampling_root/nemu64" riscv64_sampling_defconfig
make -C nemu O="$sampling_root/nemu64" -j4
sampling_nemu="$sampling_root/nemu64/build/riscv64-nemu-interpreter"

# Generate a DTB from the actual binary's capabilities without starting a VM.
python3 nemu/tools/nemu.py run --emulator "$sampling_nemu" \
  --firmware /path/to/fw_payload.bin --dry-run \
  --state-dir "$sampling_root/platform"
```

Use `riscv32_sampling_defconfig` and the matching RV32 firmware for RV32. The
Raptor physical map has no low QEMU boot ROM: these presets hand off through MROM
and place the FDT in the last 64 KiB of RAM. The FDT is therefore included in an
architectural RAM checkpoint and survives replacement of MROM by a restore stub.

Sampling uses a fixed DTB entropy seed (`fixed-dtb-v1`). Ordinary NEMU VM boots
retain their random seed. Use the same immutable emulator, firmware and DTB for
profiling and capture; capture checks their hashes against profile provenance.
Sampling also suppresses the host's asynchronous timer signal; CLINT updates
stay on the synchronous instruction path. Profile interval boundaries carry a
rolling PC/instruction fingerprint, and capture must reproduce the full guest
instruction prefix. Warmup rounds up to a BBV boundary. A region's optional
`warmup_start` permits an earlier prelude; otherwise warmup is capped at region
start. Every selected checkpoint therefore has a fingerprint.

## Package an existing Linux application

`linux_workload.py` combines existing firmware with an external initramfs. It
copies the original RV64 ELF, its shared libraries and explicitly supplied assets.
The application's loader/libraries live under `/work`, separate from the base
initramfs libraries. This matters when BusyBox and the application use different
glibc releases. Neither ELF is patched or rebuilt.
The overlay defaults to uncompressed `initramfs.cpio` to avoid spending billions
of interpreted instructions decompressing a large asset bundle. Use
`--compression gzip` when transfer size matters more than functional boot time.

```sh
python3 verification/performance/linux_workload.py \
  --firmware /path/to/linux-bundle/fw_payload.bin \
  --base-initramfs /path/to/linux-bundle/initramfs.cpio.gz \
  --dtb "$sampling_root/platform/machine.dtb" \
  --rootfs /path/to/matching-application-rootfs \
  --program /path/to/geekbench_riscv64 \
  --asset /path/to/geekbench.plar=geekbench.plar \
  --arg=--cpu --output "$sampling_root/workload"
```

Use a kernel with FPU, script and external-initramfs support. The base initramfs
must provide `/bin/sh`, mount and poweroff. The wrapper mounts proc/sys/dev,
disables userspace ASLR for reproducible addresses, and runs only the selected
application. It disables virtio nodes in the supplied DTB. RAM size and CPU/device
description must match the emulator. This controlled environment needs separate
calibration against the board's normal distribution.
Instruction-based functional time can also change the iteration counts chosen
by adaptive, time-based benchmarks. Use fixed-work ROIs for ranking and calibrate
them against native execution before applying a result to the full suite.

## Profile and select points

Start with a bounded hotspot. For example, stop after the first 20 million retired
instructions following Geekbench's AES console marker:

```sh
python3 verification/performance/profile.py --nemu "$sampling_nemu" \
  --firmware "$sampling_root/workload/fw_payload.bin" \
  --dtb "$sampling_root/workload/machine.dtb" \
  --start-marker 'Running AES-XTS' --length 20000000 --interval 1000000 \
  --timeout 3600 --output "$sampling_root/profile"

python3 verification/performance/simpoints.py select \
  --bbv "$sampling_root/profile/profile.bbv.jsonl" \
  --profile-manifest "$sampling_root/profile/profile.json" \
  --warmup 1000000 --kmax 4 --output "$sampling_root/plan.json"
```

This estimates the bounded AES ROI, not all AES iterations or the complete suite.
Console markers can precede buffer initialization and calibration. Inspect the
selected PCs before treating a marker window as the timed computation kernel.
Use symbol/PC boundaries when a kernel-specific estimate is required.
To profile a full workload, omit the marker and length. `--start-pc`/`--stop-pc`
define a symbol-based ROI. `--max-attempts` bounds the NEMU execution loop and must
not be confused with retired instructions: faults and idle-clock advancement can
make the counts differ. Deliberate prefix selection requires `--allow-prefix`.

The native frontend counts successful retirements, including compressed
instructions as one instruction, and excludes synchronous traps. BBV keys include
privilege, SATP and block start. Conditional branches terminate a block even when
not taken. Sparse vectors are projected while reading so the selector retains
only 15-dimensional vectors in memory. Weighted k-means/BIC selects representative
intervals; final cluster weights are instruction shares, including partial tails.
This independent implementation is not bit-equivalent to upstream SimPoint 3.

To avoid repeating an expensive boot/application prefix, add
`--checkpoint-every N` to `profile.py`. NEMU then captures every N full BBV
boundaries in that same process. The bounded ROI's final boundary is excluded.
`checkpoint-grid.json` records hashes for every exported file and can be supplied
to `capture.py --reuse` after selection. It is a capture grid, not a weighted
performance result. Capture failure aborts the profile; no point is silently
discarded. Choose the interval/stride with storage and restore costs in mind.
Keep selected points and their warmup starts on available grid boundaries, and
place the earliest warmup at or after the first captured boundary.

For a suite, supply `--regions regions.json`, a JSON list such as:

```json
[{"name": "AES-XTS", "start": 0, "end": 20000000}]
```

Regions use profile-relative retired counts and must align with BBV intervals.
The tool rejects crossing intervals instead of dropping them. Console marker
records preserve absolute guest counts to locate stages; their timestamps occur
at console output and are not precise internal benchmark timing boundaries.

## Align a Linux computation by user progress

A slower core takes timer interrupts at different instruction positions. Counting
kernel instructions toward a fixed computation window can end at a different
application PC even when both executions are correct. Increasing warmup does not
solve this alignment problem.

Several Linux threads can share one SATP root. For example, an adaptive benchmark
may schedule a sleeping controller thread while its worker is paused. Address
space filtering alone includes that controller's instructions and can move the
end of a fixed computation window. When the ROI belongs to one worker, profile
with its observed SATP root and Linux ABI TLS pointer:

```sh
python3 verification/performance/profile.py --nemu "$sampling_nemu" \
  --firmware "$sampling_root/workload/fw_payload.bin" \
  --dtb "$sampling_root/workload/machine.dtb" --start-pc "$kernel_pc" \
  --user-satp "$user_satp_root" --user-tp "$worker_tls" \
  --interval 500000 --length 6000000 --checkpoint-every 1 \
  --output "$sampling_root/thread-profile"
```

Obtain both values from actual dynamic state. TLS identity is an explicit Linux
ABI assumption, rather than a general thread-ID facility. The selected workload
must keep that pointer stable. The resulting retirement domain travels with the
plan into both execution backends. Kernel and other-thread cycles remain charged;
only the selected worker advances ROI progress. Full-prefix checkpoint offsets
and fingerprints still include all successfully retired instructions. At an
interval boundary, they are pinned before any subsequent interrupt or switch.
Cross-model signatures must agree for full references as well as sampled windows.

For existing all-privilege profiles, derive process-specific intervals before selection:

```sh
python3 verification/performance/filter_profile.py \
  --bbv "$sampling_root/profile/profile.bbv.jsonl" \
  --profile-manifest "$sampling_root/profile/profile.json" \
  --output "$sampling_root/user-profile"
```

The filter selects a single SATP root, ignoring ASID changes. Select
`--satp-root` explicitly if several user processes occur in the profile. Only an
interval consisting entirely of that process may begin a checkpoint interval by default.
Mixed user/kernel intervals merge into the preceding interval. Leading mixed
intervals are excluded and their original offset is recorded. This preserves
known start PCs, absolute capture offsets and full-prefix fingerprints without
guessing instruction order inside a BBV.
`--checkpoint-capture` can instead coalesce only at already captured boundaries.
It validates producer/file hashes, privilege, PC and full-prefix fingerprints,
so a mixed interval can start at a known user checkpoint. A process-only profile
does not retrospectively identify individual threads; reprofile with the worker
scope when scheduling changes its instruction stream.

Derived interval lengths can differ. Choose region boundaries from the derived
BBV records, and use their final retired count for the region end. Both execution
backends then count only successful user retirements from that address space;
**all elapsed cycles, including kernel and interrupt processing, remain charged**.
The reported CPI is cycles per selected user instruction in this mode. Full and
sampled results must use the same domain. Kernel-only ROIs retain the default
all-privilege domain.

## Capture and compare

```sh
python3 verification/performance/capture.py --nemu "$sampling_nemu" \
  --plan "$sampling_root/plan.json" \
  --firmware "$sampling_root/workload/fw_payload.bin" \
  --dtb "$sampling_root/workload/machine.dtb" \
  --output "$sampling_root/capture"

python3 verification/performance/run_samples.py \
  --plan "$sampling_root/plan.json" \
  --capture "$sampling_root/capture/capture.json" \
  --baseline /path/to/archived-baseline-npc \
  --candidate /path/to/archived-candidate-npc \
  --reference /path/to/matching-nemu-reference.so \
  --mrom /path/to/mrom-data.bin \
  --read-latency "$read_latency" --write-latency "$write_latency" \
  --jobs 4 --output "$sampling_root/comparison"
```

Build RV64 simulators and references with `SIM_MEM_PROFILE=large` /
`riscv64_ref_2g_defconfig` for the RV64 sampling preset. Supply measured memory
latencies for performance evaluation; zero latency is useful only for functional
smoke checks. Keep both models' timing, assertion, difftest and wave settings
consistent. Benchmark process concurrency and per-model Verilator thread count
together rather than oversubscribing the host.
For checkpoint bringup, add `--smoke-instructions 1000`. This checks a short
window immediately after each restored PC, skips warmup, and deliberately emits
no weighted performance estimate. It can reuse the same immutable capture.

Capture visits all selected checkpoints in one ordered pass. It saves PC,
GPR/FPR, scalar CSR/PMP state, sparse RAM, CLINT, quiet PLIC and UART configuration.
It rejects live LR reservations, virtual/MPRV execution, pending/in-service PLIC
events, queued UART RX, active virtio state and SD-card configurations. Select
points after MROM handoff: the restore stub replaces MROM, so M-mode code outside
captured RAM cannot resume. Arbitrary external I/O state is unsupported. Move an
unsafe point or extend device
serialization explicitly; do not silently discard and reweight it.

RTL starts measurement after checkpoint resumption and warms its own cache, TLB
and predictor. It records only a 64-instruction band around each requested
boundary, not a line for every cycle. A/B uses shared observed retirement counts
with the requested window length, checks start PC and rolling PC/instruction
signatures, and rejects divergent streams. Shifted boundaries are reported.
The sampling counter excludes synchronous faults, ECALL and EBREAK from CMU's
debug commit packets, matching native BBV retirement semantics. Exception handling
cycles still contribute to the measured elapsed cycles.
Restoration, warmup and shutdown are excluded from measured cycles. Interrupt or
scheduler-dependent path differences can make a window incomparable.

Models with `pmu_schema: raptor-pmu-snapshot-v1` attach cumulative `pmu` counters
to each boundary. `run_samples.py` returns `baseline_pmu` and `candidate_pmu`
for the same endpoints used for its cycle comparison; `run_model.py` retains
the interval counters as `pmu` in each measurement. Old models without this
optional schema remain usable for cycle comparisons. Unsupported schemas,
missing or decreasing counters, mismatched active cycles, and failed dispatch
cycle/slot accounting invalidate a measured window. Never subtract whole-run
text reports or occupancy/peak values to estimate a window.

PMU counts include all cycles and retired instructions between the endpoints.
For a user/SATP/TLS-filtered retirement domain this includes intervening kernel
and other-thread activity, so `instr_cnt` can exceed the selected instruction
count. Different stall counters overlap. The IOQ head counters apply only while
the ROB head awaits memory execution; divide by `active_cycle` for their share
of elapsed cycles, or by `ioq_head_samples` for their conditional share.
For a weighted region, first weight each counter per selected instruction with
the same point weights as CPI, then divide by weighted CPI for a cycle fraction.
Do not average point stall percentages or add overlapping stall categories.

The summary weights **CPI**, then estimates each region's cycles. It does not
average IPC or sample speedups, and it does not convert total cycle reduction
directly into a Geekbench score. Warmup convergence, memory behavior within a BBV
phase, full-workload error and board ranking still need calibration.

## Full reference, warmup convergence and ranking

To compare larger measurement intervals without rerunning a native profile,
coalesce contiguous BBVs in the same retirement domain:

```sh
python3 verification/performance/coalesce_profile.py \
  --bbv "$sampling_root/profile/profile.bbv.jsonl" \
  --profile-manifest "$sampling_root/profile/profile.json" \
  --interval 5000000 --output "$sampling_root/coarse-profile"
```

The tool preserves instruction counts, absolute guest offsets, prefix signatures
and markers. It retains native ordered-PC bands at the new interval boundaries;
interior source boundaries are omitted. It records the parent hashes and rejects
boundaries that would split a source interval. Recluster the new profile, align
regions and warmup to its boundaries, and capture the newly selected checkpoints.
Interval coalescing keeps the retirement stream unchanged; process filtering in
`filter_profile.py` changes that stream and discards its native PC bands.
Keep earlier failed interval/warmup studies when validating a new interval length.

Prepare all warmup variants and a full execution of exactly the same ROI. Supply
enough prelude through `warmup_start` to test a longer full-reference warmup.

```sh
python3 verification/performance/prepare.py \
  --bbv "$sampling_root/user-profile/profile.bbv.jsonl" \
  --profile-manifest "$sampling_root/user-profile/profile.json" \
  --regions "$sampling_root/regions.json" \
  --warmups 0 100000 300000 600000 --full-warmup 1000000 \
  --output "$sampling_root/plans"

python3 verification/performance/capture.py --nemu "$sampling_nemu" \
  --plan "$sampling_root/plans/capture-union.json" \
  --firmware "$sampling_root/workload/fw_payload.bin" \
  --dtb "$sampling_root/workload/machine.dtb" \
  --output "$sampling_root/capture-union"

for variant in full warmup-0 warmup-100000 warmup-300000 warmup-600000; do
  python3 verification/performance/capture.py --nemu "$sampling_nemu" \
    --plan "$sampling_root/plans/$variant.json" \
    --firmware "$sampling_root/workload/fw_payload.bin" \
    --dtb "$sampling_root/workload/machine.dtb" \
    --reuse "$sampling_root/capture-union/capture.json" \
    --output "$sampling_root/captures/$variant"
done
```

The union is a capture schedule, not a performance estimate. Reuse verifies the
requested checkpoints and derives views without booting again. Capture offsets
come from the checkpoint boundary's absolute guest count, rather than subtracting
user warmup from an all-privilege instruction count.

`run_model.py --kind full|sample` measures one immutable simulator and plan. A
full plan must contain one point covering each entire ROI. `matrix.py` executes
multiple declared cases with bounded concurrency, process groups, timeouts and
progress records. Its specification uses schema `raptor-evaluation-matrix-v1`
and a `cases` list. Each case supplies `id`, `model_name`, `kind`, `plan`,
`capture`, `model`, `reference`, `mrom`, `read_latency` and `write_latency`.
Paths are relative to the specification. Optional `jobs`, `timeout` and
`cycle_limit` bound execution.

```sh
python3 verification/performance/matrix.py --spec "$sampling_root/matrix.json" \
  --parallel 4 --output "$sampling_root/results"
python3 verification/performance/validate.py --spec "$sampling_root/validation.json" \
  --output "$sampling_root/validation-result.json"
```

A validation specification uses schema `raptor-simpoint-validation-spec-v1`, a
`selected_warmup` count, and `comparisons: [{"full": ".../results.json",
"sample": ".../results.json"}]`. Include at least three warmup settings and two
distinct RTL models per memory condition. The checker compares sampled cycles
with the full ROI, checks the selected warmup against the longest warmup and the
two longest against each other, and checks model ranking and speedup error.
Default gates are 5% cycle error, 5% speedup error, 1% warmup change and 2x replay
wall speedup; `gates` may declare a different study target before measurement.
Failed or incomparable points cannot be omitted or reweighted.

Report profiling, selection, capture and model-build costs separately from replay.
For repeated RTL candidates, setup amortizes only when the saved replay time
exceeds setup cost. Keep instruction reduction, simulated-cycle prediction,
execution wall speedup and complete wall speedup as separate quantities.

## Optional QEMU discovery frontend

`qemu_bbv.c` is a single-vCPU RISC-V system-mode plugin, compatible with the QEMU
8.2 plugin API. Build against the header matching the installed QEMU:

```sh
cc -shared -fPIC -fvisibility=hidden -O2 -Wall -Wextra -Werror \
  -I/path/to/qemu/include/qemu verification/performance/qemu_bbv.c \
  -o "$sampling_root/libraptor-bbv.so" $(pkg-config --cflags --libs glib-2.0)
# Add to an existing single-core QEMU launch, with the network disconnected:
# -plugin "$sampling_root/libraptor-bbv.so,outfile=$sampling_root/qemu.bb,interval=10000000"
```

Its standard `T:ID:COUNT` vectors can be selected with `--allow-prefix`. These are
translation-block instruction weights, not verified retirements. QEMU points
cannot be passed to NEMU capture as absolute instruction IDs. Use this frontend
for fast phase discovery, then establish checkpoints in the matching functional
platform. QEMU guest speed is not Raptor performance.

## Validation and FPGA work

```sh
make -C verification/performance check
python3 verification/performance/smoke.py --xlen 64 \
  --nemu "$sampling_nemu" --npc /path/to/rv64-large-npc \
  --reference /path/to/rv64-2g-reference.so --mrom /path/to/mrom-data.bin \
  --dtb "$sampling_root/platform/machine.dtb" \
  --output "$sampling_root/pmp-smoke"
```

Repeat with RV32 inputs. The integration payload assigns unequal PMP addresses
and reads them repeatedly, catching RV64 observation code that casts 32-bit RTL
array elements to 64-bit pointers. Short smoke windows verify the workflow and
are not warmup/accuracy evidence for application performance.

Use `--fixture store` for the regression in which the first resumed instruction
is a store. REF synchronization occurs at the restore trampoline's final mret,
before any guest store can remain in a queue or cache. Every subsequent guest
instruction is checked normally. Counter backdoor writes reach CSR storage and
its immediate observation view.
`--fixture csr` checks a first resumed CSR write, which must also survive the
post-trampoline bookkeeping.

## FPGA checkpoint replay

The NEMU profiler, SimPoint selection and Verilator window measurement do not
require changes to production `rtl/`. The simulator observes existing retirement
state and applies checkpoint fixups through its host accessors.

Exact FPGA checkpoint restoration is a separate, intrusive experiment. The
current debug module has no RV64 abstract register transfer, program buffer or
system-bus access sufficient to replace the replay hooks. A read-only `bind`
monitor alone cannot restore CSR/timer state or publish dirty cache lines.

Production `rtl/` contains no `RAPT_SAMPLING` ports, CSR/CLINT restore inputs or
sampling-driven cache maintenance. The explicit `--sampling` build applies
[the FPGA-only overlay](../../fpga/common/sampling/core.patch) to a disposable
copy before RTL export. It never patches the checkout. Its receipt,
`sources/sampling-overlay.json`, records the production source, overlay, interface
and modified-file hashes; the normal artifact manifest also fingerprints the
export. Context drift or changing inputs aborts preparation. The legacy
`-DRAPT_SAMPLING` flag alone is rejected on production sources.

This isolates the experiment's source changes; **the resulting sampling FPGA
still contains instrumentation and restore controls**. Its timing, area and
performance results apply to that instrumented build. Production CLINT formal
qualification covers the unmodified peripheral; replay ordering and restoration
must also pass the experimental bridge and real-core regressions below.

The opt-in RV64 CU08/DDR backend adds an
[AMD JTAG-to-AXI master](https://docs.amd.com/r/en-US/ug908-vivado-programming-debugging/JTAG-to-AXI-Master)
and a hardware retirement observer. Ordinary builds omit this interface.

```sh
python3 fpga/common/scripts/native_build.py \
  --board fpga/mlk-cu08-ku15p --xlen 64 --preset small --memory ddr \
  --clock-mhz 50 --sampling --cm005-bridge 1 \
  --build-root "$sampling_root/fpga" --vivado "$vivado" --jobs 8 build
```

Run the focused window/bridge tests and controller synthesis before the board
build. Keep each preset's output isolated. Load only a build whose routed setup,
hold, DRC and clock checks passed, using the board loader's source/artifact
fingerprint gate and an exact idle-board JTAG target. Retain the original board
image and its validated source environment for restoration after evaluation.

For an RV64 core regression, build the independent AXI DDR oracle from the prepared
board sources, then compare eight stopping boundaries against NEMU:

```sh
native_sources=/path/to/prepared-native-build/sources
verilator -cc --exe --build -j 4 --no-timing -Wno-fatal \
  --top-module rapt_sample_sim_top -I"$native_sources" \
  "$native_sources/soc_sources.sv" fpga/common/tests/rapt_sample_sim_top.sv \
  "$PWD/fpga/common/tests/sample_replay_sim.cc" \
  --Mdir "$sampling_root/drain-model" -CFLAGS '-O2 -std=c++17'
python3 verification/performance/drain_smoke.py \
  --model "$sampling_root/drain-model/Vrapt_sample_sim_top" \
  --nemu "$sampling_nemu" --exporter /path/to/matching-rv64-npc \
  --dtb "$sampling_root/workload/machine.dtb" \
  --output "$sampling_root/drain-regression"
```

The repeated-store fixture checks all GPRs and committed data in the DDR oracle
before reset. Completing a stop while leaving dirty committed data in cache fails
the regression. This functional check does not establish vendor DDR timing or board performance.

`fpga_replay.py` takes `--spec`, `--native-build`, `--exporter`, `--output`,
`--hw-target`, `--vivado` and optional `--repetitions` (default three). The
`--transfer-timeout` option bounds each complete upload or readback separately
(default 3600 seconds); large transfers report progress every 16 MiB in `jtag.log`.
The specification uses `raptor-fpga-evaluation-spec-v1` and a `cases` list of `id`,
`kind` (`full` or `sample`), `plan` and `capture`. Plan/capture paths are relative
to the specification. Set `gpr: true` for short functional cases. `--exporter`
is a matching RV64 NPC binary with `--ckpt-export=STATE,FILE` support.

The runner verifies routed artifacts and the connected bitstream's build ID,
then checks JTAG word ordering. It zeros DDR with an on-board engine and uploads
one sparse RAM base. Compatible workload profiles share this base; every snapshot
must use the same RAM size and chunk layout. Subsequent snapshots restore pages
whose checkpoint contents change and all CPU-written DDR pages. Exact differences
are prepared for the scheduled checkpoint transitions, so unchanged nonbase pages
remain resident across points and repetitions.
Every transferred byte is read back and checksummed. After the ROB and store
queue drain, sampling halt requests a global cache clean. Dirty lines and pending
write responses must finish before reset; all DDR writes are tracked. JTAG memory
access is permitted only after committed work, stores and memory transactions
have drained. Control remains accessible while the hart runs.
The cycle limit also bounds the drain phase. A drain timeout reports error 8
while keeping halt asserted; it never forces hart reset or grants memory access
before quiescence. The drain cycle counter is readable at control offset `0xe8`.
Offset `0xf0` exposes drain readiness: bits 0 through 3 indicate ROB halted,
store queue empty, data side idle and cache writeback idle, respectively.
Failed runs retain the active point and controller status, elapsed cycles,
retirement count, boundary count and error code before cleanup changes state.

A generated SRAM prefix restores quiet PLIC/UART configuration and executes the
same GPR/FPR/CSR/PMP trampoline as RTL simulation. The final mret restores saved
counter, mepc, mstatus and CLINT state in hardware before guest execution. Warmup
then builds this configuration's own microarchitectural state. The observer
supports the same user-progress domain and boundary bands, with a separately
labelled ordered PC digest. Its digest is not NEMU's full-prefix FNV signature.
Sampling builds disconnect external UART RX. Canonical byte accesses to captured
UART control/status registers remain supported, including the 8250 backup timer's
IER/IIR/LSR polling. FIFO identification matches the captured quiet UART. UART
data-register traffic, bursts, noncanonical accesses and NIC traffic fail this
scope. Ordinary console builds retain their original FIFO identification policy.

Results separate the initial RAM-base setup, per-point delta/SRAM transfers,
active execution and complete replay wall time. Each new run archives and hashes
its host replay tools in the output's `.tooling` directory. Hardware measurements require
repetition, full-ROI accuracy and native workload calibration. A short replay
does not establish full-suite score accuracy. Full Geekbench, cold Linux boot,
arbitrary external I/O and SMP validation remain separate acceptance runs.

For each routed configuration, include one full case and sampled cases with at
least three warmup settings. Validate the resulting hardware records with:

```sh
python3 verification/performance/fpga_validate.py \
  --spec "$sampling_root/fpga-validation.json" \
  --output "$sampling_root/fpga-validation-result.json"
```

The specification uses schema `raptor-fpga-validation-spec-v1`, a
`selected_warmup` count, and `sources: [{"model": "small", "results":
"small/results.json"}, {"model": "candidate", "results": "candidate/results.json"}]`.
Use matching workload, retirement domain, memory and clock settings. The checker
requires at least three repetitions, checks instruction signatures within and
across configurations, and compares full-ROI cycles, warmup convergence and
configuration ranking. It also requires verified checkpoint readback. Default
gates add 1% repeated-cycle variation to the software accuracy gates.
That stability gate covers the full reference, selected warmup and both warmups
used as convergence references; matching medians cannot establish convergence
when the longest-warmup repetitions are unstable.

An optional `pc_reference` in each replay case names its native BBV JSONL file.
The file must match the plan's profile hash and retirement domain and contain
`rotate-xor-pc-v1` boundary bands produced by NEMU. Replay checks every hardware
boundary against this independent stream, archives the reference, and records
the audit. Validation repeats the audit from the archived file. These compact
digests check ordered PC control flow; use DiffTest and architectural-state
checks for ISA correctness. Filtering a BBV file discards its PC bands because
filtering changes the retirement stream. Warmup and measurement boundaries must
have native reference coverage, including the hardware's boundary lookahead.

For long full references, a case may set a positive 64-bit `cycle_limit`.
The host observation deadline covers that budget at the routed clock plus
60 seconds, with a 300-second minimum. Cases without an override retain the
CLI budget. When one replay contains multiple workload profiles, give each
validation specification an explicit `profile_sha256`. The checker requires
the entire replay to have completed, validates one profile at a time, and lists
the other cases in `excluded_cases`. Report every study, including failed
short-window cost or convergence gates.

Replay wall speedup includes delta loading, readback verification, SRAM restore,
warmup and result collection. Initial RAM-base loading and offline preparation
are reported separately. Small FPGA windows can finish faster than the host can
load several checkpoints; a reduction in measured instructions alone does not
prove an end-to-end speedup. Keep a failed cost gate in the report even when
cycle prediction and configuration ranking pass.

Use the cost report to retain individual repetition times, their total and common
RAM setup alongside the steady replay median:

```sh
python3 verification/performance/fpga_cost.py \
  --source "$sampling_root/candidate/results.json" \
  --profile "$profile_sha256" --warmup 1000000 \
  --output "$sampling_root/candidate-cost.json"
```

The first full replay can need fewer dirty-page restores than later repetitions.
Adding measured shared setup to each side gives a component accounting ratio;
it does not measure a standalone selected-only session. Report profiling, capture,
build, programming and Linux restoration separately. A bounded application ROI
does not establish whole-suite Geekbench score accuracy.

Observe the environment's board locks before any programming or CPU reset.
Boards may share forwarding or storage infrastructure. A different JTAG cable
does not by itself establish that reprogramming is independent of a busy board.
