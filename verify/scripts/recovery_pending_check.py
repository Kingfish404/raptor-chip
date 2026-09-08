#!/usr/bin/env python3
"""Prove recovery-request ordering and report a generic logic-cost proxy.

The synthesis result uses no technology library. Cell count and topological
depth are structural proxies, not physical area or timing claims.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
DUT = ROOT / "hdl/backend/rapt_recovery_pending.sv"
REFERENCE = ROOT / "verify/formal/formal_recovery_pending.sv"


def run_yosys(command, log, timeout):
    with log.open("w") as stream:
        subprocess.run(
            ["yosys", "-Q", "-T", "-m", "slang", "-p", command],
            stdout=stream,
            stderr=subprocess.STDOUT,
            check=True,
            timeout=timeout,
            cwd=ROOT,
        )
    return log.read_text()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=["prove", "synth", "all"], default="all")
    parser.add_argument(
        "--output", type=Path, default=ROOT / "verify/build/recovery-pending"
    )
    parser.add_argument("--timeout", type=int, default=300)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)

    results = {
        "complete": False,
        "yosys_version": subprocess.check_output(["yosys", "-V"], text=True).strip(),
        "source_sha256": {
            str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in (DUT, REFERENCE)
        },
        "proofs": [],
        "generic_synthesis": [],
        "mapping": (
            "synth -noabc; abc -g simple; clean; stat; ltp -noff "
            "(no technology library)"
        ),
    }
    (args.output / "results.json").write_text(json.dumps(results, indent=2) + "\n")

    if args.mode in ("prove", "all"):
        for entries, ports in ((1, 1), (7, 3), (8, 5), (128, 5)):
            name = f"prove-{entries}-{ports}"
            command = (
                "read_slang --single-unit -DFORMAL --top formal_recovery_pending "
                f"-GEntries={entries} -GPorts={ports} -GXlen=8 {DUT} {REFERENCE}; "
                "select -assert-none t:$assert; chformal -assume -lower; "
                "prep -top formal_recovery_pending; flatten; memory_map; opt; "
                "sat -verify -tempinduct -seq 2 -maxsteps 4 -set-at 1 reset 1 "
                "-set-assumes -prove correct 1"
            )
            output = run_yosys(command, args.output / f"{name}.log", args.timeout)
            if "Induction step proven: SUCCESS!" not in output:
                raise RuntimeError(f"{name}: missing induction success marker")
            row = {"entries": entries, "ports": ports, "equivalent": True}
            results["proofs"].append(row)
            print(f"PASS: {name}", flush=True)

    if args.mode in ("synth", "all"):
        for entries in (64, 127, 128):
            for top, observed, sources in (
                ("rapt_recovery_pending", "full_transaction", (DUT,)),
                ("recovery_pending_fence_cost", "pending_only", (DUT, REFERENCE)),
            ):
                name = f"synth-{observed}-{entries}-5"
                command = (
                    f"read_slang --single-unit -DSYNTHESIS --top {top} "
                    f"-GEntries={entries} -GPorts=5 -GXlen=32 {' '.join(map(str, sources))}; "
                    "select -assert-none t:$check t:$assert t:$assume t:$cover; "
                    f"synth -top {top} -noabc; abc -g simple; clean; stat; ltp -noff"
                )
                output = run_yosys(command, args.output / f"{name}.log", args.timeout)
                cells = int(re.findall(r"^\s*(\d+) cells\s*$", output, re.M)[-1])
                depth = int(
                    re.findall(r"Longest topological path .*\(length=(\d+)\)", output)[-1]
                )
                row = {
                    "implementation": top,
                    "observed_outputs": observed,
                    "entries": entries,
                    "ports": 5,
                    "xlen": 32,
                    "generic_cells": cells,
                    "topological_depth": depth,
                }
                results["generic_synthesis"].append(row)
                print(json.dumps(row), flush=True)

    for path in (DUT, REFERENCE):
        if hashlib.sha256(path.read_bytes()).hexdigest() != results["source_sha256"][str(path.relative_to(ROOT))]:
            raise RuntimeError(f"source changed during recovery evaluation: {path}")
    results["complete"] = True
    (args.output / "results.json").write_text(json.dumps(results, indent=2) + "\n")


if __name__ == "__main__":
    main()
