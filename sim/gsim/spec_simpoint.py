#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Multi-benchmark SPEC CPU 2017 / 2026 NEMU SimPoint + RTL replay driver.

Automates the full `verification/performance/` flow across all discovered SPEC
benchmarks built with `sim/gsim/spec_configs/raptor-cpu*.cfg`:

  1. Generate a deterministic sampling DTB via `nemu/tools/nemu.py --dry-run`.
  2. Package each static RV64 SPEC binary and its input assets via
     `verification/performance/linux_workload.py`.
  3. Profile BBVs + capture checkpoint grids in NEMU (`profile.py`,
     starting at `RAPTOR_WORKLOAD_BEGIN`).
  4. Select representative SimPoints (`simpoints.py select`) and assemble
     the capture manifest (`capture.py --reuse`).
  5. Replay checkpoints on an archived RTL Verilator simulator
     (`run_model.py`), and emit ready-to-run `fpga_replay.py` commands for
     FPGA-accelerated replay.
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import csv
import json
import os
import subprocess
import sys
import time
from pathlib import Path

GSIM_DIR = Path(__file__).resolve().parent
RAPTOR_HOME = Path(os.environ.get("RAPTOR_HOME", GSIM_DIR.parents[1]))
PERF_DIR = RAPTOR_HOME / "verification" / "performance"

sys.path.insert(0, str(GSIM_DIR))
import spec_eval

_SKIP_ASSET_NAMES = {"speccmds.cmd", "speccmds.out", "speccmds.err", "compare.cmd", "control"}
_SKIP_ASSET_SUFFIXES = (".out", ".err", ".log", ".mis", ".cmp")


def collect_assets(run_dir: Path, exe: Path, max_asset_mb: int = 128) -> list[str]:
    """Return `--asset SRC=REL` entries for input data files in a SPEC run dir."""
    assets: list[str] = []
    exe_resolved = exe.resolve()
    max_bytes = max_asset_mb * 1024 * 1024
    for path in sorted(run_dir.rglob("*")):
        if not path.is_file():
            continue
        if path.resolve() == exe_resolved:
            continue
        rel = path.relative_to(run_dir)
        if rel.name in _SKIP_ASSET_NAMES or rel.suffix in _SKIP_ASSET_SUFFIXES:
            continue
        if rel.name.startswith("raptor-rv64") or "_base." in rel.name:
            continue
        if path.stat().st_size > max_bytes:
            continue
        assets.append(f"{path.resolve()}={rel.as_posix()}")
    return assets


def _run_step(cmd: list[str], log_path: Path, timeout: int) -> None:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("w") as logf:
        proc = subprocess.run(
            cmd, stdout=logf, stderr=subprocess.STDOUT, timeout=timeout
        )
    if proc.returncode != 0:
        tail = ""
        try:
            lines = log_path.read_text(errors="replace").splitlines()
            tail = "\n".join(lines[-10:])
        except OSError:
            pass
        raise RuntimeError(f"command failed (rc={proc.returncode}): {' '.join(cmd[:4])}\n{tail}")


