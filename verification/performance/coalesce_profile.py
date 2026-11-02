#!/usr/bin/env python3
"""Merge contiguous native BBV intervals without changing the retirement stream."""
from __future__ import annotations

import argparse
import copy
import json
from pathlib import Path
import time

from pc_reference import ALGORITHM, PcReference
from simpoints import digest, positive, read_profile, write_json

PC_FIELDS = {"pc_digest_algorithm", "pc_digest_start", "pc_digest_end", "pc_band", "last_pc"}


def coalesce(rows, interval):
    positive(interval, "coalesced interval")
    rows = list(rows)
    bands = any(PC_FIELDS & row.keys() for row in rows)
    if bands and any(not PC_FIELDS <= row.keys() for row in rows):
        raise ValueError("source has incomplete native PC bands")
    cursor, current = 0, None
    for row in rows:
        if row["start"] != cursor:
            raise ValueError("source intervals are not contiguous")
        cursor += positive(row["instructions"], "source instructions")
        if current is None:
            current = copy.deepcopy(row)
            current.update(instructions=0, blocks={}, trapped_attempts=0)
            if "privileges" in row:
                current["privileges"] = [0] * len(row["privileges"])
            if bands:
                current["pc_band"] = []
        if current["instructions"] + row["instructions"] > interval:
            raise ValueError("coalescing would split a source interval")
        current["instructions"] += row["instructions"]
        current["trapped_attempts"] += row.get("trapped_attempts", 0)
        for key, count in row["blocks"].items():
            current["blocks"][key] = current["blocks"].get(key, 0) + count
        if "privileges" in current:
            if len(current["privileges"]) != len(row.get("privileges", [])):
                raise ValueError("source privilege layouts differ")
            current["privileges"] = [a + b for a, b in
                                     zip(current["privileges"], row["privileges"])]
        for key in ("next_pc", "end_signature"):
            if key in row:
                current[key] = row[key]
            else:
                current.pop(key, None)
        if bands:
            if row["pc_digest_algorithm"] != ALGORITHM:
                raise ValueError("unsupported native PC digest algorithm")
            expected = min(row["instructions"], 64)
            if len(row["pc_band"]) != expected:
                raise ValueError("source PC band length differs")
            needed = 64 - len(current["pc_band"])
            current["pc_band"].extend(copy.deepcopy(row["pc_band"][:needed]))
            current["pc_digest_end"] = row["pc_digest_end"]
            current["last_pc"] = row["last_pc"]
        if current["instructions"] == interval:
            yield current
            current = None
    if current is not None:
        yield current


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("bbv", "profile-manifest", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--interval", type=int, required=True)
    args = parser.parse_args()
    started = time.monotonic()
    try:
        profile = json.loads(args.profile_manifest.read_text())
        source_sha = digest(args.bbv)
        manifest_sha = digest(args.profile_manifest)
        if (profile.get("schema") != "raptor-bbv-profile-v1" or
                profile.get("complete") is not True or profile["bbv_sha256"] != source_sha):
            raise ValueError("source profile is incomplete or changed")
        _checked, footer = read_profile(args.bbv)
        records = [json.loads(line) for line in args.bbv.read_text().splitlines()
                   if line.strip() and not line.startswith("#")]
        rows = [row for row in records if row["schema"] == "raptor-bbv-v1"]
        bands = any(PC_FIELDS & row.keys() for row in rows)
        domain = footer.get("retirement_domain", {"mode": "all"})
        if bands:
            PcReference(args.bbv, source_sha, domain)
        merged = list(coalesce(rows, args.interval))
        end = {key: value for key, value in footer.items() if key != "markers"}
        args.output.mkdir(parents=True, exist_ok=False)
        output = args.output / "profile.bbv.jsonl"
        with output.open("x") as stream:
            for marker in footer["markers"]:
                stream.write(json.dumps(marker, separators=(",", ":")) + "\n")
            for row in [*merged, end]:
                stream.write(json.dumps(row, separators=(",", ":")) + "\n")
        read_profile(output)
        if bands:
            PcReference(output, digest(output), domain)
        if digest(args.bbv) != source_sha or digest(args.profile_manifest) != manifest_sha:
            raise ValueError("source profile changed during coalescing")
        profile.update(bbv_sha256=digest(output), intervals=len(merged),
            derivation={"method": "contiguous-native-interval-coalescing-v1",
                "bbv_sha256": source_sha, "profile_manifest_sha256": manifest_sha,
                "interval": args.interval, "source_intervals": len(rows),
                "retirement_stream_changed": False, "pc_bands_preserved": bands,
                "wall_seconds": time.monotonic() - started})
        write_json(args.output / "profile.json", profile)
        print(f"Coalesced {len(rows)} intervals into {len(merged)}; retirement stream unchanged")
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(1, f"{error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
