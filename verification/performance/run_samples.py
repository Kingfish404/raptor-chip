#!/usr/bin/env python3
"""Compare archived RTL models on exact matched sample windows, without cycle logs."""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import json
import os
from pathlib import Path
import subprocess
import time

from simpoints import digest, summarize, write_json
from execution import run_logged

ROOT = Path(__file__).resolve().parents[2]


def check_checkpoint_domain(directory, domain):
    if domain.get("mode", "all") != "user":
        return
    fields = dict(line.split("=", 1) for line in (directory / "state.txt").read_text().splitlines()
                  if "=" in line)
    mask = 0xF0000FFFFFFFFFFF if int(fields["xlen"]) == 64 else 0x803FFFFF
    if int(fields["priv"], 0) != 0 or (
            int(fields["csr_satp"], 0) & mask) != int(domain["satp_root"], 0):
        raise ValueError("checkpoint is outside the selected user address space")
    if "thread_pointer" in domain and int(fields["gpr4"], 0) != int(domain["thread_pointer"], 0):
        raise ValueError("checkpoint belongs to a different user thread")


def load_capture(plan_path, capture_path):
    plan = json.loads(plan_path.read_text())
    capture = json.loads(capture_path.read_text())
    if (plan.get("schema") != "raptor-sample-plan-v1" or
            capture.get("schema") != "raptor-sample-capture-v1" or
            capture.get("complete") is not True or
            capture["inputs"]["plan"]["sha256"] != digest(plan_path)):
        raise ValueError("capture does not match the selected plan")
    checkpoints = {}
    required = {"state.txt", "mem_pmem.bin", "mem_pmem.bin.meta", "sample.json"}
    for row in capture["points"]:
        directory = (capture_path.parent / row["directory"]).resolve()
        if set(row["files"]) != required:
            raise ValueError("checkpoint file hashes are incomplete")
        for name, expected in row["files"].items():
            if digest(directory / name) != expected:
                raise ValueError(f"checkpoint changed: {directory / name}")
        check_checkpoint_domain(directory, plan.get("retirement_domain", {"mode": "all"}))
        if row["id"] in checkpoints:
            raise ValueError("duplicate captured point")
        checkpoints[row["id"]] = directory
    points = [p for r in plan["regions"] for p in r["points"]]
    if not points or len({p["id"] for p in points}) != len(points):
        raise ValueError("sample plan has no points or duplicate point IDs")
    if {p["id"] for p in points} != set(checkpoints):
        raise ValueError("capture does not contain exactly the selected points")
    return plan, points, checkpoints


def matched_window(before, after, point):
    for window in (before, after):
        if (window.get("schema") != "raptor-window-v1" or window.get("complete") is not True or
                window.get("warmup") != point["warmup"] or
                window.get("instructions") != point["instructions"]):
            raise ValueError("incomplete or incompatible sample window")
        if "start_pc" in point and int(window.get("start_pc", "0"), 16) != int(point["start_pc"], 16):
            raise ValueError("restored measurement PC differs from the selected profile interval")
    def index(window):
        result = {}
        for row in window["boundaries"]:
            count = row["instructions"]
            if count in result or count < 0 or row["cycle"] < 0:
                raise ValueError("duplicate or invalid window boundary")
            result[count] = row
        return result
    old, new = index(before), index(after)
    shared = sorted(old.keys() & new.keys())
    for start in shared:
        end = start + point["instructions"]
        if not point["warmup"] <= start <= point["warmup"] + 64 or end not in shared:
            continue
        for count in (start, end):
            if (old[count]["signature"] != new[count]["signature"] or
                    old[count]["last_pc"] != new[count]["last_pc"]):
                raise ValueError("sample instruction streams diverged")
        old_cycles = old[end]["cycle"] - old[start]["cycle"]
        new_cycles = new[end]["cycle"] - new[start]["cycle"]
        if min(old_cycles, new_cycles) <= 0:
            raise ValueError("nonpositive measured cycle count")
        return {"start": point["start"] + start - point["warmup"],
                "instructions": end - start, "baseline_cycles": old_cycles,
                "candidate_cycles": new_cycles, "boundary_shift": start - point["warmup"],
                "speedup": old_cycles / new_cycles}
    raise ValueError("no identical retirement boundaries with the requested window length")


