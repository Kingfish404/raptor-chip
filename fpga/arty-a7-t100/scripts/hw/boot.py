#!/usr/bin/env python3
"""Capture a persistent-flash boot across volatile FPGA reconfiguration (SW0 must be 1)."""

import argparse
import json
from pathlib import Path
import subprocess
import sys
import termios
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from flash import FIRST, Flash, Session
from flash_image import inspect_image
from host import Board


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", required=True)
    parser.add_argument("--build", type=Path, required=True)
    parser.add_argument("--vivado", required=True)
    parser.add_argument("--image", type=Path, required=True)
    parser.add_argument("--backup", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    image = args.image.read_bytes()
    header = inspect_image(image)
    with Board(args.port) as board:
        board.command("A")
        board.command("B", 2)
        if not board.command("S") & 0x10:
            raise ValueError("set SW0=1 for autonomous flash boot after reconfiguration")
        flash = Flash(board)
        sectors = json.loads((args.backup / "manifest.json").read_text())["sectors"]
        Session(flash, args.backup, sectors).compare()
        if flash.read(FIRST, (len(image) + 3) // 4 * 4)[:len(image)] != image:
            raise ValueError("flash contents do not match the requested boot image")
        board.console.clear()
        board.buffer.clear()
        board.finisher = None
        termios.tcflush(board.fd, termios.TCIFLUSH)
        command = [sys.executable, str(Path(__file__).with_name("program.py")),
                   "--build", str(args.build), "--vivado", args.vivado,
                   "--output", str(args.output / "reconfigure")]
        subprocess.run(command, check=True)
        deadline = time.monotonic() + 300
        while board.finisher is None:
            board.packet(deadline)
        passed = (board.finisher == 0x5555
                  and b"flash: CRC OK; boot RAM" in board.console)
        frames = board.command("L")
        passed &= frames > 0
        (args.output / "console.txt").write_bytes(board.console)
        record = {"pass": passed, "finisher": f"{board.finisher:08x}",
                  "link_frames": frames, "image": header, "reconfigured": True}
        (args.output / "result.json").write_text(json.dumps(record, indent=2) + "\n")
        board.command("A")
        Session(Flash(board), args.backup, sectors).compare()
        print("RAPT_HW_FLASH_BOOT_PASS" if passed else "RAPT_HW_FLASH_BOOT_FAIL")
        return int(not passed)


if __name__ == "__main__":
    raise SystemExit(main())
