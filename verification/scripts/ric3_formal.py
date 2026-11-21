#!/usr/bin/env python3
"""
rIC3 (HWMCC 2024/2025 champion IC3/PDR engine) formal verification driver.

Lowers a SystemVerilog formal harness via Yosys-Slang to BTOR2 and proves all
safety properties with rIC3 (unbounded IC3/PDR or portfolio mode).
"""

import argparse
import json
import os
import shutil
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def find_yosys(explicit):
    if explicit:
        return explicit
    return os.environ.get("RAPTOR_YOSYS_REAL") or shutil.which("yosys") or "yosys"


def find_ric3(explicit):
    if explicit:
        return explicit
    return os.environ.get("RIC3") or shutil.which("rIC3") or "rIC3"


def build_btor2(yosys, top, sources, include_dirs, defines, out_dir):
    out_dir.mkdir(parents=True, exist_ok=True)
    btor_path = out_dir / f"{top}.btor2"
    ys_path = out_dir / f"{top}.ys"
    log_path = out_dir / "yosys_btor2.log"

    inc_flags = " ".join(f"-I{d}" for d in include_dirs)
    def_flags = " ".join(f"-D{d}" for d in defines)
    src_list = " ".join(str(s) for s in sources)

    script = "\n".join(
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
            f"write_btor -s {btor_path}",
            "",
        ]
    )
    ys_path.write_text(script)
    t0 = time.monotonic()
    with log_path.open("w") as lf:
        proc = subprocess.run(
            [yosys, "-Q", "-T", "-s", str(ys_path)],
            stdout=lf,
            stderr=subprocess.STDOUT,
        )
    elapsed = round(time.monotonic() - t0, 2)
    if proc.returncode != 0 or not btor_path.exists():
        raise RuntimeError(f"Yosys BTOR2 export failed (rc={proc.returncode}), see {log_path}")
    return btor_path, elapsed


def run_ric3(ric3, btor_path, out_dir, engine, timeout):
    log_path = out_dir / "ric3.log"
    cmd = [ric3, "check", "--ui", "false", str(btor_path), engine or "ic3"]

    t0 = time.monotonic()
    status = "ERROR"
    rc = -1
    try:
        with log_path.open("w") as lf:
            proc = subprocess.run(
                cmd,
                stdout=lf,
                stderr=subprocess.STDOUT,
                timeout=timeout,
            )
        rc = proc.returncode
        text = log_path.read_text(errors="replace")
        # rIC3 prints "RESULT: UNSAT" (safe/proved) or "RESULT: SAT" (counterexample)
        if "RESULT: UNSAT" in text or "unsat" in text.lower().splitlines()[-1:]:
            status = "PROVED"
        elif "RESULT: SAT" in text or "sat" in text.lower().splitlines()[-1:]:
            status = "COUNTEREXAMPLE"
        elif rc == 20:
            status = "PROVED"
        elif rc == 10:
            status = "COUNTEREXAMPLE"
        else:
            status = f"UNKNOWN(rc={rc})"
    except subprocess.TimeoutExpired:
        status = "TIMEOUT"
    elapsed = round(time.monotonic() - t0, 2)
    return status, rc, elapsed, str(log_path)


def main():
    parser = argparse.ArgumentParser(description="Run rIC3 unbounded proof via Yosys-Slang BTOR2")
    parser.add_argument("--top", required=True, help="Top formal harness module")
    parser.add_argument("--sources", nargs="+", required=True, help="SystemVerilog source files")
    parser.add_argument("--include", "-I", nargs="*", default=[], help="Include directories")
    parser.add_argument("--define", "-D", nargs="*", default=[], help="Preprocessor defines")
    parser.add_argument("--output", required=True, help="Output directory")
    parser.add_argument("--engine", default="ic3", help="rIC3 engine (ic3|kind|bmc|portfolio)")
    parser.add_argument("--timeout", type=int, default=300, help="Solver timeout in seconds")
    parser.add_argument("--yosys", default="", help="Path to Yosys with slang plugin")
    parser.add_argument("--ric3", default="", help="Path to rIC3 executable")
    args = parser.parse_args()

    yosys = find_yosys(args.yosys)
    ric3 = find_ric3(args.ric3)
    out_dir = Path(args.output).resolve()
    sources = [Path(s).resolve() for s in args.sources]
    includes = [Path(d).resolve() for d in args.include]

    btor_path, btor_sec = build_btor2(yosys, args.top, sources, includes, args.define, out_dir)
    status, rc, solve_sec, log_path = run_ric3(ric3, btor_path, out_dir, args.engine, args.timeout)

    summary = {
        "top": args.top,
        "engine": args.engine,
        "status": status,
        "rc": rc,
        "btor2_sec": btor_sec,
        "solve_sec": solve_sec,
        "btor2": str(btor_path),
        "log": log_path,
    }
    (out_dir / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(f"[rIC3] {args.top}: {status} (btor2={btor_sec}s, solve={solve_sec}s)")
    return 0 if status == "PROVED" else 1


if __name__ == "__main__":
    raise SystemExit(main())
