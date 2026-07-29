#!/usr/bin/env python3

import argparse
import pathlib
import re
import sys


def property_value(text: str, name: str) -> str:
    match = re.search(rf"\b{re.escape(name)}\s*=\s*\"([^\"]+)\"\s*;", text)
    if not match:
        raise ValueError(f"missing string property {name}")
    return match.group(1)


def cell_value(text: str, name: str) -> int:
    match = re.search(rf"\b{re.escape(name)}\s*=\s*<\s*([^\s>]+)\s*>\s*;", text)
    if not match:
        raise ValueError(f"missing single-cell property {name}")
    return int(match.group(1), 0)


def main() -> int:
    parser = argparse.ArgumentParser(description="Check the Raptor Linux DTS capability contract")
    parser.add_argument("dts", type=pathlib.Path)
    args = parser.parse_args()

    text = args.dts.read_text(encoding="ascii")
    unresolved = sorted(set(re.findall(r"@[A-Z0-9_]+@", text)))
    if unresolved:
        raise ValueError(f"unresolved template variables: {', '.join(unresolved)}")

    isa = property_value(text, "riscv,isa")
    isa_match = re.fullmatch(r"rv(32|64)([a-z]+)(?:_(.+))?", isa)
    if not isa_match:
        raise ValueError(f"invalid riscv,isa value: {isa}")

    xlen, base_letters, multi = isa_match.groups()
    expected_extensions = list(base_letters)
    if multi:
        expected_extensions.extend(multi.split("_"))

    ext_match = re.search(r"\briscv,isa-extensions\s*=\s*(.*?)\s*;", text, re.DOTALL)
    if not ext_match:
        raise ValueError("missing riscv,isa-extensions")
    listed_extensions = re.findall(r'"([^"]+)"', ext_match.group(1))
    if listed_extensions != expected_extensions:
        raise ValueError(
            "ISA property mismatch:\n"
            f"  riscv,isa implies:       {' '.join(expected_extensions)}\n"
            f"  riscv,isa-extensions has: {' '.join(listed_extensions)}"
        )
    if len(listed_extensions) != len(set(listed_extensions)):
        raise ValueError("riscv,isa-extensions contains duplicates")

    expected_base = f"rv{xlen}i"
    actual_base = property_value(text, "riscv,isa-base")
    if actual_base != expected_base:
        raise ValueError(f"riscv,isa-base is {actual_base}, expected {expected_base}")

    expected_mmu = f"riscv,{'sv39' if xlen == '64' else 'sv32'}"
    actual_mmu = property_value(text, "mmu-type")
    if actual_mmu != expected_mmu:
        raise ValueError(f"mmu-type is {actual_mmu}, expected {expected_mmu}")

    timebase = cell_value(text, "timebase-frequency")
    if timebase <= 0:
        raise ValueError("timebase-frequency must be positive")

    if "zicbom" in listed_extensions:
        block_size = cell_value(text, "riscv,cbom-block-size")
        if block_size <= 0 or block_size & (block_size - 1):
            raise ValueError("riscv,cbom-block-size must be a positive power of two")

    print(
        f"PASS: Linux DTS contract rv{xlen}, {actual_mmu}, "
        f"{len(listed_extensions)} ISA extensions, timebase={timebase}"
    )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)