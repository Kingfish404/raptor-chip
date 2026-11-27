---
title: Performance Evaluation
permalink: /performance.html
---

# Current Performance Evaluation

This living document records performance evaluation results for the **current
Raptor RTL (`b2caaa2ad`: direct prefix dispatch, 32-entry ITT + loop predictor,
8-MSHR L1D, dual-AGU, L1I FDIP, 3-ALU on `default-w4`, 75 MHz KU5P timing cuts)
and aligned gem5 O3 performance model (`046c95621` 6-preset sweep)**.
Historical commit-by-commit logs live in
[Performance Iterations](./perf-iterations.md); this page is updated in place
as the microarchitecture evolves.

## Target Presets & Evaluation Setup

All `default*` presets target RV64GC(V) with a 16-entry SQ, 2-cycle pipelined
MUL, 1 FPU pipe, decoupled Load/Store AGU, 16-entry RAS, 32-entry ITT, 32-entry
loop predictor, L1I hit-under-prefetch + 8-entry FDIP, and degree-2 16-entry
L1D IP-stride prefetcher (`rapt_l1d_stride_pf`):

| Preset | Width (F/D/R/C) | ALU Ports | ROB / PRF | ALQ / BRQ / IOQ | BTB | L2 TLB | L1I | L1D (MSHRs) | L2 |
|---|---|---:|---|---|---:|---:|---|---|---|
| `default` | 2 / 2 / 2 / 2 | 2 | 32 / 64 | 8 / 8 / 8 | 512 (4w) | 512 (4w) | 16 KiB, 4w | 16 KiB, 4w (8) | None |
| `default-w3` | 3 / 3 / 3 / 3 | 2 | 64 / 96 | 12 / 12 / 16 | 512 (4w) | 1024 (4w) | 16 KiB, 4w | 16 KiB, 4w (8) | None |
| `default-w4` | 4 / 4 / 4 / 4 | 3 | 64 / 96 | 16 / 12 / 16 | 512 (4w) | 1024 (4w) | 16 KiB, 4w | 16 KiB, 4w (8) | None |
| `default-cache` | 2 / 2 / 2 / 2 | 2 | 32 / 64 | 8 / 8 / 8 | 128 (2w) | 256 (1w) | 128 KiB, 2w | 128 KiB, 32w (4) | None |
| `default-w4-cache` | 4 / 4 / 4 / 4 | 2 | 32 / 64 | 12 / 12 / 16 | 512 (4w) | 1024 (4w) | 128 KiB, 2w | 128 KiB, 32w (4) | None |
| `default-l2` | 2 / 2 / 2 / 2 | 2 | 32 / 64 | 8 / 8 / 8 | 128 (2w) | 256 (1w) | 16 KiB, 4w | 16 KiB, 4w (4) | 512 KiB, 8w |

- **Evaluation engines**:
  1. **gem5 25.1 O3 SE** (`sim/gsim/raptor_se.py --rtl-execution-resources`,
     `1 GHz`, flat `30 ns` backing memory, aligned L1I `TaggedPrefetcher` +
     L1D `StridePrefetcher`; `50M` instructions/benchmark on SPEC).
  2. **NEMU functional sampling** (`riscv64_sampling_defconfig`, Linux 6.18.51,
     BBV profiling + SimPoint clustering + 2 GiB architectural checkpoints).
  3. **RTL Verilator** (`SIM_MEM_PROFILE=large`, zero extra AXI wait cycles,
     replaying NEMU Linux SimPoint checkpoints across `default`, `default-w4`,
     and `default-cache` on `ccc3fb3cf`).
  4. **FPGA replay / Ubuntu NFS netboot** (`fpga/mlk-cu08-ku15p/`,
     `verification/performance/fpga_replay.py`).
