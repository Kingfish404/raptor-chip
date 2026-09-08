#!/usr/bin/env python3
"""Prove checkpoint state equivalence and report isolated generic cost.

The synthesis figures use generic gates without a technology library. They are
structural comparison points, not area, frequency, or power estimates.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
DUT = ROOT / "hdl/frontend/rapt_rename_checkpoint.sv"
REFERENCE = ROOT / "verify/formal/formal_rename_checkpoint.sv"
PACKAGE = ROOT / "hdl/rapt_pkg.sv"


def run_yosys(command, log, timeout):
    with log.open("w") as stream:
        subprocess.run(
            ["yosys", "-Q", "-T", "-m", "slang", "-p", command],
            stdout=stream, stderr=subprocess.STDOUT, check=True, timeout=timeout, cwd=ROOT
        )
    return log.read_text()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=["prove", "synth", "all"], default="all")
    parser.add_argument("--output", type=Path,
                        default=ROOT / "verify/build/rename-checkpoint")
    parser.add_argument("--timeout", type=int, default=300)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    sources = (PACKAGE, DUT, REFERENCE)
    includes = (f"-I{ROOT}/hdl/configs/default -I{ROOT}/hdl/include "
                f"-I{ROOT}/hdl/include/npc")
    results = {
        "yosys_version": subprocess.check_output(["yosys", "-V"], text=True).strip(),
        "source_sha256": {
            str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sources
        },
        "complete": False, "proofs": [], "generic_synthesis": [],
        "mapping": "synth -noabc; abc -g simple; clean; stat; ltp -noff",
        "interpretation": "No technology library; cell count/depth are structural proxies."
    }
    (args.output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    if args.mode in ("prove", "all"):
        for entries, width, ports in ((1, 1, 1), (3, 2, 2), (4, 3, 2)):
            name = f"prove-{entries}-{width}-{ports}"
            command = (
                f"read_slang {includes} --single-unit -DFORMAL --top formal_rename_checkpoint "
                f"-GEntries={entries} -GRenameWidth={width} -GResolvePorts={ports} "
                f"-GMapEntries=3 -GPhysRegs=6 {' '.join(map(str, sources))}; "
                "select -assert-none t:$assert; chformal -assume -lower; "
                "prep -top formal_rename_checkpoint; flatten; memory_map; opt; "
                "sat -verify -tempinduct -seq 2 -maxsteps 8 -set-at 1 reset 1 "
                "-set-assumes -prove correct 1"
            )
            output = run_yosys(command, args.output / f"{name}.log", args.timeout)
            if "Induction step proven: SUCCESS!" not in output:
                raise RuntimeError(f"{name}: missing induction success marker")
            results["proofs"].append({"entries": entries, "rename_width": width,
                                      "resolve_ports": ports, "inductive": True})
            print(f"PASS: {name}", flush=True)
    if args.mode in ("synth", "all"):
        for entries in (4, 8, 16):
            name = f"synth-{entries}"
            command = (
                f"read_slang {includes} --single-unit -DSYNTHESIS --top rapt_rename_checkpoint "
                f"-GEntries={entries} -GRenameWidth=4 -GResolvePorts=5 "
                f"-GMapEntries=32 -GPhysRegs=128 -GMapBits=7 {PACKAGE} {DUT}; "
                "select -assert-none t:$check t:$assert t:$assume t:$cover; "
                "synth -top rapt_rename_checkpoint -noabc; abc -g simple; clean; stat; ltp -noff"
            )
            output = run_yosys(command, args.output / f"{name}.log", args.timeout)
            row = {
                "checkpoint_entries": entries, "rename_width": 4, "resolve_ports": 5,
                "map_entries": 32, "physical_registers": 128,
                "state_bits": entries * (32 * 7 + 128 + entries) + entries,
                "generic_cells": int(re.findall(r"^\s*(\d+) cells\s*$", output, re.M)[-1]),
                "topological_depth": int(re.findall(
                    r"Longest topological path .*\(length=(\d+)\)", output)[-1]),
            }
            results["generic_synthesis"].append(row)
            print(json.dumps(row), flush=True)
    for path in sources:
        if hashlib.sha256(path.read_bytes()).hexdigest() != results["source_sha256"][str(path.relative_to(ROOT))]:
            raise RuntimeError(f"source changed during checkpoint evaluation: {path}")
    results["complete"] = True
    (args.output / "results.json").write_text(json.dumps(results, indent=2) + "\n")


if __name__ == "__main__":
    main()
