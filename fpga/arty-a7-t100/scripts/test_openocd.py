#!/usr/bin/env python3
"""Run the board's native load_image script against sampled-JTAG RTL, without USB."""

import argparse
from contextlib import ExitStack
import json
from pathlib import Path
import subprocess
import sys
import time

from sources import BOARD

sys.path.insert(0, str(BOARD / "scripts/hw"))
from common import tcl_string


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", type=Path, required=True)
    parser.add_argument("--image", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--port", type=int, default=9830)
    parser.add_argument("--mode", choices=["native", "basic", "step", "raw-sba"],
                        default="native")
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    config = out / "config"
    config.mkdir(exist_ok=True)
    helpers = (BOARD / "scripts/tap.cfg").read_text().split("proc rapt_dmi", 1)[1]
    tap = ("adapter driver remote_bitbang\nremote_bitbang host 127.0.0.1\n"
           f"remote_bitbang port {args.port}\nadapter speed 500\nreset_config none\n"
           "jtag newtap rapt tap -irlen 5 -expected-id 0x10001913\n\nproc rapt_dmi" + helpers)
    (config / "tap.cfg").write_text(tap)
    runner = out / "native-run.tcl"
    runner.write_text(f"set LOAD_FILE {tcl_string(args.image.resolve())}\n"
                      f"set LOAD_DUMP {tcl_string(out / 'native-dump.bin')}\n"
                      f"source {tcl_string(BOARD / 'scripts/hw/native_load.tcl')}\n")
    server_cmd = [str(args.server.resolve()), f"--jtag-port={args.port}"]
    command = ["openocd", "-s", str(config), "-s", str(BOARD / "scripts")]
    if args.mode == "native":
        command += ["-f", "gdb.cfg", "-c", "gdb_port disabled", "-f", str(runner)]
        marker = "RAPT_NATIVE_LOAD_IMAGE_PASS"
    elif args.mode in {"basic", "step"}:
        command += ["-f", "tap.cfg", "-c", "gdb_port disabled", "-c", "tcl_port disabled",
                    "-c", "telnet_port disabled", "-f", "sba.tcl"]
        if args.mode == "step":
            image = args.image.read_bytes()
            image += bytes((-len(image)) % 4)
            lines = ["init", "rapt_halt", "rapt_sba_require"]
            for offset in range(0, len(image), 4):
                word = int.from_bytes(image[offset:offset + 4], "little")
                lines.append(f"rapt_sba_write32 0x{0x80000000 + offset:08x} 0x{word:08x}")
            lines += ["rapt_reg_write 0x7b1 0x80000000", "rapt_resume", "runtest 20000"]
            runner.write_text("\n".join(lines) + "\n")
            command += ["-f", str(runner)]
        step = int(args.mode == "step")
        command += ["-c", f"set CHECK_STEP {step}", "-c", "set CHECK_SBA 0",
                    "-f", "debug_check.tcl"]
        marker = "RAPT_JTAG_CHECK_PASS"
    else:
        runner.write_text("init\nrapt_halt\nrapt_sba_require\n"
                          "foreach value {0 0xffffffff 0x55aa33cc 0xa55af00f} {\n"
                          "  rapt_sba_write32 0x80038000 $value\n"
                          "  if {[rapt_sba_read32 0x80038000] != $value} {error SBA_pattern}\n"
                          "}\nputs RAPT_RAW_SBA_SIM_PASS\nshutdown\n")
        command += ["-f", "tap.cfg", "-c", "gdb_port disabled", "-c", "tcl_port disabled",
                    "-c", "telnet_port disabled", "-f", "sba.tcl", "-f", str(runner)]
        marker = "RAPT_RAW_SBA_SIM_PASS"
    with ExitStack() as stack:
        log = stack.enter_context((out / "server.log").open("w"))
        server = subprocess.Popen(server_cmd, stdout=log, stderr=subprocess.STDOUT)
        stack.callback(stop, server)
        deadline = time.monotonic() + 60
        while "waiting for OpenOCD" not in (out / "server.log").read_text():
            if server.poll() is not None or time.monotonic() >= deadline:
                raise RuntimeError("RTL JTAG server did not become ready")
            time.sleep(0.05)
        with (out / "openocd.log").open("w") as log:
            result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT,
                                    timeout=180, check=False)
    output = (out / "openocd.log").read_text(errors="replace")
    passed = result.returncode == 0 and marker in output
    if args.mode == "step":
        passed &= "JTAG_SINGLE_STEP_PASS" in output and "JTAG_DPC_REDIRECT_PASS" in output
    if args.mode == "native":
        dump = out / "native-dump.bin"
        passed &= dump.is_file() and dump.read_bytes() == args.image.read_bytes()
    record = {"server_command": server_cmd, "command": command,
              "exit_code": result.returncode, "pass": passed}
    (out / "result.json").write_text(json.dumps(record, indent=2) + "\n")
    print(output, end="")
    print("RAPT_BOARD_OPENOCD_SIM_" + ("PASS" if passed else "FAIL"))
    return int(not passed)


if __name__ == "__main__":
    raise SystemExit(main())
