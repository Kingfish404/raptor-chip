# Simulator builds and configuration

From the repository root, `make run-rv32` and `make run-rv64` configure, build, and run the built-in smoke program with difftest. Use `IMG=/absolute/path.bin` for another program. `DIFFTEST=1` is the default and selects `o2_difftest_defconfig`; `DIFFTEST=0` selects `o2_defconfig` and disables the runtime reference. An explicit `NPC_DEFCONFIG` overrides the profile choice.

With `--diff`, `--diff-isa=MASK` opts the NEMU reference into Svnapot (bit 0), Zawrs (bit 1), and Zfa (bit 2); the default mask is zero. For example, `--diff-isa=0x4` enables Zfa. The simulator rejects other extension bits and missing reference negotiation; V/H and extensions with additional CSR state need RTL state export and comparison first. This option does not enable an extension in RTL: use it only when the selected RTL preset implements the feature.

`--tohost=ADDRESS` optionally observes an 8-byte-aligned HTIF exit mailbox within RAM.
It reads the mailbox after actual memory writes, including byte enables and RV32 split writes.
Device/command zero with value 1 passes; other odd exit values fail independently of `a0`.
Zero, even values and other HTIF device messages do not exit. This is an exit-only adapter,
not a general HTIF console or syscall implementation. It is disabled unless requested.
Use the [upstream riscv-tests runner](../verification/external-tools.md) to obtain the symbol
address from the ELF and run the unmodified tests with matched reference settings.

## Independent builds

`BUILD_ROOT` selects the output root (default `sim/build`); `BUILD_PROFILE` selects a named configuration workspace (default: the HDL preset name). RV32 and RV64 configurations are separate even within one profile:

```text
sim/build/<profile>/
  config-riscv32/.config
  config-riscv32/include/generated/autoconf.h
  config-riscv64/.config
  config-riscv64/include/generated/autoconf.h
  obj_dir-riscv32-<options-key>/...
  obj_dir-riscv64-<options-key>/...
  riscv32-npc-sim -> selected cached executable
  riscv64-npc-sim -> selected cached executable
  mrom/...
  run-riscv32/data/...
  run-riscv64/data/...
```

NEMU references live in `nemu/build/ref/<defconfig>/`, with separate configuration, generated headers, objects, and libraries. `SIM_MEM_PROFILE=large` selects `riscv{32,64}_ref_2g_defconfig`; the default selects `riscv{32,64}_ref_defconfig`. `nemu-reference` builds incrementally under a per-defconfig lock, leaving interactive `nemu/.config` untouched. Root `build-nemu{32,64}-ref` and verification use the default profile. Explicit `DIFF_REF_SO` overrides (including an empty value) and `DIFFTEST=0` retain their behavior. For example, after preparing both NEMU reference libraries, these simulator builds/runs can execute concurrently:

```sh
make verilog
make build-nemu32-ref
make build-nemu64-ref
make run-rv32 BUILD_PROFILE=smoke32 BUILD_ROOT=/tmp/raptor-sim-builds \
  DIFF_REF_SO="-d $PWD/nemu/build/ref/riscv32_ref_defconfig/riscv32-nemu-interpreter-so" &
make run-rv64 BUILD_PROFILE=smoke64 BUILD_ROOT=/tmp/raptor-sim-builds \
  DIFF_REF_SO="-d $PWD/nemu/build/ref/riscv64_ref_defconfig/riscv64-nemu-interpreter-so" &
wait
```

Use **different profiles for different Kconfig variants of the same XLEN**. For manual configuration, use the same profile and VFLAGS on both commands:

```sh
make -C sim o2_defconfig BUILD_PROFILE=plain64 VFLAGS=-DRAPT_RV64
make -C sim all BUILD_PROFILE=plain64 VFLAGS=-DRAPT_RV64
```

`menuconfig`, `savedefconfig`, and `print-config` operate on that selected profile/XLEN. Configure and build in separate Make invocations; root convenience targets already do this. Legacy `sim/.config` and `sim/include/generated` are not implicitly imported, rewritten, or deleted. Reapply a defconfig or use `menuconfig` to initialize a new workspace.

