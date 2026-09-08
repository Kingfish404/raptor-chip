#!/usr/bin/env python3
"""Compare physical integer-port profiles on self-checking AM workloads.

This runner compares identical workload images under NEMU difftest.  It reports
architectural cycles and PMU events, never simulator wall time.  CoreMark's AM
port derives elapsed seconds from simulated target time; short RTL runs can
therefore pass every CRC check while failing CoreMark's ten-second reporting
rule.  That condition is recorded explicitly and is not presented as an
official CoreMark score.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
import re
import subprocess

from width_evaluate import (parse_alq_selection, parse_dispatch, parse_frontend,
                            parse_recovery, parse_recovery_transaction, parse_rob_dispatch,
                            parse_rename_checkpoints)


ROOT = Path(__file__).resolve().parents[2]
ANSI = re.compile(r"\x1b\[[0-9;]*m")
COREMARK_DURATION_ERROR = "ERROR! Must execute for at least 10 secs for a valid result!"


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def parse_specification(specification: str, kind: str) -> tuple[str, Path]:
    try:
        label, path = specification.split("=", 1)
    except ValueError as error:
        raise ValueError(f"{kind} must use LABEL=PATH") from error
    if not re.fullmatch(r"[A-Za-z0-9_-]+", label):
        raise ValueError(f"invalid {kind} label {label!r}")
    path = Path(path).resolve()
    if not path.is_file():
        raise FileNotFoundError(path)
    return label, path


def validate_output(output: str) -> dict:
    """Reject architectural/self-check failures and classify CoreMark timing."""
    if "HIT GOOD TRAP" not in output:
        raise ValueError("missing GOOD TRAP")
    hard_failures = [
        r"HIT BAD TRAP",
        r"\[ERROR\]",
        r"MicroBench FAIL",
        r"difftest.*mismatch",
        r"register mismatch",
    ]
    if any(re.search(pattern, output, re.IGNORECASE) for pattern in hard_failures):
        raise ValueError("architectural or workload failure marker")

    if "CoreMark Size" in output:
        crc_errors = re.findall(r"^\[\d+\]ERROR!.*$", output, re.MULTILINE)
        other_errors = [line for line in output.splitlines()
                        if "ERROR!" in line and line != COREMARK_DURATION_ERROR
                        and not re.match(r"^\[\d+\]ERROR!", line)]
        if crc_errors or other_errors:
            raise ValueError("CoreMark CRC or porting check failed")
        duration_short = COREMARK_DURATION_ERROR in output
        if "Errors detected" in output and not duration_short:
            raise ValueError("unclassified CoreMark self-check failure")
        if duration_short:
            return {
                "self_check": "crc_checks_passed",
                "official_coremark_score_valid": False,
                "reporting_caveat": "simulated target time is below CoreMark's ten-second reporting minimum",
            }
        if "Correct operation validated" not in output:
            raise ValueError("CoreMark did not report validation")
        return {"self_check": "passed", "official_coremark_score_valid": True}

    if re.search(r"Errors detected|ERROR!|\[ERROR\]", output):
        raise ValueError("workload self-check failure marker")
    if "Running MicroBench" in output and "MicroBench PASS" not in output:
        raise ValueError("MicroBench did not report PASS")
    return {"self_check": "passed"}


def parse_metrics(output: str) -> dict:
    counters = re.findall(r"#inst:\s*(\d+), cycle:\s*(\d+)", output)
    if not counters:
        raise ValueError("missing instruction/cycle counters")
    instructions, cycles = map(int, counters[-1])
    if cycles <= 0:
        raise ValueError("non-positive cycle count")
    selection = parse_alq_selection(output)
    if selection is None or "issue_histogram" not in selection or "extra_port_issues" not in selection:
        raise ValueError("missing physical-port PMU report")
    histogram = selection["issue_histogram"]
    if sum(histogram.values()) != cycles:
        raise ValueError("ALQ histogram cycle count disagrees with architectural cycles")

    result = {
        "instructions": instructions,
        "cycles": cycles,
        "ipc": instructions / cycles,
        "alq_selection": selection,
        "physical_integer_ports": max(histogram),
        "max_issue_cycles": histogram[max(histogram)],
        "max_issue_cycle_fraction": histogram[max(histogram)] / cycles,
        "extra_port_issue_fraction": selection["extra_port_issues"] / selection["issued"]
        if selection["issued"] else 0.0,
    }
    optional = {
        "dispatch": parse_dispatch(output),
        "rob_dispatch": parse_rob_dispatch(output),
        "frontend": parse_frontend(output),
        "recovery": parse_recovery(output),
        "recovery_transaction": parse_recovery_transaction(output),
        "rename_checkpoints": parse_rename_checkpoints(output),
    }
    result.update({name: value for name, value in optional.items() if value is not None})
    if "dispatch" in result and result["dispatch"]["cycles"] != cycles:
        raise ValueError("dispatch and architectural cycle counters disagree")
    if ("rob_dispatch" in result and "sample_cycles" in result["rob_dispatch"]
            and result["rob_dispatch"]["sample_cycles"] != cycles):
        raise ValueError("ROB dispatch histogram cycle count disagrees with architectural cycles")
    return result


def comparison(baseline: dict, candidate: dict) -> dict:
    if [row["workload"] for row in baseline["workloads"]] != [
            row["workload"] for row in candidate["workloads"]]:
        raise ValueError("profile workload order changed")
    rows = []
    speedups = []
    for old, new in zip(baseline["workloads"], candidate["workloads"]):
        if old["image_sha256"] != new["image_sha256"] or old["instructions"] != new["instructions"]:
            raise ValueError(f"instruction stream changed for {new['workload']}")
        speedup = old["cycles"] / new["cycles"]
        speedups.append(speedup)
        rows.append({
            "workload": new["workload"],
            "baseline_cycles": old["cycles"],
            "candidate_cycles": new["cycles"],
            "cycle_delta": new["cycles"] - old["cycles"],
            "speedup": speedup,
            "candidate_extra_port_issues": new["alq_selection"]["extra_port_issues"],
        })
    old_cycles = sum(row["cycles"] for row in baseline["workloads"])
    new_cycles = sum(row["cycles"] for row in candidate["workloads"])
    return {
        "baseline": baseline["label"],
        "candidate": candidate["label"],
        "workloads": rows,
        "aggregate": {
            "baseline_cycles": old_cycles,
            "candidate_cycles": new_cycles,
            "cycle_delta": new_cycles - old_cycles,
            "cycle_weighted_speedup": old_cycles / new_cycles,
            "geometric_mean_speedup": math.exp(sum(math.log(value) for value in speedups) / len(speedups)),
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", action="append", required=True, metavar="LABEL=BINARY")
    parser.add_argument("--workload", action="append", required=True, metavar="LABEL=IMAGE")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--timeout", type=int, default=600)
    args = parser.parse_args()
    if args.timeout <= 0:
        raise ValueError("timeout must be positive")

    profiles = [parse_specification(item, "profile") for item in args.profile]
    workloads = [parse_specification(item, "workload") for item in args.workload]
    if len({label for label, _ in profiles}) != len(profiles):
        raise ValueError("profile labels must be unique")
    if len({label for label, _ in workloads}) != len(workloads):
        raise ValueError("workload labels must be unique")
    for _, binary in profiles:
        if not binary.stat().st_mode & 0o111:
            raise PermissionError(f"profile is not executable: {binary}")

    reference = ROOT / "nemu/build/riscv32-nemu-interpreter-so"
    boot = ROOT / "sim/csrc/mem/mrom-data/build/rv32-spike-rv32ima/mrom-data.bin"
    args.output.mkdir(parents=True, exist_ok=True)
    result = {
        "schema_version": 1,
        "scope": "same-image RV32 architectural-cycle comparison under NEMU difftest",
        "caveat": "CoreMark rows below its simulated ten-second minimum are comparison workloads, not official CoreMark scores.",
        "complete": False,
        "reference": {"path": str(reference.resolve()), "sha256": digest(reference)},
        "boot": {"path": str(boot.resolve()), "sha256": digest(boot)},
        "workload_images": [{"label": label, "path": str(path), "sha256": digest(path)}
                            for label, path in workloads],
        "profiles": [],
    }

    for profile_label, binary in profiles:
        profile = {"label": profile_label, "binary": str(binary),
                   "binary_sha256": digest(binary), "workloads": []}
        for workload_label, image in workloads:
            command = [str(binary), "-b", "-n", "--no-lightsss", "-t", str(args.timeout),
                       "-d", str(reference), "-r", str(boot), str(image)]
            try:
                completed = subprocess.run(command, cwd=ROOT / "sim", text=True,
                                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                           timeout=args.timeout + 10)
            except subprocess.TimeoutExpired as error:
                raise RuntimeError(f"{profile_label}/{workload_label} timed out") from error
            log = args.output / f"{profile_label}-{workload_label}.log"
            log.write_text(completed.stdout)
            output = ANSI.sub("", completed.stdout)
            if completed.returncode:
                raise RuntimeError(f"{profile_label}/{workload_label} exited {completed.returncode}; see {log}")
            try:
                row = {"workload": workload_label, "image_sha256": digest(image),
                       "validation": validate_output(output), **parse_metrics(output)}
            except ValueError as error:
                raise RuntimeError(f"{profile_label}/{workload_label}: {error}; see {log}") from error
            profile["workloads"].append(row)
            print(f"PASS: {profile_label}/{workload_label}: {row['instructions']} instructions, "
                  f"{row['cycles']} cycles, IPC={row['ipc']:.6f}, "
                  f"extra-port issues={row['alq_selection']['extra_port_issues']}", flush=True)
        result["profiles"].append(profile)
        (args.output / "results.json").write_text(json.dumps(result, indent=2) + "\n")

    result["comparisons"] = [comparison(result["profiles"][0], candidate)
                             for candidate in result["profiles"][1:]]
    result["complete"] = True
    (args.output / "results.json").write_text(json.dumps(result, indent=2) + "\n")
    for item in result["comparisons"]:
        aggregate = item["aggregate"]
        print(f"COMPARE: {item['candidate']} vs {item['baseline']}: "
              f"{aggregate['cycle_delta']:+d} cycles, "
              f"{(aggregate['cycle_weighted_speedup'] - 1.0) * 100:.4f}% speedup")


if __name__ == "__main__":
    main()
