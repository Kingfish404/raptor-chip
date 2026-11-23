#!/usr/bin/env python3
"""Integrated Raptor performance sweep & TMA/SPECrate report generator.

Supports two subcommands:
  embench  Run CoreMark + all 19 Embench-IoT benchmarks across RTL presets
           using gem5 SE (sim/gsim/raptor_se.py) and write summary.csv.
  report   Aggregate CoreMark/Embench, SPEC CPU 2017/2026 (gem5), and RTL
           SimPoint (results.json + PMU TMA) under --eval-root into Markdown
           tables and JSON.
"""

from __future__ import annotations

import argparse
import concurrent.futures as cf
import csv
import json
import math
import os
import subprocess
import sys
import time
from pathlib import Path

GSIM_DIR = Path(__file__).resolve().parent
RAPTOR_HOME = Path(os.environ.get("RAPTOR_HOME", GSIM_DIR.parents[1]))

sys.path.insert(0, str(GSIM_DIR))
import summarize_stats

DEFAULT_PRESETS = ("default", "default-w3", "default-w4", "default-cache", "default-l2")

EMBENCH_BENCHES = (
    "aha-mont64", "crc32", "cubic", "edn", "huffbench", "matmult-int",
    "md5sum", "minver", "nbody", "nettle-aes", "nettle-sha256", "nsichneu",
    "picojpeg", "primecount", "qrduino", "sglib-combined", "slre", "st",
    "statemate", "tarfind", "ud", "wikisort",
)

SPEC2017_INT_BENCHES = (
    "500.perlbench_r", "502.gcc_r", "505.mcf_r", "520.omnetpp_r",
    "523.xalancbmk_r", "525.x264_r", "531.deepsjeng_r", "541.leela_r",
    "548.exchange2_r", "557.xz_r",
)

# Official SPEC CPU 2017 refrate reference times (seconds, Sun Fire V490).
SPEC2017_REFTIME_S = {
    "500.perlbench_r": 1592.0,
    "502.gcc_r": 1416.0,
    "505.mcf_r": 1616.0,
    "520.omnetpp_r": 1312.0,
    "523.xalancbmk_r": 1056.0,
    "525.x264_r": 1752.0,
    "531.deepsjeng_r": 1146.0,
    "541.leela_r": 1656.0,
    "548.exchange2_r": 2620.0,
    "557.xz_r": 1080.0,
}

# Typical refrate dynamic instruction counts (trillions) for rough Rate/GHz
# positioning estimates (not an official SPEC submission).
SPEC2017_REF_INST_T = {
    "500.perlbench_r": 2.45,
    "502.gcc_r": 1.35,
    "505.mcf_r": 0.90,
    "520.omnetpp_r": 1.60,
    "523.xalancbmk_r": 1.95,
    "525.x264_r": 3.70,
    "531.deepsjeng_r": 1.70,
    "541.leela_r": 1.90,
    "548.exchange2_r": 2.85,
    "557.xz_r": 1.85,
}


SPEC2017_FP_REFTIME_S = {
    "503.bwaves_r": 10028.0,
    "507.cactuBSSN_r": 1266.0,
    "508.namd_r": 950.0,
    "510.parest_r": 2616.0,
    "511.povray_r": 2335.0,
    "519.lbm_r": 1054.0,
    "521.wrf_r": 2240.0,
    "526.blender_r": 1523.0,
    "527.cam4_r": 1749.0,
    "538.imagick_r": 2487.0,
    "544.nab_r": 1683.0,
    "549.fotonik3d_r": 3897.0,
    "554.roms_r": 1589.0,
}

SPEC2017_FP_REF_INST_T = {
    "503.bwaves_r": 9.90,
    "507.cactuBSSN_r": 2.40,
    "508.namd_r": 2.10,
    "510.parest_r": 4.20,
    "511.povray_r": 3.50,
    "519.lbm_r": 1.35,
    "521.wrf_r": 3.80,
    "526.blender_r": 2.30,
    "527.cam4_r": 2.80,
    "538.imagick_r": 5.50,
    "544.nab_r": 2.60,
    "549.fotonik3d_r": 4.10,
    "554.roms_r": 2.80,
}


def geomean(values: list[float]) -> float:
    pos = [v for v in values if v and v > 0.0]
    if not pos:
        return 0.0
    return math.exp(sum(math.log(v) for v in pos) / len(pos))


def detect_pipeline_width(run_dir: Path, default_width: int = 2) -> int:
    eff = run_dir / "raptor_se_effective.json"
    if eff.exists():
        try:
            data = json.loads(eff.read_text())
            return int(data.get("uarch", {}).get("rename_w", default_width))
        except (OSError, ValueError, TypeError):
            pass
    return default_width


