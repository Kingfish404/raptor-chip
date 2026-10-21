#!/usr/bin/env python3
"""Board entry point for the shared native FPGA flow."""
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "common/scripts"))
import native_build

if __name__ == "__main__":
    native_build.configure(Path(__file__).resolve().parent)
    try:
        native_build.main()
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as exc:
        raise SystemExit(str(exc)) from exc
