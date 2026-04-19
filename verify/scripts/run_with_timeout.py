#!/usr/bin/env python3

import subprocess
import sys


def main() -> int:
    if len(sys.argv) < 4 or sys.argv[2] != "--":
        print(
            "usage: run_with_timeout.py <seconds> -- <command> [args...]",
            file=sys.stderr,
        )
        return 2

    try:
        timeout = float(sys.argv[1])
    except ValueError:
        print(f"invalid timeout: {sys.argv[1]}", file=sys.stderr)
        return 2

    if timeout <= 0:
        timeout = None

    command = sys.argv[3:]

    try:
        return subprocess.run(command, timeout=timeout).returncode
    except FileNotFoundError as exc:
        print(exc, file=sys.stderr)
        return 127
    except subprocess.TimeoutExpired:
        return 124
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
