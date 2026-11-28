#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Parallel SPEC CPU 2017 / CPU 2026 runner for Raptor gem5 SE evaluation.

Discovers compiled static RV64 binaries and their `speccmds.cmd` arguments
from a SPEC installation built with `sim/gsim/spec_configs/raptor-cpu*.cfg`,
runs them in parallel through `raptor_se.py`, and writes a summary CSV.

Example:
    python3 sim/gsim/spec_eval.py \
        --spec-root /path/to/cpu2017 \
        --outdir /path/to/results/spec2017-default \
        --preset default --max-insts 20000000 --workers 8
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import csv
import json
import os
import shlex
import subprocess
import sys
import time
from pathlib import Path

GSIM_DIR = Path(__file__).resolve().parent
RAPTOR_HOME = Path(os.environ.get("RAPTOR_HOME", GSIM_DIR.parents[1]))
RAPTOR_SE = GSIM_DIR / "raptor_se.py"

sys.path.insert(0, str(GSIM_DIR))
import summarize_stats


def _default_gem5() -> Path:
    if "GEM5" in os.environ:
        return Path(os.environ["GEM5"])
    for variant in ("gem5.fast", "gem5.opt"):
        cand = RAPTOR_HOME / "third_party" / "gem5" / "build" / "RISCV" / variant
        if cand.exists():
            return cand
    return RAPTOR_HOME / "third_party" / "gem5" / "build" / "RISCV" / "gem5.opt"


def parse_speccmds(run_dir: Path) -> tuple[Path, list[str]] | None:
    """Parse the first benchmark command from a SPEC `speccmds.cmd` file."""
    cmd_file = run_dir / "speccmds.cmd"
    if not cmd_file.exists():
        return None
    for raw in cmd_file.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "../run_" not in line:
            continue
        tokens = shlex.split(line)
        i = 0
        while i < len(tokens) and tokens[i].startswith("-"):
            # Skip specinvoke flags: -o/-e/-i/-C/-N take a value; -r/-n etc.
            if tokens[i] in ("-o", "-e", "-i", "-C", "-N", "-k", "-E"):
                i += 2
            else:
                i += 1
        if i >= len(tokens):
            continue
        exe = (run_dir / tokens[i]).resolve()
        if exe.exists():
            return exe, tokens[i + 1 :]
    return None


def parse_speccmds_stdin(run_dir: Path) -> Path | None:
    """Return the `-i <file>` stdin path from `speccmds.cmd`, if any."""
    cmd_file = run_dir / "speccmds.cmd"
    if not cmd_file.exists():
        return None
    for raw in cmd_file.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "../run_" not in line:
            continue
        tokens = shlex.split(line)
        i = 0
        stdin_file: Path | None = None
        while i < len(tokens) and tokens[i].startswith("-"):
            if tokens[i] == "-i" and i + 1 < len(tokens):
                stdin_file = (run_dir / tokens[i + 1]).resolve()
                i += 2
            elif tokens[i] in ("-o", "-e", "-C", "-N", "-k", "-E"):
                i += 2
            else:
                i += 1
        return stdin_file if (stdin_file and stdin_file.exists()) else None
    return None


def discover_benchmarks(
    spec_root: Path,
    label: str,
    size: str,
    selected: list[str] | None,
) -> list[tuple[str, Path, Path, list[str]]]:
    """Return [(bench_name, run_dir, exe_path, argv), ...] for built benchmarks."""
    cpu_dir = spec_root / "benchspec" / "CPU"
    if not cpu_dir.is_dir():
        cpu_dir = spec_root / "benchspec" / "CPU2006"
    if not cpu_dir.is_dir():
        raise FileNotFoundError(f"SPEC CPU directory not found: {cpu_dir}")
    out: list[tuple[str, Path, Path, list[str]]] = []
    for bench_dir in sorted(cpu_dir.iterdir()):
        if not bench_dir.is_dir():
            continue
        name = bench_dir.name
        if selected and name not in selected:
            continue
        pattern = f"run_base_{size}_{label}.*"
        run_dirs = sorted(bench_dir.glob(f"run/{pattern}"))
        if not run_dirs:
            continue
        run_dir = run_dirs[-1]
        parsed = parse_speccmds(run_dir)
        if parsed is None:
            continue
        exe, argv = parsed
        out.append((name, run_dir, exe, argv))
    return out