- **Workload coverage**: **90 benchmarks** across 4 suites -- CoreMark (1/1),
  Embench-IoT (17/19 ok in RV64 SE), **SPEC CPU 2017 full rate (23/23: 10/10
  INT + 13/13 FP)**, and **SPEC CPU 2026 (49/52: 25/26 Rate + 24/26 Speed)**;
  compiled with GCC/G++/GFortran 13.3 (`-O2 -march=rv64gc -mabi=lp64d -static`).

---

## 1. Top-Down Microarchitecture Analysis (TMA) Model

Both `sim/gsim/summarize_stats.py` (gem5) and `sim/gsim/perf_report.py` (RTL
PMU `dispatch_*` hardware counters) decompose total pipeline allocation slots
($S = W \times \text{cycles}$, where $W$ is preset rename/dispatch width) into
four Level-1 categories:

| TMA Category | gem5 O3 Formula | RTL PMU Formula | Physical Meaning |
|---|---|---|---|
| **Retiring** | $\text{commitInsts} / S$ | $\text{instr\_cnt} / S$ | Useful architectural work retired |
| **Bad Speculation** | $(\text{renamedInsts} - \text{commitInsts} + W \cdot \text{renSquash}) / S$ | $(\text{disp\_acc} - \text{instr\_cnt} + \text{unfilled\_flush} + \text{unfilled\_recov}) / S$ | Branch mispredicts & flushes |
| **Frontend Bound** | $(W \cdot \text{renIdle}) / S$ | $\text{unfilled\_empty} / S$ | I-cache/ITLB misses, fetch bubbles |
| **Backend Bound** | $1 - \text{Retiring} - \text{BadSpec} - \text{Frontend}$ | $1 - \text{Retiring} - \text{BadSpec} - \text{Frontend}$ | ROB/IQ/SQ stalls, L1D/L2/DRAM wait |

---

## 2. Executive Summary (6 Presets, Commit `046c95621`)

| Benchmark Suite | `default` | `default-w3` | `default-w4` | `default-cache` | `default-w4-cache` | `default-l2` |
|---|---:|---:|---:|---:|---:|---:|
| **CoreMark/MHz** (gem5, ROI) | **5.361** | **6.162** | **6.323** | **5.393** | **6.146** | **5.194** |
| **Embench-IoT (17)** Geomean IPC | **1.480** | **1.759** | **1.848** | **1.477** | **1.829** | **1.434** |
| **SPEC CPU 2017 (23/23 @ 50M)** Geomean IPC | **0.840** | **0.928** | **0.949** | **0.945** | **1.204** | **0.834** |
| - SPEC 2017 INT (10/10) Geomean IPC | 0.983 | 1.103 | 1.131 | 1.011 | **1.297** | 0.919 |
| - SPEC 2017 FP (13/13) Geomean IPC | 0.744 | 0.812 | 0.829 | 0.897 | **1.137** | 0.774 |
| **SPEC CPU 2026 (49/52 @ 50M)** Geomean IPC | **0.931** | **1.027** | **1.052** | **1.015** | **1.263** | **0.928** |
| - SPEC 2026 Rate (25/26) Geomean IPC | 0.923 | 1.021 | 1.045 | 1.042 | **1.307** | 0.953 |
| - SPEC 2026 Speed (24/26) Geomean IPC | 0.940 | 1.033 | 1.059 | 0.988 | **1.219** | 0.902 |
| **Est. SPECrate2017_int / GHz** (10/10) | **~0.765** | **~0.858** | **~0.880** | **~0.787** | **~1.009** | **~0.715** |
| **Est. SPECrate2017_fp / GHz** (13/13) | **~0.476** | **~0.520** | **~0.530** | **~0.574** | **~0.727** | **~0.495** |

### Width-Normalized Mean TMA Across Presets (gem5 @ 50M)

