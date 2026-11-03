#!/usr/bin/env python3
"""Convert a little-endian binary to a fixed-size readmemh word ROM."""

import argparse
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--words", type=int, default=1024)
    args = parser.parse_args()
    data = args.binary.read_bytes()
    if len(data) > args.words * 4:
        parser.error("binary exceeds ROM capacity")
    data = data.ljust(args.words * 4, b"\0")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text("".join(
        f"{int.from_bytes(data[i:i + 4], 'little'):08x}\n"
        for i in range(0, len(data), 4)
    ))


if __name__ == "__main__":
    main()
