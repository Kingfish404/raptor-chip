#!/usr/bin/env python3
"""Check sampled cycle error, replay cost, warmup convergence and model ranking.

The specification lists full and sampled run_model.py results. All comparisons
must refer to identical ROI ranges, workload inputs, models and memory settings.
"""
from __future__ import annotations

import argparse
from itertools import combinations
import json
import math
from pathlib import Path

from run_samples import matched_window
from simpoints import digest, write_json


def checked_result(path, kind):
    result = json.loads(path.read_text())
    if (result.get("schema") != "raptor-model-evaluation-v1" or
            result.get("complete") is not True or result.get("kind") != kind or
            result.get("difftest") is not True):
        raise ValueError(f"{path}: missing complete, differentially checked {kind} run")
    if not result["runs"] or not result["measurements"]:
        raise ValueError(f"{path}: no measured windows")
    for run in result["runs"]:
        if (run.get("passed") is not True or run.get("returncode") != 0 or
                run.get("fatal") or run.get("timed_out") or
                run.get("window", {}).get("complete") is not True):
            raise ValueError(f"{path}: a run is incomplete or failed")
    if result["estimates"].get("complete") is not True:
        raise ValueError(f"{path}: incomplete weighted estimates")
    if {row["name"] for row in result["regions"]} != set(region_cycles(result)):
        raise ValueError(f"{path}: missing region estimates")
    if kind == "full" and sorted(row["instructions"] for row in result["regions"]) != sorted(
            row["instructions"] for row in result["measurements"]):
        raise ValueError(f"{path}: full reference did not measure each entire ROI")
    if min(result["execution_wall_seconds"], result["wall_seconds"]) <= 0:
        raise ValueError(f"{path}: nonpositive timing")
    return result


def compatible(full, sample):
    if full.get("retirement_domain", {"mode": "all"}) != sample.get(
            "retirement_domain", {"mode": "all"}):
        raise ValueError("full/sample comparison has mismatched retirement domains")
    for key in ("name", "profile_sha256", "profile_inputs", "regions", "read_latency",
                "write_latency", "jobs"):
        if full.get(key) != sample.get(key):
            raise ValueError(f"full/sample comparison has mismatched {key}")
    for key in ("model", "reference", "mrom"):
        if full["inputs"].get(key) != sample["inputs"].get(key):
            raise ValueError(f"full/sample comparison has mismatched {key}")


def region_cycles(result):
    return {row["name"]: row["profiles"][result["name"]]["cycles"]
            for row in result["estimates"]["regions"]}


def relative_error(estimated, reference):
    if not all(math.isfinite(v) and v > 0 for v in (estimated, reference)):
        raise ValueError("cycle estimates must be finite and positive")
    return abs(estimated / reference - 1) * 100


def matched_streams(left, right):
    for key in ("plan", "capture"):
        if left["inputs"].get(key) != right["inputs"].get(key):
            raise ValueError(f"model ranking uses different {key} inputs")
    before = {row["id"]: row for row in left["runs"]}
    after = {row["id"]: row for row in right["runs"]}
    measurements = {row["id"]: row for row in left["measurements"]}
    if before.keys() != after.keys() or before.keys() != measurements.keys():
        raise ValueError("model ranking has missing or different instruction windows")
    evidence = []
    for identifier, run in before.items():
        window, measured = run["window"], measurements[identifier]
        point = {"start": measured["start"] - measured["boundary_shift"],
                 "warmup": window["warmup"], "instructions": window["instructions"],
                 "start_pc": window["start_pc"]}
        common = matched_window(window, after[identifier]["window"], point)
        evidence.append({"id": identifier, **common})
    return evidence


