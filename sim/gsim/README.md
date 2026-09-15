# gem5 SE-mode runner for raptor-chip

A gem5 model of the raptor-chip parameterized superscalar OoO RISC-V core for
**design space exploration** and **performance bug analysis**, parameterised
directly from `raptor-chip/hdl/configs/<preset>/rapt_config.svh`.

## Why SE mode?

`app/Makefile` builds bare-metal newlib ELFs at
`app/build/rv$XLEN/<bench>/*.elf` using `riscv$XLEN-unknown-elf-gcc`. These
ELFs invoke newlib syscalls (`write`, `_exit`, `sbrk`) which gem5's
`RiscvEmuLinux` SE workload services natively (it accepts ELFs tagged
`unknown` OS as well as `linux`). No proxy kernel, no HTIF, no Linux —
just iterate fast on uarch parameters.

FS mode is **deliberately not modelled** here:

* The `pk` build (`app/build/pk-build-rv$XLEN/payload.elf`) targets
  `riscv-pk` over HTIF; gem5's `RiscvBoard` is a HiFive-style platform
  that does not match raptor-chip's CLINT/PLIC + AXI memory map.
* Booting Ubuntu via `riscv-ubuntu-run.py` is reproducible but useless
  for raptor-chip DSE because none of raptor's RTL knobs map there.

If you need OS-level workloads on raptor-chip, run them on
[sim](../) (Verilator with the real RTL) instead.

## Parameter map (raptor → gem5 O3)

| `rapt_config.svh`         | gem5 O3                                          |
| ------------------------- | ------------------------------------------------ |
| `RAPT_L1I_LINE_LEN` | I-side line bytes = `4 << LINE_LEN` |
| `RAPT_L1D_LINE_LEN` | D-side line bytes = `(XLEN / 8) << LINE_LEN` |
| `RAPT_L1{I,D}_LEN`        | sets = `1 << LEN`                                |
| `RAPT_L1{I,D}_N_WAYS`     | `Cache.assoc`                                    |
| `RAPT_ROB_SIZE`           | `numROBEntries`                                  |
| `RAPT_PHY_SIZE`           | `numPhysIntRegs`, `numPhysFloatRegs`             |
| `RAPT_RS_SIZE+IOQ_SIZE`   | `IQUnit.numEntries`                              |
| `RAPT_SQ_SIZE`            | `LQEntries`, `SQEntries`                         |
| `RAPT_DECODE_WIDTH`       | `fetchWidth`, `decodeWidth`                      |
| `RAPT_RENAME_WIDTH`       | `renameWidth`                                    |
| `RAPT_DISPATCH_WIDTH`     | `dispatchWidth`; also approximates global `issueWidth`/`wbWidth` |
| `RAPT_COMMIT_WIDTH`       | `commitWidth`                                    |
| `RAPT_RIQ_SIZE`           | `fetchQueueSize` (fetch→rename decoupling queue; gem5 has no IIQ analogue) |
| `RAPT_BPU_DIRP_*`         | selects the gem5 conditional predictor by default: TAGE→`tage` (RTL TAGE geometry), GSHARE→`gshare`, BIMODAL→`local`, STATIC→`local` (approximation) |
| `RAPT_INTEGER_ISSUE_PORTS`| `IntALU.count` with `--rtl-execution-resources`  |
| `RAPT_M_FAST`             | `IntMult` opLat=1 (pipelined MUL) with `--rtl-execution-resources` |
| `RAPT_INTEGER_SYSTEM_PORT`| Validated against the RTL port count; physical index has no gem5 O3 analogue |
| `RAPT_BTB_SIZE/WAYS`      | `SimpleBTB(numEntries, associativity)`           |
| `RAPT_PHT_SIZE`           | `BiModeBP(globalPredictorSize, choicePredictorSize)` |
| `RAPT_RSB_SIZE`           | `ReturnAddrStack(numEntries)`                    |