| Suite | Preset | Width | Retiring | Bad Spec | Frontend | Backend |
|---|---|---:|---:|---:|---:|---:|
| SPEC CPU 2017 (23) | `default` | 2 | 47.1% | 5.8% | 14.3% | 32.8% |
| SPEC CPU 2017 (23) | `default-w3` | 3 | 35.5% | 6.3% | 16.8% | 41.4% |
| SPEC CPU 2017 (23) | `default-w4` | 4 | 27.3% | 6.1% | 19.5% | 47.1% |
| SPEC CPU 2017 (23) | `default-cache` | 2 | **50.7%** | 10.5% | **12.7%** | **26.1%** |
| SPEC CPU 2017 (23) | `default-w4-cache` | 4 | 33.2% | 6.4% | 16.6% | 43.7% |
| SPEC CPU 2017 (23) | `default-l2` | 2 | 45.6% | 10.1% | 15.6% | 28.7% |
| SPEC CPU 2026 (49) | `default` | 2 | 51.9% | 5.9% | 13.2% | 29.1% |
| SPEC CPU 2026 (49) | `default-w3` | 3 | 38.9% | 6.9% | 16.5% | 37.7% |
| SPEC CPU 2026 (49) | `default-w4` | 4 | 30.0% | 6.8% | 19.5% | 43.8% |
| SPEC CPU 2026 (49) | `default-cache` | 2 | **55.4%** | 9.5% | **11.2%** | **23.9%** |
| SPEC CPU 2026 (49) | `default-w4-cache` | 4 | 35.1% | 6.5% | 17.3% | 41.2% |
| SPEC CPU 2026 (49) | `default-l2` | 2 | 51.3% | 9.4% | 13.8% | 25.4% |

**Key Top-Down Findings**:
1. **64-entry ROB / 96 PRF / 12-16 RS + L1 prefetchers + 512-entry 4-way BTB +
   FE/BE/LSU tuning** raised `default` Retiring on SPEC 2017 from
   `37.7% -> 47.1%` (+9.4 pp), boosting SPEC 2017 Geomean IPC by **+24.6%**
   (`0.674 -> 0.840`) and SPEC 2026 by **+20.8%** (`0.771 -> 0.931`).
2. **4-wide scaling on `default-w4`**: Even with 16 KiB L1I/L1D and no L2,
   `default-w4` now hits **`6.323` CM/MHz**, **`1.848` Embench GM** (beating
   32-ROB `default-w4-cache`), **`0.949` SPEC 2017** (`~0.880` INT/GHz), and
   **`1.052` SPEC 2026**.
3. **Next headroom**: Combining the 64-ROB / 96-PRF / 16-RS backend with a
   larger cache hierarchy (`L1 32-64 KiB + L2 512 KiB`) is expected to push
   `SPECrate2017_int / GHz` well past **`1.10+`**.

---

## 3. SPEC CPU 2017 -- Full 23/23 Rate Suite (@ 50M Instructions)

