# gem5 SE-mode runner for raptor-chip

A gem5 model of the raptor-chip parameterized superscalar OoO RISC-V core for **design space exploration** and **performance bug analysis**, parameterised directly from `raptor-chip/rtl/configs/<preset>/rapt_config.svh`.

## Why SE mode?

`app/Makefile` builds bare-metal newlib ELFs at `app/build/rv$XLEN/<bench>/*.elf` using `riscv$XLEN-unknown-elf-gcc`. These ELFs invoke newlib syscalls (`write`, `_exit`, `sbrk`) which gem5's `RiscvEmuLinux` SE workload services natively (it accepts ELFs tagged `unknown` OS as well as `linux`). No proxy kernel, no HTIF, no Linux — just iterate fast on uarch parameters.

FS mode is **deliberately not modelled** here:

* The `pk` build (`app/build/pk-build-rv$XLEN/payload.elf`) targets `riscv-pk` over HTIF; gem5's `RiscvBoard` is a HiFive-style platform that does not match raptor-chip's CLINT/PLIC + AXI memory map.
* Booting Ubuntu via `riscv-ubuntu-run.py` is reproducible but useless for raptor-chip DSE because none of raptor's RTL knobs map there.

If you need OS-level workloads on raptor-chip, run them on [sim](../) (Verilator with the real RTL) instead.

## Parameter map (raptor → gem5 O3)

| `rapt_config.svh`         | gem5 O3                                          |
| ------------------------- | ------------------------------------------------ |
| `RAPT_L1I_LINE_LEN` | I-side line bytes = `4 << LINE_LEN` |
| `RAPT_L1D_LINE_LEN` | D-side line bytes = `(XLEN / 8) << LINE_LEN` |
| `RAPT_L1{I,D}_LEN`        | sets = `1 << LEN`                                |
| `RAPT_L1{I,D}_N_WAYS`     | `Cache.assoc`                                    |
| `RAPT_L1D_MSHRS`          | L1D `Cache.mshrs` (`max(1, RAPT_L1D_MSHRS)`); L1I stays 1 (blocking) |
| `RAPT_L2_EN`, `RAPT_L2_*` | Enables shared L2 sized from `L2_LEN`/`L2_LINE_LEN`/`L2_N_WAYS` (MSHRs: 3 RV32 / 5 RV64) |
| `RAPT_ROB_SIZE`           | `numROBEntries`                                  |
| `RAPT_PHY_SIZE`           | `numPhysIntRegs`; FP model uses `max(PHY_SIZE, 64)` |
| `RAPT_RS_SIZE+IOQ_SIZE`   | Unified `IQUnit.numEntries` (or split `ALQ+BRQ`/`MDQ`/`IOQ`/`FPQ` with `--rtl-split-iq`) |
| `RAPT_SQ_SIZE`            | `LQEntries`, `SQEntries`                         |
| `RAPT_DECODE_WIDTH`       | `fetchWidth`, `decodeWidth`                      |
| `RAPT_RENAME_WIDTH`       | `renameWidth`                                    |
| `RAPT_DISPATCH_WIDTH`     | `dispatchWidth`; also approximates global `issueWidth`/`wbWidth` |
| `RAPT_COMMIT_WIDTH`       | `commitWidth`                                    |
| `RAPT_RIQ_SIZE`           | `fetchQueueSize` (fetch→rename decoupling queue; gem5 has no IIQ analogue) |
| `RAPT_BPU_DIRP_*`         | selects the gem5 conditional predictor by default: TAGE→`tage`, GSHARE→`gshare`, BIMODAL→`local`, STATIC→`local` (approximation) |
| `RAPT_TAGE_BIM_BITS`, `RAPT_TAGE_INDEX_BITS` | TAGE `logTagTableSizes = [bim, idx, idx, idx]` (default preset: 10/10; `middle`: 8/7) |
| `RAPT_INTEGER_ISSUE_PORTS`| `IntALU.count` with `--rtl-execution-resources`  |
| `RAPT_M_FAST`             | `IntMult` 2-cycle pipelined (`opLat=2`) with `--rtl-execution-resources` |
| `RAPT_INTEGER_SYSTEM_PORT`| Validated against the RTL port count; physical index has no gem5 O3 analogue |
| `RAPT_V_EXTENSION`, `RAPT_VLEN` | `RiscvISA(enable_rvv=..., vlen=...)` (default VLEN = 128) |
| `RAPT_BTB_SIZE/WAYS`      | `SimpleBTB(numEntries, associativity)`           |
| `RAPT_PHT_SIZE`           | `LocalBP`/`GshareBP`/`BiModeBP` table size       |
| `RAPT_RSB_SIZE`           | `ReturnAddrStack(numEntries)`                    |

