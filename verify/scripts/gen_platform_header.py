#!/usr/bin/env python3
"""Generate app/lib/raptor_platform.h from hdl/configs/memory_map.json."""

import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HEADER = ROOT / "app/lib/raptor_platform.h"


def render():
    memory_map = json.loads((ROOT / "hdl/configs/memory_map.json").read_text())
    lines = ["/* Generated from hdl/configs/memory_map.json by verify/scripts/gen_platform_header.py.",
             " * Do not edit: change the JSON and run `make memory-map-header`. */",
             "#ifndef RAPTOR_PLATFORM_H", "#define RAPTOR_PLATFORM_H", ""]
    for name, entry in memory_map["regions"].items():
        for key in ("base", "size", "max_size"):
            if key in entry:
                lines.append(f"#define RAPTOR_{name.upper()}_{key.upper()} {entry[key]}")
    lines += ["",
              "/* NPC leaves this mapped device aperture unbacked: accesses get DECERR. */",
              "#define RAPTOR_UNBACKED_DEVICE_BASE RAPTOR_VGA_BASE",
              "",
              "/* Sv32/Sv39 leaf PTE that maps the 4 KiB page holding physical address pa. */",
              "#define RAPTOR_PTE(pa, flags) ((((pa) >> 12) << 10) | (flags))",
              "", "#endif", ""]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail if the header is stale")
    args = parser.parse_args()
    text = render()
    if args.check:
        if not HEADER.exists() or HEADER.read_text() != text:
            raise SystemExit(f"{HEADER.relative_to(ROOT)} is stale; run `make memory-map-header`")
        return
    HEADER.write_text(text)


if __name__ == "__main__":
    main()