L1I stores 32-bit instruction words; L1D stores XLEN-bit data words. Current
presets derive both from `RAPT_CACHE_LINE_BYTES`, so byte capacities stay
constant across RV32/RV64. Default lines are 64 B with 16 KiB L1I (64 sets ×
4-way) and 16 KiB L1D (64 sets × 4-way); `large` has 32 KiB L1I (1-way) and
8 KiB L1D (2-way); `small` 512 B/256 B and `middle` 256 B/256 B on 16 B lines.
The model uses the larger derived line size as gem5's global cache line size
for historical unequal-line presets. gem5's default L1 MSHR count is 1,
modelling the RTL's single-outstanding-miss FSM; hits during a refill
approximate `RAPT_LSU_HUM`'s best-effort B channel (a second concurrent *miss*
is not modelled). `RAPT_L1I_REFILL_WORDS` (32 B sector refill) has no gem5
cache-level analogue — gem5 refills a full line on a miss.
The FP register count is a gem5 OoO modeling choice: RTL has a separate
32 × 64-bit architectural FPR bank, not a renamed FP register file.
RV64 DSE results produced before the XLEN-aware cache fix used half the
configured L1D capacity and must be rerun for comparisons with current RTL.
The old `RAPT_ISSUE_WIDTH` and `RAPT_DUAL_*` declarations are accepted only as
fallbacks for historical presets; direct ordered-stage widths always win.
Raptor's heterogeneous execution domains do not have a single RTL issue-width
boundary, so gem5's global issue/writeback widths are a throughput
approximation rather than a structural equivalence.

## Prerequisites

```sh
# 1. Build gem5 RISC-V (one time)
cd <gem5-root>
scons build/RISCV/gem5.opt -j$(nproc)

# Host notes (Linux):
#   - If the host's default python3 lacks a shared library, force the
#     embedded interpreter: env PYTHON_CONFIG=python3.12-config scons ...
#   - Keep the system protoc on PATH (a Homebrew/standalone protoc may emit
#     .pb.h requiring newer protobuf headers than the installed libprotobuf).
#   - Bare-metal Embench stubs call times(NULL); the SE model needs a
#     one-line fix in src/sim/syscall_emul.hh (timesFunc returns -EFAULT on
#     a NULL buffer) or Embench runs panic with a page-table fault at vaddr 0.
#     Linux behaves identically (EFAULT), so the patch only removes a
#     guest-programming-error panic, not a modelling difference.

# 2. Build the raptor-chip bare-metal ELF you want to run
cd <raptor-chip>/app
make coremark                 # rv32 by default
make coremark ISA64=1         # rv64
make embench                  # all of Embench-IoT
```

## Configuration precedence

The default Makefile run derives widths, capacities and execution-resource
counts from the selected preset without a JSON overlay. The conditional
branch predictor follows the preset's `RAPT_BPU_DIRP_*` define (default
preset: RTL-flavoured TAGE). `RTL_EXEC=1` (default) matches the RTL
execution resources: `RAPT_INTEGER_ISSUE_PORTS` integer ALUs, one MULDIV
(`RAPT_M_FAST` timing), one load/store request port. Set `RTL_EXEC=0` to use
gem5's broader default FUPool; select `BP=local` explicitly for a bimodal
experiment.
Use `JSON_CONFIG=dse-config.json` explicitly for the provided TAGE study
configuration; its cache, width and window settings override the preset.
`SET` overrides are applied after JSON. Output names retain the preset and
append the JSON basename, so the same overlay on different presets stays
separate. Use an explicit `OUTDIR` for JSON files with identical basenames
or for repeated experiments whose evidence must be retained.

## Quick start

```sh
cd raptor-chip/sim/gsim

# CoreMark on the default preset
make coremark

# Same workload, "small" preset (single-issue, 4-entry ROB)
make coremark PRESET=small

# Same workload, "large" preset on RV64
make coremark PRESET=large RV64=1

# Embench-IoT
make embench-crc32
make embench-matmult-int

# MicroBench uses an SE-compatible compatibility layer around the upstream
# AM-Kernels algorithms. Its optional workload argument is test/train/ref/huge.
make microbench

# Microarchitecture grid search (rob/iq/sq/cache/width/bpu x CoreMark + Embench)
# Writes sim/build/gsim/results/grid-*.csv; analyse with sweet_spot.py.
make grid
make grid GRID_ARGS="--resume"            # reuse existing stats.txt
make grid GRID_ARGS="--phase rob"         # one axis only

# Branch-predictor study: RTL-size TAGE, equal-budget gshare,
# a practical 8 KiB TAGE-SC point, and a 64 KiB upper bound
make bp-study

# In-order TimingSimpleCPU / functional AtomicSimpleCPU baselines
make timing BENCH=coremark

# Sweep small/default/large × {timing, o3} for one workload
make sweep BENCH=coremark
```

Each run lands in `raptor-chip/sim/build/gsim/<bench>-<preset>[.<json>]-rv$XLEN[.cpu=<cpu>][.<set>]/`
(the default `o3` CPU suffix is omitted)
with the following persisted artifacts:

