#!/usr/bin/env python3
"""Create reproducible phase samples and combine instruction-weighted measurements.

Uses BBVs, deterministic random projection and weighted k-means/BIC. This is a
small independent implementation, not a claim of bit equivalence to SimPoint 3.
"""
from __future__ import annotations

import argparse
from bisect import bisect_right
import hashlib
import json
import math
from pathlib import Path
import random


def digest(path: Path) -> str:
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def positive(value, label):
    if type(value) is not int or value <= 0:
        raise ValueError(f"{label} must be a positive integer")
    return value


def read_profile(path: Path, allow_prefix=False):
    with path.open() as stream:
        return _read_profile(stream, path, allow_prefix)


def _read_profile(stream, path, allow_prefix):
    rows, footer, markers = [], None, []
    projection_cache = {}
    previous_signature = None
    cursor = 0
    for number, line in enumerate(stream, 1):
        if not line.strip() or line.startswith("#"):
            continue
        if footer is not None:
            raise ValueError(f"{path}:{number}: data after profile footer")
        if line.startswith("T"):
            blocks = {}
            for field in line[1:].split():
                pieces = field.split(":")
                if len(pieces) != 3 or pieces[0] or pieces[1] in blocks:
                    raise ValueError(f"{path}:{number}: malformed SimPoint BBV")
                blocks[pieces[1]] = positive(int(pieces[2]), "block count")
            row = {"start": cursor, "instructions": sum(blocks.values()), "blocks": blocks}
        else:
            row = json.loads(line)
            if row.get("schema") == "raptor-bbv-marker-v1":
                markers.append(row)
                continue
            if row.get("schema") == "raptor-bbv-end-v1":
                footer = row
                continue
            if row.get("schema") != "raptor-bbv-v1":
                raise ValueError(f"{path}:{number}: unknown BBV schema")
        count = positive(row.get("instructions"), "interval instructions")
        if type(row.get("start")) is not int or row["start"] != cursor:
            raise ValueError(f"{path}:{number}: noncontiguous interval")
        blocks = row.get("blocks")
        if not isinstance(blocks, dict) or not blocks:
            raise ValueError(f"{path}:{number}: empty BBV")
        if sum(positive(n, "block count") for n in blocks.values()) != count:
            raise ValueError(f"{path}:{number}: BBV instruction total differs")
        if "privileges" in row and sum(row["privileges"]) != count:
            raise ValueError(f"{path}:{number}: privilege counts differ")
        if "start_signature" in row or "end_signature" in row:
            for key in ("start_signature", "end_signature"):
                value = row.get(key)
                if (not isinstance(value, str) or len(value) != 16 or
                        any(c not in "0123456789abcdef" for c in value)):
                    raise ValueError(f"{path}:{number}: invalid instruction stream signature")
            if previous_signature is not None and row["start_signature"] != previous_signature:
                raise ValueError(f"{path}:{number}: discontinuous instruction stream signature")
            previous_signature = row["end_signature"]
        # Keep only projected vectors in memory; the sparse source remains on
        # disk. A full application can have tens of thousands of intervals.
        row["vector"] = project([row], signs=projection_cache)[0]
        del row["blocks"]
        rows.append(row)
        cursor += count
    if not rows:
        raise ValueError("profile contains no instructions")
    if footer and footer.get("retired") != cursor:
        raise ValueError("profile footer instruction count differs")
    if footer:
        footer["markers"] = markers
    if not allow_prefix and (not footer or footer.get("complete") is not True):
        raise ValueError("profile is not complete; use --allow-prefix for a deliberate bounded ROI")
    return rows, footer


def project(rows, dimensions=15, signs=None):
    signs = {} if signs is None else signs
    vectors = []
    for row in rows:
        if "vector" in row:
            vectors.append(row["vector"])
            continue
        vector = [0.0] * dimensions
        for feature, count in row["blocks"].items():
            if feature not in signs:
                bits = int.from_bytes(hashlib.sha256(feature.encode()).digest(), "little")
                signs[feature] = [1 if bits >> axis & 1 else -1 for axis in range(dimensions)]
            fraction = count / row["instructions"]
            for axis, sign in enumerate(signs[feature]):
                vector[axis] += fraction * sign
        vectors.append(vector)
    return vectors


def distance(left, right):
    return sum((a - b) ** 2 for a, b in zip(left, right))


