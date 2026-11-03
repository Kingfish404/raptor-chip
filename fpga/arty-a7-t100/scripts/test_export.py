#!/usr/bin/env python3
"""Diagnose generic Verilog with Verilator, or mapped gates with Icarus."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

from image import prepare
from sources import BOARD, ROOT, tool_environment


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--netlist", type=Path, help="simulate this mapped or exported input")
    parser.add_argument("--iverilog", action="store_true", help="use four-state simulation")
    parser.add_argument("--unisims", type=Path, help="Vivado unisim source directory for gates")
    parser.add_argument("--ideal-clocks", action="store_true",
                        help="replace only the gate netlist's clock wrapper with ideal clocks")
    parser.add_argument("--half", type=int, choices=range(2, 16), action="append")
    parser.add_argument("--image", type=Path)
    parser.add_argument("--raw", action="store_true", help="image already writes the finisher")
    parser.add_argument("--console-marker")
    args = parser.parse_args()
    out = args.out.resolve()
    build = args.build.resolve()
    manifest = build / "sources.json"
    mapped = manifest.is_file() and json.loads(manifest.read_text()).get("xilinx_mapped", False)
    if mapped and not args.iverilog:
        parser.error("mapped builds need test_xsim.py, or --iverilog --unisims PATH")
    if args.iverilog and mapped and not args.unisims:
        parser.error("mapped Icarus simulation needs --unisims PATH")
    out.mkdir(parents=True, exist_ok=True)
    design = args.netlist.resolve() if args.netlist else build / "design.v"
    simulated = design
    if args.ideal_clocks:
        simulated = out / "gates-ideal-clocks.v"
        content, count = re.subn(r"(?ms)^module rapt_arty_clocks\b.*?^endmodule\s*",
                                 "", design.read_text())
        if count != 1:
            raise ValueError("expected exactly one clock wrapper to substitute")
        simulated.write_text(content)
    sources = [simulated, BOARD / "tests/rapt_arty_clock_model.sv",
               BOARD / "tests/tb_rapt_arty_export.sv"]
    if args.unisims and not args.netlist:
        sources.append(BOARD / "rtl/rapt_arty_mapped_cells.v")
    command = ["verilator", "--binary", "--timing", "-j", "4", "-Wno-fatal", "-CFLAGS", "-O3",
               "--top-module", "tb_rapt_arty_export", "--Mdir", str(out / "obj"),
               "-o", "export-test", *map(str, sources)]
    executable = out / "obj/export-test"
    if args.iverilog:
        executable.parent.mkdir(exist_ok=True)
        command = ["iverilog", "-g2012", "-s", "tb_rapt_arty_export"]
        if args.unisims:
            command += ["-s", "glbl", "-y", str(args.unisims.resolve()),
                        "-I", str(args.unisims.resolve()),
                        str(args.unisims.resolve().parent / "glbl.v")]
        command += ["-o", str(executable), *map(str, sources)]
    with (out / "compile.log").open("w") as log:
        subprocess.run(command, cwd=out, env=tool_environment(), stdout=log,
                       stderr=subprocess.STDOUT, check=True)
    original = args.image or ROOT / (
        "abstract-machine/app/am-kernels/tests/cpu-tests/build/dummy-riscv32-npc.bin")
    image = out / "dummy.bin"
    if args.raw:
        image.write_bytes(original.read_bytes())
    else:
        prepare(original, image, build / "finish.bin")
    records = []
    for half in args.half or (2, 4, 15):
        command = [str(executable), f"+IMG={image}", f"+HALF={half}"]
        if args.iverilog:
            command = ["vvp", "-i", *command]
        with (out / f"half-{half}.log").open("w") as log:
            result = subprocess.run(command, cwd=build, stdout=log,
                                    stderr=subprocess.STDOUT, timeout=900, check=False)
        output = (out / f"half-{half}.log").read_text(errors="replace")
        passed = result.returncode == 0 and "RAPT_EXPORT_BOOT_PASS" in output
        if args.console_marker:
            passed &= args.console_marker in output
        records.append({"half_period": half, "command": command, "exit_code": result.returncode,
                        "pass": passed})
        print(f"exported boot half={half}: {'PASS' if passed else 'FAIL'}\n{output[-2000:]}",
              flush=True)
    record = {"design_sha256": hashlib.sha256(design.read_bytes()).hexdigest(),
              "simulator": "iverilog" if args.iverilog else "verilator",
              "ideal_clocks": args.ideal_clocks,
              "results": records}
    (out / "results.json").write_text(json.dumps(record, indent=2) + "\n")
    return int(any(not item["pass"] for item in records))


if __name__ == "__main__":
    raise SystemExit(main())
