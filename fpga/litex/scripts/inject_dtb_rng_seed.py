#!/usr/bin/env python3
"""Replace a fixed-size /chosen/rng-seed DTB placeholder.

The source device tree deliberately contains an all-zero 32-byte property so
that the blob never needs to be resized.  This tool is run while assembling a
boot image and writes a separate, seeded DTB; the zero-filled build artifact is
not suitable for booting.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import struct
import sys
from pathlib import Path


FDT_MAGIC = 0xD00DFEED
FDT_BEGIN_NODE = 1
FDT_END_NODE = 2
FDT_PROP = 3
FDT_NOP = 4
FDT_END = 9
FDT_HEADER_SIZE = 40
RNG_SEED_SIZE = 32


class DtbError(ValueError):
    pass


def be32(blob: bytes | bytearray, offset: int) -> int:
    if offset < 0 or offset + 4 > len(blob):
        raise DtbError("truncated 32-bit FDT field")
    return struct.unpack_from(">I", blob, offset)[0]


def align4(value: int) -> int:
    return (value + 3) & ~3


def c_string(blob: bytes | bytearray, start: int, end: int) -> str:
    if not (0 <= start < end <= len(blob)):
        raise DtbError("invalid FDT string range")
    nul = blob.find(b"\0", start, end)
    if nul < 0:
        raise DtbError("unterminated FDT string")
    try:
        return bytes(blob[start:nul]).decode("ascii")
    except UnicodeDecodeError as exc:
        raise DtbError("non-ASCII FDT string") from exc


def find_rng_seed(blob: bytearray) -> tuple[int, int]:
    if len(blob) < FDT_HEADER_SIZE or be32(blob, 0) != FDT_MAGIC:
        raise DtbError("input is not a flattened device tree")

    total_size = be32(blob, 4)
    struct_offset = be32(blob, 8)
    strings_offset = be32(blob, 12)
    strings_size = be32(blob, 32)
    struct_size = be32(blob, 36)
    if total_size > len(blob):
        raise DtbError("FDT total size exceeds input size")
    if struct_offset > total_size or struct_size > total_size - struct_offset:
        raise DtbError("invalid FDT structure block")
    if strings_offset > total_size or strings_size > total_size - strings_offset:
        raise DtbError("invalid FDT strings block")

    cursor = struct_offset
    struct_end = struct_offset + struct_size
    strings_end = strings_offset + strings_size
    depth = -1
    chosen_depth: int | None = None
    matches: list[tuple[int, int]] = []

    while cursor + 4 <= struct_end:
        token = be32(blob, cursor)
        cursor += 4
        if token == FDT_BEGIN_NODE:
            name = c_string(blob, cursor, struct_end)
            cursor = align4(blob.find(b"\0", cursor, struct_end) + 1)
            if cursor > struct_end:
                raise DtbError("node name exceeds FDT structure block")
            depth += 1
            if depth == 1 and (name == "chosen" or name.startswith("chosen@")):
                chosen_depth = depth
        elif token == FDT_END_NODE:
            if depth < 0:
                raise DtbError("unbalanced FDT end-node token")
            if depth == chosen_depth:
                chosen_depth = None
            depth -= 1
        elif token == FDT_PROP:
            if cursor + 8 > struct_end:
                raise DtbError("truncated FDT property")
            length = be32(blob, cursor)
            name_offset = be32(blob, cursor + 4)
            cursor += 8
            padded_length = align4(length)
            if padded_length > struct_end - cursor:
                raise DtbError("FDT property exceeds structure block")
            if name_offset >= strings_size:
                raise DtbError("FDT property name exceeds strings block")
            name = c_string(blob, strings_offset + name_offset, strings_end)
            if depth == chosen_depth and name == "rng-seed":
                matches.append((cursor, length))
            cursor += padded_length
        elif token == FDT_NOP:
            continue
        elif token == FDT_END:
            break
        else:
            raise DtbError(f"unknown FDT token 0x{token:x}")
    else:
        raise DtbError("FDT structure has no end token")

    if len(matches) != 1:
        raise DtbError(
            f"expected exactly one /chosen/rng-seed property, found {len(matches)}"
        )
    return matches[0]


def read_seed(path: Path | None) -> bytes:
    if path is None:
        return os.urandom(RNG_SEED_SIZE)
    seed = path.read_bytes()
    if len(seed) != RNG_SEED_SIZE:
        raise DtbError(
            f"seed file must contain exactly {RNG_SEED_SIZE} bytes, got {len(seed)}"
        )
    return seed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, help="DTB containing the placeholder")
    parser.add_argument("output", type=Path, help="path for the seeded DTB")
    parser.add_argument(
        "--seed-file",
        type=Path,
        help="read exactly 32 bytes here (tests only; default: host CSPRNG)",
    )
    args = parser.parse_args()

    try:
        blob = bytearray(args.input.read_bytes())
        offset, length = find_rng_seed(blob)
        if length != RNG_SEED_SIZE:
            raise DtbError(
                f"/chosen/rng-seed must be {RNG_SEED_SIZE} bytes, got {length}"
            )
        if any(blob[offset : offset + length]):
            raise DtbError("input /chosen/rng-seed is not the all-zero placeholder")
        seed = read_seed(args.seed_file)
        if not any(seed):
            raise DtbError("refusing an all-zero RNG seed")
        blob[offset : offset + length] = seed
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_bytes(blob)
    except (DtbError, OSError) as exc:
        print(f"[rng-seed] error: {exc}", file=sys.stderr)
        return 1

    fingerprint = hashlib.sha256(seed).hexdigest()[:16]
    print(
        f"[rng-seed] injected {RNG_SEED_SIZE} host-random bytes "
        f"(sha256[:16]={fingerprint}) into {args.output}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