| Benchmark | Class | `default` | `default-w3` | `default-w4` | `default-cache` | `default-w4-cache` | `default-l2` | `default` TMA (Ret / BS / FE / BE %) |
|---|---|---:|---:|---:|---:|---:|---:|---|
| `500.perlbench_r` | INT | 0.900 | 0.982 | 1.036 | 1.018 | **1.335** | 0.951 | 45.0 / 12.4 / 19.7 / 22.9 |
| `502.gcc_r` | INT | 1.069 | 1.186 | 1.217 | 1.104 | **1.509** | 1.014 | 53.4 / 7.1 / 15.0 / 24.5 |
| `503.bwaves_r` | FP | 0.566 | 0.588 | 0.592 | 0.615 | **0.638** | 0.491 | 28.3 / 0.8 / 5.6 / 65.3 |
| `505.mcf_r` | INT | 1.644 | 2.042 | **2.141** | 1.204 | 2.009 | 1.195 | 82.2 / 2.1 / 5.6 / 10.0 |
| `507.cactuBSSN_r` | FP | 1.129 | 1.278 | 1.307 | 1.193 | **1.739** | 1.047 | 56.4 / 7.5 / 14.5 / 21.6 |
| `508.namd_r` | FP | 1.575 | 1.924 | **1.957** | 0.986 | 1.888 | 0.958 | 78.7 / 3.5 / 6.7 / 11.1 |
| `510.parest_r` | FP | 1.167 | 1.328 | 1.371 | 1.266 | **1.555** | 1.214 | 58.3 / 6.3 / 14.2 / 21.2 |
| `511.povray_r` | FP | 0.892 | 0.991 | 1.015 | 1.105 | **1.611** | 0.986 | 44.6 / 3.9 / 24.1 / 27.5 |
| `519.lbm_r` | FP | 0.190 | 0.190 | **0.190** | 0.190 | 0.190 | 0.141 | 9.5 / 0.3 / 4.4 / 85.8 |
| `520.omnetpp_r` | INT | 0.843 | 0.923 | 0.944 | 1.086 | **1.499** | 0.919 | 42.1 / 7.7 / 22.5 / 27.6 |
| `521.wrf_r` | FP | 0.348 | 0.356 | 0.358 | 1.092 | **1.248** | 0.705 | 17.4 / 2.2 / 7.7 / 72.8 |
| `523.xalancbmk_r` | INT | 0.645 | 0.696 | 0.713 | 1.039 | **1.426** | 0.875 | 32.3 / 5.0 / 27.5 / 35.3 |
| `525.x264_r` | INT | 1.385 | 1.615 | **1.648** | 1.041 | 1.147 | 1.025 | 69.3 / 0.2 / 7.5 / 23.0 |
| `526.blender_r` | FP | 1.116 | 1.278 | 1.308 | 1.350 | **1.654** | 1.186 | 55.8 / 4.4 / 5.9 / 33.9 |
| `527.cam4_r` | FP | 0.806 | 0.839 | 0.869 | 1.032 | **1.276** | 0.871 | 40.3 / 6.8 / 26.1 / 26.7 |
| `531.deepsjeng_r` | INT | 0.430 | 0.431 | **0.432** | 0.430 | 0.432 | 0.325 | 21.5 / 0.7 / 8.5 / 69.3 |
| `538.imagick_r` | FP | 1.365 | 1.509 | 1.536 | 1.437 | **1.588** | 1.343 | 68.3 / 3.8 / 8.9 / 19.0 |
| `541.leela_r` | INT | 1.425 | 1.678 | 1.723 | 1.521 | **1.807** | 1.426 | 71.2 / 7.9 / 4.7 / 16.2 |
| `544.nab_r` | FP | 0.894 | 0.964 | **0.982** | 0.808 | 0.875 | 0.801 | 44.7 / 2.5 / 10.1 / 42.7 |
| `548.exchange2_r` | INT | 1.307 | 1.542 | 1.533 | 1.240 | **1.618** | 1.188 | 65.4 / 12.4 / 10.4 / 11.8 |
| `549.fotonik3d_r` | FP | 0.436 | 0.470 | 0.483 | 0.798 | **1.085** | 0.685 | 21.8 / 5.7 / 38.1 / 34.4 |
| `554.roms_r` | FP | 0.644 | 0.709 | 0.735 | 0.899 | **1.335** | 0.802 | 32.2 / 8.7 / 30.9 / 28.2 |
| `557.xz_r` | INT | 0.887 | 0.967 | 1.005 | 0.869 | **1.075** | 0.826 | 44.3 / 21.7 / 11.1 / 22.8 |
| **Geomean ALL (23)** | | **0.840** | **0.928** | **0.949** | **0.945** | **1.204** | **0.834** | |
| **Geomean INT (10)** | | **0.983** | **1.103** | **1.131** | **1.011** | **1.297** | **0.919** | |
| **Geomean FP (13)** | | **0.744** | **0.812** | **0.829** | **0.897** | **1.137** | **0.774** | |

---

## 4. RTL Verilator Evaluation (Commit `046c95621`)

### 4.0 Bare-Metal RTL CoreMark & Dhrystone (Measured ROI Cycles)

