#!/usr/bin/env python3
"""Validate repeated hardware full/sample runs, including actual loading costs."""
from __future__ import annotations

import argparse
from itertools import combinations
import json
import math
from pathlib import Path
from statistics import median

from pc_reference import PcReference
from run_samples import matched_window
from simpoints import digest, write_json
from validate import relative_error


def checked_case(case, repetitions):
    if len(case["estimates"]) != repetitions or repetitions < 3:
        raise ValueError("hardware validation requires at least three complete repetitions")
    grouped = {repeat: {} for repeat in range(repetitions)}
    reference = None
    if "pc_reference" in case:
        definition = case["pc_reference"]
        if definition["sha256"] != case["profile_sha256"]:
            raise ValueError("hardware PC reference differs from its selected profile")
        reference = PcReference(Path(definition["path"]), definition["sha256"],
                                case["retirement_domain"])
    for run in case["runs"]:
        point = run["point"]
        repeat = run["repetition"]
        if repeat not in grouped or run["id"] in grouped[repeat]:
            raise ValueError("duplicate or invalid hardware repetition")
        measured = matched_window(run["window"], run["window"], point)
        if measured != run["measurement"]:
            raise ValueError("hardware measurement differs from its recorded boundaries")
        if reference is not None:
            if reference.verify(run["window"], point) != run.get("native_pc_audit"):
                raise ValueError("hardware run lacks its independent native PC audit")
        for transfer in (run["delta_transfer"], run["sram_transfer"]):
            if transfer.get("readback_verified") is not True:
                raise ValueError("checkpoint transfer was not verified")
        if not math.isfinite(run["wall_seconds"]) or run["wall_seconds"] <= 0:
            raise ValueError("invalid hardware replay cost")
        grouped[repeat][run["id"]] = run
    if not grouped[0] or any(rows.keys() != grouped[0].keys() for rows in grouped.values()):
        raise ValueError("hardware repetitions have missing points")
    for identifier, reference in grouped[0].items():
        for rows in grouped.values():
            matched_window(reference["window"], rows[identifier]["window"], reference["point"])
    cycles = {}
    for estimate in case["estimates"]:
        if estimate.get("complete") is not True:
            raise ValueError("incomplete hardware weighted estimate")
        current = {row["name"]: row["profiles"][case["id"]]["cycles"]
                   for row in estimate["regions"]}
        if set(current) != {row["name"] for row in case["regions"]}:
            raise ValueError("hardware estimate has missing regions")
        for name, value in current.items():
            if not math.isfinite(value) or value <= 0:
                raise ValueError("invalid hardware cycle estimate")
            cycles.setdefault(name, []).append(value)
    if case["kind"] == "full":
        expected = sorted(row["instructions"] for row in case["regions"])
        actual = sorted(row["point"]["instructions"] for row in grouped[0].values())
        if expected != actual:
            raise ValueError("hardware full reference did not measure each entire ROI")
    return {"cycles": {name: median(values) for name, values in cycles.items()},
            "variation_percent": {name: (max(values) / min(values) - 1) * 100
                                  for name, values in cycles.items()},
            "wall_seconds": median(sum(run["wall_seconds"] for run in rows.values())
                                   for rows in grouped.values()),
            "execution_wall_seconds": median(
                sum(run["execution_wall_seconds"] for run in rows.values())
                for rows in grouped.values()),
            "runs": grouped[0]}