## Cache and cleanup

Kconfig contents and effective compiler/Verilator options select the model cache directory. Switching options preserves older models; switching back reuses an up-to-date model. Reapplying an unchanged defconfig preserves generated header timestamps. Source changes still use normal Make dependency rebuilding. The conventional executable pathname is published atomically; an already running executable is not overwritten in place.

`make -C sim clean BUILD_PROFILE=<name>` explicitly removes only that profile. Do not clean a profile while another process is using it. Ordinary builds no longer delete configuration stamps or entire model directories at parse time. `make help` is read-only; `make -n all` may still generate a missing included Kconfig file, but only in its selected build directory.

`run` and `run_log` execute in the selected `run-riscv*` directory. `IMG`, `DISK`, `SDCARD`, and MROM paths are resolved before changing directories. Use absolute paths for file arguments embedded directly in `ARGS`.

Long simulations print a progress heartbeat every 60 seconds by default.
Set `NSIM_HEARTBEAT_SECONDS=300` for fewer lines, or `=0` to suppress the
wall-clock heartbeat. `NSIM_PROGRESS_CYCLES` separately controls the periodic
LightSSS snapshot interval (default 40 million cycles); its progress line
remains enabled when the heartbeat is suppressed.

Repeat `--serial-milestone=TEXT` to timestamp the first occurrence of each text
on UART TX without stopping execution. For example, use
`--serial-milestone='Run /init as init process' --serial-milestone='Starting syslogd'`.
Reports have the form `serial milestone: cycles=N insts=N text=TEXT`. Counts start
at the current `cpu_exec` invocation (reset/resume for a batch run), exclude reset
cycles, include all retire slots in the cycle containing the final matching byte,
and are independent of benchmark PMU resets. Reporting waits for a UART newline
to preserve guest log lines; the timestamp still refers to the matching cycle.
`--serial-exit-on=TEXT` can also be used to stop at a final milestone, and pending
milestones are reported on that stop even when the guest has not sent a newline.
Markers must be nonempty single-line text. Repeated identical markers are deduplicated.

Native NPC PMU reports also include AXI channel handshakes, channel backpressure
(`valid && !ready`), posted-write occupancy, and overlap with SQ-full cycles.
Signals are captured immediately before the rising edge and accumulated with the
ordinary per-cycle PMU sample. `wlast_without_bvalid` counts cycles with a completed
write-data burst still awaiting B and no BVALID. `wlast_pending_sum` is the integral
of completed write-data bursts awaiting B; divided by B handshakes it gives mean
WLAST-to-B latency when `wlast_pending_end` and `unmatched_b` are both zero.
`unmatched_b` exposes measurement boundaries that cut in-flight writes rather than
allowing a pending counter to underflow. Posted histogram entry N counts cycles
with N posted writes; `capacity=0` disables posting and never counts as full.
The AXI master's outstanding count includes its accepted staging/skid requests,
which can exceed transactions already presented on external AW. These are whole
PMU-interval counters, include MMIO, and overlap; use a store-only workload to
isolate store behavior. No RTL or architectural counters are changed.

The L1D activity report labels the observed quantities directly: tag-ready cycles
in `LD_A`, bus-load starts on `LD_A -> LD_D`, and service cycles in `LD_D`. A held
write-back lookup may contribute several tag-ready cycles, and bus-load starts
include uncached loads while MSHR-served misses can bypass `LD_D`. These counters
therefore do not define a comprehensive cache miss rate or AMAT. `cache_drain`
measures the memory drain controller's request to L1D, not the backend's raw request.

## Memory response timing

The memory model accepts `--mem-read-latency=N` and `--mem-write-latency=N`
to add cycles before the first read beat and each write response, respectively.
Their Make variables are `SIM_MEM_READ_LATENCY` and `SIM_MEM_WRITE_LATENCY`.
Both default to zero. Random delay, when enabled, remains additive.