def kmeans(vectors, weights, clusters, seed):
    rng = random.Random(seed)
    centers = [vectors[rng.randrange(len(vectors))][:]]
    for _ in range(1, clusters):
        distances = [min(distance(v, c) for c in centers) * w
                     for v, w in zip(vectors, weights)]
        if not any(distances):
            break
        index = rng.choices(range(len(vectors)), weights=distances)[0]
        centers.append(vectors[index][:])
    assignments = None
    for _ in range(100):
        updated = [min(range(len(centers)), key=lambda c: distance(v, centers[c]))
                   for v in vectors]
        if assignments == updated:
            break
        assignments = updated
        for cluster in range(len(centers)):
            indices = [i for i, c in enumerate(assignments) if c == cluster]
            if not indices:
                continue
            total = sum(weights[i] for i in indices)
            centers[cluster] = [sum(vectors[i][axis] * weights[i] for i in indices) / total
                                for axis in range(len(vectors[0]))]
    sse = sum(w * distance(v, centers[c]) for v, w, c in zip(vectors, weights, assignments))
    return sse, assignments, centers


def cluster_rows(rows, kmax=4, seeds=5):
    vectors = project(rows)
    # Normalize instruction weights to a mean of one for BIC's sample count.
    mean = sum(r["instructions"] for r in rows) / len(rows)
    weights = [r["instructions"] / mean for r in rows]
    candidates = []
    for k in range(1, min(kmax, len(rows)) + 1):
        sse, assignment, centers = min(
            (kmeans(vectors, weights, k, seed) for seed in range(seeds)), key=lambda r: r[0])
        groups = [c for c in range(len(centers)) if c in assignment]
        n, dimensions = len(rows), len(vectors[0])
        variance = max(sse / max(dimensions * (n - len(groups)), 1), 1e-12)
        likelihood = 0.0
        for c in groups:
            size = sum(w for w, group in zip(weights, assignment) if group == c)
            likelihood += size * math.log(size / n) - size * dimensions / 2 * math.log(
                2 * math.pi * variance) - max(size - 1, 0) * dimensions / 2
        bic = likelihood - len(groups) * (dimensions + 1) / 2 * math.log(n)
        candidates.append((bic, assignment, centers, groups))
    low, high = min(r[0] for r in candidates), max(r[0] for r in candidates)
    chosen = next(r for r in candidates if r[0] >= low + 0.9 * (high - low))
    _, assignment, centers, groups = chosen
    representatives = []
    for cluster in groups:
        members = [i for i, c in enumerate(assignment) if c == cluster]
        representative = min(members, key=lambda i: (distance(vectors[i], centers[cluster]), i))
        representatives.append((representative, sum(rows[i]["instructions"] for i in members)))
    return sorted(representatives)


def make_plan(path, rows, footer, regions, warmup, kmax=4, seeds=5):
    rows_by_start = {row["start"]: row for row in rows}
    result = {"schema": "raptor-sample-plan-v1", "method": "BBV weighted k-means/BIC",
              "profile_sha256": digest(path), "profile_complete": bool(
                  footer and footer.get("complete")),
              "counting": "retired" if footer else "frontend BBV instruction weights",
              "retirement_domain": footer.get("retirement_domain", {"mode": "all"}) if footer
                                   else {"mode": "frontend"},
              "settings": {"warmup": warmup, "kmax": kmax, "seeds": seeds,
                           "warmup_alignment": "previous-BBV-boundary",
                           "projection": "sha256-signed-15-v1"}, "regions": []}
    seen = set()
    for region in regions:
        name, start, end = region["name"], region["start"], region["end"]
        if not isinstance(name, str) or not name or name in seen:
            raise ValueError("region names must be nonempty and unique")
        seen.add(name)
        if type(start) is not int or type(end) is not int or not 0 <= start < end:
            raise ValueError(f"{name}: invalid region range")
        selected = [r for r in rows if r["start"] < end and r["start"] + r["instructions"] > start]
        if not selected or selected[0]["start"] != start or (
                selected[-1]["start"] + selected[-1]["instructions"] != end):
            raise ValueError(f"{name}: region boundaries must match BBV intervals")
        floor = region.get("warmup_start", start)
        if type(floor) is not int or not 0 <= floor <= start or floor not in rows_by_start:
            raise ValueError(f"{name}: warmup_start must be a preceding BBV boundary")
        points = []
        starts = [row["start"] for row in rows if floor <= row["start"] < end]
        for index, (representative, represented) in enumerate(cluster_rows(selected, kmax, seeds)):
            row = selected[representative]
            requested_checkpoint = max(floor, row["start"] - warmup)
            checkpoint_start = starts[bisect_right(starts, requested_checkpoint) - 1]
            actual_warmup = row["start"] - checkpoint_start
            point = {"id": f"{name}:{index}", "start": row["start"],
                     "checkpoint_start": row["start"] - actual_warmup,
                     "warmup": actual_warmup, "instructions": row["instructions"],
                     "represented_instructions": represented, "weight": represented / (end - start)}
            for key in ("start_pc", "next_pc", "guest_start", "start_signature"):
                if key in row:
                    point[key] = row[key]
            checkpoint_row = rows_by_start.get(point["checkpoint_start"], {})
            if "guest_start" in checkpoint_row:
                point["checkpoint_guest_start"] = checkpoint_row["guest_start"]
            if "start_pc" in checkpoint_row:
                point["checkpoint_pc"] = checkpoint_row["start_pc"]
            if "start_signature" in checkpoint_row:
                point["checkpoint_signature"] = checkpoint_row["start_signature"]
            points.append(point)
        result["regions"].append({"name": name, "start": start, "end": end,
                                  "warmup_start": floor,
                                  "instructions": end - start, "points": points})
    total = sum(r["instructions"] for r in result["regions"])
    points = [p for r in result["regions"] for p in r["points"]]
    sampled = sum(p["instructions"] + p["warmup"] for p in points)
    result.update(instructions=total, sampled_instructions=sampled,
                  instruction_reduction=total / sampled, points=len(points))
    return result


