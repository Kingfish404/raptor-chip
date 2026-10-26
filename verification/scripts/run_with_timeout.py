#!/usr/bin/env python3

import subprocess
import sys


def main() -> int:
    # Accept both "run_with_timeout.py <seconds> -- <cmd> [args...]"
    # and        "run_with_timeout.py <seconds> <cmd> [args...]".
    # The "--" separator is optional; GNU timeout on some distros treats it
    # as a positional argument, so the Makefile now omits it and we mirror
    # that behaviour here for consistency.
    if len(sys.argv) < 3:
        print(
            "usage: run_with_timeout.py <seconds> [--] <command> [args...]",
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

    rest = sys.argv[2:]
    if rest and rest[0] == "--":
        rest = rest[1:]
    if not rest:
        print("run_with_timeout.py: missing command", file=sys.stderr)
        return 2
    command = rest

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