The simulation-only AXI endpoint (`sim/rtl/rapt_npc_soc.sv`) supports FIXED,
INCR and WRAP bursts, including narrow transfers and unaligned INCR starts.
WRAP lengths are 2, 4, 8 or 16 beats. Invalid burst geometry, oversized
transfers, 4 KiB crossings, illegal WSTRB lanes and WLAST/AWLEN mismatches
produce SLVERR; unmapped addresses produce DECERR. Descriptor errors cause no
host memory/device access. A write-data error suppresses that beat and later
beats; earlier valid writes are already visible. Early WLAST ends the malformed
burst; missing WLAST at AWLEN also terminates it with an error so the endpoint
can recover. This diagnostic behavior does not make malformed traffic legal AXI.

`ReadOutstanding` is a top-level RTL parameter (default 8, range 1..16).
Reads preserve order within each ID and can interleave beats across IDs.
Round-robin arbitration and a registered R output maintain one beat per cycle
at zero additional delay while holding the complete response stable under
backpressure. Host reads occur when a beat enters that output register, once
per beat. A queued request does not perform an early MMIO read.

AW and W are independent: one elastic W slot accepts data before its address,
and zero-delay AW/W can be serviced together. No host write occurs before both
channels have handshaken. Valid strobes are passed in one host callback per
beat, preserving device register write atomicity; a zero strobe has no effect.

`--mem-serialize-writes` (`SIM_MEM_SERIALIZE_WRITES=1`) holds AWREADY low
until the previous write response has been consumed, including its handshake
cycle. It defaults off. The W slot can still hold one early beat in this mode.
Fixed delays approximate aggregate memory service time; this option does not
model DDR scheduling, bridge address stages, or refresh.

`--mem-write-outstanding=N` (`SIM_MEM_WRITE_OUTSTANDING=N`, range 1..64)
selects response queue capacity, default 1. Larger values permit independent
writes; B responses remain ordered. RAM read/write hazards cover complete burst
footprints, including wrapped addresses and canonical aliases. Device accesses
are conservative barriers through final R/B consumption. Independent RAM reads
can pass pending write responses. Serialization adds an AW admission restriction
at any queue capacity. Fixed latency, capacity and serialization options are
sampled at reset; random delay is sampled per request/beat/response.

Run the endpoint regressions without building the core:

```sh
python3 sim/tests/test_npc_axi_protocol.py --output /tmp/npc-axi-check
python3 sim/tests/test_npc_write_outstanding.py --output /tmp/npc-write-queue-check
python3 sim/tools/test_npc_write_serialization.py --output /tmp/npc-write-check
```

The protocol scoreboard covers both XLENs, read capacities 1/3/8, fixed and
seeded random delays, same-ID ordering, interleaving, response backpressure,
burst geometry, errors, side effects, reset, and zero-delay streaming throughput.
The write regressions cover capacities 1/2/4/8/64 and both serialization modes.
The serialization output path must not already exist.

For performance comparisons, freeze the core configuration and executable image,
keep difftest/assertion/wave options and host compiler settings identical, and
report ROI cycles separately from elapsed host time. A lower AXI wait count can
have little effect on CoreMark/MHz when the benchmark runs mostly from cache.
Exclude build time and use repeated alternating runs for host throughput.

## FPGA timing evaluation harness

`python3 sim/scripts/eval-fpga.py TREE TAG PRESET "EXTRA_VFLAGS" [WORKLOADS...]`
builds an isolated simulator and runs the selected existing images. Workloads
default to `mp cm eb` (Linux requires explicit `lx64`); `mq`, `ms`, and `pf` select the quick memory probe,
store probe, and Sv39 pagefault probe. Select only one of `mp`, `mq`, and `ms`.
The default is RV64 with `o2_defconfig`, DIFFTEST=0 and `make -j4`.

