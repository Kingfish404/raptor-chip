#!/usr/bin/env python3
"""Prepare full references, warmup studies and one union of native checkpoints."""
from __future__ import annotations

import argparse
from bisect import bisect_right
import copy
import json
from pathlib import Path
import time

from simpoints import digest, make_plan, read_profile, write_json


def full_plan(template, rows, regions, warmup):
    result = copy.deepcopy(template)
    result.update(method="Full ROI reference without sampling", regions=[])
    result["settings"]["warmup"] = warmup
    for region in regions:
        name, start, end = (region[key] for key in ("name", "start", "end"))
        floor = region.get("warmup_start", start)
        available = [row for row in rows if floor <= row["start"] <= start]
        index = bisect_right([row["start"] for row in available], max(floor, start - warmup)) - 1
        checkpoint = available[index]
        first = next(row for row in rows if row["start"] == start)
        actual = start - checkpoint["start"]
        point = {"id": name + ":full", "start": start, "checkpoint_start": checkpoint["start"],
                 "warmup": actual, "instructions": end - start,
                 "represented_instructions": end - start, "weight": 1,
                 "start_pc": first["start_pc"], "guest_start": first["guest_start"],
                 "start_signature": first["start_signature"],
                 "checkpoint_guest_start": checkpoint["guest_start"],
                 "checkpoint_pc": checkpoint["start_pc"],
                 "checkpoint_signature": checkpoint["start_signature"]}
        result["regions"].append({"name": name, "start": start, "end": end,
                                  "instructions": end - start, "warmup_start": floor,
                                  "points": [point]})
    points = [p for r in result["regions"] for p in r["points"]]
    result.update(points=len(points), sampled_instructions=sum(
        p["instructions"] + p["warmup"] for p in points))
    result["instruction_reduction"] = result["instructions"] / result["sampled_instructions"]
    return result


def checkpoint_union(plans):
    result = copy.deepcopy(plans[0])
    result.update(method="Checkpoint capture union; not a performance estimate", regions=[])
    unique = {}
    for plan in plans:
        for region in plan["regions"]:
            for point in region["points"]:
                key = point["checkpoint_guest_start"]
                if key in unique:
                    if unique[key]["checkpoint_signature"] != point["checkpoint_signature"]:
                        raise ValueError("plans disagree on checkpoint instruction prefixes")
                else:
                    unique[key] = copy.deepcopy(point)
    for offset, point in sorted(unique.items()):
        name = f"checkpoint-{offset}"
        point.update(id=name, weight=1, represented_instructions=point["instructions"])
        result["regions"].append({"name": name, "start": point["start"],
            "end": point["start"] + point["instructions"], "instructions": point["instructions"],
            "points": [point]})
    result.update(points=len(unique), instructions=sum(r["instructions"] for r in result["regions"]))
    result["sampled_instructions"] = sum(p["instructions"] + p["warmup"] for p in unique.values())
    result["instruction_reduction"] = result["instructions"] / result["sampled_instructions"]
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("bbv", "profile-manifest", "regions", "output"):
        parser.add_argument("--" + name, required=True, type=Path)
    parser.add_argument("--warmups", nargs="+", type=int, default=[0, 100000, 500000])
    parser.add_argument("--full-warmup", type=int, default=500000)
    parser.add_argument("--kmax", type=int, default=4)
    parser.add_argument("--seeds", type=int, default=5)
    args = parser.parse_args()
    started = time.monotonic()
    try:
        if min(*args.warmups, args.full_warmup) < 0 or min(args.kmax, args.seeds) < 1:
            raise ValueError("invalid warmup or clustering settings")
        rows, footer = read_profile(args.bbv)
        profile = json.loads(args.profile_manifest.read_text())
        if (profile.get("schema") != "raptor-bbv-profile-v1" or not profile.get("complete") or
                profile["bbv_sha256"] != digest(args.bbv)):
            raise ValueError("profile provenance is incomplete or mismatched")
        if any("start_signature" not in row for row in rows):
            raise ValueError("native instruction-prefix fingerprints are required")
        regions = json.loads(args.regions.read_text())
        args.output = args.output.resolve()
        args.output.mkdir(parents=True, exist_ok=False)
        plans = {}
        for warmup in sorted(set(args.warmups)):
            plan = make_plan(args.bbv, rows, footer, regions, warmup, args.kmax, args.seeds)
            plan.update(profile_inputs=profile["inputs"], entropy_policy=profile["entropy_policy"],
                        scope=profile["scope"])
            plans[f"warmup-{warmup}"] = plan
        plans["full"] = full_plan(next(iter(plans.values())), rows, regions, args.full_warmup)
        plans["capture-union"] = checkpoint_union(list(plans.values()))
        manifest = {"schema": "raptor-evaluation-plans-v1", "plans": {},
                    "sources": {name: digest(getattr(args, name)) for name in (
                        "bbv", "profile_manifest", "regions")}}
        for label, plan in plans.items():
            path = args.output / (label + ".json")
            write_json(path, plan)
            manifest["plans"][label] = {"file": path.name, "sha256": digest(path),
                                         "points": plan["points"]}
        manifest["wall_seconds"] = time.monotonic() - started
        write_json(args.output / "plans.json", manifest)
        print(f"Prepared {len(plans) - 1} evaluation plans and "
              f"{plans['capture-union']['points']} unique checkpoints", flush=True)
    except (OSError, ValueError, KeyError, TypeError, StopIteration) as error:
        parser.exit(1, f"{error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
