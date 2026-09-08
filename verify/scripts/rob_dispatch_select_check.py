#!/usr/bin/env python3
"""Prove ROB-dispatch selection and compare flat/tree generic logic proxies.

The synthesis figures use no technology library.  Cell count and topological
depth are comparative RTL-logic proxies, not physical area or timing in ns.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

from rank_select_check import run_yosys

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = ROOT / "hdl/rapt_pkg.sv"
RANK_SELECT = ROOT / "hdl/common/rapt_rank_select.sv"
SELECTOR = ROOT / "hdl/backend/rapt_rob_dispatch_select.sv"
REFERENCE = ROOT / "verify/formal/formal_rob_dispatch_select.sv"
SOURCES = [PACKAGE, RANK_SELECT, SELECTOR, REFERENCE]


def synthesis_metrics(output):
    cells = int(re.findall(r"^\s*(\d+) cells\s*$", output, re.M)[-1])
    depth = int(re.findall(r"Longest topological path .*\(length=(\d+)\)", output)[-1])
    return cells, depth


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=["prove", "synth", "all"], default="all")
    parser.add_argument("--output", type=Path,
                        default=ROOT / "verify/build/rob-dispatch-select")
    parser.add_argument("--timeout", type=int, default=300)
    parser.add_argument("--extended-proof", action="store_true",
                        help="also attempt the expensive 64-entry monolithic SAT proof")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    includes = f"-I{ROOT}/hdl/configs/default -I{ROOT}/hdl/include -I{ROOT}/hdl/include/npc"
    source_text = " ".join(map(str, SOURCES))
    results = {
        "schema_version": 1,
        "mode": args.mode,
        "complete": False,
        "yosys_version": subprocess.check_output(["yosys", "-V"], text=True).strip(),
        "source_sha256": {
            str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in SOURCES
        },
        "mapping": "synth -noabc; abc -g simple; clean; stat; ltp -noff (no technology library)",
        "proofs": [],
        "generic_synthesis": [],
        "comparisons": [],
    }

    if args.mode in ("prove", "all"):
        proof_cases = [
            (1, 1, 1), (3, 2, 2), (7, 3, 3), (7, 2, 4),
            (16, 4, 4), (16, 2, 8),
        ]
        if args.extended_proof:
            proof_cases.append((64, 4, 4))
        for entries, width, scan_entries in proof_cases:
            name = f"prove-{entries}-{width}-{scan_entries}"
            command = (
                "read_slang --single-unit "
                f"--top formal_rob_dispatch_select -GEntries={entries} -GWidth={width} "
                f"-GScanEntries={scan_entries} "
                f"{includes} {source_text}; select -assert-none t:$check t:$assert t:$assume t:$cover; "
                "prep -top formal_rob_dispatch_select; "
                "flatten; memory_map; opt; sat -verify -prove correct 1 -set-def-inputs"
            )
            output = run_yosys(command, args.output / f"{name}.log", args.timeout)
            if "SAT proof finished - no model found: SUCCESS!" not in output:
                raise RuntimeError(f"{name}: missing proof success marker")
            results["proofs"].append(
                {"entries": entries, "width": width, "scan_entries": scan_entries,
                 "equivalent": True}
            )
            (args.output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
            print(f"PASS: {name}", flush=True)

    if args.mode in ("synth", "all"):
        synthesis_cases = [
            (entries, width, width)
            for entries in [16, 32, 64, 128]
            for width in [2, 4]
        ] + [(64, 2, 4), (64, 2, 8)]
        for entries, width, scan_entries in synthesis_cases:
            for implementation, top in [
                    ("flat_reference", "rob_dispatch_select_reference"),
                    ("hierarchical", "rapt_rob_dispatch_select"),
            ]:
                name = f"synth-{implementation}-{entries}-{width}-{scan_entries}"
                command = (
                    f"read_slang --single-unit -DSYNTHESIS --top {top} "
                    f"-GEntries={entries} -GWidth={width} -GScanEntries={scan_entries} "
                    f"{includes} {source_text}; select -assert-none t:$check t:$assert t:$assume t:$cover; "
                    f"synth -top {top} -noabc; abc -g simple; clean; stat; ltp -noff"
                )
                output = run_yosys(command, args.output / f"{name}.log", args.timeout)
                cells, depth = synthesis_metrics(output)
                row = {
                    "implementation": implementation,
                    "entries": entries,
                    "width": width,
                    "scan_entries": scan_entries,
                    "generic_cells": cells,
                    "topological_depth": depth,
                }
                results["generic_synthesis"].append(row)
                print(json.dumps(row), flush=True)

        by_configuration = {
            (row["entries"], row["width"], row["scan_entries"], row["implementation"]): row
            for row in results["generic_synthesis"]
        }
        for entries, width, scan_entries in synthesis_cases:
            flat = by_configuration[(entries, width, scan_entries, "flat_reference")]
            tree = by_configuration[(entries, width, scan_entries, "hierarchical")]
            comparison = {
                "entries": entries,
                "width": width,
                "scan_entries": scan_entries,
                "generic_cell_reduction_percent":
                    (flat["generic_cells"] - tree["generic_cells"])
                    / flat["generic_cells"] * 100.0,
                "topological_depth_reduction_percent":
                    (flat["topological_depth"] - tree["topological_depth"])
                    / flat["topological_depth"] * 100.0,
            }
            results["comparisons"].append(comparison)
            print("COMPARE: " + json.dumps(comparison), flush=True)

    results["complete"] = True
    (args.output / "results.json").write_text(json.dumps(results, indent=2) + "\n")


if __name__ == "__main__":
    main()
