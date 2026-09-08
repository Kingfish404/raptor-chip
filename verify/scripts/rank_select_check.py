#!/usr/bin/env python3
"""Prove rank-selection equivalence and compare generic gate cost/depth.

No technology library is used: these are logic proxies, never area in um^2 or
timing in ns. The reference circuit is verification-only, not a core option.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
SELECTOR = ROOT / "hdl/common/rapt_rank_select.sv"
REFERENCE = ROOT / "verify/formal/formal_rank_select.sv"


def run_yosys(command, log, timeout):
    with log.open("w") as stream:
        subprocess.run(["yosys", "-Q", "-T", "-m", "slang", "-p", command],
                       stdout=stream, stderr=subprocess.STDOUT, check=True,
                       timeout=timeout, cwd=ROOT)
    return log.read_text()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=["prove", "synth", "all"], default="all")
    parser.add_argument("--output", type=Path, default=ROOT / "verify/build/rank-select")
    parser.add_argument("--timeout", type=int, default=300)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    results = {
        "yosys_version": subprocess.check_output(["yosys", "-V"], text=True).strip(),
        "source_sha256": {str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
                          for path in [SELECTOR, REFERENCE]},
        "mapping": "synth -noabc; abc -g simple; clean; stat; ltp -noff (no technology library)",
        "proofs": [], "generic_synthesis": [],
    }
    if args.mode in ("prove", "all"):
        for entries, width in [(1, 1), (3, 4), (13, 3), (128, 1), (128, 2), (128, 3), (128, 4)]:
            name = f"prove-{entries}-{width}"
            command = (f"read_slang --single-unit --top formal_rank_select "
                       f"-GEntries={entries} -GNumSelect={width} {SELECTOR} {REFERENCE}; "
                       "select -assert-none t:$check t:$assert t:$assume t:$cover; "
                       "prep -top formal_rank_select; flatten; memory_map; opt; "
                       "sat -verify -prove equivalent 1 -set-def-inputs")
            output = run_yosys(command, args.output / f"{name}.log", args.timeout)
            if "SAT proof finished - no model found: SUCCESS!" not in output:
                raise RuntimeError(f"{name}: missing proof success marker")
            results["proofs"].append({"entries": entries, "width": width, "equivalent": True})
            print(f"PASS: {name}", flush=True)
    if args.mode in ("synth", "all"):
        for width in [1, 2, 3, 4]:
            for top, source in [("rank_select_reference", REFERENCE), ("rapt_rank_select", SELECTOR)]:
                name = f"synth-{top}-128-{width}"
                command = (f"read_slang --single-unit -DSYNTHESIS --top {top} "
                           f"-GEntries=128 -GNumSelect={width} {source}; "
                           "select -assert-none t:$check t:$assert t:$assume t:$cover; "
                           f"synth -top {top} -noabc; abc -g simple; clean; stat; ltp -noff")
                output = run_yosys(command, args.output / f"{name}.log", args.timeout)
                cells = int(re.findall(r"^\s*(\d+) cells\s*$", output, re.M)[-1])
                depth = int(re.findall(r"Longest topological path .*\(length=(\d+)\)", output)[-1])
                row = {"implementation": top, "entries": 128, "width": width,
                       "generic_cells": cells, "topological_depth": depth}
                results["generic_synthesis"].append(row)
                print(json.dumps(row), flush=True)
    (args.output / "results.json").write_text(json.dumps(results, indent=2) + "\n")


if __name__ == "__main__":
    main()
