#!/usr/bin/env python3
"""Prove history state + next-query equivalence for arbitrary accepted events."""
import hashlib
import json
from pathlib import Path
import re
import subprocess
from rank_select_check import run_yosys

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "verify/build/predict-history"


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    sources = [ROOT / "hdl/frontend/branch_predictor/rapt_predict_history.sv",
               ROOT / "verify/formal/formal_predict_history.sv"]
    results = {"yosys_version": subprocess.check_output(["yosys", "-V"], text=True).strip(),
               "source_sha256": {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources},
               "proof_kind": "two-state temporal induction from reset, arbitrary boundary events",
               "proofs": [], "generic_synthesis": []}
    for ghr, phr in [(1, 1), (7, 3), (64, 8), (128, 16)]:
        command = (f"read_slang --single-unit --top formal_predict_history -GGhrBits={ghr} -GPhrBits={phr} "
                   f"{' '.join(map(str, sources))}; prep -top formal_predict_history; flatten; memory_map; opt; "
                   "sat -verify -tempinduct -seq 2 -maxsteps 4 -set-at 1 reset 1 -prove correct 1")
        output = run_yosys(command, OUTPUT / f"prove-{ghr}-{phr}.log", 120)
        if "Induction step proven: SUCCESS!" not in output:
            raise RuntimeError("missing induction proof success")
        results["proofs"].append({"ghr_bits": ghr, "phr_bits": phr, "passed": True})
        (OUTPUT / "results.json").write_text(json.dumps(results, indent=2) + "\n")
        print(f"PASS: prediction history GHR={ghr}, PHR={phr}", flush=True)
    command = (f"read_slang --single-unit --top rapt_predict_history {sources[0]}; "
               "synth -top rapt_predict_history -noabc; abc -g simple; clean; stat; ltp -noff")
    output = run_yosys(command, OUTPUT / "synth-64-8.log", 120)
    row = {"ghr_bits": 64, "phr_bits": 8, "state_bits": 216,
           "mapping": "abc -g simple; no technology library or physical timing",
           "generic_cells": int(re.findall(r"^\s*(\d+) cells\s*$", output, re.M)[-1]),
           "topological_depth": int(re.findall(r"Longest topological path .*\(length=(\d+)\)", output)[-1])}
    results["generic_synthesis"].append(row)
    (OUTPUT / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    print(json.dumps(row), flush=True)


if __name__ == "__main__":
    main()