def summarize(plan, measurements):
    if plan.get("schema") != "raptor-sample-plan-v1":
        raise ValueError("unknown sample plan schema")
    rows = {}
    for row in measurements:
        key = row["profile"], row["id"]
        if key in rows:
            raise ValueError(f"duplicate measurement: {key}")
        rows[key] = row
    profiles = sorted({key[0] for key in rows})
    if not profiles:
        raise ValueError("no measurements")
    result = {"schema": "raptor-sample-results-v1", "official_score": False,
              "complete": True, "regions": [], "errors": []}
    expected = {p["id"] for r in plan["regions"] for p in r["points"]}
    if any(key[1] not in expected for key in rows):
        raise ValueError("measurement refers to an unknown point")
    for region in plan["regions"]:
        if not math.isclose(sum(p["weight"] for p in region["points"]), 1, abs_tol=1e-8):
            raise ValueError("region weights do not sum to one")
        estimates = {}
        for profile in profiles:
            cpi = 0.0
            valid = True
            for point in region["points"]:
                row = rows.get((profile, point["id"]))
                if (row is None or row.get("passed") is not True or
                        row.get("instructions") != point["instructions"]):
                    result["errors"].append(f"missing/failed/wrong-length point: {profile}/{point['id']}")
                    valid = False
                    continue
                cycles = positive(row.get("cycles"), "measurement cycles")
                if row.get("start") != point["start"]:
                    raise ValueError("measurement start differs from sample plan")
                cpi += point["weight"] * cycles / row["instructions"]
            if valid:
                estimates[profile] = {"cpi": cpi, "cycles": region["instructions"] * cpi}
            else:
                result["complete"] = False
        result["regions"].append({"name": region["name"], "profiles": estimates})
    return result


def write_json(path, result):
    with path.open("x") as stream:
        json.dump(result, stream, indent=2, allow_nan=False)
        stream.write("\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    select = commands.add_parser("select", help="select representative intervals")
    select.add_argument("--bbv", required=True, type=Path)
    select.add_argument("--output", required=True, type=Path)
    select.add_argument("--regions", type=Path, help="JSON list of name/start/end regions")
    select.add_argument("--profile-manifest", type=Path, help="profile.py provenance for capture")
    select.add_argument("--name", default="workload")
    select.add_argument("--warmup", type=int, default=5000000)
    select.add_argument("--kmax", type=int, default=4)
    select.add_argument("--seeds", type=int, default=5)
    select.add_argument("--allow-prefix", action="store_true")
    combine = commands.add_parser("summarize", help="combine instruction-weighted CPI")
    combine.add_argument("--plan", required=True, type=Path)
    combine.add_argument("--measurements", required=True, type=Path)
    combine.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        if args.command == "select":
            if args.warmup < 0 or min(args.kmax, args.seeds) < 1:
                raise ValueError("warmup must be nonnegative; kmax and seeds must be positive")
            rows, footer = read_profile(args.bbv, args.allow_prefix)
            regions = json.loads(args.regions.read_text()) if args.regions else [
                {"name": args.name, "start": 0,
                 "end": rows[-1]["start"] + rows[-1]["instructions"]}]
            result = make_plan(args.bbv, rows, footer, regions, args.warmup, args.kmax, args.seeds)
            if args.profile_manifest:
                manifest = json.loads(args.profile_manifest.read_text())
                if (manifest.get("schema") != "raptor-bbv-profile-v1" or
                        manifest.get("complete") is not True or
                        manifest.get("bbv_sha256") != result["profile_sha256"]):
                    raise ValueError("profile manifest is incomplete or belongs to another BBV")
                result["profile_inputs"] = manifest["inputs"]
                result["entropy_policy"] = manifest["entropy_policy"]
                result["scope"] = manifest["scope"]
        else:
            result = summarize(json.loads(args.plan.read_text()),
                               json.loads(args.measurements.read_text()))
        write_json(args.output, result)
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(1, f"{error}\n")
    return int(result.get("complete") is False)


if __name__ == "__main__":
    raise SystemExit(main())