def evaluate(cases, gates, selected_warmup):
    rows, errors, sources = [], [], []
    grouped, streams = {}, {}
    for full_path, sample_path in cases:
        full = checked_result(full_path, "full")
        sample = checked_result(sample_path, "sample")
        compatible(full, sample)
        full_cycles, sampled_cycles = region_cycles(full), region_cycles(sample)
        if full_cycles.keys() != sampled_cycles.keys():
            raise ValueError("full/sample region estimates differ")
        warmup = sample["settings"]["warmup"]
        condition = (full["profile_sha256"], full["read_latency"], full["write_latency"])
        streams[condition + (full["name"], warmup)] = (full, sample)
        sources.append({"full": str(full_path), "full_sha256": digest(full_path),
                        "sample": str(sample_path), "sample_sha256": digest(sample_path)})
        for region in full_cycles:
            error = relative_error(sampled_cycles[region], full_cycles[region])
            row = {"model": full["name"], "region": region, "warmup": warmup,
                   "model_sha256": full["inputs"]["model"],
                   "read_latency": full["read_latency"], "write_latency": full["write_latency"],
                   "full_cycles": full_cycles[region], "estimated_cycles": sampled_cycles[region],
                   "cycle_error_percent": error,
                   "replay_wall_speedup": full["wall_seconds"] / sample["wall_seconds"],
                   "execution_wall_speedup": full["execution_wall_seconds"] /
                                             sample["execution_wall_seconds"],
                   "full_wall_seconds": full["wall_seconds"],
                   "sample_wall_seconds": sample["wall_seconds"]}
            key = condition + (region, full["name"])
            group = grouped.setdefault(key, {})
            if warmup in group:
                raise ValueError("duplicate model/region/warmup comparison")
            group[warmup] = row
            rows.append(row)
    convergences, selected = [], {}
    for key, group in grouped.items():
        settings = sorted(group)
        label = f"{key[-2]}/{key[-1]}/latency={key[1]}/{key[2]}"
        if selected_warmup not in group or len(settings) < 3:
            errors.append(f"{label}: selected warmup missing or fewer than three warmup settings")
            continue
        largest = group[settings[-1]]
        previous = group[settings[-2]]
        chosen = group[selected_warmup]
        change = relative_error(chosen["estimated_cycles"], largest["estimated_cycles"])
        tail_change = relative_error(previous["estimated_cycles"], largest["estimated_cycles"])
        convergences.append({"model": key[-1], "region": key[-2],
                             "profile_sha256": key[0],
                             "read_latency": key[1], "write_latency": key[2],
                             "selected_warmup": selected_warmup, "largest_warmup": settings[-1],
                             "change_percent": change, "largest_pair_change_percent": tail_change})
        if max(change, tail_change) > gates["warmup_change_percent"]:
            errors.append(f"{label}: warmup change {change:.3f}% exceeds gate")
        if chosen["cycle_error_percent"] > gates["cycle_error_percent"]:
            errors.append(f"{label}: sampled cycle error exceeds gate")
        if chosen["replay_wall_speedup"] < gates["minimum_wall_speedup"]:
            errors.append(f"{label}: replay wall speedup is below gate")
        selected.setdefault(key[:-1], {})[key[-1]] = chosen
    rankings = []
    for condition, models in selected.items():
        if len({row["model_sha256"] for row in models.values()}) < gates["minimum_models"]:
            errors.append(f"{condition!s}: not enough distinct RTL models")
        for left, right in combinations(sorted(models), 2):
            a, b = models[left], models[right]
            full_speedup = a["full_cycles"] / b["full_cycles"]
            sampled_speedup = a["estimated_cycles"] / b["estimated_cycles"]
            error = relative_error(sampled_speedup, full_speedup)
            margin = abs(full_speedup - 1) * 100
            ordered = ((full_speedup >= 1) == (sampled_speedup >= 1) or
                       margin <= gates["ranking_tie_percent"])
            left_sources = streams[condition[:-1] + (left, selected_warmup)]
            right_sources = streams[condition[:-1] + (right, selected_warmup)]
            windows = {kind: matched_streams(x, y) for kind, x, y in
                       zip(("full", "sample"), left_sources, right_sources)}
            rankings.append({"region": condition[-1], "models": [left, right],
                             "read_latency": condition[1], "write_latency": condition[2],
                             "full_speedup": full_speedup, "sampled_speedup": sampled_speedup,
                             "speedup_error_percent": error, "ranking_preserved": ordered,
                             "matched_windows": windows})
            if not ordered or error > gates["speedup_error_percent"]:
                errors.append(f"{condition[-1]}/{left}/{right}: performance ranking or speedup failed")
    if not rows:
        errors.append("no full/sample comparisons")
    return {"schema": "raptor-simpoint-validation-v1", "complete": not errors,
            "selected_warmup": selected_warmup, "gates": gates, "comparisons": rows,
            "warmup_convergence": convergences, "rankings": rankings,
            "sources": sources, "errors": errors, "official_score": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--spec", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        spec = json.loads(args.spec.read_text())
        if spec.get("schema") != "raptor-simpoint-validation-spec-v1":
            raise ValueError("unknown validation specification")
        cases = [(args.spec.parent / row["full"], args.spec.parent / row["sample"])
                 for row in spec["comparisons"]]
        gates = {"cycle_error_percent": 5, "speedup_error_percent": 5,
                 "warmup_change_percent": 1, "minimum_wall_speedup": 2,
                 "minimum_models": 2, "ranking_tie_percent": 1}
        gates.update(spec.get("gates", {}))
        if any(not math.isfinite(value) or value < 0 for value in gates.values()):
            raise ValueError("invalid validation gate")
        if type(gates["minimum_models"]) is not int or gates["minimum_models"] < 2:
            raise ValueError("ranking validation requires at least two distinct RTL models")
        result = evaluate(cases, gates, spec["selected_warmup"])
        result["spec_sha256"] = digest(args.spec)
        write_json(args.output, result)
        print(f"Validated {len(result['comparisons'])} full/sample pairs; "
              f"passed={result['complete']}")
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(1, f"{error}\n")
    return int(not result["complete"])


if __name__ == "__main__":
    raise SystemExit(main())
