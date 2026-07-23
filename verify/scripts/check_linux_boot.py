#!/usr/bin/env python3
"""Validate that an NPC/NEMU log reached Linux userspace without fatal errors."""

from __future__ import annotations

import argparse
from pathlib import Path


REQUIRED_MILESTONES = (
    "Linux version",
    "Run /init as init process",
)

FATAL_MARKERS = (
    "difftest mismatch",
    "Kernel panic",
    "HIT BAD TRAP",
    "Assertion failed",
    "%Error:",
)


def check_log(log_path: Path, from_checkpoint: bool = False) -> None:
    text = log_path.read_bytes().decode("utf-8", errors="replace")

    required = REQUIRED_MILESTONES[1:] if from_checkpoint else REQUIRED_MILESTONES
    missing = [marker for marker in required if marker not in text]
    fatal = [marker for marker in FATAL_MARKERS if marker in text]
    if missing or fatal:
        if missing:
            print(f"FAIL: missing Linux boot milestone(s): {', '.join(missing)}")
        if fatal:
            print(f"FAIL: fatal marker(s) in Linux boot log: {', '.join(fatal)}")
    else:
        print(f"PASS: Linux reached /init without fatal markers ({log_path})")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--from-checkpoint",
        action="store_true",
        help="only require milestones that occur after a Linux checkpoint",
    )
    parser.add_argument("log", type=Path, help="NPC or NEMU Linux boot log")
    args = parser.parse_args()
    check_log(args.log, from_checkpoint=args.from_checkpoint)


if __name__ == "__main__":
    main()