All default evaluation inputs and outputs live under
`TREE/sim/build/fpga-eval` (`EVAL_CAL_DIR`): `latency.env`, `img/`, `build/`,
and `logs/`. **Provide a calibrated `latency.env` containing `RL=N` and `WL=N`
before running.** There is no built-in calibration and the harness does not
create or modify this file. Both values must be in `0..1048574`; `RL`/`WL`
environment overrides support explicit sweeps after the file is supplied.

```sh
TREE=$PWD
mkdir -p "$TREE/sim/build/fpga-eval"
cp /path/to/calibrated/latency.env "$TREE/sim/build/fpga-eval/latency.env"
EVAL_COREMARK_IMAGE=/path/to/coremark-riscv64-npc.bin \
  python3 sim/scripts/eval-fpga.py "$TREE" reference small-cache "" cm
python3 sim/tools/fpga_eval_summary.py \
  --logs-root "$TREE/sim/build/fpga-eval/logs" reference
```

Default image paths are relative to `EVAL_CAL_DIR`:

| Workload | Image path |
|---|---|
| `mp` | `img/memprobe-rv64/memprobe-riscv64-npc.bin` |
| `mq` | `img/memprobe-rv64/memprobe-quick-matched-riscv64-npc.bin` |
| `ms` | `img/memprobe-rv64/memprobe-store-riscv64-npc.bin` |
| `pf` | `img/pagefault-rv64/pagefault-riscv64-npc.bin` |
| `cm` | `img/coremark-rv64/coremark-riscv64-npc.bin` |
| `eb` | The exact 19 benchmark `.bin` files in `img/embench-rv64/` |
| `lx64` | `img/linux-rv64/fw_payload.bin` |

Use `EVAL_MEMPROBE_IMAGE`, `EVAL_COREMARK_IMAGE`, or `EVAL_LINUX_IMAGE` to select
existing images explicitly. Relative overrides resolve from the invocation
directory. `EVAL_XLEN=32` selects the matching `rv32`/`riscv32` image names for
bare-metal workloads; `pf` and `lx64` require RV64. No images are downloaded.
`EVAL_BUILD_ROOT` and `EVAL_LOG_ROOT` override `EVAL_CAL_DIR/build` and
`EVAL_CAL_DIR/logs`; `EVAL_MAKE` selects a recursive make executable and defaults
to normal `make`. A published experiment wrapper may set these variables to
retain its own images, calibration and output layout.

Every invocation needs a new tag. Logs include return codes, image hashes and
model settings in a manifest. `EVAL_RUN_JOBS` controls workload concurrency;
the default is 1. Builds use `make -j4` and `VERILATOR_JOBS=4`.
Apply resource limits and machine scheduling outside the runner (for example,
invoke it through your batch scheduler). No host-specific thresholds or locks
are built in. TERM/INT and per-command `.cancel` files cancel owned subprocess
groups, including children, with TERM followed by KILL after five seconds.
`-n` disables VCD; this harness
builds with DIFFTEST=0 and supplies no `-d` reference. `EVAL_MEM_ARGS` accepts only `--mem-serialize-writes`,
`--mem-random-delay=N`, `--mem-random-seed=N`, and `--mem-write-outstanding=N`
(also with separate values). Runtime overrides belong in `EVAL_MEM_ARGS`; the
harness neutralizes Make-level memory options before recording its command.
Use `RL`/`WL` for fixed delays so recorded settings match the simulator command.
Keep model arguments and images identical when comparing configurations.

Build evaluation images with `bash sim/scripts/build-fpga-workloads.sh TREE WORKLOAD`
(`memprobe`, `pagefault`, or `embench`). Memprobe accepts an optional variant:
`full`, `full-matched`, `quick` (default), `quick-matched`, `store`, or `store-matched`.
`EVAL_CAL_DIR` selects the image/build directory, and `MEMPROBE_STEPS` overrides
access counts. Embench uses local source selected by `EMBENCH_SOURCE`; no download
is performed. CoreMark and Linux images use their existing application build flows.
For a custom Linux device tree, set `EVAL_DT_SOURCE` when running the evaluation.

