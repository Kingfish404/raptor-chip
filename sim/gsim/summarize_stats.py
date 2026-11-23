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
import json
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
    ("system.cpu.branchPred.committed_0::total", "bp_total_cmt"),
    ("system.cpu.branchPred.mispredicted_0::total", "bp_total_wrong"),
    ("system.cpu.branchPred.BTBLookups", "btb_lookups"),
    ("system.cpu.branchPred.BTBHits", "btb_hits"),
    ("system.cpu.icache.demandMisses::total", "l1i_misses"),
    ("system.cpu.icache.demandAccesses::total", "l1i_accesses"),
    ("system.cpu.dcache.demandMisses::total", "l1d_misses"),
    ("system.cpu.dcache.demandAccesses::total", "l1d_accesses"),
    ("system.l2.demandMisses::total", "l2_misses"),
    ("system.l2.demandAccesses::total", "l2_accesses"),
    ("system.cpu.iew.iqFullEvents", "iq_full"),
    ("system.cpu.rename.ROBFullEvents", "rob_full"),
    ("system.cpu.iew.lsqFullEvents", "lsq_full"),
    ("system.cpu.rename.renamedInsts", "renamed_insts"),
    ("system.cpu.rename.status::Idle", "rename_idle_cyc"),
    ("system.cpu.rename.status::Squashing", "rename_squash_cyc"),
    ("system.cpu.rename.status::Blocked", "rename_blocked_cyc"),
    ("system.cpu.rename.status::Unblocking", "rename_unblock_cyc"),
    ("system.cpu.fetch.status::squashing", "fetch_squash_cyc"),
    ("system.cpu.fetch.status::icacheWaitResponse", "icache_wait_cyc"),
    ("system.cpu.fetch.status::icacheWaitRetry", "icache_retry_cyc"),
    ("system.cpu.rob.reads", "rob_reads"),
    ("system.cpu.rob.writes", "rob_writes"),
    ("system.cpu.commitStats0.numInsts", "commit_insts"),
    ("system.cpu.commitStats0.numOps", "commit_ops"),
    ("system.cpu.lsq0.loadToUse::mean", "ld_to_use_avg"),
]

# Legacy gem5 stat aliases (used only if the gem5 25.1 key is absent).
LEGACY_ALIASES = {
    "system.cpu.rob.rob_reads": "system.cpu.rob.reads",
    "system.cpu.rob.rob_writes": "system.cpu.rob.writes",
}