def run_benchmark(
    bench: str,
    run_dir: Path,
    exe: Path,
    argv: list[str],
    args: argparse.Namespace,
    dtb_path: Path,
    empty_rootfs: Path,
) -> dict:
    bdir = args.outdir / bench
    bdir.mkdir(parents=True, exist_ok=True)
    t0 = time.monotonic()
    py = sys.executable
    row: dict = {"bench": bench, "status": "ok"}

    try:
        # 1. Package Linux workload (initramfs + static ELF + assets)
        wdir = bdir / "workload"
        if not (wdir / "fw_payload.bin").exists():
            assets = collect_assets(run_dir, exe)
            cmd = [
                py, str(PERF_DIR / "linux_workload.py"),
                "--firmware", str(args.firmware),
                "--base-initramfs", str(args.base_initramfs),
                "--dtb", str(dtb_path),
                "--rootfs", str(empty_rootfs),
                "--program", str(exe),
                "--output", str(wdir),
            ]
            for asset in assets:
                cmd += ["--asset", asset]
            for arg in argv:
                cmd.append(f"--arg={arg}")
            _run_step(cmd, bdir / "01-workload.log", timeout=300)

        # 2. NEMU BBV profiling (optional inline checkpoint grid if >0)
        pdir = bdir / "profile"
        if not (pdir / "profile.json").exists():
            cmd = [
                py, str(PERF_DIR / "profile.py"),
                "--nemu", str(args.nemu),
                "--firmware", str(wdir / "fw_payload.bin"),
                "--dtb", str(wdir / "machine.dtb"),
                "--start-marker", args.start_marker,
                "--length", str(args.length),
                "--interval", str(args.interval),
                "--timeout", str(args.profile_timeout),
                "--output", str(pdir),
            ]
            if args.checkpoint_every > 0:
                cmd += ["--checkpoint-every", str(args.checkpoint_every)]
            _run_step(cmd, bdir / "02-profile.log", timeout=args.profile_timeout + 60)

        prof = json.loads((pdir / "profile.json").read_text())
        row["nemu_wall_s"] = round(float(prof.get("wall_seconds", 0.0)), 2)

        # 3. SimPoint selection (skip initial exec/UART prelude after marker)
        plan_path = bdir / "plan.json"
        if not plan_path.exists():
            cmd = [
                py, str(PERF_DIR / "simpoints.py"), "select",
                "--bbv", str(pdir / "profile.bbv.jsonl"),
                "--profile-manifest", str(pdir / "profile.json"),
                "--warmup", str(args.warmup),
                "--kmax", str(args.kmax),
                "--output", str(plan_path),
            ]
            if args.skip_prelude > 0 and args.length > args.skip_prelude:
                regions_path = bdir / "regions.json"
                regions_path.write_text(
                    json.dumps(
                        [{"name": bench, "start": args.skip_prelude, "end": args.length}]
                    )
                )
                cmd += ["--regions", str(regions_path)]
            _run_step(cmd, bdir / "03-select.log", timeout=120)

        plan = json.loads(plan_path.read_text())
        n_points = sum(len(r["points"]) for r in plan.get("regions", []))
        row["simpoints"] = n_points

        # 4. Capture selected SimPoint checkpoints (reuse grid when available)
        cdir = bdir / "capture"
        if not (cdir / "capture.json").exists():
            cmd = [
                py, str(PERF_DIR / "capture.py"),
                "--nemu", str(args.nemu),
                "--plan", str(plan_path),
                "--firmware", str(wdir / "fw_payload.bin"),
                "--dtb", str(wdir / "machine.dtb"),
                "--output", str(cdir),
            ]
            grid_json = pdir / "checkpoint-grid.json"
            if args.checkpoint_every > 0 and grid_json.exists():
                cmd += ["--reuse", str(grid_json)]
            else:
                cmd += ["--timeout", str(args.profile_timeout)]
            _run_step(cmd, bdir / "04-capture.log", timeout=args.profile_timeout + 120)

        # 5. Replay checkpoints on RTL Verilator (if --rtl-model is provided)
        if args.rtl_model is not None:
            rdir = bdir / "rtl-eval"
            if not (rdir / "results.json").exists():
                cmd = [
                    py, str(PERF_DIR / "run_model.py"),
                    "--plan", str(plan_path),
                    "--capture", str(cdir / "capture.json"),
                    "--model", str(args.rtl_model),
                    "--name", args.model_name,
                    "--kind", "sample",
                    "--read-latency", str(args.read_latency),
                    "--write-latency", str(args.write_latency),
                    "--jobs", str(args.rtl_jobs),
                    "--timeout", str(args.rtl_timeout),
                    "--output", str(rdir),
                ]
                _run_step(cmd, bdir / "05-rtl.log", timeout=args.rtl_timeout + 120)

            res = json.loads((rdir / "results.json").read_text())
            regions = (res.get("estimates") or {}).get("regions") or []
            prof_est = (
                (regions[0].get("profiles") or {}).get(args.model_name)
                if regions
                else None
            ) or {}
            cpi = prof_est.get("cpi")
            row["rtl_complete"] = bool(res.get("complete", False))
            row["rtl_cpi"] = round(float(cpi), 4) if cpi else ""
            row["rtl_ipc"] = round(1.0 / float(cpi), 4) if cpi else ""
            row["rtl_est_cycles"] = prof_est.get("cycles", "")
            row["rtl_est_insts"] = (
                regions[0].get("instructions", "") if regions else ""
            )
            row["rtl_wall_s"] = round(float(res.get("wall_seconds", 0.0)), 2)

        row["total_wall_s"] = round(time.monotonic() - t0, 2)
    except Exception as exc:  # noqa: BLE001
        row["status"] = f"error: {str(exc).splitlines()[0][:120]}"
        row["total_wall_s"] = round(time.monotonic() - t0, 2)
    return row


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--spec-root", required=True, type=Path)
    ap.add_argument("--outdir", required=True, type=Path)
    ap.add_argument("--nemu", required=True, type=Path,
                    help="Path to riscv64-nemu-interpreter (riscv64_sampling_defconfig)")
    ap.add_argument("--firmware", required=True, type=Path,
                    help="Path to RV64 Linux fw_payload.bin")
    ap.add_argument("--base-initramfs", required=True, type=Path,
                    help="Path to base initramfs.cpio.gz")
    ap.add_argument("--rtl-model", type=Path, default=None,
                    help="Optional Verilator RTL binary (e.g. sim/build/default/riscv64-npc-sim-t4)")
    ap.add_argument("--model-name", default="default-rv64")
    ap.add_argument("--label", default="raptor-rv64-static")
    ap.add_argument("--size", default="test")
    ap.add_argument("--benches", default="",
                    help="Comma-separated benchmark subset (empty = all discovered)")
    ap.add_argument("--start-marker", default="RAPTOR_WORKLOAD_BEGIN")
    ap.add_argument("--length", type=int, default=50000000,
                    help="ROI retired instruction length (default: 50,000,000)")
    ap.add_argument("--interval", type=int, default=500000,
                    help="BBV interval size (default: 500,000)")
    ap.add_argument("--warmup", type=int, default=500000,
                    help="SimPoint warmup instructions (default: 500,000)")
    ap.add_argument("--skip-prelude", type=int, default=1000000,
                    help="Skip initial instructions after marker to avoid active UART/exec prelude")
    ap.add_argument("--kmax", type=int, default=6,
                    help="Max SimPoint clusters per benchmark (default: 6)")
    ap.add_argument("--checkpoint-every", type=int, default=0,
                    help="Inline checkpoint grid stride (0 = 2-pass capture of selected SimPoints only)")
    ap.add_argument("--read-latency", type=int, default=0)
    ap.add_argument("--write-latency", type=int, default=0)
    ap.add_argument("--workers", type=int, default=4,
                    help="Parallel benchmark pipelines (default: 4)")
    ap.add_argument("--rtl-jobs", type=int, default=2,
                    help="Parallel SimPoint replays per benchmark (default: 2)")
    ap.add_argument("--profile-timeout", type=int, default=1200)
    ap.add_argument("--rtl-timeout", type=int, default=1800)
    args = ap.parse_args(argv)

    selected = [b.strip() for b in args.benches.split(",") if b.strip()] or None
    discovered = spec_eval.discover_benchmarks(args.spec_root, args.label, args.size, selected)
    if not discovered:
        print(f"[spec_simpoint] no benchmarks found under {args.spec_root}", file=sys.stderr)
        return 2

    args.outdir.mkdir(parents=True, exist_ok=True)
    empty_rootfs = args.outdir / "empty-rootfs"
    empty_rootfs.mkdir(exist_ok=True)

    # Generate shared deterministic sampling DTB once.
    # Raptor's PLIC exposes sources 1..31 (nemu/src/device/intr.c:plic_sample_state
    # rejects plic_priority[32] != 0), so clamp riscv,ndev to 31 before packaging.
    platform_dir = args.outdir / "platform"
    dtb_path = platform_dir / "machine.dtb"
    if not dtb_path.exists():
        _run_step(
            [
                sys.executable, str(RAPTOR_HOME / "nemu/tools/nemu.py"), "run",
                "--emulator", str(args.nemu),
                "--firmware", str(args.firmware),
                "--dry-run", "--state-dir", str(platform_dir),
            ],
            args.outdir / "00-dtb.log",
            timeout=60,
        )
        _run_step(
            ["fdtput", "-t", "u", str(dtb_path), "/soc/plic@c000000", "riscv,ndev", "31"],
            args.outdir / "00-dtb-plic.log",
            timeout=30,
        )

    print(
        f"[spec_simpoint] {len(discovered)} benchmarks, length={args.length}, "
        f"interval={args.interval}, warmup={args.warmup}, kmax={args.kmax}, "
        f"workers={args.workers}"
    )

    rows: list[dict] = []
    with cf.ThreadPoolExecutor(max_workers=args.workers) as pool:
        futs = {
            pool.submit(
                run_benchmark, bench, run_dir, exe, b_argv,
                args, dtb_path, empty_rootfs,
            ): bench
            for bench, run_dir, exe, b_argv in discovered
        }
        for fut in cf.as_completed(futs):
            row = fut.result()
            rows.append(row)
            print(
                f"[spec_simpoint] {row['bench']:18s} status={row['status']} "
                f"pts={row.get('simpoints', '-')} rtl_ipc={row.get('rtl_ipc', '-')} "
                f"nemu_s={row.get('nemu_wall_s', '-')} rtl_s={row.get('rtl_wall_s', '-')}",
                flush=True,
            )

    rows.sort(key=lambda r: r["bench"])
    csv_path = args.outdir / "simpoint_summary.csv"
    cols = [
        "bench", "status", "simpoints", "rtl_complete", "rtl_ipc", "rtl_cpi",
        "rtl_est_insts", "rtl_est_cycles", "nemu_wall_s", "rtl_wall_s", "total_wall_s",
    ]
    with csv_path.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=cols, extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)
    print(f"[spec_simpoint] wrote {csv_path}")
    return 0 if all(r["status"] == "ok" for r in rows) else 1


if __name__ == "__main__":
    raise SystemExit(main())
