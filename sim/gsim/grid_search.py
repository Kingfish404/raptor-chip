#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
Grid-search driver for raptor_se.py (gem5 SE-mode DSE).

Sweeps microarchitecture knobs around the current HDL default preset
(`hdl/configs/default/rapt_config.svh`, parsed directly by raptor_se.py) by
appending --set overrides, runs CoreMark + Embench workloads in parallel, and
aggregates IPC / miss-rate / window-pressure stats into one CSV per workload
plus a merged all-workloads CSV under sim/build/gsim/results/.

Usage:
    python3 grid_search.py            # full grid, all workloads
    python3 grid_search.py --phase rob --benches coremark
    python3 grid_search.py --max-insts 20000000   # fast smoke grid
    python3 grid_search.py --workers 24
    python3 grid_search.py --resume   # skip outdirs that already have stats.txt

The Makefile wrapper is `make grid` (see sim/gsim/Makefile).
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import csv
import math
import os
import re
import subprocess
import sys
from pathlib import Path

RAPTOR_HOME = Path(os.environ.get("RAPTOR_HOME", Path(__file__).resolve().parents[2]))
GSIM_DIR = RAPTOR_HOME / "sim" / "gsim"
SCRIPT = GSIM_DIR / "raptor_se.py"
GEM5 = Path(
    os.environ.get(
        "GEM5",
        RAPTOR_HOME / "third_party" / "gem5" / "build" / "RISCV" / "gem5.opt",
    )
)
RESULTS = RAPTOR_HOME / "sim" / "build" / "gsim" / "results"
GRID_ROOT = RAPTOR_HOME / "sim" / "build" / "gsim" / "grid"

PRESET = "default"
RV64 = False
COREMARK_OPTS = "0;0;0x66;10"

EMBENCH_ALL = [
    "aha-mont64", "crc32", "depthconv", "edn", "huffbench",
    "matmult-int", "md5sum", "nettle-aes", "nettle-sha256",
    "nsichneu", "picojpeg", "qrduino", "sglib-combined", "slre",
    "statemate", "tarfind", "ud", "wikisort", "xgboost",
]
# Representative subset for the grid: integer-dense, control-dense, and
# memory-dense workloads with short runtimes.
EMBENCH_SUBSET = [
    "crc32", "aha-mont64", "matmult-int", "slre", "wikisort",
    "qrduino", "huffbench", "ud",
]


def next_pow2(x: int) -> int:
    n = 1
    while n < x:
        n *= 2
    return n


def set_flags(**knobs) -> list[str]:
    """Knob name → --set flag list. Keys are uarch keys of raptor_se.py."""
    out: list[str] = []
    for k, v in knobs.items():
        out += ["--set", f"uarch.{k}={v}"]
    return out


class Point:
    """One grid point: label + --set overrides on top of PRESET."""

    def __init__(self, label: str, phase: str, flags: list[str],
                 rtl_legal: bool = True, note: str = ""):
        self.label = label
        self.phase = phase
        self.flags = flags
        self.rtl_legal = rtl_legal
        self.note = note