| Preset / XLEN | DMIPS / MHz | CoreMark / MHz | CoreMark IPC | CoreMark ROI Cycles (2 iter) | Gain vs Prior Baseline |
|---|---:|---:|---:|---:|---:|
| `default` / RV32 | **1.96-2.42** | **5.9034** | 1.4661 | 338,789 | +13.1% (`5.2173`) |
| `default` / RV64 | **2.11-2.68** | **5.6709** | 1.4876 | 352,675 | +18.8% (`4.7743`) |
| `default-w4` / RV64 | **2.47-3.56** | **7.0576** | 1.8514 | 283,383 | +26.5% (`5.5781`) |

### 4.1 Three-Preset RTL SPEC SimPoint (5M-ROI, `kmax=2`, 100% Weight Coverage)

| Benchmark | RTL `default` | RTL `default-w4` | RTL `default-cache` |
|---|---:|---:|---:|
| `519.lbm_r` | 0.3537 | **0.3618** | 0.3467 |
| `531.deepsjeng_r` | 0.4213 | **0.4360** | 0.4064 |
| `557.xz_r` | 0.4098 | **0.4243** | 0.3916 |
| `706.stockfish_r` | 1.7248 | **2.1233** | 1.4991 |
| `707.ntest_r` | 0.7887 | **0.8231** | 0.7661 |
| `708.sqlite_r` | 0.6182 | **0.6845** | 0.6573 |
| `777.zstd_r` | 1.1888 | **1.3590** | 1.0799 |
| **Geomean (7)** | **0.6707** | **0.7284** | **0.6421** |

### 4.2 High-Precision SimPoint (50M-ROI, `kmax=6`, 500K Interval + 500K Warmup) & Real RTL PMU TMA

| Benchmark | Clusters Passed | Weight Cov. | RTL `default` IPC | RTL `default-w4` IPC | `default` RTL PMU TMA (Ret / BS / FE / BE %) |
|---|---|---:|---:|---:|---|
| `519.lbm_r` | 4 / 5 | 96.9% | **0.3606** | **0.3703** | 18.1 / 1.9 / 13.9 / 66.1 |
| `557.xz_r` | 3 / 6 | 94.9% | **0.4090** | **0.4236** | 20.5 / 2.6 / 19.2 / 57.7 |
| `706.stockfish_r` | 5 / 6 | 98.0% | **0.9617** | **0.9945** | 50.5 / 1.5 / 3.4 / 44.6 |
| `708.sqlite_r` | 6 / 6 | 100.0% | **0.6489** | **0.7281** | 32.5 / 6.4 / 49.8 / 11.3 |
| `777.zstd_r` | 4 / 4 | 100.0% | **1.1797** | **1.3477** | 59.0 / 19.8 / 17.2 / 4.0 |

### 4.3 Geekbench 5.4.1 Preview Linux SimPoint (AES-XTS Marker Window, 3 RTL Presets)

Because `geekbench_riscv64` is a dynamically linked glibc binary, it runs under
Linux SimPoint (`k=4`, 5M-instruction `geekbench-aes-marker-window`, 92.0%
weight coverage across 3/4 passing clusters):

| Preset | Weight Cov. | RTL IPC | RTL PMU TMA (Ret / BS / FE / BE %) |
|---|---:|---:|---|
| `default` | 92.0% | **0.6950** | 34.8 / 0.5 / 2.8 / 62.0 |
| `default-w4` | 92.0% | **0.6994** | 17.5 / 0.2 / 2.9 / 79.5 |
| `default-cache` | 92.0% | **0.6905** | 34.5 / 1.1 / 3.2 / 61.2 |

### 4.4 Real RTL Simulation (`b2caaa2ad`: Bare-metal, Linux Sim, and SPEC SimPoint)