L1I stores 32-bit instruction words; L1D stores XLEN-bit data words. Current
presets derive both from `RAPT_CACHE_LINE_BYTES`, preserving byte capacities
across RV32/RV64. Default lines are 64 B with 16 KiB L1I and L1D (64 sets,
four-way); `large` has 32 KiB L1I (one-way) and 8 KiB L1D (two-way).
`small` uses 512 B/256 B and `middle` 1 KiB/256 B on 16 B lines.

The model uses the larger derived line size as gem5's global line size for
historical unequal-line presets. L1I defaults to one MSHR (blocking refill) and
L1D defaults to `max(1, RAPT_L1D_MSHRS)` (four on `default`/`large`, one on
`small`/`middle`). Explicit `--mshrs=N` overrides both caches; `L1I.mshr_size`
and `L1D.mshr_size` override each independently. `RAPT_L1I_REFILL_WORDS`
(32 B sectors) has no cache-level analogue here: gem5 refills full lines.
Presets that define `RAPT_L2_EN` (`default-l2` 512 KiB 8-way, `large` 128 KiB
1-way) automatically instantiate the shared L2 unless `--no-l2` is passed.

The gem5 FP register count is a modeling choice. RTL uses ROB-backed FP
renaming and speculative results plus a committed 32 × 64-bit FPR bank; it
does not allocate FP destinations from gem5's free-list-style physical file.
RV64 DSE results from before the XLEN-aware cache fix used half the configured
L1D capacity and require new runs for comparison with current RTL.

