#!/usr/bin/env python3
"""Validate that an NPC/NEMU log reached a Linux boot milestone without fatal errors."""

from __future__ import annotations

import argparse
from pathlib import Path


LINUX_ENTRY_MILESTONE = "Linux version"
DEFAULT_SUCCESS_MILESTONE = "Run /init as init process"

FATAL_MARKERS = (
    "difftest mismatch",
    "Kernel panic",
    "HIT BAD TRAP",
    "Assertion failed",
    "%Error:",
)


def check_log(
    log_path: Path,
    from_checkpoint: bool = False,
    success_marker: str = DEFAULT_SUCCESS_MILESTONE,
) -> bool:
    text = log_path.read_bytes().decode("utf-8", errors="replace")

    required = tuple(
        dict.fromkeys(
            (success_marker,)
            if from_checkpoint
            else (LINUX_ENTRY_MILESTONE, success_marker)
        )
    )
    missing = [marker for marker in required if marker not in text]
    fatal = [marker for marker in FATAL_MARKERS if marker in text]
    if missing or fatal:
        if missing:
            print(f"FAIL: missing Linux boot milestone(s): {', '.join(missing)}")
        if fatal:
            print(f"FAIL: fatal marker(s) in Linux boot log: {', '.join(fatal)}")
        return False
    else:
        print(f"PASS: Linux reached '{success_marker}' without fatal markers ({log_path})")
        return True


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--from-checkpoint",
        action="store_true",
        help="only require milestones that occur after a Linux checkpoint",
    )
    parser.add_argument(
        "--success-marker",
        default=DEFAULT_SUCCESS_MILESTONE,
        help="final serial-log milestone to require (default: userspace /init)",
    )
    parser.add_argument("log", type=Path, help="NPC or NEMU Linux boot log")
    args = parser.parse_args()
    if not check_log(
        args.log,
        from_checkpoint=args.from_checkpoint,
        success_marker=args.success_marker,
    ):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
