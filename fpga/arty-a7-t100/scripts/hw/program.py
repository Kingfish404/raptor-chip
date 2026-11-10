#!/usr/bin/env python3
"""Volatile-program only the authorized Arty, using a dedicated hw_server that is closed."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import socket
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from vivado import active_vivado, available_memory


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vivado", default=os.environ.get("VIVADO", "vivado"))
    parser.add_argument("--hw-server", type=Path)
    parser.add_argument("--build", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--serial", default=os.environ.get("RAPT_ARTY_SERIAL", ""),
                        help="Digilent serial of the one Arty to program (or RAPT_ARTY_SERIAL)")
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9]{1,64}", args.serial):
        parser.error("give one alphanumeric Digilent serial; no other target is opened")
    if Path("/proc/1/comm").read_text().strip() not in {"systemd", "init"}:
        parser.error("run hardware scripts outside the sandbox")
    if active_vivado() or available_memory() <= 25 * 1024 ** 3:
        print("PROGRAM_DEFERRED: Vivado busy or less than 25 GiB available")
        return 75
    build = args.build.resolve()
    bitstream = build / "rapt_arty.bit"
    evidence = json.loads((build / "artifacts.json").read_text())
    if hashlib.sha256(bitstream.read_bytes()).hexdigest() != evidence["bitstream_sha256"]:
        parser.error("bitstream does not match the successful routed-build evidence")
    source_hash = hashlib.sha256((build / "sources.json").read_bytes()).hexdigest()
    if source_hash != evidence["source_manifest_sha256"]:
        parser.error("source manifest does not match the routed build")
    args.output.mkdir(parents=True, exist_ok=True)
    with socket.socket() as reserve:
        reserve.bind(("127.0.0.1", 0))
        port = reserve.getsockname()[1]
    import shutil
    vivado = Path(shutil.which(args.vivado) or args.vivado).resolve()
    server_binary = args.hw_server or vivado.parent / "hw_server"
    # UG908: filter before discovery and disable automatic scan-chain opening.
    # Tcl still requires one exact serial match before explicitly opening it.
    command = [str(server_binary), "-s", f"tcp:127.0.0.1:{port}",
               "-e", "set auto-open-ports 0", "-e", f"set jtag-port-filter {args.serial}"]
    (args.output / "hw-server-command.json").write_text(json.dumps(command, indent=2) + "\n")
    server_log = (args.output / "hw-server.log").open("w")
    server = subprocess.Popen(command, stdout=server_log, stderr=subprocess.STDOUT,
                              start_new_session=True)
    try:
        deadline = time.monotonic() + 15
        while True:
            if server.poll() is not None:
                raise RuntimeError("dedicated hw_server exited before connection")
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                    break
            except OSError:
                if time.monotonic() > deadline:
                    raise TimeoutError("dedicated hw_server startup timeout")
                time.sleep(0.1)
        command = [str(vivado), "-mode", "batch", "-nojournal", "-log", "program-vivado.log",
                   "-source", str(Path(__file__).with_suffix(".tcl")), "-tclargs",
                   str(bitstream), str(port), args.serial]
        (args.output / "command.json").write_text(json.dumps(command, indent=2) + "\n")
        with (args.output / "program.log").open("w") as log:
            process = subprocess.Popen(command, cwd=args.output, stdout=log,
                                       stderr=subprocess.STDOUT, start_new_session=True)
            try:
                process.wait(timeout=180)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                raise
        output = (args.output / "program.log").read_text(errors="replace")
        passed = process.returncode == 0 and "RAPT_ARTY_VOLATILE_PROGRAM_PASS" in output
        (args.output / "result.json").write_text(json.dumps(
            {"pass": passed, "exit_code": process.returncode,
             "bitstream_sha256": evidence["bitstream_sha256"]}, indent=2) + "\n")
        print("VOLATILE_PROGRAM_PASS" if passed else "VOLATILE_PROGRAM_FAIL")
        return int(not passed)
    finally:
        if server.poll() is None:
            os.killpg(server.pid, signal.SIGTERM)
            try:
                server.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(server.pid, signal.SIGKILL)
                server.wait()
        server_log.close()


if __name__ == "__main__":
    raise SystemExit(main())