def build_points() -> dict[str, Point]:
    pts: dict[str, Point] = {}

    def add(p: Point) -> None:
        assert p.label not in pts, p.label
        pts[p.label] = p

    # ---- Phase A: ROB sweep (PHY stays at the preset's 128 unless the ROB
    # needs more register-file cover: pow2 >= 32 + ROB) ----
    for rob in (16, 32, 48, 64, 96, 128):
        add(Point(
            f"rob{rob}",
            "rob",
            set_flags(rob=rob, phys_int=max(128, next_pow2(32 + rob)),
                      phys_fp=max(128, next_pow2(32 + rob))),
            rtl_legal=rob in (16, 32, 64, 128),
            note="RTL ROB depth needs power-of-2 pointer wrap",
        ))

    # ---- Phase B: IQ (RS+IOQ) sweep at the selected preset's ROB depth ----
    for iq in (8, 16, 24, 32):
        add(Point(
            f"iq{iq}",
            "iq",
            set_flags(iq=iq),
            rtl_legal=iq in (8, 16, 32),
            note="RTL RS/IOQ depths need power-of-2",
        ))

    # ---- Phase C: SQ sweep at the selected preset's ROB depth ----
    for sq in (4, 8, 16, 32):
        add(Point(
            f"sq{sq}",
            "sq",
            set_flags(sq=sq, lq=sq),
            rtl_legal=True,
        ))

    # ---- Phase D: L1I/L1D associativity sweep (64 sets fixed, VIPT cap) ----
    for l1i_w, l1d_w in ((4, 4), (4, 2), (2, 4), (2, 2), (8, 4)):
        add(Point(
            f"l1i{4 * l1i_w}k-l1d{4 * l1d_w}k",
            "cache",
            set_flags(l1i_assoc=l1i_w, l1d_assoc=l1d_w,
                      l1i_size=f"{64 * 64 * l1i_w}B",
                      l1d_size=f"{64 * 64 * l1d_w}B"),
            rtl_legal=l1i_w in (2, 4) and l1d_w in (2, 4),
            note="RTL L1D fill logic caps assoc at 4; L1I 8-way gem5-only",
        ))

    # ---- Phase E: ordered-stage widths ----
    for dec, ren, disp, cmt in ((4, 4, 4, 2), (2, 2, 2, 4), (4, 4, 4, 4)):
        add(Point(
            f"w{dec}{ren}{disp}{cmt}",
            "width",
            set_flags(decode_w=dec, rename_w=ren, dispatch_w=disp,
                      commit_w=cmt, fetch_w=dec, issue_w=disp, wb_w=disp,
                      squash_w=max(disp, cmt)),
            rtl_legal=True,
        ))
    # Wider execution: 4 ALU ports at width 4.
    add(Point(
        "w4444-p4",
        "width",
        set_flags(decode_w=4, rename_w=4, dispatch_w=4, commit_w=4,
                  fetch_w=4, issue_w=4, wb_w=4, squash_w=4,
                  integer_issue_ports=4),
        rtl_legal=True,
    ))

    # ---- Phase F: branch predictor (TAGE = RTL default vs bimodal) ----
    add(Point(
        "bp-local",
        "bpu",
        ["--set", "sim.bp=local"],
        rtl_legal=True,
        note="RAPT_BPU_DIRP_BIMODAL ablation",
    ))

    # ---- Phase G: BTB / RAS sizing ----
    for btb in (64, 256):
        add(Point(
            f"btb{btb}",
            "bpu",
            set_flags(btb_entries=btb),
            rtl_legal=True,
        ))
    add(Point("rsb8", "bpu", set_flags(rsb_size=8), rtl_legal=True))

    return pts


def bench_argv(bench: str) -> list[str]:
    if bench == "coremark":
        return ["--benchmark", "coremark", "--options", COREMARK_OPTS]
    if bench.startswith("embench-"):
        return ["--benchmark", bench]
    raise ValueError(bench)


def run_one(bench: str, point: Point, outdir: Path, max_insts: int,
            extra: list[str]) -> tuple[str, str, dict]:
    """Run one gem5 simulation; returns (bench, label, stats dict)."""
    outdir.mkdir(parents=True, exist_ok=True)
    log = outdir / "run.log"
    cmd = [
        str(GEM5),
        f"--outdir={outdir}",
        str(SCRIPT),
        "--preset", PRESET,
        "--rtl-execution-resources",
        *bench_argv(bench),
        *point.flags,
        *extra,
    ]
    if max_insts > 0:
        cmd += ["--max-insts", str(max_insts)]
    try:
        with log.open("w") as f:
            subprocess.run(cmd, stdout=f, stderr=subprocess.STDOUT,
                           check=True, timeout=7200)
    except subprocess.CalledProcessError as e:
        return bench, point.label, {"error": f"gem5 exit {e.returncode}"}
    stats = parse_stats(outdir / "stats.txt")
    return bench, point.label, stats


def parse_stats(path: Path) -> dict:
    want = {
        "simInsts": "insts",
        "system.cpu.numCycles": "cycles",
        "system.cpu.ipc": "ipc",
        "system.cpu.branchPred.condPredicted": "bp_cond_pred",
        "system.cpu.branchPred.condIncorrect": "bp_cond_wrong",
        "system.cpu.branchPred.BTBLookups": "btb_lookups",
        "system.cpu.branchPred.BTBHits": "btb_hits",
        "system.cpu.icache.demandMisses::total": "l1i_misses",
        "system.cpu.icache.demandAccesses::total": "l1i_accesses",
        "system.cpu.dcache.demandMisses::total": "l1d_misses",
        "system.cpu.dcache.demandAccesses::total": "l1d_accesses",
        "system.cpu.iew.iqFullEvents": "iq_full",
        "system.cpu.rob.rob_reads": "rob_reads",
        "system.cpu.rob.rob_writes": "rob_writes",
        "system.cpu.commitStats0.numInsts": "commit_insts",
        "system.cpu.lsq0.loadToUse::mean": "ld_to_use_avg",
    }
    out: dict = {}
    line_re = re.compile(r"^\s*(\S+)\s+(\S+)")
    if not path.exists():
        return {"error": "no stats.txt"}
    with path.open() as f:
        for line in f:
            m = line_re.match(line)
            if m and m.group(1) in want:
                out[want[m.group(1)]] = m.group(2)
    return out


