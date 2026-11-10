#!/usr/bin/env python3
"""Run the exact exported or mapped board input with the vendor simulator offline."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess

from image import prepare
from sources import BOARD, ROOT


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--bin", type=Path, required=True, help="Vivado bin directory")
    parser.add_argument("--netlist", type=Path)
    parser.add_argument("--ideal-clocks", action="store_true")
    parser.add_argument("--image", type=Path)
    parser.add_argument("--raw", action="store_true")
    parser.add_argument("--half", type=int, default=4, choices=range(2, 16))
    parser.add_argument("--console-marker")
    parser.add_argument("--startup", action="store_true",
                        help="short ROM/data-load diagnosis; forces only the host run latch")
    parser.add_argument("--extra-file", type=Path, action="append", default=[])
    parser.add_argument("--jobs", type=int, choices=range(1, 5), default=2)
    parser.add_argument("--boot-timeout-ns", type=int, default=20_000_000)
    parser.add_argument("--stage-timeout", type=int, default=3600,
                        help="wall-clock seconds per vendor compile/elaborate/run stage")
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    build = args.build.resolve()
    manifest = build / "sources.json"
    pin_join = manifest.is_file() and not json.loads(manifest.read_text())["internal_join"]
    if args.startup and pin_join:
        raise ValueError("startup diagnosis uses internal probes; use the full pin-build test")
    design = args.netlist.resolve() if args.netlist else build / "design.v"
    simulated = design
    if args.ideal_clocks:
        content, count = re.subn(r"(?ms)^module rapt_arty_clocks\b.*?^endmodule\s*",
                                 "", design.read_text())
        if count != 1:
            raise ValueError("expected exactly one clock wrapper")
        simulated = out / "gates-ideal-clocks.v"
        simulated.write_text(content)
    original = args.image or ROOT / (
        "abstract-machine/app/am-kernels/tests/cpu-tests/build/dummy-riscv32-npc.bin")
    image = out / "image.bin"
    if args.raw:
        image.write_bytes(original.read_bytes())
    else:
        prepare(original, image, build / "finish.bin")
    vendor = args.bin.resolve().parent / "data/verilog/src"
    top = "tb_rapt_arty_startup" if args.startup else "tb_rapt_arty_export"
    bench = BOARD / "tests" / f"{top}.sv"
    if args.startup:
        content = bench.read_text()
        aliases = {
            "g_internal.u_chip.u_chip.u_backend.u_bridge.u_byte.dq_o": "g_internal.u_chip.dq_out",
            "u_board.u_target.dq_o": "g_internal.u_delay.board_dq_i",
        }
        netlist = design.read_text()
        for old, new in aliases.items():
            if "\\" + old + " " not in netlist:
                if "\\" + new + " " not in netlist:
                    raise ValueError(f"missing startup probe: {old} / {new}")
                content = re.sub(r"\\" + re.escape(old) + r"(?=\s)",
                                 lambda match: "\\" + new, content)
        bench = out / "startup.sv"
        bench.write_text(content)
    commands = [
        [str(args.bin / "xvlog"), "-sv", str(simulated),
         str(BOARD / "tests/rapt_arty_clock_model.sv"),
         str(bench), str(vendor / "glbl.v"),
         *(str(path.resolve()) for path in args.extra_file)],
        [str(args.bin / "xelab"), "-mt", "off" if args.jobs == 1 else str(args.jobs),
         "-L", "unisims_ver", "-L", "secureip",
         top, "glbl", "-s", "board_sim"],
        [str(args.bin / "xsim"), "board_sim", "-runall", "-testplusarg", f"IMG={image}",
         "-testplusarg", f"HALF={args.half}", "-testplusarg",
         f"BOOT_NS={args.boot_timeout_ns}"]]
    if pin_join:
        commands[-1] += ["-testplusarg", "PINS"]
    env = os.environ.copy()
    scratch = out / "tmp"
    scratch.mkdir(exist_ok=True)
    env["TMPDIR"] = str(scratch)
    record = {"design_sha256": hashlib.sha256(design.read_bytes()).hexdigest(),
              "commands": commands, "results": [], "half_period": args.half,
              "startup_only": args.startup, "pin_join": pin_join, "pass": False}
    for name, command in zip(("compile", "elaborate", "run"), commands):
        with (out / f"{name}.log").open("w") as log:
            process = subprocess.Popen(command, cwd=out, env=env, stdout=log,
                                       stderr=subprocess.STDOUT, start_new_session=True)
            try:
                code = process.wait(timeout=args.stage_timeout)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=3)
                code = 124
        text = (out / f"{name}.log").read_text(errors="replace")
        record["results"].append({"stage": name, "exit_code": code})
        print(f"XSIM {name}: exit={code}\n{text[-2000:]}", flush=True)
        if code:
            break
        if name == "run":
            marker = "RAPT_STARTUP_PASS" if args.startup else "RAPT_EXPORT_BOOT_PASS"
            record["pass"] = marker in text
            if args.console_marker:
                record["pass"] &= args.console_marker in text
    (out / "results.json").write_text(json.dumps(record, indent=2) + "\n")
    print("RAPT_XSIM_BOOT_" + ("PASS" if record["pass"] else "FAIL"))
    return int(not record["pass"])


if __name__ == "__main__":
    raise SystemExit(main())