def evaluate(sources, selected_warmup, gates, profile_sha256=None):
    comparisons, convergence, errors, selected, witnesses = [], [], [], {}, {}
    excluded, scoped = {}, {}
    for model, result in sources.items():
        if result.get("schema") != "raptor-fpga-evaluation-v1" or not result.get("complete"):
            raise ValueError("a hardware source is incomplete or has an unknown schema")
        if result["routed"].get("timing_pass") is not True:
            raise ValueError("hardware source lacks a passing routed timing gate")
        cases = result["cases"]
        if profile_sha256 is not None:
            excluded[model] = [{"id": case["id"], "profile_sha256": case["profile_sha256"]}
                               for case in cases if case["profile_sha256"] != profile_sha256]
            cases = [case for case in cases if case["profile_sha256"] == profile_sha256]
        result = dict(result, cases=cases)
        scoped[model] = result
        full_cases = [case for case in result["cases"] if case["kind"] == "full"]
        if len(full_cases) != 1:
            raise ValueError("each hardware source must have one full reference case")
        full = full_cases[0]
        reference = checked_case(full, result["repetitions"])
        samples = {}
        for case in result["cases"]:
            if case["kind"] != "sample":
                continue
            for key in ("profile_sha256", "profile_inputs", "retirement_domain", "regions"):
                if case[key] != full[key]:
                    raise ValueError(f"hardware full/sample comparison has mismatched {key}")
            warmup = case["settings"]["warmup"]
            if warmup in samples:
                raise ValueError("duplicate hardware warmup setting")
            sample = checked_case(case, result["repetitions"])
            samples[warmup] = sample
            for name, cycles in reference["cycles"].items():
                row = {"model": model, "region": name, "warmup": warmup,
                       "full_cycles": cycles, "estimated_cycles": sample["cycles"][name],
                       "cycle_error_percent": relative_error(sample["cycles"][name], cycles),
                       "replay_wall_speedup": reference["wall_seconds"] / sample["wall_seconds"],
                       "full_wall_seconds": reference["wall_seconds"],
                       "sample_wall_seconds": sample["wall_seconds"],
                       "repeat_variation_percent": sample["variation_percent"][name]}
                comparisons.append(row)
        settings = sorted(samples)
        if selected_warmup not in samples or len(settings) < 3:
            raise ValueError("selected hardware warmup missing or fewer than three settings")
        chosen, largest, previous = (samples[w] for w in
                                     (selected_warmup, settings[-1], settings[-2]))
        for name, cycles in reference["cycles"].items():
            change = relative_error(chosen["cycles"][name], largest["cycles"][name])
            tail = relative_error(previous["cycles"][name], largest["cycles"][name])
            repeat_variation = {
                label: value["variation_percent"][name]
                for label, value in (("full", reference), ("selected", chosen),
                                     ("largest", largest), ("previous", previous))}
            convergence.append({"model": model, "region": name, "change_percent": change,
                                "largest_pair_change_percent": tail,
                                "repeat_variation_percent": repeat_variation})
            if max(change, tail) > gates["warmup_change_percent"]:
                errors.append(f"{model}/{name}: hardware warmup has not converged")
            if relative_error(chosen["cycles"][name], cycles) > gates["cycle_error_percent"]:
                errors.append(f"{model}/{name}: hardware cycle error exceeds gate")
            if max(repeat_variation.values()) > gates["repeat_variation_percent"]:
                errors.append(f"{model}/{name}: repeated hardware cycles are unstable")
            if reference["wall_seconds"] / chosen["wall_seconds"] < gates["minimum_wall_speedup"]:
                errors.append(f"{model}/{name}: hardware replay including transfers is too slow")
            selected.setdefault(name, {})[model] = (cycles, chosen["cycles"][name])
        witnesses[model] = {"full": reference["runs"], "sample": chosen["runs"]}
    rankings = []
    if len({result["build"]["sha256"] for result in sources.values()}) < 2:
        errors.append("hardware ranking needs at least two distinct routed configurations")
    for left, right in combinations(sorted(sources), 2):
        a, b = scoped[left], scoped[right]
        full_a = next(case for case in a["cases"] if case["kind"] == "full")
        full_b = next(case for case in b["cases"] if case["kind"] == "full")
        for key in ("profile_sha256", "profile_inputs", "retirement_domain", "regions"):
            if full_a[key] != full_b[key]:
                raise ValueError(f"hardware model comparison has mismatched {key}")
        for key in ("memory", "clock_mhz", "xlen", "ddr_part"):
            if a["build"]["configuration"][key] != b["build"]["configuration"][key]:
                raise ValueError(f"hardware ranking has mismatched {key}")
        for kind in ("full", "sample"):
            x, y = witnesses[left][kind], witnesses[right][kind]
            if x.keys() != y.keys():
                raise ValueError("hardware models selected different sample points")
            for identifier in x:
                matched_window(x[identifier]["window"], y[identifier]["window"],
                               x[identifier]["point"])
        for name, models in selected.items():
            full_ratio = models[left][0] / models[right][0]
            sample_ratio = models[left][1] / models[right][1]
            error = relative_error(sample_ratio, full_ratio)
            ordered = ((full_ratio >= 1) == (sample_ratio >= 1) or
                       abs(full_ratio - 1) * 100 <= gates["ranking_tie_percent"])
            rankings.append({"models": [left, right], "region": name,
                             "full_speedup": full_ratio, "sampled_speedup": sample_ratio,
                             "speedup_error_percent": error, "ranking_preserved": ordered})
            if not ordered or error > gates["speedup_error_percent"]:
                errors.append(f"{left}/{right}/{name}: hardware ranking or speedup failed")
    return {"schema": "raptor-fpga-validation-v1", "complete": not errors,
            "selected_warmup": selected_warmup, "gates": gates, "comparisons": comparisons,
            "warmup_convergence": convergence, "rankings": rankings, "errors": errors,
            "setup": {model: result["setup"] for model, result in sources.items()},
            "profile_sha256": profile_sha256, "excluded_cases": excluded,
            "official_score": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--spec", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        spec = json.loads(args.spec.read_text())
        if spec.get("schema") != "raptor-fpga-validation-spec-v1":
            raise ValueError("unknown hardware validation specification")
        paths = {row["model"]: args.spec.parent / row["results"] for row in spec["sources"]}
        if len(paths) != len(spec["sources"]):
            raise ValueError("duplicate hardware model names")
        gates = {"cycle_error_percent": 5, "speedup_error_percent": 5,
                 "warmup_change_percent": 1, "repeat_variation_percent": 1,
                 "minimum_wall_speedup": 2, "ranking_tie_percent": 1}
        gates.update(spec.get("gates", {}))
        if any(not math.isfinite(value) or value < 0 for value in gates.values()):
            raise ValueError("invalid hardware validation gate")
        result = evaluate({name: json.loads(path.read_text()) for name, path in paths.items()},
                          spec["selected_warmup"], gates, spec.get("profile_sha256"))
        result["sources"] = {name: {"path": str(path), "sha256": digest(path)}
                             for name, path in paths.items()}
        result["spec_sha256"] = digest(args.spec)
        write_json(args.output, result)
        print(f"Hardware validation passed={result['complete']}; {len(result['errors'])} errors")
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(1, f"{error}\n")
    return int(not result["complete"])


if __name__ == "__main__":
    raise SystemExit(main())
