#!/usr/bin/env python3
"""Run one NEMU BBV pass and preserve inputs, markers, throughput and scope."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import time

from capture import FILES
from execution import run_logged
from simpoints import digest, read_profile, write_json


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("nemu", "firmware", "dtb", "output"):
        parser.add_argument("--" + name, required=True, type=Path)
    parser.add_argument("--interval", type=int, default=10000000)
    parser.add_argument("--max-attempts", type=int, default=0,
                        help="NEMU execution-loop budget; zero profiles the full workload")
    parser.add_argument("--timeout", type=int, default=3600)
    parser.add_argument("--start-pc", type=lambda s: int(s, 0))
    parser.add_argument("--stop-pc", type=lambda s: int(s, 0))
    parser.add_argument("--start-marker", help="exact UART line, e.g. 'Running AES-XTS'")
    parser.add_argument("--length", type=int, default=0, help="bounded ROI retirements; then exit")
    parser.add_argument("--checkpoint-every", type=int, default=0,
                        help="capture every N interior BBV boundaries during this same pass")
    parser.add_argument("--user-satp", type=lambda value: int(value, 0))
    parser.add_argument("--user-tp", type=lambda value: int(value, 0))
    args = parser.parse_args()
    started = time.monotonic()
    result = None
    try:
        if min(args.interval, args.timeout) <= 0 or min(
                args.max_attempts, args.length, args.checkpoint_every) < 0:
            raise ValueError("invalid interval, timeout or execution budget")
        if args.user_tp is not None and args.user_satp is None:
            raise ValueError("a user thread requires --user-satp")
        inputs = {name: getattr(args, name).resolve() for name in ("nemu", "firmware", "dtb")}
        hashes = {name: digest(path) for name, path in inputs.items()}
        args.output = args.output.resolve()
        args.output.mkdir(parents=True, exist_ok=False)
        bbv = args.output / "profile.bbv.jsonl"
        command = [str(inputs["nemu"]), "-b", f"--bbv={bbv}", f"--bbv-interval={args.interval}"]
        if args.checkpoint_every:
            command += [f"--sample-bbv-every={args.checkpoint_every}",
                        f"--sample-directory={args.output / 'checkpoints'}"]
        for name in ("user_satp", "user_tp"):
            if getattr(args, name) is not None:
                command += [f"--bbv-{name.replace('_', '-')}={getattr(args, name):#x}"]
        if args.max_attempts:
            command += ["-m", str(args.max_attempts)]
        if args.start_marker:
            command += ["--bbv-start-marker=" + args.start_marker]
        if args.length:
            command += [f"--bbv-length={args.length}"]
        for name in ("start_pc", "stop_pc"):
            if getattr(args, name) is not None:
                command.append(f"--bbv-{name.replace('_', '-')}={getattr(args, name):#x}")
        command += ["-t", str(inputs["dtb"]), str(inputs["firmware"])]
        result = {"schema": "raptor-bbv-profile-v1", "complete": False,
                  "command": command, "entropy_policy": "fixed-dtb-v1",
                  "inputs": {name: {"path": str(path), "sha256": hashes[name]}
                             for name, path in inputs.items()}, "max_attempts": args.max_attempts,
                  "start_marker": args.start_marker, "roi_length": args.length}
        result.update(run_logged(command, args.output / "run.log", args.timeout,
                                 env={**os.environ, "NEMU_STATUS_DIR": str(args.output)}))
        if result["returncode"] == 0 and not result["fatal"] and not result["timed_out"]:
            rows, footer = read_profile(bbv, allow_prefix=bool(args.max_attempts))
            if footer is None:
                raise ValueError("NEMU did not close the profile cleanly")
            if any(digest(path) != hashes[name] for name, path in inputs.items()):
                raise ValueError("profile input changed during execution")
            failed_guest = [m for m in footer["markers"] if m["text"].startswith(
                "RAPTOR_WORKLOAD_EXIT=") and m["text"] != "RAPTOR_WORKLOAD_EXIT=0"]
            scope = "bounded-marker-window" if args.start_marker else "bounded-window"
            if not args.length:
                scope = "bounded-prefix" if args.max_attempts else "full-roi"
            result.update(complete=not failed_guest,
                          workload_complete=footer.get("program_complete", footer["complete"]),
                          scope=scope,
                          intervals=len(rows), retired=footer["retired"],
                          retired_per_second=footer["retired"] / result["wall_seconds"],
                          guest_retired=footer["guest_retired"],
                          guest_retired_per_second=footer["guest_retired"] / result["wall_seconds"],
                          bbv_sha256=digest(bbv), markers=footer["markers"])
            if "retirement_domain" in footer:
                result["retirement_domain"] = footer["retirement_domain"]
        if args.checkpoint_every and result["complete"]:
            points = []
            directories = sorted((args.output / "checkpoints").glob("sample-*"),
                                 key=lambda path: int(path.name.split("-")[1]))
            for directory in directories:
                metadata = json.loads((directory / "sample.json").read_text())
                points.append({"id": f"boundary:{metadata['guest_start']}",
                               "directory": str(directory.relative_to(args.output)),
                               "metadata": metadata,
                               "files": {name: digest(directory / name) for name in FILES}})
            if not points:
                raise ValueError("profile ended before any requested interior checkpoint")
            grid = args.output / "checkpoint-grid.json"
            write_json(grid, {"schema": "raptor-bbv-capture-grid-v1", "complete": True,
                             "inputs": result["inputs"], "bbv_sha256": result["bbv_sha256"],
                             "interval_stride": args.checkpoint_every, "points": points,
                             "bounded_roi_end_excluded": bool(args.length)})
            result["checkpoint_grid"] = {"path": str(grid), "sha256": digest(grid),
                                         "points": len(points)}
        result["total_wall_seconds"] = time.monotonic() - started
        write_json(args.output / "profile.json", result)
        print(f"BBV profile complete={result['complete']}; "
              f"retired={result.get('retired', 0)}; seconds={result['wall_seconds']:.3f}")
    except (OSError, ValueError, KeyError) as error:
        if result is not None and not (args.output / "profile.json").exists():
            result.update(complete=False, error=str(error))
            write_json(args.output / "profile.json", result)
        parser.exit(1, f"{error}\n")
    return int(not result["complete"])


if __name__ == "__main__":
    raise SystemExit(main())