Current presets declare ordered-stage widths directly. The bridge accepts
`RAPT_ISSUE_WIDTH` and `RAPT_DUAL_*` only for historical presets. Raptor's
heterogeneous execution domains have no single global issue-width boundary;
`--rtl-execution-resources` models `RAPT_INTEGER_ISSUE_PORTS` ALUs, one 2-cycle
pipelined MUL + unpipelined DIV, one FPU pipe (3-cycle Add/Cmp/Cvt, 8-cycle
FMUL/FMA), and one LSU port, and `--rtl-split-iq` partitions gem5's issue queue
into domain-specific `IQUnit`s (`ALQ+BRQ`, `MDQ`, `IOQ`, `FPQ`).

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
make coremark-build           # rv32 by default
make coremark-build ISA64=1    # rv64
make embench-build            # all of Embench-IoT
```

## Configuration precedence

The default Makefile run derives widths, capacities and execution-resource counts from the selected preset without a JSON overlay. The conditional branch predictor follows the preset's `RAPT_BPU_DIRP_*` define (default preset: RTL-flavoured TAGE). `RTL_EXEC=1` (default) matches the RTL execution resources: `RAPT_INTEGER_ISSUE_PORTS` integer ALUs, one MULDIV (`RAPT_M_FAST` timing), one load/store request port. Set `RTL_EXEC=0` to use gem5's broader default FUPool; select `BP=local` explicitly for a bimodal experiment. Use `JSON_CONFIG=dse-config.json` explicitly for the provided TAGE study configuration; its cache, width and window settings override the preset. `SET` overrides are applied after JSON. Output names retain the preset and append the JSON basename, so the same overlay on different presets stays separate. Use an explicit `OUTDIR` for JSON files with identical basenames or for repeated experiments whose evidence must be retained.

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

Each run lands in `raptor-chip/sim/build/gsim/<bench>-<preset>[.<json>]-rv$XLEN[.cpu=<cpu>][.<set>]/` (the default `o3` CPU suffix is omitted) with the following persisted artifacts:

| file           | purpose                                                       |
| -------------- | ------------------------------------------------------------- |
| `stats.txt`    | full gem5 stat dump (raw counters)                            |
| `config.{ini,json}` | full system params for reproducibility                   |
| `run.log`      | tee'd stdout/stderr (gem5 banner + workload output)           |
| `summary.txt`  | human-readable digest: IPC, BP/BTB acc, L1 miss rates, …      |
| `summary.csv`  | one-row machine-readable digest                               |

`make sweep BENCH=<bench>` additionally writes `raptor-chip/sim/build/gsim/results/sweep-<bench>-rv$XLEN.csv` aggregating every preset×CPU combo. To regenerate the summaries from existing `stats.txt` without re-running gem5: `make summary OUTDIR=<dir>` or `make aggregate BENCH=<bench>`.

`make bp-study` writes one CSV per selected workload under `sim/build/gsim/results/bp-study-<bench>-rv32.csv`; by default this includes CoreMark and the SE-compatible MicroBench port. `rtl-tage` is the current Raptor-equivalent direction predictor: a 256-entry bimodal base and three 128-entry tagged tables. `same-budget-gshare` uses the same normalized direction-predictor budget, separating algorithm benefit from capacity. `practical-tage-sc` uses gem5's fixed 8 KiB TAGE-SC-L implementation; the fixed 64 KiB `upper-tage-sc` model is a deliberately impractical ceiling for this RTL, useful for bounding the benefit of direction-prediction accuracy.

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
* `--no-l2` / `--with-l2` — override the preset's `RAPT_L2_EN` setting (`default-l2` and `large` enable L2 automatically; other presets connect L1s directly to membus).
* `--rtl-execution-resources` — use the configured integer-ALU port count, one MULDIV unit (2-cycle pipelined MUL when `RAPT_M_FAST=1`), one FPU pipe, and one load/store request port. The Make wrapper enables it with `RTL_EXEC=1` by default; direct script use is opt-in. Set `RTL_EXEC=0` to compare against gem5's broader FUPool.
* `--rtl-split-iq` (Make: `SPLIT_IQ=1`) — partition gem5's issue queue into domain-specific `IQUnit`s mirroring `rapt_backend.sv` (`ALQ+BRQ`, `MDQ`, `IOQ`, `FPQ`).
* `--fetch-queue-size N` — override gem5's per-thread fetch queue depth (defaults to `RAPT_RIQ_SIZE`). A small value helps quantify frontend-buffer decoupling separately from `fetchWidth`.
* `--max-insts N` — early stop for long workloads.
* `--mem-latency 30ns` — flat backing-memory latency.

## Performance-bug triage workflow

1. Run on `--cpu timing` (in-order, perfect issue) as an in-order comparison point for ISA and memory effects, not a rigorous CPI bound.
2. Run on `--cpu o3 --preset default` and diff `stats.txt` for:
   * `system.cpu.commitStats0.numInsts` and `numCycles` → IPC.
   * `system.cpu.iew.iqFullEvents`, `system.cpu.rename.ROBFullEvents`,
     `system.cpu.iew.lsqFullEvents` → window pressure.
   * `system.cpu.branchPred.condPredicted` /
     `condIncorrect` → BPU accuracy vs. raptor's BPU.
   * `system.cpu.icache.demandMisses::total`, `dcache.*` → cache pressure.
3. Compare against the same numbers from `make coremark-rv32` on the matching `RAPT_CONFIG`. Use divergence to select hypotheses for RTL traces; differences can also come from the model approximations above and do not by themselves establish an RTL defect.
4. Sweep `PRESET` to bracket the design — e.g. if `large` doesn't beat `default` in gem5 but does in your hopes, you have a bottleneck the gem5 model surfaces (LSU, BPU, MSHR count, etc.).

## Limitations / known caveats

* gem5 O3 is **a different uarch** from raptor-chip — same parameter *names* don't guarantee same *cycle behaviour*. Use this for trends and scaling, not absolute IPC matching.
* RTL IOQ schedules loads, stores and atomics, with conditional out-of-order load issue; by default its capacity is folded into gem5's unified IQ (use `--rtl-split-iq` / `SPLIT_IQ=1` to separate `ALQ+BRQ`, `MDQ`, `IOQ`, and `FPQ`).
* With `--rtl-execution-resources`, `RAPT_M_FAST=1` sets `IntMult` `opLat=2` (pipelined, matching `rapt_ieu_mul.sv`). Division keeps gem5's unpipelined 20-cycle latency, an approximation of the RTL's iterative divider; queue behaviour requires separate calibration.
* RV32 SE is supported by gem5 but is less battle-tested than RV64; if you hit a decoder gap, retry with `--rv64` after building the rv64 ELF (`make -C app coremark-build ISA64=1`).
* `Makefile` and `grid_search.py` automatically prefer `gem5.fast` over `gem5.opt` when built (`scons build/RISCV/gem5.fast -j$(nproc)`), which typically accelerates DSE sweeps by ~1.5–2×.

## SPEC CPU 2017 / CPU 2026 & Full-Suite Evaluation

Cross-compilation configs for static RV64GC Linux binaries (C, C++, and Fortran)
live in `sim/gsim/spec_configs/`:

* `sim/gsim/spec_configs/raptor-cpu2017-rv64.cfg`
* `sim/gsim/spec_configs/raptor-cpu2026-rv64.cfg`

Copy the config into `<spec-root>/config/` before invoking `runcpu` so SPEC's
`__HASH__` updates do not dirty the repository tree:

```sh
cp sim/gsim/spec_configs/raptor-cpu2017-rv64.cfg <spec-root>/config/
cd <spec-root> && source shrc
runcpu --config=raptor-cpu2017-rv64.cfg --action=setup --size=test \
    --tune=base intrate fprate