def point_knobs(point: Point) -> dict:
    """Extract explicit knob columns from a point's --set flags."""
    knobs: dict = {}
    i = 0
    while i < len(point.flags) - 1:
        if point.flags[i] == "--set":
            kpath, _, v = point.flags[i + 1].partition("=")
            key = kpath.split(".")[-1]
            knobs[key] = v
        i += 1
    return knobs


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--phase", default=None,
                    help="only run points of this phase (rob|iq|sq|cache|width|bpu)")
    ap.add_argument("--benches", default="coremark",
                    help="comma list: coremark, embench-subset, embench-all, or names")
    ap.add_argument("--workers", type=int, default=16)
    ap.add_argument("--max-insts", type=int, default=0)
    ap.add_argument("--resume", action="store_true",
                    help="skip points whose outdir already has stats.txt")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--aggregate-only", action="store_true",
                    help="skip simulation; rebuild CSVs from existing stats.txt files")
    args = ap.parse_args()

    points = build_points()
    all_points = dict(points)
    if args.phase:
        points = {k: v for k, v in points.items() if v.phase == args.phase}

    benches: list[str] = []
    for b in args.benches.split(","):
        b = b.strip()
        if b == "coremark":
            benches.append("coremark")
        elif b == "embench-subset":
            benches.extend(f"embench-{x}" for x in EMBENCH_SUBSET)
        elif b == "embench-all":
            benches.extend(f"embench-{x}" for x in EMBENCH_ALL)
        elif b:
            benches.append(b if b.startswith("embench-") else f"embench-{b}")

    jobs: list[tuple[str, Point, Path]] = []
    preloaded: dict[str, dict[str, dict]] = {b: {} for b in benches}
    for bench in benches:
        for label, point in all_points.items():
            outdir = GRID_ROOT / point.phase / label / bench
            if (args.resume or args.aggregate_only) and (outdir / "stats.txt").exists():
                preloaded[bench][label] = parse_stats(outdir / "stats.txt")
                continue
            if args.aggregate_only or label not in points:
                continue
            jobs.append((bench, point, outdir))

    if args.dry_run:
        for bench, point, outdir in jobs:
            print(f"{bench:24s} {point.label:22s} phase={point.phase} "
                  f"rtl={point.rtl_legal} {point.flags}")
        print(f"\n[grid] {len(jobs)} runs, benches={benches}")
        return 0

    if args.aggregate_only:
        print(f"[grid] aggregate-only: rebuilding CSVs from existing stats")
        return aggregrate(benches, all_points, preloaded, [])

    if not GEM5.exists():
        print(f"[grid] gem5 binary not found: {GEM5}", file=sys.stderr)
        return 2

    print(f"[grid] {len(jobs)} runs, {args.workers} workers, "
          f"max-insts={args.max_insts or 'unbounded'}")

    rows: dict[str, dict[str, dict]] = {b: dict(preloaded[b]) for b in benches}
    errors: list[str] = []
    with cf.ThreadPoolExecutor(max_workers=args.workers) as ex:
        futs = {
            ex.submit(run_one, bench, point, outdir, args.max_insts, []):
            (bench, point.label)
            for bench, point, outdir in jobs
        }
        done = 0
        for fut in cf.as_completed(futs):
            bench, label = futs[fut]
            done += 1
            b, l, stats = fut.result()
            rows[b][l] = stats
            if "error" in stats:
                errors.append(f"{b}@{l}: {stats['error']}")
            print(f"[grid] {done}/{len(futs)} {b}@{l} "
                  f"ipc={stats.get('ipc', '?')}", flush=True)

    # ---- Aggregate ----
    return aggregrate(benches, all_points, rows, errors)


def aggregrate(benches: list[str], points: dict[str, Point],
               rows: dict[str, dict[str, dict]], errors: list[str]) -> int:
    """Write per-workload CSVs from collected/preloaded stats rows."""
    RESULTS.mkdir(parents=True, exist_ok=True)

    for bench in benches:
        per_bench: list[dict] = []
        for label, point in points.items():
            stats = rows[bench].get(label)
            if not stats:
                continue
            row = {
                "bench": bench,
                "label": label,
                "phase": point.phase,
                "rtl_legal": "Y" if point.rtl_legal else "N",
                "note": point.note,
                **point_knobs(point),
                **stats,
            }
            per_bench.append(row)
        csv_path = RESULTS / f"grid-{bench}-rv{32 if not RV64 else 64}.csv"
        with csv_path.open("w", newline="") as f:
            cols = sorted({k for r in per_bench for k in r})
            w = csv.DictWriter(f, fieldnames=cols, extrasaction="ignore")
            w.writeheader()
            for row in per_bench:
                w.writerow(row)
        print(f"[grid] wrote {csv_path}")

    if errors:
        print("\n[grid] errors:")
        for e in errors:
            print("   ", e)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