Measured directly on Verilator RTL (`b2caaa2ad`: direct dispatch, loop predictor,
8-MSHR L1D, dual-AGU, L1I FDIP, and backend/memory timing cuts closing 75 MHz on
KU5P) for bare-metal (`abstract-machine` / `embench-baremetal`) and NEMU Linux
6.18.51 checkpoints (`sim/gsim/linux_sim_bench.py`, `sim/gsim/spec_simpoint.py`):

| Environment | Preset / XLEN | DMIPS/MHz | CM/MHz | Embench-IoT (vs KU5P) | RTL SPECrate2017 (INT/FP / GHz) | RTL SPECrate2026 (INT/FP / GHz) |
|---|---|---:|---:|---:|---:|---:|
| Bare-metal sim | `default` / RV32 | **1.82-2.29** | **5.8889** | **2.0069x** *(19/19)* | - | - |
| Bare-metal sim | `default` / RV64 | **1.99-2.55** | **5.6685** | **2.0362x** *(19/19)* | - | - |
| Bare-metal sim | `default-w4` / RV64 | **2.46-3.31** | **7.1016** | **2.6969x** *(19/19)* | - | - |
| Linux sim | `default` / RV32 | **1.29-1.62** | **4.3148** | **1.4714x** *(19/19)* | - | - |
| Linux sim | `default` / RV64 | **1.52-2.15** | **3.3654** | **1.6573x** *(19/19)* | **0.54 / 0.44** *(9/10, 13/13)* | **0.24 / 0.23** *(13/14, 8/12; 25/26 IPC 0.844)* |
| Linux sim | `default-w4` / RV64 | **1.66-2.43** | **3.8553** | **1.9116x** *(19/19)* | **0.58 / 0.46** *(9/10, 13/13)* | **0.29 / 0.24** *(13/14, 8/12; 25/26 IPC 0.956)* |

Compared to `046c95621`, `default-w4` improves across bare-metal CoreMark (`7.0576 -> 7.1016`),
bare-metal Embench-IoT (`2.6607x -> 2.6969x`, +1.4%), Linux-sim Dhrystone (`1.64-2.41 -> 1.66-2.43`),
Linux-sim CoreMark (`3.7935 -> 3.8553`, +1.6%), and Linux-sim Embench-IoT (`1.8387x -> 1.9116x`,
+4.0%), while `default` preserves `0.54 / 0.44` SPECrate2017 alongside 75 MHz KU5P timing closure.

### 4.5 Live FPGA Hardware Linux (50 MHz Core, 333 MHz DDR4 UI)

Measured directly on KU5P and KU15P boards running Linux over NFS (binaries staged in RAM `/tmp`,
200k-iteration Dhrystone strict/standard, 2000-iteration official CoreMark, 19/19 Embench-IoT):

| Board | Preset / XLEN | DMIPS/MHz | CoreMark/MHz | Embench-IoT (vs KU5P) | SPECrate2017 (INT/FP / GHz) | SPECrate2026 (INT/FP / GHz) |
|---|---|---:|---:|---:|---:|---:|
| KU5P | `default` / RV64 | **1.34-1.93** | **3.3514** | **1.0477x** *(19/19)* | **0.21 / 0.16** *(23/23 `test` IPC)* | - |
| KU15P | `default-w4` / RV64 | **1.46-2.16** | **3.9803** | **1.2319x** *(19/19)* | **0.23 / 0.17** *(23/23 `test` IPC)* | **0.06 / 0.10** *(25/26 `test` IPC)* |

Live Ubuntu 26.10 (RVA23) full-workload SPEC CPU 2017 `test` hardware runs on real DDR4 (no L2
cache) completed **23/23** workloads (`rc=0`) on both boards:
- **KU5P (`default / RV64`)**: **1.40T instructions** / 4.87T cycles over 27.0h, geomean IPC
  `0.2533` (INT `0.2644` / FP `0.2451`, aggregate IPC `0.2874`), e.g., `525.x264_r` `0.6286`,
  `548.exchange2_r` `0.6304`, `541.leela_r` `0.6112`, `557.xz_r` `0.3778`.