def _estimate_specrate(
    ipc_by_bench: dict[str, float],
    reftimes: dict[str, float],
    ref_insts_t: dict[str, float],
) -> tuple[float, int]:
    ratios: list[float] = []
    for bench, reftime in reftimes.items():
        ipc = ipc_by_bench.get(bench)
        ref_t = ref_insts_t.get(bench)
        if not ipc or ipc <= 0.0 or not ref_t:
            continue
        est_sec_1ghz = (ref_t * 1e12) / (ipc * 1e9)
        ratios.append(reftime / est_sec_1ghz)
    return geomean(ratios), len(ratios)


def estimate_specrate2017_int_per_ghz(ipc_by_bench: dict[str, float]) -> tuple[float, int]:
    """Return (estimated SPECrate2017_int/GHz, benchmark_count)."""
    return _estimate_specrate(ipc_by_bench, SPEC2017_REFTIME_S, SPEC2017_REF_INST_T)


def estimate_specrate2017_fp_per_ghz(ipc_by_bench: dict[str, float]) -> tuple[float, int]:
    """Return (estimated SPECrate2017_fp/GHz, benchmark_count)."""
    return _estimate_specrate(ipc_by_bench, SPEC2017_FP_REFTIME_S, SPEC2017_FP_REF_INST_T)


def compute_rtl_pmu_tma(
    plan: dict, results: dict
) -> dict[str, float | int | bool]:
    """Compute weighted RTL IPC, coverage, and Level-1 TMA from RTL PMU."""
    points = (plan.get("regions") or [{}])[0].get("points") or []
    wmap = {p["id"]: float(p["weight"]) for p in points}
    w_sum = 0.0
    w_cpi = 0.0
    w_ret = w_bs = w_fe = w_be = 0.0
    w_bp_tot = w_bp_fail = 0.0
    passed = 0

    for meas in results.get("measurements") or []:
        if not meas.get("passed"):
            continue
        pid = meas.get("id")
        if pid not in wmap:
            continue
        w = wmap[pid]
        insts = float(meas.get("instructions") or 0.0)
        cycles = float(meas.get("cycles") or 0.0)
        if insts <= 0.0 or cycles <= 0.0:
            continue
        w_sum += w
        w_cpi += w * (cycles / insts)
        passed += 1

        pmu = meas.get("pmu") or {}
        cap = float(pmu.get("dispatch_capacity") or 0.0)
        if cap > 0.0:
            icnt = float(pmu.get("instr_cnt") or insts)
            d_acc = float(pmu.get("dispatch_accepted") or icnt)
            d_emp = float(pmu.get("dispatch_unfilled_empty") or 0.0)
            d_fls = float(pmu.get("dispatch_unfilled_flush") or 0.0)
            d_rec = float(pmu.get("dispatch_unfilled_recovery") or 0.0)
            ret = icnt / cap * 100.0
            fe = d_emp / cap * 100.0
            bad = max(0.0, (d_acc - icnt + d_fls + d_rec) / cap * 100.0)
            be = max(0.0, 100.0 - ret - fe - bad)
            w_ret += w * ret
            w_bs += w * bad
            w_fe += w * fe
            w_be += w * be
        w_bp_tot += w * float(pmu.get("bpu_cnt") or 0.0)
        w_bp_fail += w * float(pmu.get("bpu_fail_cnt") or 0.0)

    ipc = (w_sum / w_cpi) if w_cpi > 0.0 else 0.0
    bp_acc = (1.0 - w_bp_fail / w_bp_tot) * 100.0 if w_bp_tot > 0.0 else 0.0
    denom = w_sum if w_sum > 0.0 else 1.0
    return {
        "passed": passed,
        "total": len(wmap),
        "coverage_pct": round(w_sum * 100.0, 1),
        "rtl_ipc": round(ipc, 4),
        "tma_ret_pct": round(w_ret / denom, 1),
        "tma_bad_pct": round(w_bs / denom, 1),
        "tma_fe_pct": round(w_fe / denom, 1),
        "tma_be_pct": round(w_be / denom, 1),
        "bp_acc_pct": round(bp_acc, 2),
        "complete": bool(results.get("complete", False)),
    }


def _default_gem5() -> Path:
    return RAPTOR_HOME / "third_party/gem5/build/RISCV/gem5.opt"


