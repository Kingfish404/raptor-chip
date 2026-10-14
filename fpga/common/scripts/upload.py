#!/usr/bin/env python3
"""Upload native Raptor images over a POSIX UART (Python standard library only)."""
import argparse
import os
from pathlib import Path
import select
import struct
import termios
import time
import zlib

HEADER = struct.Struct("<4sBIII")
CHUNK = 4096


def packet(op, address, count, crc=0):
    return HEADER.pack(b"RAPT", op, address, count, crc)


class Serial:
    def __init__(self, port, baud=115200):
        self.fd = os.open(port, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
        self.previous = termios.tcgetattr(self.fd)
        attrs = termios.tcgetattr(self.fd)
        attrs[0] = attrs[1] = attrs[3] = 0
        attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL
        attrs[4] = attrs[5] = getattr(termios, f"B{baud}")
        attrs[6][termios.VMIN] = attrs[6][termios.VTIME] = 0
        termios.tcsetattr(self.fd, termios.TCSANOW, attrs)

    def close(self):
        termios.tcsetattr(self.fd, termios.TCSANOW, self.previous)
        os.close(self.fd)

    def read(self, count=1, timeout=10):
        result = bytearray()
        deadline = time.monotonic() + timeout
        while len(result) < count:
            remain = deadline - time.monotonic()
            if remain <= 0 or not select.select([self.fd], [], [], remain)[0]:
                raise TimeoutError("UART response timed out; check board reset, baud and boot image")
            result.extend(os.read(self.fd, count - len(result)))
        return bytes(result)

    def write(self, data):
        view = memoryview(data)
        while view:
            if not select.select([], [self.fd], [], 10)[1]:
                raise TimeoutError("UART write timed out")
            try:
                view = view[os.write(self.fd, view):]
            except BlockingIOError:
                continue


def ack(serial, timeout=10):
    result = serial.read(timeout=timeout)
    if result == b"E":
        code = serial.read()[0]
        raise RuntimeError(f"Boot ROM rejected command: error {code}")
    if result != b"K":
        raise RuntimeError(f"Unexpected boot response {result!r}; wait for 'RAPT ready' before uploading")


def load(serial, address, data):
    for offset in range(0, len(data), CHUNK):
        chunk = data[offset:offset + CHUNK]
        serial.write(packet(1, address + offset, len(chunk), zlib.crc32(chunk)) + chunk)
        ack(serial)


def number(value):
    return int(value, 0)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", required=True)
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--image", action="append", default=[], metavar="ADDRESS:FILE")
    parser.add_argument("--entry", type=number)
    parser.add_argument("--dtb", type=number, default=0)
    parser.add_argument("--memtest", metavar="ADDRESS:LENGTH", help="destructively test the specified RAM range")
    parser.add_argument("--wait-ready", action="store_true", help="wait for boot banner after a board reset")
    parser.add_argument("--console", action="store_true", help="stream UART output after commands")
    args = parser.parse_args()
    # Validate and read every input before contacting the board.
    images = []
    for item in args.image:
        address, path = item.split(":", 1)
        address, data = number(address), Path(path).read_bytes()
        if not data or address < 0x80000000 or address + len(data) > 0x100000000:
            parser.error(f"image is empty or outside the physical RAM window: {item}")
        images.append((address, data, path))
    for i, (address, data, path) in enumerate(images):
        for other, content, name in images[:i]:
            if max(address, other) < min(address + len(data), other + len(content)):
                parser.error(f"overlapping images: {path} and {name}")
    if args.entry is not None and (args.entry < 0x80000000 or args.entry >= 0x100000000 or args.entry & 1):
        parser.error("entry must be an aligned 32-bit RAM address")
    if args.dtb and (args.dtb < 0x80000000 or args.dtb >= 0x100000000 or args.dtb & 7):
        parser.error("DTB must be an 8-byte aligned 32-bit RAM address")
    memtest = tuple(map(number, args.memtest.split(":"))) if args.memtest else None
    if memtest and (len(memtest) != 2 or memtest[0] & 3 or memtest[1] & 3 or
                    memtest[0] < 0x80000000 or memtest[1] <= 0 or sum(memtest) > 0x100000000):
        parser.error("memtest requires an aligned, nonempty RAM range")
    serial = Serial(args.port, args.baud)
    try:
        if args.wait_ready:
            tail = b""
            while not tail.endswith(b"RAPT ready\r\n"):
                c = serial.read(timeout=60)
                os.write(1, c)
                tail = (tail + c)[-32:]
        else:
            # Drain stale banner bytes; callers must already have seen ready.
            termios.tcflush(serial.fd, termios.TCIFLUSH)
        if memtest:
            serial.write(packet(3, *memtest))
            ack(serial, timeout=300)
            print("Memory test passed")
        for address, data, path in images:
            load(serial, address, data)
            print(f"Loaded {len(data)} bytes at {address:#x}: {path}", flush=True)
        if args.entry is not None:
            serial.write(packet(2, args.entry, args.dtb))
            ack(serial)
        if args.console:
            while True:
                if select.select([serial.fd], [], [], 1)[0]:
                    os.write(1, os.read(serial.fd, 4096))
    finally:
        serial.close()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
    except (OSError, ValueError, RuntimeError, TimeoutError) as exc:
        raise SystemExit(str(exc)) from exc
