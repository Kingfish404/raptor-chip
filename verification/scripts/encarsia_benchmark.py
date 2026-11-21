#!/usr/bin/env python3
"""
Encarsia-style (ETH Zurich 2025) automated RTL mutation benchmark.

Discovers AST/token-level candidate mutations across Raptor RTL modules using
`ast_mutator.py`, evaluates each mutant against the corresponding formal
verification harness (`rIC3` IC3/PDR or `rtlcheck_formal.py` Bitwuzla SMT),
and reports quantitative Kill Rate (Killed / Survived / Error).
"""

import argparse
import concurrent.futures
import json
import os
import shutil
import subprocess
import time
from pathlib import Path

from ast_mutator import apply_candidate, discover_mutations, sha256_text

ROOT = Path(__file__).resolve().parents[2]
OSS_CAD_BIN = ROOT / "third_party/oss-cad-suite/bin"

TARGETS = {
    "sq_forward": {
        "dut": ROOT / "rtl/core/backend/lsu/rapt_sq_forward.sv",
        "top": "formal_rtlcheck_lsu",
        "sources": [
            ROOT / "rtl/rapt_pkg.sv",
            None,  # replaced by mutant
            ROOT / "verification/formal/formal_rtlcheck_lsu.sv",
        ],
        "includes": [ROOT / "rtl/configs/formal", ROOT / "rtl/include"],
        "defines": ["FORMAL", "SYNTHESIS"],
        "backend": "smtbmc",
    },
    "plru": {
        "dut": ROOT / "rtl/core/memory/replacement/rapt_cache_plru.sv",
        "top": "formal_plru",
        "sources": [None, ROOT / "verification/formal/formal_plru.sv"],
        "includes": [ROOT / "rtl/configs/formal", ROOT / "rtl/include"],
        "defines": ["FORMAL"],
        "backend": "ric3",
    },
    "cache_nru": {
        "dut": ROOT / "rtl/core/memory/replacement/rapt_cache_nru.sv",
        "top": "formal_cache_nru",
        "sources": [None, ROOT / "verification/formal/formal_cache_nru.sv"],
        "includes": [ROOT / "rtl/configs/formal", ROOT / "rtl/include"],
        "defines": ["FORMAL"],
        "backend": "ric3",
    },
}


def find_yosys(explicit: str) -> str:
    return explicit or os.environ.get("RAPTOR_YOSYS_REAL") or shutil.which("yosys") or "yosys"


def find_ric3(explicit: str) -> str:
    return explicit or os.environ.get("RIC3") or shutil.which("ric3") or "ric3"