def run_one(args, point, profile, simulator, directory):
    work = args.output / f"point-{point['ordinal']}" / profile
    work.mkdir(parents=True)
    window = work / "window.json"
    command = [str(simulator), "-b", "-n", "--no-lightsss", "-t", str(args.timeout),
               "-m", str(args.cycle_limit), "--ckpt-load=" + str(directory),
               "--sample-output=" + str(window), f"--sample-warmup={point['warmup']}",
               f"--sample-instructions={point['instructions']}",
               f"--mem-read-latency={args.read_latency}",
               f"--mem-write-latency={args.write_latency}", "--mem-random-delay=0"]
    if args.reference:
        command += ["-d", str(args.reference)]
    if args.mrom:
        command += ["-r", str(args.mrom)]
    domain = getattr(args, "retirement_domain", {"mode": "all"})
    if domain["mode"] == "user":
        command += ["--sample-user-satp=" + domain["satp_root"]]
        if "thread_pointer" in domain:
            command += ["--sample-user-tp=" + domain["thread_pointer"]]
    row = {"id": point["id"], "profile": profile, "passed": False, "command": command}
    started = time.monotonic()
    try:
        environment = {**os.environ, "NSIM_PROGRESS_CYCLES": "40000000"}
        row.update(run_logged(command, work / "run.log", args.timeout + 30,
                              cwd=ROOT / "sim", env=environment, stop=getattr(args, "stop", None)))
        if row["returncode"] or row["fatal"] or row["timed_out"] or row.get("cancelled"):
            raise ValueError("RTL run failed")
        row["window"] = json.loads(window.read_text())
        if row["window"].get("complete") is not True:
            raise ValueError("RTL did not finish the sample")
        actual = row["window"].get("retirement_domain", {"mode": "all"})
        if actual["mode"] != domain["mode"] or (domain["mode"] == "user" and
                int(actual["satp_root"], 0) != int(domain["satp_root"], 0)) or (
                "thread_pointer" in domain and
                int(actual.get("thread_pointer", "0"), 0) != int(domain["thread_pointer"], 0)):
            raise ValueError("RTL measured a different retirement domain")
        if args.reference and "resynchronized difftest REF" not in (work / "run.log").read_text():
            raise ValueError("reference did not synchronize to the checkpoint")
        row["passed"] = True
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        row["error"] = str(error)
    row["wall_seconds"] = time.monotonic() - started
    return row


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("plan", "capture", "baseline", "candidate", "output"):
        parser.add_argument("--" + name, required=True, type=Path)
    parser.add_argument("--reference", type=Path)
    parser.add_argument("--mrom", type=Path)
    parser.add_argument("--read-latency", type=int, required=True)
    parser.add_argument("--write-latency", type=int, required=True)
    parser.add_argument("--cycle-limit", type=int, default=1000000000)
    parser.add_argument("--timeout", type=int, default=900)
    parser.add_argument("--jobs", type=int, default=1)
    parser.add_argument("--smoke-instructions", type=int, default=0,
                        help="check N instructions directly after resume; produce no performance estimate")
    args = parser.parse_args()
    try:
        if min(args.read_latency, args.write_latency, args.smoke_instructions) < 0 or min(
                args.cycle_limit, args.timeout, args.jobs) < 1:
            raise ValueError("invalid latency, cycle limit, timeout or jobs")
        for name in ("plan", "capture", "baseline", "candidate", "output", "reference", "mrom"):
            path = getattr(args, name)
            if path is not None:
                setattr(args, name, path.resolve())
        plan, points, checkpoints = load_capture(args.plan, args.capture)
        args.retirement_domain = plan.get("retirement_domain", {"mode": "all"})
        if args.smoke_instructions:
            for point in points:
                point.update(start=point["checkpoint_start"], warmup=0,
                             instructions=args.smoke_instructions, start_pc=point["checkpoint_pc"])
        args.output.mkdir(parents=True, exist_ok=False)
        inputs = {name: digest(getattr(args, name)) for name in (
            "plan", "capture", "baseline", "candidate", "reference", "mrom")
                  if getattr(args, name) is not None}
        result = {"schema": "raptor-sample-ab-v1", "complete": False, "inputs": inputs,
                  "scope": "functional-checkpoint-smoke" if args.smoke_instructions
                           else "sampled-performance",
                  "smoke_instructions": args.smoke_instructions,
                  "difftest": args.reference is not None, "runs": [], "comparisons": [],
                  "read_latency": args.read_latency, "write_latency": args.write_latency}
        with ThreadPoolExecutor(max_workers=args.jobs) as pool:
            futures = []
            for ordinal, point in enumerate(points):
                point["ordinal"] = ordinal
                for profile in ("baseline", "candidate"):
                    futures.append(pool.submit(run_one, args, point, profile,
                                               getattr(args, profile), checkpoints[point["id"]]))
            for future in as_completed(futures):
                result["runs"].append(future.result())
        indexed = {(r["profile"], r["id"]): r for r in result["runs"]}
        # Preserve exact original plan starts; a common boundary may be shifted
        # by at most 64 instructions to accommodate multi-instruction commit.
        measured_plan = json.loads(json.dumps(plan))
        measurements = []
        for region in measured_plan["regions"]:
            for point in region["points"]:
                before, after = (indexed[profile, point["id"]] for profile in (
                    "baseline", "candidate"))
                if not before["passed"] or not after["passed"]:
                    continue
                try:
                    comparison = matched_window(before["window"], after["window"], point)
                    result["comparisons"].append({"id": point["id"], **comparison})
                    point["start"] = comparison["start"]
                    for profile in ("baseline", "candidate"):
                        measurements.append({"id": point["id"], "profile": profile,
                                             "passed": True, "start": point["start"],
                                             "instructions": comparison["instructions"],
                                             "cycles": comparison[profile + "_cycles"]})
                except ValueError as error:
                    before.update(passed=False, error=str(error))
        result["estimates"] = (summarize(measured_plan, measurements)
                               if measurements and not args.smoke_instructions else None)
        result["complete"] = (all(r["passed"] for r in result["runs"]) and
                              len(result["comparisons"]) == len(points) and
                              (bool(args.smoke_instructions) or result["estimates"]["complete"]))
        for name, expected in inputs.items():
            if digest(getattr(args, name)) != expected:
                raise ValueError(f"input changed during evaluation: {name}")
        write_json(args.output / "results.json", result)
        print(f"Sample comparisons: {len(result['comparisons'])}/{len(points)}; "
              f"complete={result['complete']}")
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(1, f"{error}\n")
    return int(not result["complete"])


if __name__ == "__main__":
    raise SystemExit(main())