| file           | purpose                                                       |
| -------------- | ------------------------------------------------------------- |
| `stats.txt`    | full gem5 stat dump (raw counters)                            |
| `config.{ini,json}` | full system params for reproducibility                   |
| `run.log`      | tee'd stdout/stderr (gem5 banner + workload output)           |
| `summary.txt`  | human-readable digest: IPC, BP/BTB acc, L1 miss rates, …      |
| `summary.csv`  | one-row machine-readable digest                               |

`make sweep BENCH=<bench>` additionally writes
`raptor-chip/sim/build/gsim/results/sweep-<bench>-rv$XLEN.csv` aggregating every
preset×CPU combo. To regenerate the summaries from existing `stats.txt`
without re-running gem5: `make summary OUTDIR=<dir>` or
`make aggregate BENCH=<bench>`.

`make bp-study` writes one CSV per selected workload under
`sim/build/gsim/results/bp-study-<bench>-rv32.csv`; by default this includes
CoreMark and the SE-compatible MicroBench port. `rtl-tage` is the current
Raptor-equivalent direction predictor: a 256-entry bimodal base and three
128-entry tagged tables. `same-budget-gshare` uses the same normalized
direction-predictor budget, separating algorithm benefit from capacity.
`practical-tage-sc` uses gem5's fixed 8 KiB TAGE-SC-L implementation; the
fixed 64 KiB `upper-tage-sc` model is a deliberately impractical ceiling for
this RTL, useful for bounding the benefit of direction-prediction accuracy.

## Direct gem5 invocation

```sh
build/RISCV/gem5.opt \
    --outdir=m5out/cmk-default \
    raptor-chip/sim/gsim/raptor_se.py \
    --preset default \
    --benchmark coremark \
    --options "0;0;0x66;10" \
    --cpu o3 \
    --clk-freq 1GHz
```

Useful flags:

* `--config-svh <path>` — point at a custom `rapt_config.svh` (skips `--preset`).
* `--cpu timing|atomic` — in-order timing / functional no-cache baselines for triage.
* `--no-l2` — drop the model L2; L1s connect directly to membus
  (closer to raptor-chip's RTL today, which has no L2).
* `--rtl-execution-resources` — use the configured integer-ALU port count,
  one MULDIV unit, and one load/store request port. This is opt-in because gem5's default FUPool is
  deliberately more provisioned; it isolates execution-resource effects from
  branch-predictor DSE results.
* `--fetch-queue-size N` — override gem5's default 32-uop per-thread fetch
  queue. A small value helps quantify frontend-buffer decoupling separately
  from `fetchWidth`.
* `--max-insts N` — early stop for long workloads.
* `--mem-latency 30ns` — flat backing-memory latency.

## Performance-bug triage workflow

1. Run on `--cpu timing` (in-order, perfect issue) to get an upper bound
   on CPI driven purely by ISA + cache misses.
2. Run on `--cpu o3 --preset default` and diff `stats.txt` for:
   * `system.cpu.commitStats0.committedInsts` and `numCycles` → IPC.
   * `system.cpu.iew.iqFullEvents`, `robFullEvents`,
     `lsq0.{loadQueue,storeQueue}.full` → window pressure.
   * `system.cpu.branchPred.condPredicted` /
     `condIncorrect` → BPU accuracy vs. raptor's BPU.
   * `system.cpu.icache.overall_miss_rate`, `dcache.*` → cache pressure.
3. Compare against the same numbers from
  `make -C sim sim-perf` on the matching `RAPT_CONFIG`. Divergence
   localises uarch perf bugs (e.g. dispatch stall not modelled in gem5,
   or a real RTL bug you can fix in the SV).
4. Sweep `PRESET` to bracket the design — e.g. if `large` doesn't beat
   `default` in gem5 but does in your hopes, you have a bottleneck the
   gem5 model surfaces (LSU, BPU, MSHR count, etc.).

## Limitations / known caveats

* gem5 O3 is **a different uarch** from raptor-chip — same parameter
  *names* don't guarantee same *cycle behaviour*. Use this for trends and
  scaling, not absolute IPC matching.
* RTL IOQ schedules loads, stores and atomics, with conditional out-of-order
  load issue; its capacity is folded into gem5's unified IQ.
  An IOQ-specific stall in raptor will not appear in gem5 stats.
* `RAPT_M_FAST` is parsed as metadata; with `--rtl-execution-resources` it
  sets the MULDIV unit's `IntMult` opLat to 1 (pipelined, matching the RTL).
  Division keeps gem5's unpipelined 20-cycle latency, an approximation of the
  RTL's iterative divider; queue behaviour requires separate calibration.
* RV32 SE is supported by gem5 but is less battle-tested than RV64; if
  you hit a decoder gap, retry with `--rv64` after building the rv64
  ELF (`make -C app coremark ISA64=1`).
