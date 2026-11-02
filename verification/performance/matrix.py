#!/usr/bin/env python3
"""Execute a declared full/sample experiment matrix with bounded child sessions."""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import json
import os
from pathlib import Path
import re
import signal
import sys
import threading
import time

from execution import run_logged
from simpoints import digest, write_json

HERE = Path(__file__).resolve().parent


def run_case(root, output, case, stop):
    name = case["id"]
    command = [sys.executable, str(HERE / "run_model.py"), "--name", case["model_name"],
               "--kind", case["kind"], "--output", str(output / name)]
    for key in ("plan", "capture", "model", "reference", "mrom"):
        if key in case:
            command += ["--" + key, str((root / case[key]).resolve())]
    for key in ("read_latency", "write_latency", "jobs", "timeout", "cycle_limit"):
        if key in case:
            command += ["--" + key.replace("_", "-"), str(case[key])]
    timeout = case.get("timeout", 3600) + 90
    row = {"id": name, "command": command, "passed": False}
    row.update(run_logged(command, output / (name + ".log"), timeout, stop=stop))
    path = output / name / "results.json"
    if path.is_file():
        result = json.loads(path.read_text())
        row.update(result=str(path), result_sha256=digest(path),
                   passed=row["returncode"] == 0 and result.get("complete") is True)
    return row


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--spec", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--parallel", type=int, default=2)
    args = parser.parse_args()
    try:
        if args.parallel < 1:
            raise ValueError("parallelism must be positive")
        spec = json.loads(args.spec.read_text())
        if spec.get("schema") != "raptor-evaluation-matrix-v1" or not spec.get("cases"):
            raise ValueError("invalid or empty experiment matrix")
        names = [case["id"] for case in spec["cases"]]
        if len(set(names)) != len(names) or any(not re.fullmatch(r"[\w.-]+", name) for name in names):
            raise ValueError("case IDs must be unique filename components")
        args.output = args.output.resolve()
        args.output.mkdir(parents=True, exist_ok=False)
        stop = threading.Event()
        for signum in (signal.SIGINT, signal.SIGTERM):
            signal.signal(signum, lambda _signum, _frame: stop.set())
        result = {"schema": "raptor-evaluation-matrix-result-v1", "complete": False,
                  "spec_sha256": digest(args.spec), "parallel": args.parallel, "cases": []}
        started = time.monotonic()
        with ThreadPoolExecutor(max_workers=args.parallel) as pool:
            futures = [pool.submit(run_case, args.spec.parent, args.output, case, stop)
                       for case in spec["cases"]]
            for future in as_completed(futures):
                row = future.result()
                result["cases"].append(row)
                write_json(args.output / "progress.tmp", result)
                os.replace(args.output / "progress.tmp", args.output / "progress.json")
                print(f"{row['id']}: passed={row['passed']}", flush=True)
        result.update(complete=all(row["passed"] for row in result["cases"]),
                      wall_seconds=time.monotonic() - started)
        write_json(args.output / "matrix.json", result)
    except (OSError, ValueError, KeyError, TypeError) as error:
        parser.exit(1, f"{error}\n")
    return int(not result["complete"])


if __name__ == "__main__":
    raise SystemExit(main())