- **KU15P (`default-w4 / RV64`)**: **1.38T instructions** / 4.45T cycles, geomean IPC
  `0.2761` (INT `0.2938` / FP `0.2633`, aggregate IPC `0.3105`, +9.0% over `default`), e.g.,
  `525.x264_r` `0.7061`, `548.exchange2_r` `0.6625`, `541.leela_r` `0.6433`, `557.xz_r` `0.4248`.
- **KU15P SPEC CPU 2026 `test` (`default-w4 / RV64`)**: **25/26** workloads (`rc=0`, **2.74T
  instructions** / 5.61T cycles over 31.2h, geomean IPC `0.2749`, INT `0.2518` / FP `0.3023`,
  aggregate IPC `0.4875`), e.g., `772.marian_r` `0.9756` (1.76T insts), `750.sealcrypto_r`
  `0.9132`, `706.stockfish_r` `0.7277`, `777.zstd_r` `0.5928`, `731.astcenc_r` `0.4911`.
All runs demonstrate full real-hardware Linux + glibc + DDR4 stability while highlighting
DRAM-bound sensitivity (e.g., `507.cactuBSSN_r` IPC `~0.065`, `709.cactus_r` IPC `0.0609`)
without an L2 cache.

---

## 5. `riscv100.top` Leaderboard Scorecard & Commercial Positioning