DERIVED_HEADER = [
    "bp_cond_acc",      # = 1 - wrong/predicted
    "bp_total_acc",     # = 1 - total_wrong/total_cmt
    "btb_hit_rate",
    "l1i_miss_rate",
    "l1d_miss_rate",
    "l2_miss_rate",
    "fetch_squash_pct",
    "tma_retiring_pct",
    "tma_bad_spec_pct",
    "tma_frontend_pct",
    "tma_backend_pct",
    "tma_icache_wait_pct",
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
            elif name in LEGACY_ALIASES:
                canonical = LEGACY_ALIASES[name]
                out.setdefault(canonical, val)
    return out


def to_float(v: str | None) -> float | None:
    if v is None:
        return None
    try:
        return float(v)
    except ValueError:
        return None


def derive(stats: dict[str, str], pipeline_width: int = 2) -> dict[str, str]:
    pred = to_float(stats.get("system.cpu.branchPred.condPredicted"))
    wrong = to_float(stats.get("system.cpu.branchPred.condIncorrect"))
    tot_cmt = to_float(stats.get("system.cpu.branchPred.committed_0::total"))
    tot_wrong = to_float(stats.get("system.cpu.branchPred.mispredicted_0::total"))
    btb_l = to_float(stats.get("system.cpu.branchPred.BTBLookups"))
    btb_h = to_float(stats.get("system.cpu.branchPred.BTBHits"))
    l1i_m = to_float(stats.get("system.cpu.icache.demandMisses::total"))
    l1i_a = to_float(stats.get("system.cpu.icache.demandAccesses::total"))
    l1d_m = to_float(stats.get("system.cpu.dcache.demandMisses::total"))
    l1d_a = to_float(stats.get("system.cpu.dcache.demandAccesses::total"))
    l2_m = to_float(stats.get("system.l2.demandMisses::total"))
    l2_a = to_float(stats.get("system.l2.demandAccesses::total"))
    cycles = to_float(stats.get("system.cpu.numCycles"))
    squash_cyc = to_float(stats.get("system.cpu.fetch.status::squashing"))
    cmt_insts = to_float(stats.get("system.cpu.commitStats0.numInsts")) or to_float(
        stats.get("simInsts")
    )
    ren_insts = to_float(stats.get("system.cpu.rename.renamedInsts"))
    ren_idle = to_float(stats.get("system.cpu.rename.status::Idle"))
    ren_squash = to_float(stats.get("system.cpu.rename.status::Squashing"))
    ic_wait = to_float(stats.get("system.cpu.fetch.status::icacheWaitResponse"))
    ic_retry = to_float(stats.get("system.cpu.fetch.status::icacheWaitRetry"))

    def safe(num, den, scale=1.0):
        if num is None or den is None or den == 0:
            return ""
        return f"{(num / den) * scale:.4f}"

    # Top-Down Microarchitecture Analysis (TMA Level 1, Yasin ISPASS 2014)
    # Normalized to total allocation slots = pipeline_width * cycles.
    tma_ret = tma_bad = tma_fe = tma_be = tma_ic = ""
    if cycles and cycles > 0 and cmt_insts is not None:
        w = max(1, int(pipeline_width))
        total_slots = w * cycles
        ret_frac = min(1.0, max(0.0, cmt_insts / total_slots))
        tma_ret = f"{ret_frac * 100.0:.2f}"
        if ren_insts is not None and ren_idle is not None:
            wasted = max(0.0, ren_insts - cmt_insts)
            recov = w * (ren_squash or 0.0)
            bad_frac = min(1.0 - ret_frac, (wasted + recov) / total_slots)
            fe_frac = min(1.0 - ret_frac - bad_frac, max(0.0, ren_idle / cycles))
            be_frac = max(0.0, 1.0 - ret_frac - bad_frac - fe_frac)
            tma_bad = f"{bad_frac * 100.0:.2f}"
            tma_fe = f"{fe_frac * 100.0:.2f}"
            tma_be = f"{be_frac * 100.0:.2f}"
        if ic_wait is not None:
            tma_ic = f"{((ic_wait + (ic_retry or 0.0)) / cycles) * 100.0:.2f}"

    return {
        "bp_cond_acc": safe(pred - wrong, pred) if pred and wrong is not None else "",
        "bp_total_acc": (
            safe(tot_cmt - tot_wrong, tot_cmt)
            if tot_cmt and tot_wrong is not None
            else ""
        ),
        "btb_hit_rate": safe(btb_h, btb_l),
        "l1i_miss_rate": safe(l1i_m, l1i_a),
        "l1d_miss_rate": safe(l1d_m, l1d_a),
        "l2_miss_rate": safe(l2_m, l2_a),
        "fetch_squash_pct": safe(squash_cyc, cycles, scale=100.0),
        "tma_retiring_pct": tma_ret,
        "tma_bad_spec_pct": tma_bad,
        "tma_frontend_pct": tma_fe,
        "tma_backend_pct": tma_be,
        "tma_icache_wait_pct": tma_ic,
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
    pipe_w = 2
    eff_cfg = args.outdir / "raptor_se_effective.json"
    if eff_cfg.exists():
        try:
            pipe_w = int(json.loads(eff_cfg.read_text()).get("uarch", {}).get("rename_w", 2))
        except (OSError, ValueError, TypeError):
            pipe_w = 2
    derived = derive(stats, pipeline_width=pipe_w)
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
