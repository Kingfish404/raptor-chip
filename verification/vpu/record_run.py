#!/usr/bin/env python3
"""Fingerprint VPU simulations without duplicating their RTL/header inventories."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parents[2]
mode, output, *values = sys.argv[1:]
output = Path(output)
if mode == "top":
    names = ("XLEN", "VLEN", "ELEN", "BankBits", "Banks", "OptimizeOperandReads",
             "Spike", "CoreAdapter")
    if len(values) != len(names) + 1:
        raise SystemExit("top requires XLEN VLEN ELEN BankBits Banks OptimizeReads Spike Adapter Suite")
    result = dict(configuration=dict(zip(names, map(int, values[:-1]))), suite=values[-1])
elif mode == "leaf":
    top, *parameters = values
    if not (root / "rtl/backend/vpu" / (top + ".sv")).is_file():
        raise SystemExit("Unknown VPU top: " + top)
    result = dict(top=top, parameters={k: int(v) for k, v in
                                     (item.split("=", 1) for item in parameters)})
elif mode == "adapter":
    rob, generation = map(int, values)
    result = dict(parameters=dict(RobBits=rob, GenerationBits=generation,
                                  CommandBits=32, ResultBits=32, MetadataBits=64))
else:
    raise SystemExit("Use top, leaf or adapter")

# Include the complete local source family. This conservatively invalidates old
# evidence when any shared helper changes, without coupling it to file splits.
files = set((root / "rtl/backend/vpu").glob("*.sv"))
files.update((root / "rtl/backend/feu/fpu").glob("*.sv"))
files.update((root / "rtl/include").rglob("*.svh"))
files.add(root / "rtl/configs/default/rapt_config.svh")
files.add(root / "rtl/sram/rapt_sram_1rw.sv")
files.add(root / "rtl/rapt_pkg.sv")
for path in Path(__file__).resolve().parent.iterdir():
    if path.is_file() and (path.suffix in {".cpp", ".h", ".sv", ".py", ".vlt"}
                           or path.name == "Makefile"):
        files.add(path)
files.add(root / "verification/vpu/vendor/riscv-opcodes/rv_v")
result.update(
    verilator=subprocess.check_output(["verilator", "--version"], text=True).strip(),
    sources={str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
             for p in sorted(files)})
output.write_text(json.dumps(result, indent=2) + "\n")
