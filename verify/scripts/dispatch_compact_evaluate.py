#!/usr/bin/env python3
"""Measure generic logic cost/depth of the capacity-aware dispatch compactor.

Figures use no technology library and cover only domain/token compaction, not
the ROB payload read. They are comparative RTL proxies, not physical area,
delay, or Fmax.
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
DPU = ROOT / "hdl/backend/rapt_dpu.sv"
RANK_SELECT = ROOT / "hdl/common/rapt_rank_select.sv"
REFERENCE = ROOT / "verify/formal/formal_dispatch_compact.sv"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path,
                        default=ROOT / "verify/build/dispatch-compact")
    parser.add_argument("--timeout", type=int, default=300)
    parser.add_argument("--candidates", type=int, nargs="+", default=[2, 4, 8])
    parser.add_argument("--width", type=int, default=2)
    parser.add_argument("--mode", choices=["prove", "synth", "all"], default="all")
    args = parser.parse_args()
    if args.width < 1 or any(c < args.width for c in args.candidates):
        parser.error("width must be positive and each candidate window must be at least width")
    args.output.mkdir(parents=True, exist_ok=True)
    # Includes affect types and defaults just as much as the module bodies.
    sources = [PACKAGE, RANK_SELECT, DPU, REFERENCE,
               ROOT / 'hdl/configs/default/rapt_config.svh',
               *sorted((ROOT / 'hdl/include').rglob('*.svh'))]
    includes = (f"-DRAPT_DISPATCH_WIDTH={args.width} "
                f"-I{ROOT}/hdl/configs/default -I{ROOT}/hdl/include -I{ROOT}/hdl/include/npc")
    results = {
        "schema_version": 1,
        "complete": False,
        "yosys_version": subprocess.check_output(["yosys", "-V"], text=True).strip(),
        "source_sha256": {
            str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sources
        },
        "mapping": "synth -noabc; abc -g simple; clean; stat; ltp -noff (no technology library)",
        "proofs": [], "rows": [],
    }
    (args.output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    if args.mode in ("prove", "all"):
        for candidates in args.candidates:
            name = f"prove-{candidates}"
            command = (
                "read_slang --single-unit --top formal_dispatch_compact "
                f"-GNumCandidates={candidates} {includes} {PACKAGE} {RANK_SELECT} {DPU} {REFERENCE}; "
                "select -assert-none t:$check t:$assert t:$assume t:$cover; "
                "prep -top formal_dispatch_compact; flatten; memory_map; opt; "
                "sat -verify -prove correct 1 -set-def-inputs"
            )
            output = run_yosys(command, args.output / f"{name}.log", args.timeout)
            if "SAT proof finished - no model found: SUCCESS!" not in output:
                raise RuntimeError(f"{name}: missing proof success marker")
            results["proofs"].append({"dispatch_width": args.width, "candidates": candidates,
                                      "equivalent": True, "oldest_capacity_proven": True})
            (args.output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
            print(f"PASS: {name}", flush=True)
    if args.mode in ("synth", "all"):
        for candidates in args.candidates:
            name = f"synth-{candidates}"
            command = (
                "read_slang --single-unit -DSYNTHESIS --top rapt_dpu "
                f"-GNumCandidates={candidates} {includes} {PACKAGE} {RANK_SELECT} {DPU}; "
                "select -assert-none t:$check t:$assert t:$assume t:$cover; "
                "synth -top rapt_dpu -noabc; abc -g simple; clean; stat; ltp -noff"
            )
            output = run_yosys(command, args.output / f"{name}.log", args.timeout)
            cells = int(re.findall(r"^\s*(\d+) cells\s*$", output, re.M)[-1])
            depth = int(re.findall(r"Longest topological path .*\(length=(\d+)\)", output)[-1])
            row = {"dispatch_width": args.width, "candidates": candidates,
                   "generic_cells": cells, "topological_depth": depth}
            results["rows"].append(row)
            (args.output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
            print(json.dumps(row), flush=True)
    baseline = results["rows"][0] if results["rows"] else None
    for row in results["rows"]:
        row["cell_growth_vs_first_percent"] = (
            row["generic_cells"] - baseline["generic_cells"]
        ) / baseline["generic_cells"] * 100.0
        row["depth_growth_vs_first_percent"] = (
            row["topological_depth"] - baseline["topological_depth"]
        ) / baseline["topological_depth"] * 100.0
    for path in sources:
        if hashlib.sha256(path.read_bytes()).hexdigest() != results["source_sha256"][str(path.relative_to(ROOT))]:
            raise RuntimeError(f"source changed during compactor evaluation: {path}")
    results["complete"] = True
    (args.output / "results.json").write_text(json.dumps(results, indent=2) + "\n")


if __name__ == "__main__":
    main()
