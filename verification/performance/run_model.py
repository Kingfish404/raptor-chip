#!/usr/bin/env python3
"""Measure one archived RTL configuration on a full or sampled ROI plan."""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import copy
import os
from pathlib import Path
import resource
import signal
import threading
import time

from run_samples import load_capture, matched_window, run_one
from simpoints import digest, summarize, write_json


def validate_full_plan(plan):
    for region in plan["regions"]:
        if len(region["points"]) != 1:
            raise ValueError("a full reference must have one point covering each entire ROI")
        point = region["points"][0]
        if (point["start"] != region["start"] or
                point["instructions"] != region["instructions"] or point["weight"] != 1):
            raise ValueError("full reference point does not cover its entire ROI")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("plan", "capture", "model", "output"):
        parser.add_argument("--" + name, required=True, type=Path)
    parser.add_argument("--name", required=True)
    parser.add_argument("--kind", choices=("full", "sample"), required=True)
    parser.add_argument("--reference", type=Path)
    parser.add_argument("--mrom", type=Path)
    parser.add_argument("--read-latency", required=True, type=int)
    parser.add_argument("--write-latency", required=True, type=int)
    parser.add_argument("--jobs", type=int, default=1)
    parser.add_argument("--timeout", type=int, default=3600)
    parser.add_argument("--cycle-limit", type=int, default=1000000000)
    args = parser.parse_args()
    started = time.monotonic()
    result = None
    try:
        if min(args.read_latency, args.write_latency) < 0 or min(
                args.jobs, args.timeout, args.cycle_limit) < 1:
            raise ValueError("invalid latency or execution budget")
        if not args.name or any(c in args.name for c in "/\\"):
            raise ValueError("model name must be nonempty and contain no path separator")
        for name in ("plan", "capture", "model", "output", "reference", "mrom"):
            value = getattr(args, name)
            if value is not None:
                setattr(args, name, value.resolve())
        plan, points, checkpoints = load_capture(args.plan, args.capture)
        args.retirement_domain = plan.get("retirement_domain", {"mode": "all"})
        if args.kind == "full":
            validate_full_plan(plan)
        args.output.mkdir(parents=True, exist_ok=False)
        inputs = {name: digest(getattr(args, name)) for name in (
            "plan", "capture", "model", "reference", "mrom")
                  if getattr(args, name) is not None}
        result = {"schema": "raptor-model-evaluation-v1", "complete": False,
                  "kind": args.kind, "name": args.name, "inputs": inputs,
                  "profile_sha256": plan["profile_sha256"],
                  "profile_inputs": plan["profile_inputs"], "settings": plan["settings"],
                  "retirement_domain": args.retirement_domain,
                  "read_latency": args.read_latency, "write_latency": args.write_latency,
                  "difftest": args.reference is not None, "jobs": args.jobs,
                  "host_cpus": os.cpu_count(), "runs": [], "measurements": []}
        args.stop = threading.Event()
        for signum in (signal.SIGINT, signal.SIGTERM):
            signal.signal(signum, lambda _signum, _frame: args.stop.set())
        measured_plan = copy.deepcopy(plan)
        cpu_before = resource.getrusage(resource.RUSAGE_CHILDREN)
        execution_start = time.monotonic()
        with ThreadPoolExecutor(max_workers=args.jobs) as pool:
            futures = []
            for ordinal, point in enumerate(points):
                point["ordinal"] = ordinal
                futures.append(pool.submit(run_one, args, point, args.name,
                                           args.model, checkpoints[point["id"]]))
            for future in as_completed(futures):
                result["runs"].append(future.result())
                temporary = args.output / "progress.tmp"
                write_json(temporary, {"state": "running", "finished": len(result["runs"]),
                                       "total": len(points), "runs": result["runs"]})
                os.replace(temporary, args.output / "progress.json")
        result["execution_wall_seconds"] = time.monotonic() - execution_start
        cpu_after = resource.getrusage(resource.RUSAGE_CHILDREN)
        result["child_cpu_seconds"] = (cpu_after.ru_utime + cpu_after.ru_stime -
                                       cpu_before.ru_utime - cpu_before.ru_stime)
        indexed = {row["id"]: row for row in result["runs"]}
        for region in measured_plan["regions"]:
            for point in region["points"]:
                row = indexed[point["id"]]
                if not row["passed"]:
                    continue
                try:
                    measured = matched_window(row["window"], row["window"], point)
                    point["start"] = measured["start"]
                    measurement = {"id": point["id"], "profile": args.name,
                        "passed": True, "start": measured["start"],
                        "instructions": measured["instructions"], "cycles": measured["baseline_cycles"],
                        "boundary_shift": measured["boundary_shift"]}
                    if "baseline_pmu" in measured:
                        measurement["pmu"] = measured["baseline_pmu"]
                    result["measurements"].append(measurement)
                except ValueError as error:
                    row.update(passed=False, error=str(error))
        result["estimates"] = (summarize(measured_plan, result["measurements"])
                               if result["measurements"] else None)
        result["regions"] = [{key: region[key] for key in ("name", "start", "end", "instructions")}
                             for region in plan["regions"]]
        for name, expected in inputs.items():
            if digest(getattr(args, name)) != expected:
                raise ValueError(f"input changed during execution: {name}")
        result["complete"] = (all(row["passed"] for row in result["runs"]) and
                              len(result["measurements"]) == len(points) and
                              result["estimates"]["complete"])
        result["wall_seconds"] = time.monotonic() - started
        write_json(args.output / "results.json", result)
        print(f"{args.kind}/{args.name}: {len(result['measurements'])}/{len(points)}; "
              f"complete={result['complete']}; wall={result['wall_seconds']:.3f}s", flush=True)
    except (OSError, ValueError, KeyError, TypeError) as error:
        if result is not None and not (args.output / "results.json").exists():
            result.update(complete=False, error=str(error), wall_seconds=time.monotonic() - started)
            write_json(args.output / "results.json", result)
        parser.exit(1, f"{error}\n")
    return int(not result["complete"])


if __name__ == "__main__":
    raise SystemExit(main())