```

Integrated Make targets and scripts in `sim/gsim/`:

```sh
# 1. CoreMark + all 19 Embench-IoT across 5 presets
make -C sim/gsim embench-sweep EVAL_OUTDIR=<eval-out>/presets-embench-rv64

# 2. Parallel gem5 SE evaluation of SPEC CPU 2017 / 2026 (@ 50M insts)
make -C sim/gsim spec-eval SPEC_ROOT=<spec-root> \
    EVAL_OUTDIR=<eval-out>/gem5-2017-50m-default PRESET=default

# 3. High-precision 50M-ROI kmax=6 NEMU SimPoint + RTL Verilator replay
make -C sim XLEN=64 RAPT_CONFIG=default SIM_MEM_PROFILE=large -j16
make -C sim/gsim spec-simpoint SPEC_ROOT=<spec-root> \
    EVAL_OUTDIR=<eval-out>/simpoint50m-2017-rv64 \
    NEMU_BIN=<sampling-nemu>/build/riscv64-nemu-interpreter \
    FW_PAYLOAD=<linux-bundle>/fw_payload.bin \
    INITRAMFS=<linux-bundle>/initramfs.cpio.gz \
    RTL_MODEL=sim/build/default-pmem2g/riscv64-npc-sim \
    SIMPOINT_ARGS="--benches 519.lbm_r,557.xz_r --length 50000000 --interval 500000 --warmup 500000 --kmax 6"

# 4. Aggregate multi-preset gem5 TMA, estimated SPECrate2017_int/GHz, and RTL PMU TMA
make -C sim/gsim perf-report EVAL_ROOT=<eval-out>
```

The resulting SimPoint checkpoints can also be replayed on an FPGA target with
`verification/performance/fpga_replay.py`.