def run_one(
    gem5: Path,
    bench: str,
    run_dir: Path,
    exe: Path,
    argv: list[str],
    outdir: Path,
    preset: str,
    max_insts: int,
    split_iq: bool,
    mem_size: str,
    extra: list[str],
) -> dict:
    bench_out = outdir / bench
    bench_out.mkdir(parents=True, exist_ok=True)
    cmd = [
        str(gem5),
        f"--outdir={bench_out}",
        str(RAPTOR_SE),
        "--preset", preset,
        "--rv64",
        "--benchmark", str(exe),
        "--cwd", str(run_dir),
        "--mem-size", mem_size,
        "--rtl-execution-resources",
    ]
    if argv:
        cmd.append(f"--options={';'.join(argv)}")
    stdin_path = parse_speccmds_stdin(run_dir)
    if stdin_path is not None:
        cmd.append(f"--input={stdin_path}")
    if split_iq:
        cmd.append("--rtl-split-iq")
    if max_insts > 0:
        cmd += ["--max-insts", str(max_insts)]
    cmd += extra

    t0 = time.monotonic()
    log_path = bench_out / "run.log"
    with log_path.open("w") as logf:
        proc = subprocess.run(
            cmd,
            stdin=subprocess.DEVNULL,
            stdout=logf,
            stderr=subprocess.STDOUT,
            timeout=1800,
        )
    wall_s = round(time.monotonic() - t0, 2)
    stats_path = bench_out / "stats.txt"
    if proc.returncode != 0 or not stats_path.exists():
        return {"bench": bench, "preset": preset, "status": f"rc={proc.returncode}", "wall_s": wall_s}

    raw = summarize_stats.parse_stats(stats_path)
    pipe_w = 2
    eff_cfg = bench_out / "raptor_se_effective.json"
    if eff_cfg.exists():
        try:
            pipe_w = int(json.loads(eff_cfg.read_text()).get("uarch", {}).get("rename_w", 2))
        except (OSError, ValueError, TypeError):
            pipe_w = 2
    derived = summarize_stats.derive(raw, pipeline_width=pipe_w)
    row = {
        "bench": bench,
        "preset": preset,
        "split_iq": int(split_iq),
        "status": "ok",
        "wall_s": wall_s,
    }
    for key, col in summarize_stats.WANTED:
        row[col] = raw.get(key, "")
    for col in summarize_stats.DERIVED_HEADER:
        row[col] = derived.get(col, "")
    return row


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--spec-root", required=True, type=Path,
                    help="Installed SPEC CPU 2017 or CPU 2026 root directory")
    ap.add_argument("--outdir", required=True, type=Path,
                    help="Output directory outside the source tree")
    ap.add_argument("--label", default="raptor-rv64-static",
                    help="SPEC config label used during runcpu --action=setup")
    ap.add_argument(
        "--size",
        default="test",
        choices=("test", "train", "ref", "refrate", "refspeed"),
    )
    ap.add_argument("--benches", default="",
                    help="Comma-separated benchmark names (empty = all discovered)")
    ap.add_argument("--preset", default="default",
                    help="Raptor RTL preset under rtl/configs/")
    ap.add_argument("--rtl-split-iq", action="store_true",
                    help="Enable domain-split IQUnits mirroring rapt_backend.sv")
    ap.add_argument("--max-insts", type=int, default=20000000,
                    help="Instruction cap per benchmark (0 = run to completion)")
    ap.add_argument("--mem-size", default="2GiB",
                    help="Backing memory size for gem5 SE (default: 2GiB)")
    ap.add_argument("--workers", type=int, default=5)
    ap.add_argument("--gem5", type=Path, default=_default_gem5())
    ap.add_argument("--extra", action="append", default=[],
                    help="Extra argument passed through to raptor_se.py")
    args = ap.parse_args(argv)

    selected = [b.strip() for b in args.benches.split(",") if b.strip()] or None
    discovered = discover_benchmarks(args.spec_root, args.label, args.size, selected)
    if not discovered:
        print(f"[spec_eval] no built benchmarks found under {args.spec_root}", file=sys.stderr)
        return 2

    args.outdir.mkdir(parents=True, exist_ok=True)
    print(
        f"[spec_eval] {len(discovered)} benchmarks, preset={args.preset}, "
        f"split_iq={args.rtl_split_iq}, max_insts={args.max_insts}"
    )

    rows: list[dict] = []
    with cf.ThreadPoolExecutor(max_workers=args.workers) as pool:
        futs = {
            pool.submit(
                run_one, args.gem5, bench, run_dir, exe, b_argv,
                args.outdir, args.preset, args.max_insts,
                args.rtl_split_iq, args.mem_size, args.extra,
            ): bench
            for bench, run_dir, exe, b_argv in discovered
        }
        for fut in cf.as_completed(futs):
            row = fut.result()
            rows.append(row)
            print(
                f"[spec_eval] {row['bench']:18s} status={row['status']} "
                f"ipc={row.get('ipc', '-')} bp={row.get('bp_cond_acc', '-')} "
                f"l1d_mr={row.get('l1d_miss_rate', '-')} "
                f"l2_mr={row.get('l2_miss_rate', '-')} wall={row['wall_s']}s",
                flush=True,
            )

    rows.sort(key=lambda r: r["bench"])
    csv_path = args.outdir / "spec_summary.csv"
    fieldnames = sorted({k for r in rows for k in r})
    preferred = [
        "bench", "preset", "split_iq", "status", "wall_s", "insts", "cycles",
        "ipc", "bp_cond_acc", "bp_total_acc", "l1i_miss_rate", "l1d_miss_rate",
        "l2_miss_rate", "iq_full", "rob_full", "lsq_full", "ld_to_use_avg",
    ]
    ordered = [c for c in preferred if c in fieldnames] + [
        c for c in fieldnames if c not in preferred
    ]
    with csv_path.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=ordered, extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)
    print(f"[spec_eval] wrote {csv_path}")
    return 0 if all(r["status"] == "ok" for r in rows) else 1


if __name__ == "__main__":
    raise SystemExit(main())
