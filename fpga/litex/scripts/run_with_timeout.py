#!/usr/bin/env python3

import subprocess
import sys


def usage() -> int:
    print(
        "usage: run_with_timeout.py [--foreground] <seconds> [--] <command> [args...]",
        file=sys.stderr,
    )
    return 2


def main() -> int:
    args = sys.argv[1:]

    if args and args[0] == "--foreground":
        args = args[1:]

    if len(args) < 2:
        return usage()

    try:
        timeout = float(args[0])
    except ValueError:
        print(f"invalid timeout: {args[0]}", file=sys.stderr)
        return 2

    command = args[1:]
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        return usage()

    if timeout <= 0:
        timeout = None

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
