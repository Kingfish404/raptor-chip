#!/usr/bin/env python3
"""Format/check this FPGA vehicle without relying on a Git checkout."""

import argparse
from pathlib import Path
import subprocess

from sources import BOARD, ROOT


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--format", action="store_true")
    args = parser.parse_args()
    sources = sorted(p for p in BOARD.rglob("*") if p.is_file() and
                     not {"build", "__pycache__", ".Xil"}.intersection(p.relative_to(BOARD).parts))
    paths = [p for p in sources if p.suffix in {".sv", ".v"}]
    flagfile = ROOT / ".verible-format.flags"
    flags = [f"--flagfile={flagfile}"] if flagfile.exists() else [
        "--indentation_spaces=2", "--column_limit=100"]
    for path in paths:
        subprocess.run(["verible-verilog-format", *flags,
                        "--failsafe_success=false", "--inplace" if args.format else "--verify",
                        str(path)], check=True)
    failures = []
    suffixes = {".sv", ".v", ".py", ".c", ".h", ".S", ".tcl", ".xdc", ".ld", ".mk"}
    for path in sources:
        if path.suffix in suffixes or path.name == "Makefile":
            for number, line in enumerate(path.read_text().splitlines(), 1):
                if len(line) > 120:
                    failures.append(f"{path.relative_to(ROOT)}:{number}: {len(line)} columns")
    if failures:
        raise ValueError("\n".join(failures))
    print(f"FPGA formatting and line limits PASS ({len(paths)} HDL files)")


if __name__ == "__main__":
    main()
