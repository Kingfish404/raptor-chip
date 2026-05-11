#!/usr/bin/env python3
"""Extract key gem5 microarchitecture metrics from a stats.txt into a concise
summary.txt and (optionally) a one-line CSV record.

Usage:
    summarize_stats.py <m5out_dir> [--csv <append_path>] [--tag <name>]

Reads <m5out_dir>/stats.txt and writes:
    <m5out_dir>/summary.txt   (human-readable, table layout)
    <m5out_dir>/summary.csv   (single-row CSV, header included)

If --csv is given, the same row (without header) is appended to that path,
creating the file with a header on first write. --tag is the row's leading
column (defaults to the basename of <m5out_dir>).
"""
from __future__ import annotations

import argparse
import csv
import re
import sys
from pathlib import Path

# Stat name → column label. Values are lifted as-is from gem5 stats.txt; ratios
# and miss rates are recomputed in Python so callers always see consistent
# numbers even on configs gem5 omits a derived stat for.
WANTED = [
    ("simInsts", "insts"),
    ("system.cpu.numCycles", "cycles"),
    ("system.cpu.ipc", "ipc"),
    ("system.cpu.cpi", "cpi"),
    ("system.cpu.branchPred.condPredicted", "bp_cond_pred"),
    ("system.cpu.branchPred.condIncorrect", "bp_cond_wrong"),
    ("system.cpu.branchPred.BTBLookups", "btb_lookups"),
    ("system.cpu.branchPred.BTBHits", "btb_hits"),
    ("system.cpu.icache.demandMisses::total", "l1i_misses"),
    ("system.cpu.icache.demandAccesses::total", "l1i_accesses"),
    ("system.cpu.dcache.demandMisses::total", "l1d_misses"),
    ("system.cpu.dcache.demandAccesses::total", "l1d_accesses"),
    ("system.cpu.iew.iqFullEvents", "iq_full"),
    ("system.cpu.rob.rob_reads", "rob_reads"),
    ("system.cpu.rob.rob_writes", "rob_writes"),
    ("system.cpu.commitStats0.numInsts", "commit_insts"),
    ("system.cpu.commitStats0.numOps", "commit_ops"),
    ("system.cpu.lsq0.loadToUse::mean", "ld_to_use_avg"),
]

DERIVED_HEADER = [
    "bp_cond_acc",      # = 1 - wrong/predicted
    "btb_hit_rate",
    "l1i_miss_rate",
    "l1d_miss_rate",
]


def parse_stats(stats_path: Path) -> dict[str, str]:
    """Return {stat_name: raw_value_token} for every line we care about."""
    wanted_keys = {k for k, _ in WANTED}
    out: dict[str, str] = {}
    line_re = re.compile(r"^\s*(\S+)\s+(\S+)")
    with stats_path.open() as f:
        for line in f:
            m = line_re.match(line)
            if not m:
                continue
            name, val = m.group(1), m.group(2)
            if name in wanted_keys:
                out[name] = val
    return out


def to_float(v: str | None) -> float | None:
    if v is None:
        return None
    try:
        return float(v)
    except ValueError:
        return None


def derive(stats: dict[str, str]) -> dict[str, str]:
    pred = to_float(stats.get("system.cpu.branchPred.condPredicted"))
    wrong = to_float(stats.get("system.cpu.branchPred.condIncorrect"))
    btb_l = to_float(stats.get("system.cpu.branchPred.BTBLookups"))
    btb_h = to_float(stats.get("system.cpu.branchPred.BTBHits"))
    l1i_m = to_float(stats.get("system.cpu.icache.demandMisses::total"))
    l1i_a = to_float(stats.get("system.cpu.icache.demandAccesses::total"))
    l1d_m = to_float(stats.get("system.cpu.dcache.demandMisses::total"))
    l1d_a = to_float(stats.get("system.cpu.dcache.demandAccesses::total"))

    def safe(num, den, scale=1.0):
        if num is None or den is None or den == 0:
            return ""
        return f"{(num / den) * scale:.4f}"

    return {
        "bp_cond_acc": safe(pred - wrong, pred) if pred and wrong is not None else "",
        "btb_hit_rate": safe(btb_h, btb_l),
        "l1i_miss_rate": safe(l1i_m, l1i_a),
        "l1d_miss_rate": safe(l1d_m, l1d_a),
    }


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("outdir", type=Path, help="m5out directory")
    ap.add_argument("--csv", type=Path, default=None,
                    help="aggregate CSV to append a single row to")
    ap.add_argument("--tag", default=None,
                    help="run identifier (default: outdir basename)")
    args = ap.parse_args(argv)

    stats_path = args.outdir / "stats.txt"
    if not stats_path.exists():
        print(f"[summarize_stats] no stats.txt at {stats_path}", file=sys.stderr)
        return 1

    stats = parse_stats(stats_path)
    derived = derive(stats)
    tag = args.tag or args.outdir.name

    # Human-readable summary
    summary_path = args.outdir / "summary.txt"
    width = max(len(label) for _, label in WANTED + [(None, k) for k in DERIVED_HEADER])
    with summary_path.open("w") as f:
        f.write(f"# gem5 raptor-chip run summary — {tag}\n")
        f.write(f"# stats source: {stats_path}\n\n")
        f.write("[raw counters]\n")
        for key, label in WANTED:
            f.write(f"  {label:<{width}} = {stats.get(key, '<missing>')}\n")
        f.write("\n[derived ratios]\n")
        for key in DERIVED_HEADER:
            f.write(f"  {key:<{width}} = {derived.get(key, '')}\n")
    print(f"[summarize_stats] wrote {summary_path}")

    # CSV (always: per-run summary.csv with header)
    header = ["run"] + [label for _, label in WANTED] + DERIVED_HEADER
    row = [tag] + [stats.get(k, "") for k, _ in WANTED] + [derived.get(k, "") for k in DERIVED_HEADER]

    per_run_csv = args.outdir / "summary.csv"
    with per_run_csv.open("w", newline="") as f:
        w = csv.writer(f)
        w.writerow(header)
        w.writerow(row)
    print(f"[summarize_stats] wrote {per_run_csv}")

    if args.csv is not None:
        args.csv.parent.mkdir(parents=True, exist_ok=True)
        write_header = not args.csv.exists()
        with args.csv.open("a", newline="") as f:
            w = csv.writer(f)
            if write_header:
                w.writerow(header)
            w.writerow(row)
        print(f"[summarize_stats] appended row to {args.csv}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
