#!/usr/bin/env python3
"""Check physical-baud loader pins at RTL, exported Verilog and mapped-gate levels."""

import argparse
import json
from pathlib import Path
import subprocess

from sources import BOARD, tool_environment


def run(command, out, name, env):
    with (out / f"{name}.log").open("w") as log:
        result = subprocess.run(command, cwd=out, env=env, stdout=log,
                                stderr=subprocess.STDOUT, check=False, timeout=180)
    return result.returncode, (out / f"{name}.log").read_text(errors="replace")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--quick", action="store_true")
    parser.add_argument("--netlist", type=Path, help="test an externally synthesized loader")
    parser.add_argument("--unisims", type=Path, help="use Icarus with these Vivado primitives")
    parser.add_argument("--cell-models", type=Path, help="Verilator-compatible FPGA cell models")
    parser.add_argument("--legacy-export", action="store_true", help="reproduce the old export")
    parser.add_argument("--rtl-only", action="store_true")
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    env = tool_environment()
    sources = [BOARD / p for p in ("rtl/rapt_arty_host.sv", "rtl/rapt_arty_uart.sv",
                                  "tests/rapt_arty_loader.sv")]
    modes = [("rtl", sources)]
    if args.netlist:
        modes = [("mapped", [args.netlist.resolve()])]
    elif not args.rtl_only:
        script = "read_slang --single-unit -DSYNTHESIS --top rapt_arty_loader "
        script += " ".join(str(p) for p in sources) + "\n"
        script += "proc\nflatten\nmemory_collect\ntribuf -logic\nopt\nbwmuxmap\n"
        if not args.legacy_export:
            script += "techmap t:$shiftx\nopt\nselect -assert-none t:$shiftx\n"
        script += "check -assert\nwrite_verilog loader.v\n"
        (out / "export.ys").write_text(script)
        result, output = run(["yosys", "-Q", "-T", "-m", "slang", "-s", "export.ys"],
                             out, "export", env)
        if result:
            print(output[-4000:])
            return result
        modes.append(("export", [out / "loader.v"]))
    records = []
    for mode, files in modes:
        if args.cell_models:
            files = [args.cell_models.resolve(), *files]
        obj = out / f"obj-{mode}"
        command = ["verilator", "--binary", "--timing", "-j", "4", "-Wno-fatal",
                   "--top-module", "tb_rapt_arty_loader", "--Mdir", str(obj), "-o", "loader",
                   *map(str, files), str(BOARD / "tests/tb_rapt_arty_loader.sv")]
        if args.unisims:
            obj.mkdir(parents=True, exist_ok=True)
            command = ["iverilog", "-g2012", "-s", "tb_rapt_arty_loader", "-s", "glbl",
                       "-y", str(args.unisims.resolve()), "-o", str(obj / "loader"),
                       *map(str, files), str(BOARD / "tests/tb_rapt_arty_loader.sv")]
        result, output = run(command, out, f"compile-{mode}", env)
        if result:
            print(output[-4000:])
            return result
        periods = [1.0] if args.quick else [1.0, 0.98, 1.02]
        for scale in periods:
            for first in ("write", "read"):
                extra = ["+QUICK"] if args.quick else []
                if first == "read":
                    extra.append("+READ_FIRST")
                command = [str(obj / "loader"), f"+HOST_BIT={1e9 / 115200 * scale}", *extra]
                if args.unisims:
                    command.insert(0, "vvp")
                name = f"{mode}-{scale}-{first}"
                result, output = run(command, out, name, env)
                passed = result == 0 and "RAPT_LOADER_PASS" in output
                records.append({"mode": mode, "scale": scale, "first": first,
                                "command": command, "exit_code": result, "pass": passed})
                print(f"{name}: {'PASS' if passed else 'FAIL'}\n{output[-1200:]}", flush=True)
    (out / "results.json").write_text(json.dumps(records, indent=2) + "\n")
    return int(any(not record["pass"] for record in records))


if __name__ == "__main__":
    raise SystemExit(main())
