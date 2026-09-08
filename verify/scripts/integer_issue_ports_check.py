#!/usr/bin/env python3
"""Collect reproducible whole-core elaboration proxies for integer-port variants."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SOURCES = [
    ROOT / "hdl/configs/default/rapt_config.svh",
    ROOT / "hdl/include/rapt.svh",
    ROOT / "hdl/rapt_pkg.sv",
    ROOT / "hdl/rapt_core.sv",
    ROOT / "hdl/backend/ieu/rapt_ieu.sv",
    ROOT / "hdl/backend/rapt_cdb_arb.sv",
    ROOT / "hdl/backend/rapt_iq.sv",
    ROOT / "hdl/common/rapt_issue_select.sv",
]
REPORT = re.compile(
    r"Built from ([0-9.]+) MB sources in (\d+) modules, "
    r"into ([0-9.]+) MB in (\d+) C\+\+ files"
)


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--ports", type=int, nargs="+", required=True)
    parser.add_argument("--system-ports", type=int, nargs="+")
    args = parser.parse_args()
    system_ports = args.system_ports or [0] * len(args.ports)
    if len(system_ports) != len(args.ports):
        raise ValueError("--system-ports must have one entry per --ports entry")
    variants = list(zip(args.ports, system_ports))
    if (any(port <= 0 or system < 0 or system >= port for port, system in variants)
            or len(set(variants)) != len(variants)):
        raise ValueError("port/system-port variants must be unique and in range")

    rows = []
    for port, system_port in variants:
        suffix = f"-system-{system_port}" if system_port else ""
        log_path = args.output / f"lint-port-{port}{suffix}.log"
        text = log_path.read_text()
        if re.search(r"^%Error", text, re.MULTILINE):
            raise RuntimeError(f"Verilator error in {log_path}")
        matches = REPORT.findall(text)
        if not matches:
            raise RuntimeError(f"missing Verilator report in {log_path}")
        source_mb, modules, output_mb, cpp_files = matches[-1]
        rows.append({
            "integer_issue_ports": port,
            "integer_system_port": system_port,
            "ordered_widths": {stage: 2 for stage in
                               ("decode", "rename", "dispatch", "commit")},
            "warnings": len(re.findall(r"^%Warning-", text, re.MULTILINE)),
            "verilator_proxy": {
                "source_mb": float(source_mb),
                "modules": int(modules),
                "generated_mb": float(output_mb),
                "cpp_files": int(cpp_files),
            },
            "log": str(log_path.resolve()),
        })

    version = subprocess.run(["verilator", "--version"], check=True, text=True,
                             stdout=subprocess.PIPE).stdout.strip()
    result = {
        "tool": version,
        "scope": "whole-core Verilator elaboration with default ordered widths",
        "caveat": "Generated C++ size/file count are elaboration-complexity proxies, not silicon area, timing, or power.",
        "source_sha256": {str(path.relative_to(ROOT)): digest(path) for path in SOURCES},
        "variants": rows,
    }
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "results.json").write_text(json.dumps(result, indent=2) + "\n")
    for row in rows:
        proxy = row["verilator_proxy"]
        print(f"port={row['integer_issue_ports']}, system={row['integer_system_port']}: "
              f"{proxy['generated_mb']:.3f} MB, "
              f"{proxy['cpp_files']} C++ files, {row['warnings']} warnings")


if __name__ == "__main__":
    main()
