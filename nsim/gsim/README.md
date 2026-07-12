# gem5 SE-mode runner for raptor-chip

A gem5 model of the raptor-chip dual-issue OoO RISC-V core for **design
space exploration** and **performance bug analysis**, parameterised
directly from `raptor-chip/configs/<preset>/rapt_config.svh`.

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
[nsim](../../nsim/) (Verilator with the real RTL) instead.

## Parameter map (raptor → gem5 O3)

| `rapt_config.svh`         | gem5 O3                                          |
| ------------------------- | ------------------------------------------------ |
| `RAPT_L1{I,D}_LINE_LEN`   | `cache_line_size = 4 << LINE_LEN` bytes          |
| `RAPT_L1{I,D}_LEN`        | sets = `1 << LEN`                                |
| `RAPT_L1{I,D}_N_WAYS`     | `Cache.assoc`                                    |
| `RAPT_ROB_SIZE`           | `numROBEntries`                                  |
| `RAPT_PHY_SIZE`           | `numPhysIntRegs`, `numPhysFloatRegs`             |
| `RAPT_RS_SIZE+IOQ_SIZE`   | `IQUnit.numEntries`                              |
| `RAPT_SQ_SIZE`            | `LQEntries`, `SQEntries`                         |
| `RAPT_ISSUE_WIDTH`        | `fetch/decode/rename/dispatch/issue/wb` width    |
| `RAPT_DUAL_COMMIT`        | `commitWidth = 2`                                |
| `RAPT_BTB_SIZE/WAYS`      | `SimpleBTB(numEntries, associativity)`           |
| `RAPT_PHT_SIZE`           | `BiModeBP(globalPredictorSize, choicePredictorSize)` |
| `RAPT_RSB_SIZE`           | `ReturnAddrStack(numEntries)`                    |

Cache line derivation: a `LINE_LEN=2` raptor cache stores 2² 32-bit words
per line = 16 B; `LINE_LEN=1` ⇒ 8 B. This matches the comments in
`configs/large/rapt_config.svh` ("16B line * 256 sets * 2 ways = 8 KiB").

## Prerequisites

```sh
# 1. Build gem5 RISC-V (one time)
cd <gem5-root>
scons build/RISCV/gem5.opt -j$(sysctl -n hw.ncpu)

# 2. Build the raptor-chip bare-metal ELF you want to run
cd <raptor-chip>/app
make coremark                 # rv32 by default
make coremark ISA64=1         # rv64
make embench                  # all of Embench-IoT
```

## Quick start

```sh
cd raptor-chip/nsim/gsim

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

# Branch-predictor study: RTL-size TAGE, equal-budget gshare,
# a practical 8 KiB TAGE-SC point, and a 64 KiB upper bound
make bp-study

# In-order TimingSimpleCPU baseline (pure ISA throughput, no uarch)
make timing BENCH=coremark

# Sweep small/default/large × {timing, o3} for one workload
make sweep BENCH=coremark
```

Each run lands in `raptor-chip/nsim/build/gsim/<bench>-<preset>-<cpu>-rv$XLEN/`
with the following persisted artifacts:

| file           | purpose                                                       |
| -------------- | ------------------------------------------------------------- |
| `stats.txt`    | full gem5 stat dump (raw counters)                            |
| `config.{ini,json}` | full system params for reproducibility                   |
| `run.log`      | tee'd stdout/stderr (gem5 banner + workload output)           |
| `summary.txt`  | human-readable digest: IPC, BP/BTB acc, L1 miss rates, …      |
| `summary.csv`  | one-row machine-readable digest                               |

`make sweep BENCH=<bench>` additionally writes
`raptor-chip/nsim/build/gsim/results/sweep-<bench>-rv$XLEN.csv` aggregating every
preset×CPU combo. To regenerate the summaries from existing `stats.txt`
without re-running gem5: `make summary OUTDIR=<dir>` or
`make aggregate BENCH=<bench>`.

`make bp-study` writes one CSV per selected workload under
`nsim/build/gsim/results/bp-study-<bench>-rv32.csv`; by default this includes
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
    raptor-chip/nsim/gsim/raptor_se.py \
    --preset default \
    --benchmark coremark \
    --options "0;0;0x66;10" \
    --cpu o3 \
    --clk-freq 1GHz
```

Useful flags:

* `--config-svh <path>` — point at a custom `rapt_config.svh` (skips `--preset`).
* `--no-l2` — drop the model L2; L1s connect directly to membus
  (closer to raptor-chip's RTL today, which has no L2).
* `--rtl-execution-resources` — use two integer ALUs, one MULDIV unit, and
  one load/store request port. This is opt-in because gem5's default FUPool is
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
   `make -C nsim sim-perf` on the matching `RAPT_CONFIG`. Divergence
   localises uarch perf bugs (e.g. dispatch stall not modelled in gem5,
   or a real RTL bug you can fix in the SV).
4. Sweep `PRESET` to bracket the design — e.g. if `large` doesn't beat
   `default` in gem5 but does in your hopes, you have a bottleneck the
   gem5 model surfaces (LSU, BPU, MSHR count, etc.).

## Limitations / known caveats

* gem5 O3 is **a different uarch** from raptor-chip — same parameter
  *names* don't guarantee same *cycle behaviour*. Use this for trends and
  scaling, not absolute IPC matching.
* `IOQ` (raptor's in-order load queue) is folded into gem5's unified IQ.
  An IOQ-specific stall in raptor will not appear in gem5 stats.
* `RAPT_M_FAST` (1-cycle MUL) is the gem5 default for `IntMult`; nothing
  to do. If you toggle it off in raptor and want to mirror that, edit
  `IntMultDiv.opLat` in `src/cpu/o3/FuncUnitConfig.py` or expose a CLI
  knob here.
* RV32 SE is supported by gem5 but is less battle-tested than RV64; if
  you hit a decoder gap, retry with `--rv64` after building the rv64
  ELF (`make -C app coremark ISA64=1`).
