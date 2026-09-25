#!/usr/bin/env python3
"""Create an abstract Liberty model for firtool-replaced BOOM memories."""

from pathlib import Path
import re
import sys


def main() -> int:
    if len(sys.argv) not in (4, 5):
        raise SystemExit(
            f"usage: {sys.argv[0]} <mems.conf> <blackboxes.sv> <output.lib> [um2_per_bit]"
        )
    conf_path, blackbox_path, output_path = map(Path, sys.argv[1:4])
    area_per_bit = float(sys.argv[4]) if len(sys.argv) == 5 else 2.2

    sizes = {}
    for line in conf_path.read_text().splitlines():
        match = re.match(r"name (\S+) depth (\d+) width (\d+)", line)
        if match:
            sizes[match.group(1)] = int(match.group(2)) * int(match.group(3))

    cells = []
    module_re = re.compile(r"module\s+(\w+)\s*\((.*?)\);", re.S)
    port_re = re.compile(r"\b(input|output|inout)\b(?:\s+\[[^]]+\])?\s+(\w+)")
    for module, ports in module_re.findall(blackbox_path.read_text()):
        if module not in sizes:
            continue
        pins = []
        for direction, name in port_re.findall(ports):
            pins.append((direction, name))
        lines = [f"  cell ({module}) {{", f"    area : {sizes[module] * area_per_bit:.4f};"]
        for direction, name in pins:
            lines.append(f"    pin ({name}) {{")
            lines.append(f"      direction : {direction};")
            if direction == "input":
                lines.append("      capacitance : 1.0;")
            lines.append("    }")
        lines.append("  }")
        cells.append("\n".join(lines))

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(
        "library (boom_abstract_memories) {\n"
        '  time_unit : "1ns";\n'
        '  capacitive_load_unit (1, ff);\n'
        + "\n".join(cells)
        + "\n}\n"
    )
    print(f"generated {len(cells)} abstract memory cells in {output_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