def _run_embench_one(
    gem5: Path, preset: str, bench: str, outdir: Path, split_iq: bool
) -> dict[str, str]:
    run_dir = outdir / preset / bench
    run_dir.mkdir(parents=True, exist_ok=True)
    bench_arg = bench if bench == "coremark" else f"embench-{bench}"
    cmd = [
        str(gem5),
        f"--outdir={run_dir}",
        str(GSIM_DIR / "raptor_se.py"),
        "--preset", preset,
        "--rv64",
        "--rtl-execution-resources",
        "--benchmark", bench_arg,
    ]
    if bench == "coremark":
        cmd.append("--options=0;0;0x66;10")
    if split_iq:
        cmd.append("--rtl-split-iq")
    t0 = time.monotonic()
    proc = subprocess.run(cmd, capture_output=True, text=True)
    (run_dir / "run.log").write_text(proc.stdout + proc.stderr)
    wall = round(time.monotonic() - t0, 2)
    stats_path = run_dir / "stats.txt"
    if proc.returncode != 0 or not stats_path.exists():
        return {"preset": preset, "bench": bench, "status": f"rc={proc.returncode}",
                "wall_s": str(wall)}
    raw = summarize_stats.parse_stats(stats_path)
    pipe_w = detect_pipeline_width(run_dir)
    der = summarize_stats.derive(raw, pipeline_width=pipe_w)
    cm_mhz = ""
    if bench == "coremark" and raw.get("system.cpu.numCycles"):
        cyc = float(raw["system.cpu.numCycles"])
        if cyc > 0:
            cm_mhz = f"{10.0 * 1e6 / cyc:.3f}"
    return {
        "preset": preset,
        "bench": bench,
        "status": "ok",
        "wall_s": str(wall),
        "ipc": raw.get("system.cpu.ipc", ""),
        "cm_per_mhz": cm_mhz,
        "tma_ret": der.get("tma_retiring_pct", ""),
        "tma_bad": der.get("tma_bad_spec_pct", ""),
        "tma_fe": der.get("tma_frontend_pct", ""),
        "tma_be": der.get("tma_backend_pct", ""),
    }


def cmd_embench(args: argparse.Namespace) -> int:
    presets = [p.strip() for p in args.presets.split(",") if p.strip()]
    benches = ["coremark"] + list(EMBENCH_BENCHES)
    if args.benches:
        benches = [b.strip() for b in args.benches.split(",") if b.strip()]
    args.outdir.mkdir(parents=True, exist_ok=True)
    jobs = [(pr, b) for pr in presets for b in benches]
    rows: list[dict[str, str]] = []
    with cf.ThreadPoolExecutor(max_workers=args.workers) as pool:
        futs = {
            pool.submit(
                _run_embench_one, args.gem5, pr, b, args.outdir, args.rtl_split_iq
            ): (pr, b)
            for pr, b in jobs
        }
        for fut in cf.as_completed(futs):
            row = fut.result()
            rows.append(row)
            print(
                f"[embench] {row['preset']:14s} {row['bench']:16s} "
                f"status={row['status']} ipc={row.get('ipc', '-')}"
            )
    rows.sort(key=lambda r: (presets.index(r["preset"]), benches.index(r["bench"])))
    cols = [
        "preset", "bench", "status", "wall_s", "ipc", "cm_per_mhz",
        "tma_ret", "tma_bad", "tma_fe", "tma_be",
    ]
    csv_path = args.outdir / "summary.csv"
    with csv_path.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=cols)
        w.writeheader()
        w.writerows(rows)
    print(f"[embench] wrote {csv_path}")
    return 0


def _load_spec_dir(spec_dir: Path) -> dict[str, dict[str, float]]:
    out: dict[str, dict[str, float]] = {}
    if not spec_dir.exists():
        return out
    for stats_path in sorted(spec_dir.glob("*/stats.txt")):
        bench = stats_path.parent.name
        raw = summarize_stats.parse_stats(stats_path)
        pipe_w = detect_pipeline_width(stats_path.parent)
        der = summarize_stats.derive(raw, pipeline_width=pipe_w)
        ipc_s = raw.get("system.cpu.ipc")
        if not ipc_s:
            continue
        out[bench] = {
            "width": float(pipe_w),
            "ipc": float(ipc_s),
            "ret": float(der.get("tma_retiring_pct") or 0.0),
            "bad": float(der.get("tma_bad_spec_pct") or 0.0),
            "fe": float(der.get("tma_frontend_pct") or 0.0),
            "be": float(der.get("tma_backend_pct") or 0.0),
        }
    return out


