#!/usr/bin/env python3
"""Prove completion ownership filtering and report generic lookup cost.

The synthesis numbers use generic cells and topological depth without a
technology library; they are structural proxies, not physical timing/area.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
DUT = ROOT / "hdl/backend/rapt_completion_guard.sv"
REFERENCE = ROOT / "verify/formal/formal_completion_guard.sv"


def yosys(command: str, log: Path, timeout: int) -> str:
    with log.open("w") as stream:
        subprocess.run(
            ["yosys", "-Q", "-T", "-m", "slang", "-p", command],
            cwd=ROOT,
            stdout=stream,
            stderr=subprocess.STDOUT,
            check=True,
            timeout=timeout,
        )
    return log.read_text()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("prove", "synth", "all"), default="all")
    parser.add_argument(
        "--output", type=Path, default=ROOT / "verify/build/completion-guard"
    )
    parser.add_argument("--timeout", type=int, default=300)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)

    result = {
        "yosys_version": subprocess.check_output(["yosys", "-V"], text=True).strip(),
        "source_sha256": {
            str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in (DUT, REFERENCE)
        },
        "proofs": [],
        "generic_synthesis": [],
        "generic_bank_synthesis": [],
        "generic_identity_synthesis": [],
        "generic_identity_bank_synthesis": [],
        "mapping": "synth -noabc; abc -g simple; clean; stat; ltp -noff (no technology library)",
    }

    if args.mode in ("prove", "all"):
        for enforce_payload in (1, 0):
            for entries, generation_bits in ((1, 1), (7, 3), (8, 4), (64, 4)):
                mode = "strict" if enforce_payload else "identity"
                name = f"prove-{mode}-{entries}-{generation_bits}"
                command = (
                    "read_slang --single-unit --top formal_completion_guard "
                    f"-GEntries={entries} -GGenerationBits={generation_bits} "
                    f"-GPhysBits=6 -GArchBits=5 -GEnforcePayload={enforce_payload} "
                    f"{DUT} {REFERENCE}; select -assert-none t:$check t:$assert t:$assume t:$cover; "
                    "prep -top formal_completion_guard; "
                    "flatten; memory_map; opt; sat -verify -prove correct 1"
                )
                output = yosys(command, args.output / f"{name}.log", args.timeout)
                if "SAT proof finished - no model found: SUCCESS!" not in output:
                    raise RuntimeError(f"{name}: proof success marker missing")
                result["proofs"].append(
                    {
                        "entries": entries,
                        "generation_bits": generation_bits,
                        "enforce_payload": bool(enforce_payload),
                        "equivalent": True,
                    }
                )
                print(f"PASS: {name}", flush=True)

    if args.mode in ("synth", "all"):
        for entries in (64, 128):
            name = f"synth-{entries}-4"
            command = (
                "read_slang --single-unit -DSYNTHESIS --top rapt_completion_guard "
                f"-GEntries={entries} -GGenerationBits=4 -GPhysBits=7 -GArchBits=5 {DUT}; "
                "select -assert-none t:$check t:$assert t:$assume t:$cover; "
                "synth -top rapt_completion_guard -noabc; abc -g simple; clean; stat; ltp -noff"
            )
            output = yosys(command, args.output / f"{name}.log", args.timeout)
            cells = int(re.findall(r"^\s*(\d+) cells\s*$", output, re.M)[-1])
            depth = int(re.findall(r"Longest topological path .*\(length=(\d+)\)", output)[-1])
            row = {
                "entries": entries,
                "generation_bits": 4,
                "phys_bits": 7,
                "arch_bits": 5,
                "generic_cells": cells,
                "topological_depth": depth,
            }
            result["generic_synthesis"].append(row)
            print(json.dumps(row), flush=True)

        for ports in (5, 7):
            for entries in (64, 128):
                name = f"synth-bank-{entries}-{ports}-4"
                command = (
                    "read_slang --single-unit -DSYNTHESIS --top completion_guard_bank "
                    f"-GEntries={entries} -GPorts={ports} -GGenerationBits=4 "
                    f"-GPhysBits=7 -GArchBits=5 {DUT} {REFERENCE}; "
                    "select -assert-none t:$check t:$assert t:$assume t:$cover; "
                    "synth -top completion_guard_bank -noabc; "
                    "abc -g simple; clean; stat; ltp -noff"
                )
                output = yosys(command, args.output / f"{name}.log", args.timeout)
                cells = int(re.findall(r"^\s*(\d+) cells\s*$", output, re.M)[-1])
                depth = int(
                    re.findall(r"Longest topological path .*\(length=(\d+)\)", output)[-1]
                )
                row = {
                    "entries": entries,
                    "ports": ports,
                    "generation_bits": 4,
                    "phys_bits": 7,
                    "arch_bits": 5,
                    "generic_cells": cells,
                    "topological_depth": depth,
                }
                result["generic_bank_synthesis"].append(row)
                print(json.dumps(row), flush=True)

        for entries in (64, 128):
            name = f"synth-identity-{entries}-4"
            command = (
                "read_slang --single-unit -DSYNTHESIS "
                "--top completion_identity_guard_bank "
                f"-GEntries={entries} -GPorts=1 -GGenerationBits=4 "
                f"-GPhysBits=7 -GArchBits=5 {DUT} {REFERENCE}; "
                "select -assert-none t:$check t:$assert t:$assume t:$cover; "
                "synth -top completion_identity_guard_bank -noabc; "
                "abc -g simple; clean; stat; ltp -noff"
            )
            output = yosys(command, args.output / f"{name}.log", args.timeout)
            row = {
                "entries": entries,
                "generation_bits": 4,
                "generic_cells": int(re.findall(r"^\s*(\d+) cells\s*$", output, re.M)[-1]),
                "topological_depth": int(
                    re.findall(r"Longest topological path .*\(length=(\d+)\)", output)[-1]
                ),
            }
            result["generic_identity_synthesis"].append(row)
            print(json.dumps(row), flush=True)

        for entries in (64, 128):
            name = f"synth-identity-bank-{entries}-7-4"
            command = (
                "read_slang --single-unit -DSYNTHESIS "
                "--top completion_identity_guard_bank "
                f"-GEntries={entries} -GPorts=7 -GGenerationBits=4 "
                f"-GPhysBits=7 -GArchBits=5 {DUT} {REFERENCE}; "
                "select -assert-none t:$check t:$assert t:$assume t:$cover; "
                "synth -top completion_identity_guard_bank -noabc; "
                "abc -g simple; clean; stat; ltp -noff"
            )
            output = yosys(command, args.output / f"{name}.log", args.timeout)
            row = {
                "entries": entries,
                "ports": 7,
                "generation_bits": 4,
                "generic_cells": int(re.findall(r"^\s*(\d+) cells\s*$", output, re.M)[-1]),
                "topological_depth": int(
                    re.findall(r"Longest topological path .*\(length=(\d+)\)", output)[-1]
                ),
            }
            result["generic_identity_bank_synthesis"].append(row)
            print(json.dumps(row), flush=True)

    (args.output / "results.json").write_text(json.dumps(result, indent=2) + "\n")


if __name__ == "__main__":
    main()
