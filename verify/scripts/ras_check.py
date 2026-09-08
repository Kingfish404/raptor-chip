#!/usr/bin/env python3
"""Inductive RAS state equivalence, plus isolated generic synthesis (not STA)."""
import hashlib
import json
from pathlib import Path
import re
import subprocess
from rank_select_check import run_yosys

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "verify/build/ras-check"


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    sources = [ROOT / "hdl/frontend/branch_predictor/rapt_ras.sv",
               ROOT / "verify/formal/formal_ras.sv"]
    results = {"yosys_version": subprocess.check_output(["yosys", "-V"], text=True).strip(),
               "source_sha256": {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
               "proof_kind": "two-state temporal induction of live-entry relation, reset at step 1",
               "proofs": [], "generic_synthesis": []}
    for depth in [1, 3, 4, 16]:
        command = (f"read_slang --single-unit --top formal_ras -GDepth={depth} -GXlen=32 "
                   f"{' '.join(map(str, sources))}; prep -top formal_ras; flatten; memory_map; opt; "
                   "sat -verify -tempinduct -seq 2 -maxsteps 8 -set-at 1 reset 1 "
                   "-prove correct 1")
        output = run_yosys(command, OUTPUT / f"prove-{depth}.log", 300)
        if "Induction step proven: SUCCESS!" not in output:
            raise RuntimeError(f"missing proof success for depth {depth}")
        results["proofs"].append({"depth": depth, "address_bits": 32, "inductive": True, "passed": True})
        print(f"PASS: RAS depth {depth}, inductive state equivalence", flush=True)
        (OUTPUT / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    for depth in [1, 3, 4, 16]:
        command = (f"read_slang --single-unit --top rapt_ras -GDepth={depth} -GXlen=32 {sources[0]}; "
                   "synth -top rapt_ras -noabc; abc -g simple; clean; stat; ltp -noff")
        output = run_yosys(command, OUTPUT / f"synth-{depth}.log", 300)
        row = {"depth": depth, "xlen": 32,
               "generic_cells": int(re.findall(r"^\s*(\d+) cells\s*$", output, re.M)[-1]),
               "topological_depth": int(re.findall(r"Longest topological path .*\(length=(\d+)\)", output)[-1])}
        results["generic_synthesis"].append(row)
        (OUTPUT / "results.json").write_text(json.dumps(results, indent=2) + "\n")
        print(json.dumps(row), flush=True)


if __name__ == "__main__":
    main()
