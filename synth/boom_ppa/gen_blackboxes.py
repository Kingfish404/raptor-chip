#!/usr/bin/env python3
"""Emit ported black-box declarations for firtool's external SRAM modules."""

from pathlib import Path
import re
import sys


def main() -> int:
    if len(sys.argv) != 3:
        raise SystemExit(f"usage: {sys.argv[0]} <generated-sv-dir> <output-sv>")
    source_dir = Path(sys.argv[1])
    output = Path(sys.argv[2])
    modules: dict[str, str] = {}
    for source in sorted(source_dir.glob("*.sv")):
        text = source.read_text()
        for match in re.finditer(
            r"module\s+(\w+)\s*\((.*?)\);(.*?)endmodule", text, re.S
        ):
            wrapper, ports, body = match.groups()
            port_decls = {}
            for port_match in re.finditer(
                r"\b(input|output|inout)\s+(?:\[[^\]]+\]\s+)?(\w+)\s*,?", ports
            ):
                port_decls[port_match.group(2)] = port_match.group(0).rstrip(",")
            instances = re.finditer(r"\b(\w+_ext)\s+\1\s*\((.*?)\);", body, re.S)
            ext_names = set()
            for instance in instances:
                ext_name, connections = instance.groups()
                ext_names.add(ext_name)
                ext_ports = []
                for connection in re.finditer(r"\.([A-Za-z_]\w*)\s*\(", connections):
                    port_name = connection.group(1)
                    ext_ports.append(port_decls.get(port_name, f"input {port_name}"))
                declaration_ports = ",\n  ".join(dict.fromkeys(ext_ports))
                declaration = f"module {ext_name}(\n  {declaration_ports}\n);\nendmodule\n"
                modules.setdefault(ext_name, declaration)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("// Generated black-box declarations for BOOM PPA synthesis.\n" + "\n".join(modules.values()))
    print(f"generated {len(modules)} black-box declarations in {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
