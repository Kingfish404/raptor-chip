#!/usr/bin/env python3
"""Check the fixed CMSIS-DAP probe; exit 77 when the standard SBA patch is absent."""

import argparse
import json
import os
import shutil
from pathlib import Path
import subprocess
import sys

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
from host import Board
from common import tcl_string



def probe_serial():
    serial = os.environ.get("RAPT_PROBE_SERIAL", "")
    if not serial:
        raise SystemExit("set RAPT_PROBE_SERIAL to the CMSIS-DAP probe serial for the SoC's JTAG")
    return serial


def openocd_path():
    # sudo resets PATH, so pass an absolute path (RAPT_OPENOCD overrides the lookup).
    path = os.environ.get("RAPT_OPENOCD") or shutil.which("openocd")
    if not path:
        raise SystemExit("openocd not found; set RAPT_OPENOCD")
    return str(Path(path).resolve())


def run_openocd(arguments, output, timeout=180):
    # timeout runs with the same privilege as OpenOCD, so no orphan root process
    # remains when USB or a debug request stalls. Every batch ends with shutdown.
    command = ["sudo", "-n", "timeout", "--foreground", "--signal=TERM", "--kill-after=5s",
               str(timeout),
               openocd_path(), "-s", str(SCRIPTS),
               "-c", f"set RAPT_PROBE_SERIAL {probe_serial()}", *arguments]
    output.parent.mkdir(parents=True, exist_ok=True)
    output.with_suffix(".command.json").write_text(json.dumps(command, indent=2) + "\n")
    with output.open("w") as log:
        result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=False)
    text = output.read_text(errors="replace")
    if "SBA_PENDING:" in text:
        return 77, text
    return result.returncode, text


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=["basic", "step", "sba"], default="basic")
    parser.add_argument("--port", required=True)
    parser.add_argument("--build", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    with Board(args.port) as board:
        result = board.run(args.build / "jtag_fixture.bin", 4, 120, keep_running=True)
        if not result["pass"]:
            raise ValueError(f"JTAG fixture failed before debug: {result}")
    arguments = ["-f", "tap.cfg", "-c", "gdb_port disabled", "-c", "tcl_port disabled",
                 "-c", "telnet_port disabled", "-f", "sba.tcl",
                 "-c", f"set CHECK_STEP {int(args.mode == 'step')}",
                 "-c", f"set CHECK_SBA {int(args.mode == 'sba')}",
                 "-f", "debug_check.tcl"]
    code, output = run_openocd(arguments, args.output / f"jtag-{args.mode}.log")
    passed = code == 0 and "RAPT_JTAG_CHECK_PASS" in output
    record = {"probe_serial": probe_serial(), "mode": args.mode, "pass": passed, "exit_code": code}
    (args.output / f"result-{args.mode}.json").write_text(json.dumps(record, indent=2) + "\n")
    print(output, end="")
    if code == 77:
        return 77
    if passed and args.mode == "sba":
        image = (args.build / "jtag_fixture.bin").resolve()
        if image.stat().st_size % 4 or image.stat().st_size > 16384:
            raise ValueError("load_image fixture must be word aligned and fit its scratch area")
        native = Path(__file__).with_name("native_load.tcl").resolve()
        runner = args.output.resolve() / "native-run.tcl"
        dump = args.output.resolve() / "native-dump.bin"
        runner.write_text(f"set LOAD_FILE {tcl_string(image)}\n"
                          f"set LOAD_DUMP {tcl_string(dump)}\n"
                          f"source {tcl_string(native)}\n")
        arguments = ["-f", "gdb.cfg", "-f", "sba.tcl", "-c", "gdb_port disabled",
                     "-c", "tcl_port disabled", "-c", "telnet_port disabled",
                     "-f", str(runner)]
        code, output = run_openocd(arguments, args.output / "native-load.log")
        passed = code == 0 and "RAPT_NATIVE_LOAD_IMAGE_PASS" in output
        passed &= dump.is_file() and dump.read_bytes() == image.read_bytes()
        (args.output / "result-native.json").write_text(json.dumps(
            {"pass": passed, "exit_code": code}, indent=2) + "\n")
        print(output, end="")
    return int(not passed)


if __name__ == "__main__":
    raise SystemExit(main())
