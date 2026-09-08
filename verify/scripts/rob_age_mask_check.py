#!/usr/bin/env python3
"""Prove the recovery age mask and compare standalone generic mapped cones."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
DUT = ROOT / "hdl/backend/rapt_rob_age_mask.sv"
REF = ROOT / "verify/formal/formal_rob_age_mask.sv"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "verify/build/rob-age-mask")
    parser.add_argument("--mode", choices=("prove", "synth", "all"), default="all")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    report = {"complete": False, "mode": args.mode, "cases": []}

    def save():
        (args.output / "results.json").write_text(json.dumps(report, indent=2) + "\n")

    save()
    sources = (DUT, REF, Path(__file__).resolve())
    report["source_sha256"] = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                               for p in sources}
    report["yosys_version"] = subprocess.check_output(["yosys", "-V"], text=True).strip()
    save()

    def run(name, command):
        (args.output / f"{name}.ys").write_text(command + "\n")
        with (args.output / f"{name}.log").open("w") as stream:
            subprocess.run(["yosys", "-Q", "-T", "-m", "slang", "-p", command],
                           cwd=ROOT, stdout=stream, stderr=subprocess.STDOUT,
                           check=True, timeout=300)
        return (args.output / f"{name}.log").read_text()

    if args.mode in ("prove", "all"):
        for entries in (1, 7, 8, 64, 127, 128):
            name = f"prove-{entries}"
            output = run(name, f"read_slang --single-unit --top formal_rob_age_mask "
                         f"-GEntries={entries} {DUT} {REF}; chformal -assume -lower; "
                         "prep -top formal_rob_age_mask -flatten; opt; "
                         "sat -verify -set-assumes -prove correct 1")
            if "SAT proof finished - no model found: SUCCESS!" not in output:
                raise RuntimeError(f"missing proof success: {name}")
            report["cases"].append({"name": name, "equivalent": True})
            save()
            print(f"PASS: {name}", flush=True)

    if args.mode in ("synth", "all"):
        for entries in (7, 64, 127, 128):
            for top in ("rob_age_mask_reference", "rapt_rob_age_mask"):
                name = f"synth-{entries}-{top}"
                output = run(name, f"read_slang --single-unit -DSYNTHESIS --top {top} "
                             f"-GEntries={entries} {DUT} {REF}; "
                             "select -assert-none t:$check t:$assert t:$assume t:$cover; "
                             f"synth -top {top} -noabc; abc -g simple; clean; stat; ltp -noff")
                cells = int(re.findall(r"^\s*(\d+) cells\s*$", output, re.M)[-1])
                depth = int(re.findall(r"Longest topological path .*\(length=(\d+)\)", output)[-1])
                row = {"name": name, "entries": entries, "top": top,
                       "generic_cells": cells, "topological_depth": depth}
                report["cases"].append(row)
                save()
                print(json.dumps(row), flush=True)
    for p in sources:
        if hashlib.sha256(p.read_bytes()).hexdigest() != report["source_sha256"][str(p.relative_to(ROOT))]:
            raise RuntimeError(f"source changed during evaluation: {p}")
    report["complete"] = True
    save()


if __name__ == "__main__":
    main()