def cmd_report(args: argparse.Namespace) -> int:
    presets = [p.strip() for p in args.presets.split(",") if p.strip()]
    root = args.eval_root
    report_data: dict[str, object] = {}

    for suite in ("2017", "2026"):
        suite_data: dict[str, dict[str, dict[str, float]]] = {}
        for pr in presets:
            sdir = root / f"gem5-{suite}-{args.tag}-{pr}"
            loaded = _load_spec_dir(sdir)
            if loaded:
                suite_data[pr] = loaded
        if not suite_data:
            continue
        report_data[f"spec{suite}"] = {}
        print(f"\n## SPEC CPU {suite} ({args.tag}) Multi-Preset Summary\n")
        common = sorted(
            set.intersection(*(set(d.keys()) for d in suite_data.values()))
        )
        hdr = "| Preset | N | Geomean IPC | Retiring | BadSpec | Frontend | Backend |"
        sep = "|---|---:|---:|---:|---:|---:|---:|"
        if suite == "2017":
            hdr += " Est. Rate_int/GHz | Est. Rate_fp/GHz |"
            sep += "---:|---:|"
        print(hdr)
        print(sep)
        for pr in presets:
            if pr not in suite_data:
                continue
            d = suite_data[pr]
            gm = geomean([d[b]["ipc"] for b in common])
            n = len(common)
            ret = sum(d[b]["ret"] for b in common) / n
            bad = sum(d[b]["bad"] for b in common) / n
            fe = sum(d[b]["fe"] for b in common) / n
            be = sum(d[b]["be"] for b in common) / n
            line = (
                f"| `{pr}` | {n} | {gm:.4f} | {ret:.1f}% | {bad:.1f}% | "
                f"{fe:.1f}% | {be:.1f}% |"
            )
            entry = {
                "n": n, "geomean_ipc": round(gm, 4),
                "tma_ret": round(ret, 1), "tma_bad": round(bad, 1),
                "tma_fe": round(fe, 1), "tma_be": round(be, 1),
            }
            if suite == "2017":
                ipc_map = {b: d[b]["ipc"] for b in common}
                r_int, n_int = estimate_specrate2017_int_per_ghz(ipc_map)
                r_fp, n_fp = estimate_specrate2017_fp_per_ghz(ipc_map)
                line += f" ~{r_int:.3f} ({n_int}) | ~{r_fp:.3f} ({n_fp}) |"
                entry["est_specrate2017_int_per_ghz"] = round(r_int, 3)
                entry["est_specrate2017_fp_per_ghz"] = round(r_fp, 3)
            print(line)
            report_data[f"spec{suite}"][pr] = entry

    # Scan SimPoint RTL directories if present.
    sp_dirs = sorted(root.glob("simpoint*"))
    if sp_dirs:
        print("\n## RTL SimPoint Summary\n")
        print(
            "| Suite Dir | Benchmark | Passed | Weight Cov | RTL IPC | "
            "TMA (Ret/BS/FE/BE %) | BP Acc |"
        )
        print("|---|---|---:|---:|---:|---|---:|")
        for sdir in sp_dirs:
            for plan_p in sorted(sdir.glob("*/plan.json")):
                res_p = plan_p.parent / "rtl-eval" / "results.json"
                if not res_p.exists():
                    continue
                summary = compute_rtl_pmu_tma(
                    json.loads(plan_p.read_text()),
                    json.loads(res_p.read_text()),
                )
                print(
                    f"| `{sdir.name}` | `{plan_p.parent.name}` | "
                    f"{summary['passed']}/{summary['total']} | "
                    f"{summary['coverage_pct']:.1f}% | "
                    f"{summary['rtl_ipc']:.4f} | "
                    f"{summary['tma_ret_pct']}/{summary['tma_bad_pct']}/"
                    f"{summary['tma_fe_pct']}/{summary['tma_be_pct']} | "
                    f"{summary['bp_acc_pct']:.2f}% |"
                )

    if args.json_out:
        args.json_out.parent.mkdir(parents=True, exist_ok=True)
        args.json_out.write_text(json.dumps(report_data, indent=2) + "\n")
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_em = sub.add_parser("embench", help="Run CoreMark + Embench-IoT sweep")
    p_em.add_argument("--outdir", required=True, type=Path)
    p_em.add_argument("--presets", default=",".join(DEFAULT_PRESETS))
    p_em.add_argument("--benches", default="")
    p_em.add_argument("--rtl-split-iq", action="store_true")
    p_em.add_argument("--workers", type=int, default=8)
    p_em.add_argument("--gem5", type=Path, default=_default_gem5())
    p_em.set_defaults(func=cmd_embench)

    p_rep = sub.add_parser("report", help="Aggregate gem5 & RTL results")
    p_rep.add_argument("--eval-root", required=True, type=Path)
    p_rep.add_argument("--presets", default=",".join(DEFAULT_PRESETS))
    p_rep.add_argument("--tag", default="50m")
    p_rep.add_argument("--json-out", type=Path, default=None)
    p_rep.set_defaults(func=cmd_report)

    args = ap.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
