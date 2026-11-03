#!/usr/bin/env python3
"""Create/check the board MROM's length/CRC/entry flash image format."""

import argparse
import json
from pathlib import Path
import struct
import zlib

MAGIC = 0x52505446
MAX_IMAGE = 0x3e000


def pack_image(payload, entry=0x80000000):
    if not 0 < len(payload) <= MAX_IMAGE:
        raise ValueError("payload must contain 1..253952 bytes")
    if entry & 1 or not 0 <= entry - 0x80000000 < len(payload):
        raise ValueError("entry must be an aligned address inside the RAM payload")
    header = struct.pack("<4I", MAGIC, len(payload), zlib.crc32(payload), entry)
    return header + payload


def inspect_image(data):
    if len(data) < 16:
        raise ValueError("short flash header")
    magic, length, crc, entry = struct.unpack_from("<4I", data)
    if magic != MAGIC or not 0 < length <= MAX_IMAGE or len(data) < 16 + length:
        raise ValueError("bad magic/length")
    payload = data[16:16 + length]
    if zlib.crc32(payload) != crc:
        raise ValueError("payload CRC mismatch")
    if entry & 1 or not 0 <= entry - 0x80000000 < length:
        raise ValueError("entry outside payload")
    return {"length": length, "crc32": f"{crc:08x}", "entry": f"{entry:08x}"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path, nargs="?")
    args = parser.parse_args()
    data = args.input.read_bytes()
    if args.output:
        data = pack_image(data)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_bytes(data)
    print(json.dumps(inspect_image(data)))


if __name__ == "__main__":
    main()
