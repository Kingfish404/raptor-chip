#!/usr/bin/env python3
"""Account for repeated FPGA replay costs and shared RAM setup separately."""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
from statistics import median

from fpga_validate import checked_case
from simpoints import digest, write_json


def case_cost(case, repetitions):
    checked_case(case, repetitions)
    rows = []
    for repeat in range(repetitions):
        runs = [run for run in case["runs"] if run["repetition"] == repeat]
        for run in runs:
            execution = run["execution_wall_seconds"]
            if not math.isfinite(execution) or not 0 < execution <= run["wall_seconds"]:
                raise ValueError("invalid hardware execution cost")
        rows.append({"repetition": repeat, "windows": len(runs),
                     "wall_seconds": sum(run["wall_seconds"] for run in runs),
                     "execution_wall_seconds": sum(run["execution_wall_seconds"] for run in runs)})
    return {"repetitions": rows, "total_wall_seconds": sum(row["wall_seconds"] for row in rows),
            "median_wall_seconds": median(row["wall_seconds"] for row in rows)}


def evaluate(source, profile, warmup):
    if (source.get("schema") != "raptor-fpga-evaluation-v1" or
            source.get("complete") is not True or
            source["routed"].get("timing_pass") is not True):
        raise ValueError("cost accounting requires a complete, routed hardware evaluation")
    if type(warmup) is not int or warmup < 0:
        raise ValueError("selected warmup must be a nonnegative integer")
    cases = [case for case in source["cases"] if case["profile_sha256"] == profile]
    full = [case for case in cases if case["kind"] == "full"]
    sample = [case for case in cases if case["kind"] == "sample" and
              case["settings"]["warmup"] == warmup]
    if len(full) != 1 or len(sample) != 1:
        raise ValueError("cost accounting needs one full and one selected sample case")
    full, sample = full[0], sample[0]
    for key in ("profile_inputs", "retirement_domain", "regions"):
        if full[key] != sample[key]:
            raise ValueError("hardware full/sample costs have mismatched " + key)
    a, b = (case_cost(case, source["repetitions"]) for case in (full, sample))
    setup = [row["wall_seconds"] for row in source["setup"]]
    if any(not math.isfinite(value) or value < 0 for value in setup):
        raise ValueError("invalid shared RAM setup cost")
    setup = sum(setup)
    return {"schema": "raptor-fpga-cost-v1", "complete": True,
            "build_identity": source["build"]["sha256"], "profile_sha256": profile,
            "selected_warmup": warmup, "full": a, "sample": b,
            "median_replay_wall_speedup": a["median_wall_seconds"] / b["median_wall_seconds"],
            "repeat_total_wall_speedup": a["total_wall_seconds"] / b["total_wall_seconds"],
            "first_observed_repetition_wall_speedup": (
                a["repetitions"][0]["wall_seconds"] / b["repetitions"][0]["wall_seconds"]),
            "common_setup_seconds": setup,
            "setup_plus_repeats_component_ratio": (
                (setup + a["total_wall_seconds"]) / (setup + b["total_wall_seconds"])),
            "entire_observed_session_seconds": source.get("wall_seconds"),
            "scope": "First repetitions inherit the experiment case order. Component ratios "
                     "allocate all shared RAM setup to this study; they are not standalone "
                     "selected-only measurements. Offline preparation, bitstream programming "
                     "and Linux restoration are separate costs. Accuracy is checked separately."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--profile", required=True)
    parser.add_argument("--warmup", required=True, type=int)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        sha = digest(args.source)
        result = evaluate(json.loads(args.source.read_text()), args.profile, args.warmup)
        if digest(args.source) != sha:
            raise ValueError("hardware source changed during cost accounting")
        result.update(source=str(args.source.resolve()), source_sha256=sha)
        write_json(args.output, result)
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(1, f"{error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
