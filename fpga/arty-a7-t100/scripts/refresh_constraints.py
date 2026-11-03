#!/usr/bin/env python3
"""Refresh timing constraints only after proving the routed RTL/ROM inputs are unchanged."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil

from sources import BOARD, ROOT, fingerprint, input_files


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    out = args.out.resolve()
    manifest = out / "sources.json"
    old_text = manifest.read_bytes()
    record = json.loads(old_text)
    current = fingerprint(input_files())
    for path, digest in current.items():
        hardware = path.startswith("rtl/") or path.startswith("fpga/common/rtl/")
        hardware |= path.startswith("fpga/arty-a7-t100/rtl/")
        hardware |= path == "fpga/arty-a7-t100/scripts/primitives.sv"
        if hardware and record["sources"].get(path) != digest:
            raise ValueError(f"RTL input changed; full rebuild required: {path}")
    if sha(out / "mrom.hex") != record["mrom_sha256"]:
        raise ValueError("ROM changed; full rebuild required")
    design_hash = sha(out / "design.v")
    if record.get("design_sha256", design_hash) != design_hash:
        raise ValueError("exported design changed; full rebuild required")
    old_xdc = (out / "inputs/arty.xdc").read_text()
    new_xdc = (BOARD / "constraints/arty.xdc").read_text()
    pin_pattern = r"^set_property -dict .*PACKAGE_PIN.*$"
    if re.findall(pin_pattern, old_xdc, re.M) != re.findall(pin_pattern, new_xdc, re.M):
        raise ValueError("pin assignments changed; full rebuild required")
    for name in ("arty.xdc", "link_timing.tcl"):
        shutil.copy2(BOARD / "constraints" / name, out / "inputs" / name)
    record["retimed_from_manifest_sha256"] = hashlib.sha256(old_text).hexdigest()
    record["sources"] = current
    record["design_sha256"] = design_hash
    manifest.write_text(json.dumps(record, indent=2) + "\n")
    print("RTL and ROM unchanged; timing constraints refreshed")


if __name__ == "__main__":
    main()