The table below compares Raptor (`046c95621`) against published commercial and
open-source cores tracked by [riscv100.top](https://riscv100.top/)
(BenchCouncil) and vendor disclosures.

> **Methodology & caveats**:
> - **ISA & Toolchain**: RV64GC (`-O2 -march=rv64gc -mabi=lp64d -static`,
>   GCC/G++/GFortran 13.3). Official vendor CoreMark/SPEC submissions typically
>   use `-O3 -flto` or PGO (+10%-25%).
> - **SPECrate2017_int / GHz (10/10)** and **SPECrate2017_fp / GHz (13/13)** are
>   **estimated** from full 23/23 50M-instruction aligned gem5 SE runs using
>   official SPEC `refrate` reference times and reference dynamic instruction
>   counts (not an official SPEC submission).

| Processor | ISA / Arch | Issue Width | CoreMark / MHz | SPECrate2017_int / GHz | SPECrate2017_fp / GHz | Positioning Notes |
|---|---|---:|---:|---:|---:|---|
| SiFive Rocket | RV64 In-Order | 1 | 2.3-2.75 | ~0.25-0.35 | ~0.20-0.30 | Scalar 5-stage in-order |
| ARM Cortex-A55 | ARMv8 In-Order | 2 | 3.0-4.0 | 0.5-0.7 | ~0.45-0.65 | Improved in-order |
| SiFive U74 | RV64 In-Order | 2 | 4.9-5.7 | 0.7-0.9 | ~0.6-0.8 | Dual-issue app core |
| **Raptor `default`** | **RV64 OoO** | **2** | **5.67** *(RTL)* | **~0.77** *(10/10 est.)* | **~0.48** *(13/13 est.)* | 2W, 64 ROB, 16K L1+PF, 512 BTB |
| **Raptor `default-l2`** | **RV64 OoO** | **2** | **5.19** *(gem5)* | **~0.72** *(10/10 est.)* | **~0.50** *(13/13 est.)* | 2W, 32 ROB, 16K L1+PF, 512K L2 |
| **Raptor `default-cache`** | **RV64 OoO** | **2** | **5.39** *(gem5)* | **~0.79** *(10/10 est.)* | **~0.57** *(13/13 est.)* | 2W, 32 ROB, 128K L1+PF |
| **Raptor `default-w3`** | **RV64 OoO** | **3** | **6.16** *(gem5)* | **~0.86** *(10/10 est.)* | **~0.52** *(13/13 est.)* | 3W, 64 ROB, 16K L1+PF, 512 BTB |
| **Raptor `default-w4`** | **RV64 OoO** | **4** | **7.10** *(RTL)* | **~0.88** *(10/10 est.)* | **~0.53** *(13/13 est.)* | 4W, 64 ROB, 16K L1+PF, 512 BTB |
| **Raptor `default-w4-cache`** | **RV64 OoO** | **4** | **6.15** *(gem5)* | **~1.01** *(10/10 est.)* | **~0.73** *(13/13 est.)* | 4W, 32 ROB, 128K L1+PF, 512 BTB |
| ARM Cortex-A72 | ARMv8 OoO | 3 | 4.7-5.0 | 1.0-1.2 | ~0.9-1.2 | Classic 3-wide OoO + L2 |
| XiangShan Yanqihu | RV64 OoO | 6 | 5.3 (-O2) | ~1.0-1.2 | ~1.0-1.3 | 1st-gen XiangShan (-O2) |
| SonicBOOM (v3) | RV64 OoO | 3-4 | 6.2-6.9 | ~1.0-1.3 | ~0.9-1.2 | Open-source OoO (L1+L2) |
| XuanTie C910 / C920 | RV64 OoO | 3 | 7.1-7.2+ | 1.2-1.6 | ~1.2-1.7 | Commercial 3W OoO (64K L1+L2) |
| SiFive P550 | RV64 OoO | 3 | 8.0+ | 1.2-1.4 | ~1.2-1.5 | Commercial 3W OoO (32K L1+256K L2) |
| ARM Cortex-A76 | ARMv8 OoO | 4 | 5.0-6.0+ | ~1.5-1.8 | ~1.6-2.0 | 4W OoO, 128 ROB, 64K L1+512K L2 |
| XiangShan Nanhu / KMH | RV64 OoO | 6-8 | 7.0-9.0+ | 2.0-2.5+ | ~2.0-2.8+ | Wide open-source OoO (64K L1+1M L2) |

---

## 6. Reproducing These Results (Integrated Repo Tooling)

```bash
# 0. Verify config mapping, TMA, SPEC discovery, and reporting unit tests
make -C sim/gsim test

# 1. CoreMark + Embench-IoT across 6 presets
make -C sim/gsim embench-sweep EVAL_OUTDIR=<EVAL_OUT>/presets-embench-rv64 \
    EVAL_PRESETS="default,default-w3,default-w4,default-cache,default-w4-cache,default-l2"

# 2. Full SPEC CPU 2017 (23/23) or CPU 2026 (49/52) @ 50M instructions
cp sim/gsim/spec_configs/raptor-cpu2017-rv64.cfg <SPEC_ROOT>/config/
make -C sim/gsim spec-eval SPEC_ROOT=<SPEC_ROOT> \
    EVAL_OUTDIR=<EVAL_OUT>/gem5-2017-50m-default-w4-cache PRESET=default-w4-cache

# 3. High-precision 50M-ROI kmax=6 NEMU SimPoint + RTL Verilator replay
make -C sim XLEN=64 RAPT_CONFIG=default SIM_MEM_PROFILE=large -j16
make -C sim/gsim spec-simpoint SPEC_ROOT=<SPEC_ROOT> \
    EVAL_OUTDIR=<EVAL_OUT>/simpoint50m-2017-rv64 \
    NEMU_BIN=<NEMU_SAMPLING_BIN> FW_PAYLOAD=<FW_PAYLOAD> \
    INITRAMFS=<INITRAMFS> RTL_MODEL=sim/build/default-pmem2g/riscv64-npc-sim \
    SIMPOINT_ARGS="--benches 519.lbm_r,557.xz_r --length 50000000 --interval 500000 --warmup 500000 --kmax 6"

# 4. Aggregate multi-preset gem5 TMA, estimated SPECrate2017/GHz, and RTL PMU TMA
make -C sim/gsim perf-report EVAL_ROOT=<EVAL_OUT> \
    EVAL_PRESETS="default,default-w3,default-w4,default-cache,default-w4-cache,default-l2"
```
