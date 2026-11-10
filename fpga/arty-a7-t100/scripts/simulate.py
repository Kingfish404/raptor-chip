#!/usr/bin/env python3
"""Build the FPGA board testbench with the unchanged pad-level SoC RTL."""

import argparse
import json
from pathlib import Path
import subprocess

from sources import ROOT, BOARD, board_sources, fingerprint, includes, rtl_sources, tool_environment


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--fast", action="store_true", help="omit wave tracing; compile C++ with -O3")
    parser.add_argument("--synthesis", action="store_true", help="exercise SYNTHESIS code paths")
    parser.add_argument("--lutram", type=int, choices=(0, 1), default=1)
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    sources = rtl_sources() + [p for p in board_sources() if p.name != "rapt_arty_top.sv"]
    sources += [ROOT / "verification/models/rapt_xspi_profile1_model.sv",
                BOARD / "tests/tb_rapt_arty.sv"]
    files = sources + [p for inc in includes() for p in inc.glob("*.svh")]
    current = {"sources": fingerprint(files), "fast": args.fast, "synthesis": args.synthesis,
               "lutram": args.lutram, "verilator": subprocess.check_output(
        ["verilator", "--version"], text=True).strip()}
    stamp = out / "simulation_sources.json"
    binary = out / "obj/tb_rapt_arty"
    if not binary.exists() or not stamp.exists() or json.loads(stamp.read_text()) != current:
        command = ["verilator", "--binary", "--timing", "-j", "4",
                   "--top-module", "tb_rapt_arty", "--Mdir", str(out / "obj"),
                   "-o", "tb_rapt_arty", "-Wno-fatal", "--timescale", "1ns/1ps",
                   "+define+RAPT_FPGA_DSP=1", f"+define+RAPT_FPGA_LUTRAM={args.lutram}",
                   "+define+RAPT_CORE_CLOCK_MHZ=20", "+define+RAPT_MTIME_FREQ_MHZ=1"]
        command += ["-CFLAGS", "-O3"] if args.fast else ["--trace"]
        if args.synthesis:
            command.append("+define+SYNTHESIS=1")
        command += ["-I" + str(p) for p in includes()] + [str(p) for p in sources]
        with (out / "simulation_compile.log").open("w") as log:
            subprocess.run(command, cwd=out, env=tool_environment(), stdout=log,
                           stderr=subprocess.STDOUT, check=True)
        stamp.write_text(json.dumps(current, indent=2) + "\n")
    print(binary)


if __name__ == "__main__":
    main()
