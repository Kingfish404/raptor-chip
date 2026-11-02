#!/usr/bin/env python3
"""Derive exact user-process intervals from native full-system BBVs.

An interval containing exclusively this process may begin a new interval.
An optional fingerprinted capture can instead supply proven user boundaries.
Mixed kernel/user intervals merge into the preceding interval, preserving its
known first PC, absolute checkpoint offset and full-prefix signature. Kernel
execution is excluded from the progress count, but remains in replay cycles.
"""
from __future__ import annotations

import argparse
from collections import Counter
import copy
import json
from pathlib import Path
import time

from simpoints import digest, read_profile, write_json
from capture import reusable_points


def root(satp):
    # satp.MODE distinguishes Sv32 from the supported RV64 Sv39 contexts.
    mask = 0xF0000FFFFFFFFFFF if satp > 0xFFFFFFFF else 0x803FFFFF
    return satp & mask


def user_blocks(row, satp_root):
    result = {}
    for key, count in row["blocks"].items():
        privilege, satp, _pc = key.split(":")
        if privilege == "0" and root(int(satp, 16)) == satp_root:
            result[key] = count
    return result


def derive(rows, satp_root, boundaries=None):
    current, cursor = None, 0
    for row in rows:
        blocks = user_blocks(row, satp_root)
        count = sum(blocks.values())
        safe_start = count == row["instructions"]
        if boundaries is not None:
            boundary = boundaries.get(row["guest_start"])
            safe_start = boundary is not None
            if safe_start and (not count or
                    int(boundary["pc"], 16) != int(row["start_pc"], 16) or
                    boundary["signature"] != row["start_signature"]):
                raise ValueError("captured user boundary differs from the native BBV fingerprint")
        if safe_start:
            if current is not None:
                yield current
                cursor += current["instructions"]
            current = copy.deepcopy(row)
            current.update(start=cursor, instructions=0, blocks={}, privileges=[0, 0, 0, 0],
                           raw_start=row["start"], raw_instructions=0, trapped_attempts=0)
            current.pop("next_pc", None)
            # Filtering/coalescing changes the progress domain. Native ordered
            # PC bands cannot be relabelled as a trace of the derived stream.
            for field in ("pc_digest_algorithm", "pc_digest_start", "pc_digest_end",
                          "pc_band", "last_pc"):
                current.pop(field, None)
        if current is None:
            continue
        current["instructions"] += count
        current["privileges"][0] += count
        current["raw_instructions"] += row["instructions"]
        current["trapped_attempts"] += row.get("trapped_attempts", 0)
        current["end_signature"] = row["end_signature"]
        for key, value in blocks.items():
            current["blocks"][key] = current["blocks"].get(key, 0) + value
    if current is not None:
        yield current


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("bbv", "profile-manifest", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--satp-root", type=lambda value: int(value, 0))
    parser.add_argument("--checkpoint-capture", type=Path,
                        help="coalesce only at proven user checkpoints in this matching capture")
    args = parser.parse_args()
    started = time.monotonic()
    try:
        profile = json.loads(args.profile_manifest.read_text())
        if (profile.get("complete") is not True or profile["bbv_sha256"] != digest(args.bbv)):
            raise ValueError("incomplete or changed source profile")
        _checked, footer = read_profile(args.bbv)
        rows = [json.loads(line) for line in args.bbv.read_text().splitlines()]
        rows = [row for row in rows if row.get("schema") == "raptor-bbv-v1"]
        roots = Counter()
        for row in rows:
            for key, count in row["blocks"].items():
                privilege, satp, _pc = key.split(":")
                if privilege == "0":
                    roots[root(int(satp, 16))] += count
        selected_root = args.satp_root
        if selected_root is None:
            if len(roots) != 1:
                raise ValueError("select --satp-root explicitly when multiple user processes exist")
            selected_root = next(iter(roots))
        domain = {"mode": "user", "satp_root": hex(selected_root), "include_kernel_cycles": True}
        boundaries = None
        if args.checkpoint_capture:
            hashes = {name: profile["inputs"][name]["sha256"]
                      for name in ("nemu", "firmware", "dtb")}
            checkpoints, _sources = reusable_points([args.checkpoint_capture], hashes)
            boundaries = {}
            for offset, (directory, _files) in checkpoints.items():
                metadata = json.loads((directory / "sample.json").read_text())
                state = dict(line.split("=", 1) for line in
                             (directory / "state.txt").read_text().splitlines() if "=" in line)
                if metadata["privilege"] != 0 or root(int(state["csr_satp"], 0)) != selected_root:
                    raise ValueError("captured boundary is not in the selected user process")
                boundaries[offset] = metadata
            raw_offsets = {row["guest_start"] for row in rows}
            if not boundaries or not boundaries.keys() <= raw_offsets:
                raise ValueError("captured boundaries must coincide with native BBV starts")
        filtered = list(derive(rows, selected_root, boundaries))
        if not filtered:
            raise ValueError("no unambiguous user-mode interval boundaries")
        args.output.mkdir(parents=True, exist_ok=False)
        output = args.output / "profile.bbv.jsonl"
        total = sum(row["instructions"] for row in filtered)
        end = {key: value for key, value in footer.items() if key != "markers"}
        end.update(retired=total, retirement_domain=domain, roi_limit=total)
        with output.open("x") as stream:
            for row in filtered:
                stream.write(json.dumps(row, separators=(",", ":")) + "\n")
            stream.write(json.dumps(end, separators=(",", ":")) + "\n")
        read_profile(output)
        profile.update(bbv_sha256=digest(output), intervals=len(filtered), retired=total,
                       retirement_domain=domain, scope="derived-user-process-window",
                       derivation={"method": "coalesce-mixed-native-intervals-v1",
                                   "bbv_sha256": digest(args.bbv),
                                   "profile_sha256": digest(args.profile_manifest),
                                   "raw_start": filtered[0]["raw_start"],
                                   "user_roots": {hex(key): value for key, value in roots.items()},
                                   "wall_seconds": time.monotonic() - started})
        if args.checkpoint_capture:
            profile["derivation"]["checkpoint_capture_sha256"] = digest(args.checkpoint_capture)
        write_json(args.output / "profile.json", profile)
        print(f"Derived {len(filtered)} intervals / {total} user retirements; "
              "kernel cycles remain included during replay")
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(1, f"{error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
