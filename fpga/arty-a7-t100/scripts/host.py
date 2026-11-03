#!/usr/bin/env python3
"""Load, verify and run a prepared binary via the Arty USB-UART command port.

Uses only Python's standard library. Select the UART wired to ChipKIT ck8/ck7
explicitly with --port or ARTY_UART; no unrelated UART is opened automatically.
"""

import argparse
import fcntl
import json
import os
from pathlib import Path
import select
import struct
import sys
import termios
import time

from image import CONTROL

DEFAULT_PORT = os.environ.get("ARTY_UART")


class Board:
    def __init__(self, port=DEFAULT_PORT):
        if not port:
            raise ValueError("select the UART connected to ck8/ck7 using --port or ARTY_UART")
        port = Path(port)
        self.fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        self.original = termios.tcgetattr(self.fd)
        settings = termios.tcgetattr(self.fd)
        settings[0] = 0
        settings[1] = 0
        settings[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
        settings[3] = 0
        settings[4] = termios.B115200
        settings[5] = termios.B115200
        settings[6][termios.VMIN] = 0
        settings[6][termios.VTIME] = 0
        termios.tcsetattr(self.fd, termios.TCSANOW, settings)
        termios.tcflush(self.fd, termios.TCIOFLUSH)
        self.buffer = bytearray()
        self.console = bytearray()
        self.finisher = None
        self.last_run = {}

    def close(self):
        termios.tcsetattr(self.fd, termios.TCSANOW, self.original)
        os.close(self.fd)

    def __enter__(self):
        return self

    def __exit__(self, *unused):
        self.close()

    def write(self, data):
        view = memoryview(data)
        deadline = time.monotonic() + len(data) / 8000 + 5
        while view:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([], [self.fd], [], remaining)[1]:
                raise TimeoutError("UART transmit timeout")
            try:
                count = os.write(self.fd, view)
                view = view[count:]
            except BlockingIOError:
                pass

    def packet(self, deadline):
        while len(self.buffer) < 6:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self.fd], [], [], remaining)[0]:
                raise TimeoutError("UART response/finisher timeout")
            self.buffer.extend(os.read(self.fd, 4096))
        if self.buffer[0] != 0x5a:
            raise ValueError("UART framing lost; reset board and retry")
        _, kind, value = struct.unpack("<BBI", self.buffer[:6])
        del self.buffer[:6]
        if kind == ord("C"):
            self.console.append(value & 255)
            sys.stdout.write(chr(value & 255))
            sys.stdout.flush()
        if kind == ord("F"):
            self.finisher = value
        return chr(kind), value

    def command(self, cmd, address=0, data=b"", timeout=10):
        self.write(struct.pack("<BBIH", 0xa5, ord(cmd), address, len(data)) + data)
        deadline = time.monotonic() + timeout
        expected = cmd if cmd in "SRLFQ" else "A"
        while True:
            kind, value = self.packet(deadline)
            if kind == "E":
                raise ValueError(f"board rejected {cmd}: {value:#x}")
            if kind == expected:
                if kind == "A" and value != ord(cmd):
                    raise ValueError(f"unexpected acknowledgement {value:#x} for {cmd}")
                return value

    def read32(self, address):
        return self.command("Q", address)

    def write32(self, address, value):
        self.command("P", address, struct.pack("<I", value))

    def write_ram(self, address, data):
        for offset in range(0, len(data), 4096):
            self.command("W", address + offset, data[offset:offset + 4096])

    def load(self, data):
        if len(data) > CONTROL - 0x80000000:
            raise ValueError("image overlaps reserved loader words")
        self.command("A")
        self.command("Z")
        self.console.clear()
        self.finisher = None
        for offset in range(0, len(data), 4096):
            block = data[offset:offset + 4096]
            self.command("W", 0x80000000 + offset, block)
        # Full word-by-word verification catches corrupted byte writes before
        # execution. The final short word has zero-filled high bytes after Z.
        for offset in range(0, len(data), 4):
            value = self.command("R", 0x80000000 + offset)
            expected = int.from_bytes(data[offset:offset + 4].ljust(4, b"\0"), "little")
            if value != expected:
                raise ValueError(f"RAM mismatch at {0x80000000 + offset:#x}")

    def run(self, image, half, timeout, delay=0, keep_running=False):
        self.last_run = {}
        self.load(image.read_bytes())
        self.command("B", 0)
        self.command("D", delay)
        self.command("W", CONTROL, struct.pack("<I", half))
        deadline = time.monotonic() + timeout
        try:
            self.command("G", timeout=min(10, timeout))
            while self.finisher is None:
                self.packet(deadline)
        except (TimeoutError, ValueError, OSError):
            # A resets the traffic counter: preserve live diagnostics first.
            for name, command in (("running_status", "S"), ("link_frames", "L")):
                try:
                    self.last_run[name] = self.command(command, timeout=2)
                except (TimeoutError, ValueError, OSError) as error:
                    self.last_run[name + "_error"] = str(error)
            raise
        raw = self.finisher
        frames = self.command("L")
        if keep_running:
            return {"image": str(image), "half_period": half, "finisher": raw,
                    "link_frames": frames, "pass": raw == 0x5555 and frames > 0,
                    "running": True, "divider_readback": "pending while running"}
        self.command("A")
        divider = self.command("R", CONTROL + 4)
        return {"image": str(image), "half_period": half, "divider_readback": divider,
                "finisher": raw, "exit_code": 0 if raw == 0x5555 else raw >> 16 or 1,
                "link_frames": frames,
                "pass": raw == 0x5555 and divider == half and frames > 0}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", default=DEFAULT_PORT)
    parser.add_argument("--image", type=Path)
    parser.add_argument("--half", type=int, choices=range(2, 16), default=4)
    parser.add_argument("--sweep", action="store_true")
    parser.add_argument("--timeout", type=int, default=120)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--status", action="store_true")
    parser.add_argument("--delay", type=int, choices=range(8), default=0)
    parser.add_argument("--keep-running", action="store_true")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    board = Board(args.port)
    records = []
    try:
        if args.status:
            print(f"Status: {board.command('S'):#010x}")
            return 0
        if not args.image:
            parser.error("--image is required except with --status")
        for half in range(2, 16) if args.sweep else [args.half]:
            try:
                result = board.run(args.image, half, args.timeout, args.delay, args.keep_running)
            except (TimeoutError, ValueError) as error:
                result = {"half_period": half, "pass": False, "error": str(error)}
                try:
                    board.command("A")
                except (TimeoutError, ValueError, OSError) as recovery_error:
                    result["recovery_error"] = str(recovery_error)
            records.append(result)
            print(json.dumps(result), flush=True)
            (args.output / f"console-{half}.txt").write_bytes(board.console)
            (args.output / "results.json").write_text(json.dumps(records, indent=2) + "\n")
            if "recovery_error" in result:
                break
    finally:
        board.close()
    return int(any(not r["pass"] for r in records))


if __name__ == "__main__":
    raise SystemExit(main())