The one-off M/S/U `mmu-hit` calibration probe and quick-user DTS fallback were
removed. Memprobe retains cache/memory latency measurements; pagefault retains
Sv39 demand, resident, and hot-page measurements. Existing privileged directed
tests remain the functional translation checks.

Run the runner/summary regression suite with
`python3 -m unittest discover -s sim/tools -p test_fpga_eval.py`.

## Static timing analysis

`make sta` defaults to `MEMORY=sram`, `XLEN=32`, `STA_PLATFORM=nangate45` and `CLK_FREQ_MHZ=50`. `sta-detail` adds detailed paths; `sta-check` only checks RTL elaboration. SRAM timing libraries are selected by `SRAM_PLATFORM` (defaults to the normalized STA platform). Missing libraries trigger placeholder generation; a successful default run does not establish characterized SRAM timing. See [OpenRAM integration](sram/README.md) for real macro libraries.

For DFF-only analysis, from the repository root (or with `make -C sim`), use the memory-model parameter for behavioral memories expanded into standard-cell flip-flops and selection logic:

```sh
make sta MEMORY=dff
make sta MEMORY=dff RAPT_CONFIG=small STA_PLATFORM=nangate45 CLK_FREQ_MHZ=100
make sta MEMORY=dff XLEN=64 RAPT_CONFIG=default STA_PLATFORM=sky130 CLK_FREQ_MHZ=50
make sta-detail MEMORY=dff RAPT_CONFIG=small STA_PLATFORM=asap7 VFLAGS=-DRAPT_RV64
make sta-check MEMORY=dff RAPT_CONFIG=default VFLAGS=-DRAPT_RV64
```

`sta-check MEMORY=dff` only preprocesses and elaborates the full core; it does not run technology mapping or STA. The SRAM-macro define is explicitly disabled, and no extra macro Liberty or blackbox files are supplied to the backend. Standard-cell timing still comes from the selected PDK. Supported in-tree platforms are `nangate45`, `asap7`, and `sky130hd` (`sky130` is an alias). A proprietary PDK such as TSMC 22 nm requires licensed libraries and a corresponding platform configuration in the `YOSYS_OPENSTA` backend; these targets do not provide that PDK.

Outputs are isolated by build profile, HDL preset, XLEN, PDK, and frequency:

```text
sim/build/<profile>/sta/dff/<preset>/<riscv32|riscv64>/<platform>/<frequency>MHz/
  rtl/rapt_pack.sv
  rtl/pack-synth-check.log
  backend/result/<platform>-rapt-<frequency>MHz/...
```

Use an absolute `BUILD_ROOT` or `STA_WORK_DIR` to relocate outputs. Use distinct directories for concurrent runs with other differing `VFLAGS`/RTL inputs. Backend scripts and libraries are linked into the isolated workspace; output does not overwrite the backend's shared SRAM reports. Prepare tools and PDKs before running: the DFF targets do not fetch, update, or install dependencies. Large DFF caches substantially increase synthesis cost. These are pre-layout STA results, not SRAM-macro estimates or post-route signoff.

## Remaining shared resources and checks

This isolates the **simulator**, not every external tool. NEMU's legacy config and some software/Chisel generation workflows still have shared state. The default sim run refreshes its NEMU reference. For parallel runs, first build references sequentially, then pass explicit `DIFF_REF_SO="-d /absolute/reference.so"` paths to bypass reference rebuilding. Do not concurrently reconfigure NEMU. Likewise, do not regenerate Chisel decoders while building simulators that read them. Concurrent incompatible configurations must not share the same profile/XLEN directory.

`make -C verification sim-build-isolation-check` checks real Kconfig generation, parallel profile/XLEN isolation, idempotence, cache switching, read-only help, and profile-local cleanup. Its cache tests use a fake compiler; they do not replace an actual `make run-rv32` smoke test. Directed Verilator checks also retain option-keyed object caches instead of deleting the whole test directory on every run. Explicit clean targets remain available.
