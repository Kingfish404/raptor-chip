#!/usr/bin/env python3
"""Record one hardware command, its output and a required final pass marker."""

import argparse
import datetime
import json
from pathlib import Path
import shlex
import re
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--name", required=True)
    parser.add_argument("--expect", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command
    if command and command[0] == "--":
        command = command[1:]
    if not command or "/" in args.name or args.name in {".", ".."}:
        parser.error("supply a command and a plain log name")
    args.output.mkdir(parents=True, exist_ok=True)
    log_path = args.output / f"{args.name}.log"
    if log_path.exists():
        parser.error("log already exists; use a new run directory or name")
    started = datetime.datetime.now(datetime.timezone.utc).isoformat()
    start = time.monotonic()
    with log_path.open("x") as log:
        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=False)
    output = log_path.read_text(errors="replace")
    error_line = re.search(r"^(%Error|%Fatal|ERROR:|RAPT_\S*_FAIL)", output, re.MULTILINE)
    passed = result.returncode == 0 and args.expect in output and not error_line
    status = "pending" if result.returncode == 77 else "deferred" if result.returncode == 75 else (
        "pass" if passed else "fail")
    record = {"command": shlex.join(command), "exit_code": result.returncode, "status": status,
              "started": started,
              "seconds": round(time.monotonic() - start, 3), "expected": args.expect,
              "log": str(log_path)}
    (args.output / f"{args.name}.json").write_text(json.dumps(record, indent=2) + "\n")
    print("\n".join(output.splitlines()[-15:]))
    print(json.dumps(record), flush=True)
    return result.returncode if result.returncode else int(not passed)


if __name__ == "__main__":
    raise SystemExit(main())