def eval_mutant(
    target_name: str,
    spec: dict,
    cand,
    orig_text: str,
    out_dir: Path,
    yosys: str,
    ric3: str,
    timeout: int,
):
    mdir = out_dir / target_name / cand.mutation_id
    mdir.mkdir(parents=True, exist_ok=True)
    mpath = mdir / spec["dut"].name
    mpath.write_text(apply_candidate(orig_text, cand))

    srcs = [mpath if s is None else s for s in spec["sources"]]
    inc_flags = " ".join(f"-I{d}" for d in spec["includes"])
    def_flags = " ".join(f"-D{d}" for d in spec["defines"])
    src_list = " ".join(str(s) for s in srcs)
    top = spec["top"]

    t0 = time.monotonic()
    env = os.environ.copy()
    if OSS_CAD_BIN.is_dir():
        env["PATH"] = f"{OSS_CAD_BIN}:{env.get('PATH', '')}"

    if spec["backend"] == "ric3":
        btor = mdir / "model.btor2"
        ys = mdir / "emit.ys"
        ys.write_text(
            "\n".join(
                [
                    "plugin -i slang",
                    f"read_slang --threads 1 --single-unit --top {top} {def_flags} {inc_flags} {src_list}",
                    f"prep -top {top} -flatten",
                    "async2sync",
                    "memory_map",
                    "opt -fast",
                    "dffunmap",
                    "setundef -undriven -anyseq",
                    "chformal -assume -early",
                    "chformal -live -fair -cover -remove",
                    "opt_clean",
                    f"write_btor -s {btor}",
                    "",
                ]
            )
        )
        yproc = subprocess.run([yosys, "-Q", "-T", "-s", str(ys)], capture_output=True, text=True)
        if yproc.returncode != 0 or not btor.exists():
            return {"id": cand.mutation_id, "line": cand.line, "kind": cand.kind, "outcome": "COMPILE_ERR"}
        try:
            rproc = subprocess.run(
                [ric3, "check", "--ui", "false", str(btor), "ic3"],
                capture_output=True,
                text=True,
                timeout=timeout,
            )
            out = rproc.stdout + "\n" + rproc.stderr
            last = out.strip().splitlines()[-1].strip().upper() if out.strip() else ""
            if last == "SAT" or "RESULT: SAT" in out or rproc.returncode == 10:
                outcome = "KILLED"
            elif last == "UNSAT" or "RESULT: UNSAT" in out or rproc.returncode == 20:
                outcome = "SURVIVED"
            else:
                outcome = f"UNKNOWN({rproc.returncode})"
        except subprocess.TimeoutExpired:
            outcome = "TIMEOUT"
    else:
        smt2 = mdir / "model.smt2"
        ys = mdir / "emit.ys"
        ys.write_text(
            "\n".join(
                [
                    "plugin -i slang",
                    f"read_slang --threads 1 --single-unit --top {top} {def_flags} {inc_flags} {src_list}",
                    f"prep -top {top} -flatten",
                    "async2sync",
                    "opt -fast",
                    "chformal -assume -early",
                    "chformal -live -fair -cover -remove",
                    "setundef -undriven -anyseq",
                    "dffunmap",
                    f"write_smt2 -wires {smt2}",
                    "",
                ]
            )
        )
        yproc = subprocess.run([yosys, "-Q", "-T", "-s", str(ys)], capture_output=True, text=True)
        if yproc.returncode != 0 or not smt2.exists():
            return {"id": cand.mutation_id, "line": cand.line, "kind": cand.kind, "outcome": "COMPILE_ERR"}
        smtbmc = str(OSS_CAD_BIN / "yosys-smtbmc") if (OSS_CAD_BIN / "yosys-smtbmc").exists() else "yosys-smtbmc"
        try:
            sproc = subprocess.run(
                [smtbmc, "-s", "bitwuzla", "--presat", "--noprogress", "-t", "1", str(smt2)],
                env=env,
                capture_output=True,
                text=True,
                timeout=timeout,
            )
            out = sproc.stdout + sproc.stderr
            if "Status: FAILED" in out and "Assert failed" in out:
                outcome = "KILLED"
            elif "Status: PASSED" in out:
                outcome = "SURVIVED"
            else:
                outcome = f"UNKNOWN({sproc.returncode})"
        except subprocess.TimeoutExpired:
            outcome = "TIMEOUT"

    return {
        "id": cand.mutation_id,
        "line": cand.line,
        "kind": cand.kind,
        "original": cand.original,
        "replacement": cand.replacement,
        "outcome": outcome,
        "sec": round(time.monotonic() - t0, 2),
    }


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Encarsia-style automated RTL mutation benchmark")
    parser.add_argument("--targets", nargs="+", default=list(TARGETS.keys()), choices=list(TARGETS.keys()))
    parser.add_argument("--limit-per-target", type=int, default=12)
    parser.add_argument("--jobs", type=int, default=8)
    parser.add_argument("--timeout", type=int, default=60)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--yosys", default="")
    parser.add_argument("--ric3", default="")
    args = parser.parse_args(argv)

    yosys = find_yosys(args.yosys)
    ric3 = find_ric3(args.ric3)
    args.output.mkdir(parents=True, exist_ok=True)

    report = {"targets": {}, "totals": {"evaluated": 0, "killed": 0, "survived": 0, "other": 0}}
    for tname in args.targets:
        spec = TARGETS[tname]
        orig = spec["dut"].read_text()
        cands = discover_mutations(orig, limit=args.limit_per_target)
        with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as ex:
            rows = list(
                ex.map(
                    lambda c: eval_mutant(tname, spec, c, orig, args.output, yosys, ric3, args.timeout),
                    cands,
                )
            )
        killed = sum(1 for r in rows if r["outcome"] == "KILLED")
        survived = sum(1 for r in rows if r["outcome"] == "SURVIVED")
        other = len(rows) - killed - survived
        denom = killed + survived
        rate = round(100.0 * killed / denom, 1) if denom else 0.0
        report["targets"][tname] = {
            "dut": str(spec["dut"].relative_to(ROOT)),
            "dut_sha256": sha256_text(orig),
            "evaluated": len(rows),
            "killed": killed,
            "survived": survived,
            "other": other,
            "kill_rate_pct": rate,
            "mutants": rows,
        }
        report["totals"]["evaluated"] += len(rows)
        report["totals"]["killed"] += killed
        report["totals"]["survived"] += survived
        report["totals"]["other"] += other
        print(
            f"[encarsia] {tname}: evaluated={len(rows)} killed={killed} "
            f"survived={survived} other={other} kill_rate={rate}%"
        )

    tot = report["totals"]
    denom = tot["killed"] + tot["survived"]
    tot["kill_rate_pct"] = round(100.0 * tot["killed"] / denom, 1) if denom else 0.0
    (args.output / "encarsia_report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(
        f"[encarsia] TOTAL: evaluated={tot['evaluated']} killed={tot['killed']} "
        f"survived={tot['survived']} other={tot['other']} kill_rate={tot['kill_rate_pct']}%"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
