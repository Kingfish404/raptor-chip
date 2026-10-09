"""Shared Yosys execution for verification drivers."""
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def run_yosys(command, log, timeout):
    with log.open("w") as stream:
        subprocess.run(
            ["yosys", "-Q", "-T", "-m", "slang", "-p", command],
            stdout=stream,
            stderr=subprocess.STDOUT,
            check=True,
            timeout=timeout,
            cwd=ROOT,
        )
    return log.read_text()

