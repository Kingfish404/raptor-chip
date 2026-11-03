#!/usr/bin/env python3
"""Run one Vivado batch after checking global tool use and available memory."""

import argparse
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys


def available_memory():
    for line in Path("/proc/meminfo").read_text().splitlines():
        if line.startswith("MemAvailable:"):
            return int(line.split()[1]) * 1024
    raise RuntimeError("MemAvailable is unavailable")


def active_vivado():
    result = subprocess.run(["ps", "-eo", "pid,comm"], capture_output=True,
                            text=True, check=True)
    return [line.strip() for line in result.stdout.splitlines()[1:]
            if line.split()[1] == "vivado"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vivado", default="vivado")
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--script", type=Path, required=True)
    parser.add_argument("args", nargs="*")
    args = parser.parse_args()
    init_name = Path("/proc/1/comm").read_text().strip()
    if init_name not in {"systemd", "init"}:
        print("Vivado deferred: global process inventory is hidden by this PID namespace")
        return 75
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    lock = (out.parent / ".rapt-vivado.lock").open("a+")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print("Vivado deferred: another Arty build owns the build lock")
        return 75
    memory = available_memory()
    busy = active_vivado()
    if busy or memory <= 25 * 1024 ** 3:
        print(f"Vivado deferred: active={busy}, MemAvailable={memory / 1024 ** 3:.1f} GiB")
        return 75
    record = {"started": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "available_memory_bytes": memory, "pid": os.getpid(), "threads": 4}
    (out / "launch.json").write_text(json.dumps(record, indent=2) + "\n")
    command = [args.vivado, "-mode", "batch", "-nojournal", "-log", "vivado.log",
               "-source", str(args.script.resolve()), "-tclargs", *args.args]
    env = os.environ.copy()
    scratch = out / "tmp"
    scratch.mkdir(exist_ok=True)
    env["TMPDIR"] = str(scratch)
    result = subprocess.run(command, cwd=out, env=env, check=False)
    bitstream = out / "rapt_arty.bit"
    final_build = any(action in args.args for action in ("build", "retime"))
    if result.returncode == 0 and bitstream.exists() and final_build:
        record["bitstream_sha256"] = hashlib.sha256(bitstream.read_bytes()).hexdigest()
        record["source_manifest_sha256"] = hashlib.sha256(
            (out / "sources.json").read_bytes()).hexdigest()
        record["metrics"] = (out / "metrics.txt").read_text()
        (out / "artifacts.json").write_text(json.dumps(record, indent=2) + "\n")
    return result.returncode


if __name__ == "__main__":
    sys.exit(main())
