#!/usr/bin/env python3
"""Export selected architectural points in one deterministic NEMU pass."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import time

from simpoints import digest, write_json
from execution import run_logged
from run_samples import check_checkpoint_domain


FILES = ("state.txt", "mem_pmem.bin", "mem_pmem.bin.meta", "sample.json")


def reusable_points(manifests, hashes, wanted=None):
    available, sources = {}, []
    for path in manifests:
        path = path.resolve()
        parent = json.loads(path.read_text())
        if parent.get("schema") not in (
                "raptor-sample-capture-v1", "raptor-bbv-capture-grid-v1") or not parent.get("complete"):
            raise ValueError("cannot reuse an incomplete capture")
        for name in ("nemu", "firmware", "dtb"):
            if parent["inputs"][name]["sha256"] != hashes[name]:
                raise ValueError(f"reused capture has different input: {name}")
        sources.append({"path": str(path), "sha256": digest(path)})
        for row in parent["points"]:
            directory = (path.parent / row["directory"]).resolve()
            metadata = json.loads((directory / "sample.json").read_text())
            if wanted is not None and metadata["guest_start"] not in wanted:
                continue
            if set(row["files"]) != set(FILES):
                raise ValueError("reused capture has incomplete file hashes")
            for name in FILES:
                if digest(directory / name) != row["files"][name]:
                    raise ValueError(f"reused checkpoint changed: {directory / name}")
            offset = metadata["guest_start"]
            if offset in available and available[offset][1] != row["files"]:
                raise ValueError("reused checkpoints disagree at the same retirement count")
            available[offset] = directory, row["files"]
    return available, sources


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("nemu", "plan", "firmware", "dtb", "output"):
        parser.add_argument("--" + name, required=True, type=Path)
    parser.add_argument("--timeout", type=int, default=3600)
    parser.add_argument("--reuse", type=Path, action="append", default=[],
                        help="reuse matching immutable checkpoints; may be specified repeatedly")
    args = parser.parse_args()
    result = None
    try:
        if args.timeout <= 0:
            raise ValueError("timeout must be positive")
        inputs = {name: getattr(args, name).resolve()
                  for name in ("nemu", "plan", "firmware", "dtb")}
        hashes = {name: digest(path) for name, path in inputs.items()}
        plan = json.loads(inputs["plan"].read_text())
        if plan.get("schema") != "raptor-sample-plan-v1" or plan.get("counting") != "retired":
            raise ValueError("capture requires a NEMU retired-instruction sample plan")
        if plan.get("entropy_policy") != "fixed-dtb-v1":
            raise ValueError("capture requires --profile-manifest provenance from profile.py")
        for name in ("nemu", "firmware", "dtb"):
            if plan["profile_inputs"][name]["sha256"] != hashes[name]:
                raise ValueError(f"capture differs from the profiling input: {name}")
        points = [p for r in plan["regions"] for p in r["points"]]
        if not points or any("checkpoint_signature" not in point for point in points):
            raise ValueError("capture requires checkpoint stream fingerprints; regenerate the profile")
        offsets = sorted({p["checkpoint_guest_start"] for p in points})
        if not offsets or any(type(n) is not int or n < 0 for n in offsets):
            raise ValueError("invalid absolute checkpoint instruction counts")
        args.output = args.output.resolve()
        args.output.mkdir(parents=True, exist_ok=False)
        result = {"schema": "raptor-sample-capture-v1", "complete": False,
                  "inputs": {name: {"path": str(path), "sha256": hashes[name]}
                             for name, path in inputs.items()},
                  "points": []}
        if args.reuse:
            started = time.monotonic()
            available, sources = reusable_points(args.reuse, hashes, set(offsets))
            if not set(offsets) <= available.keys():
                raise ValueError("reuse does not cover all requested checkpoint offsets")
            directories = {offset: available[offset][0] for offset in offsets}
            result.update(reused_from=sources, returncode=0, timed_out=False, fatal=False,
                          wall_seconds=time.monotonic() - started)
        else:
            point_file = args.output / "points.txt"
            point_file.write_text("".join(f"{offset}\n" for offset in offsets))
            snapshot_root = args.output / "checkpoints"
            command = [str(inputs["nemu"]), "-b", f"--sample-points={point_file}",
                       f"--sample-directory={snapshot_root}", "-t", str(inputs["dtb"]),
                       str(inputs["firmware"])]
            result["command"] = command
            result.update(run_logged(command, args.output / "capture.log", args.timeout,
                                     env={**os.environ, "NEMU_STATUS_DIR": str(args.output)}))
            directories = {offset: snapshot_root / f"sample-{offset}" for offset in offsets}
        if result["returncode"] or result["fatal"] or result["timed_out"]:
            write_json(args.output / "capture.json", result)
            raise ValueError("NEMU capture failed; inspect capture.log (unsafe devices are rejected)")
        for name, path in inputs.items():
            if digest(path) != hashes[name]:
                raise ValueError(f"capture input changed during execution: {name}")
        for point in points:
            directory = directories[point["checkpoint_guest_start"]]
            metadata = json.loads((directory / "sample.json").read_text())
            if metadata["guest_start"] != point["checkpoint_guest_start"]:
                raise ValueError("captured instruction count differs from the selected point")
            if (metadata["privilege"] == 3 and not
                    0x80000000 <= int(metadata["pc"], 16) < 0x80000000 + metadata["ram_bytes"]):
                raise ValueError("cannot resume M-mode code outside captured RAM; move past MROM")
            if "checkpoint_pc" in point and int(metadata["pc"], 16) != int(point["checkpoint_pc"], 16):
                raise ValueError("capture control flow differs from profiling at the checkpoint")
            if metadata.get("signature") != point["checkpoint_signature"]:
                raise ValueError("capture instruction stream differs from profiling")
            check_checkpoint_domain(directory, plan.get("retirement_domain", {"mode": "all"}))
            files = {name: digest(directory / name) for name in FILES}
            result["points"].append({"id": point["id"],
                                     "directory": os.path.relpath(directory, args.output),
                                     "files": files, "metadata": metadata})
        for source in result.get("reused_from", []):
            if digest(Path(source["path"])) != source["sha256"]:
                raise ValueError("reuse source manifest changed during capture")
        result["complete"] = True
        write_json(args.output / "capture.json", result)
        print(f"Captured {len(offsets)} unique checkpoints for {len(points)} samples")
    except (OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
        if result is not None and not (args.output / "capture.json").exists():
            result.update(complete=False, error=str(error))
            write_json(args.output / "capture.json", result)
        parser.exit(1, f"{error}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
