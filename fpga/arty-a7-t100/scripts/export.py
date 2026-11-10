#!/usr/bin/env python3
"""Elaborate SoC RTL and map it to 7-series primitives for Vivado."""

import argparse
import json
from pathlib import Path
import subprocess
import shutil

from sources import BOARD, ROOT, board_sources, fingerprint, includes, input_files, rtl_sources


def quoted(path):
    # read_slang treats quote characters as part of filenames. Reject spaces
    # rather than emitting a subtly different source list.
    if any(c.isspace() for c in str(path)):
        raise ValueError("Slang export requires paths without whitespace")
    return str(path)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--internal", action="store_true")
    parser.add_argument("--lutram", type=int, choices=(0, 1), default=1)
    parser.add_argument("--map-xilinx", action=argparse.BooleanOptionalAction, default=True,
                        help="map logic/memories to 7-series primitives before Vivado")
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    inputs = out / "inputs"
    inputs.mkdir(exist_ok=True)
    for path in (BOARD / "constraints/arty.xdc", BOARD / "constraints/link_timing.tcl",
                 BOARD / "rtl/rapt_arty_clocks.v", BOARD / "rtl/rapt_arty_mapped_cells.v"):
        shutil.copy2(path, inputs / path.name)
    sources = rtl_sources() + [BOARD / "scripts/primitives.sv"] + board_sources()
    flags = ["--single-unit", "--unroll-limit=100000", "--allow-toplevel-iface-ports", "-DSYNTHESIS",
             "-DRAPT_FPGA_DSP=1", f"-DRAPT_FPGA_LUTRAM={args.lutram}",
             "-DRAPT_CORE_CLOCK_MHZ=20", "-DRAPT_MTIME_FREQ_MHZ=1"]
    if args.internal:
        flags.append("-DARTY_INTERNAL_JOIN=1")
    flags += ["-I" + quoted(p) for p in includes()]
    script = "read_slang " + " ".join(flags) + " --top rapt_arty_top "
    script += " ".join(quoted(p) for p in sources) + "\n"
    script += "hierarchy -check -top rapt_arty_top\nproc\nflatten\nmemory_collect\ntribuf -logic\n"
    # Dynamic byte writes lower to signed, negative-base $shiftx cells. Mapping
    # those cells here avoids out-of-range variable selects in exported Verilog,
    # which lose the upper address bytes in the downstream toolchain.
    script += "opt\nbwmuxmap\ntechmap t:$shiftx\nopt\nselect -assert-none t:$shiftx\n"
    script += "check -assert\n"
    if args.map_xilinx:
        # Match the native fixture's local-RAM mapping. Fold only its three
        # byte-lane address adders before combining ports and absorbing the
        # read address FF. Keep the memory's reset and transparency semantics.
        branch = "g_internal" if args.internal else "g_pins"
        memory = f"rapt_arty_top/c:{branch}.u_chip.u_chip.u_backend.u_flash.ram"
        addresses = memory + " %ci2 t:$add %i"
        script += "write_rtlil unmapped.il\nwrite_json unmapped.json\n"
        script += f"select -assert-count 1 {memory}\n"
        script += f"select -assert-count 3 {addresses}\n"
        script += f"opt_expr -fine {addresses}\nopt_clean\n"
        for command in ("memory_share -nosat", "opt_mem_widen", "memory_dff"):
            script += f"{command} {memory}\n"
        script += "check -assert\nwrite_rtlil normalized.il\nwrite_json normalized.json\n"
        script += "synth_xilinx -family xc7 -top rapt_arty_top -noiopad -noclkbuf\n"
        # Cascaded TDP RAMs need legal widths on the otherwise unused ports.
        # Their enables stay zero and their outputs stay unused.
        script += "setparam -set READ_WIDTH_A 1 t:RAMB36E1 r:READ_WIDTH_A=0 %i "
        script += "r:RAM_EXTENSION_A=NONE %d\n"
        script += "setparam -set WRITE_WIDTH_B 1 t:RAMB36E1 r:WRITE_WIDTH_B=0 %i "
        script += "r:RAM_EXTENSION_B=NONE %d\n"
        script += "check -assert\n"
    script += "write_verilog design.v\n"
    (out / "export.ys").write_text(script)
    with (out / "export.log").open("w") as log:
        subprocess.run(["yosys", "-Q", "-T", "-m", "slang", "-s", "export.ys"],
                       cwd=out, stdout=log, stderr=subprocess.STDOUT, check=True)
    record = {"preset": "chip32-small", "no_fpu": True, "xlen": 32,
              "fpga_lutram": args.lutram,
              "xilinx_mapped": args.map_xilinx,
              "memory": "FPGA LUTRAM/BRAM", "internal_join": args.internal,
              "sources": fingerprint(input_files()), "root": str(ROOT)}
    record["mrom_sha256"] = fingerprint_hash(out / "mrom.hex")
    record["design_sha256"] = fingerprint_hash(out / "design.v")
    (out / "sources.json").write_text(json.dumps(record, indent=2) + "\n")
    print(f"Exported {out / 'design.v'}; preset chip32-small, RAPT_NO_FPU")


def fingerprint_hash(path):
    import hashlib
    return hashlib.sha256(path.read_bytes()).hexdigest()


if __name__ == "__main__":
    main()
