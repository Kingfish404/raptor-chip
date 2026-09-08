#!/usr/bin/env python3
"""Prove issue-selection contracts and measure generic logic cost, not Fmax."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
SELECTOR = ROOT / "hdl/common/rapt_issue_select.sv"
FORMAL = ROOT / "verify/formal/formal_issue_select.sv"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=["prove", "synth", "all"], default="all")
    parser.add_argument("--output", type=Path, default=ROOT / "verify/build/issue-select")
    parser.add_argument("--timeout", type=int, default=300)
    parser.add_argument("--matrix", choices=["baseline", "port-scaling"], default="baseline",
                        help="port-scaling holds Entries=16 while varying Ports")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    report = args.output / "results.json"
    report.write_text(json.dumps({"complete": False}) + "\n")
    results = {
        "complete": False, "mode": args.mode, "matrix": args.matrix,
        "yosys_version": subprocess.check_output(["yosys", "-V"], text=True).strip(),
        "source_sha256": {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                          for p in [SELECTOR, FORMAL]},
        "mapping": "synth -noabc; abc -g simple; clean; stat; ltp -noff (no technology library)",
        "proofs": [], "generic_synthesis": [],
    }

    def run(name, commands):
        with (args.output / f"{name}.log").open("w") as stream:
            subprocess.run(["yosys", "-Q", "-T", "-m", "slang", "-p", commands],
                           stdout=stream, stderr=subprocess.STDOUT, check=True,
                           timeout=args.timeout, cwd=ROOT)
        return (args.output / f"{name}.log").read_text()

    def save():
        report.write_text(json.dumps(results, indent=2) + "\n")

    save()

    if args.mode in ("prove", "all"):
        for entries, ports, ordered in [(1, 1, 0), (4, 2, 0), (4, 3, 0), (4, 3, 1), (7, 4, 0)]:
            name = f"prove-{entries}-{ports}-{ordered}"
            commands = (f"read_slang --single-unit --top formal_issue_select "
                        f"-GEntries={entries} -GPorts={ports} -GInOrder={ordered} {SELECTOR} {FORMAL}; "
                        "select -assert-none t:$check t:$assert t:$assume t:$cover; "
                        "prep -top formal_issue_select; flatten; memory_map; opt; "
                        "sat -verify -prove correct 1 -set-def-inputs")
            output = run(name, commands)
            if "SAT proof finished - no model found: SUCCESS!" not in output:
                raise RuntimeError(f"{name}: missing proof success marker")
            results["proofs"].append({"entries": entries, "ports": ports, "in_order": ordered,
                                      "contracts_proven": True})
            save()
            print(f"PASS: {name}", flush=True)
    if args.mode in ("synth", "all"):
        matrix = ([(16, p) for p in (1, 2, 3, 4, 6, 8)]
                  if args.matrix == "port-scaling" else [(8, 1), (8, 2), (8, 3), (16, 4)])
        for entries, ports in matrix:
            for rebalance in [0, 1]:
                name = f"synth-{entries}-{ports}-{rebalance}"
                commands = (f"read_slang --single-unit -DSYNTHESIS --top rapt_issue_select "
                            f"-GEntries={entries} -GPorts={ports} -GRebalance={rebalance} {SELECTOR}; "
                            "select -assert-none t:$check t:$assert t:$assume t:$cover; "
                            "synth -top rapt_issue_select -noabc; abc -g simple; clean; stat; ltp -noff")
                output = run(name, commands)
                cells = int(re.findall(r"^\s*(\d+) cells\s*$", output, re.M)[-1])
                depth = int(re.findall(r"Longest topological path .*\(length=(\d+)\)", output)[-1])
                row = {"entries": entries, "ports": ports, "rebalance": rebalance,
                       "generic_cells": cells, "topological_depth": depth}
                results["generic_synthesis"].append(row)
                save()
                print(json.dumps(row), flush=True)
    current_hashes = {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                      for p in [SELECTOR, FORMAL]}
    if current_hashes != results["source_sha256"]:
        raise RuntimeError("source changed during issue-selector evaluation")
    results["complete"] = True
    save()


if __name__ == "__main__":
    main()
