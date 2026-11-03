#!/usr/bin/env python3
"""Back up/compare external MT35X sectors, then test or program by UART or SoC firmware."""

import argparse
import json
from pathlib import Path
import struct
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from flash import COMMAND, CTRL, END, FIRST, SECTOR, Flash, Session, checked_range
from flash_image import inspect_image
from host import Board
from image import CONTROL


class FirmwareFlash(Flash):
    def __init__(self, board, flasher):
        super().__init__(board)
        self.flasher = flasher

    def invoke(self, operation, offset, length, data=b""):
        board = self.io
        board.load(self.flasher.read_bytes())
        board.command("B", 0)
        board.write_ram(0x8001f000, struct.pack("<5I", 0x5241464c, operation,
                                              offset, length, 0x80020000))
        if data:
            board.write_ram(0x80020000, data)
        board.write_ram(CONTROL, struct.pack("<I", 4))
        board.command("G")
        deadline = time.monotonic() + 300
        while board.finisher is None:
            board.packet(deadline)
        frames = board.command("L")
        code = board.finisher
        board.command("A")
        if code != 0x5555 or frames == 0:
            raise ValueError(f"firmware flasher failed: finisher={code:08x}, frames={frames}")
        print(f"FIRMWARE_FLASHER_PASS op={operation} offset={offset:08x} bytes={length}", flush=True)

    def program(self, offset, data):
        checked_range(offset, len(data))
        for index in range(0, len(data), 65536):
            chunk = data[index:index + 65536]
            self.invoke(2, offset + index, len(chunk), chunk)
        if self.read(offset, len(data)) != data:
            raise ValueError("firmware-programmed image differs from full host readback")

    def erase(self, offset):
        checked_range(offset, SECTOR, SECTOR)
        self.invoke(1, offset, SECTOR)
        if self.read(offset, SECTOR) != b"\xff" * SECTOR:
            raise ValueError("firmware-erased sector is not completely blank")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", required=True)
    parser.add_argument("--path", choices=["uart", "firmware"], default="uart")
    parser.add_argument("--flasher", type=Path)
    parser.add_argument("--mode", choices=["backup", "test", "program", "cleanup"], required=True)
    parser.add_argument("--offset", type=lambda value: int(value, 0), default=FIRST)
    parser.add_argument("--image", type=Path)
    parser.add_argument("--backup", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    data = None
    if args.mode == "program":
        if not args.image:
            parser.error("--image must name a checked length/CRC/entry flash image")
        data = args.image.read_bytes()
        inspect_image(data)
        data += b"\xff" * (-len(data) % 4)
        checked_range(args.offset, len(data))
        sectors = list(range(args.offset, args.offset + len(data), SECTOR))
    elif args.mode == "cleanup":
        sectors = json.loads((args.backup / "manifest.json").read_text())["sectors"]
    else:
        checked_range(args.offset, SECTOR, SECTOR)
        sectors = [args.offset]
    if args.offset % SECTOR:
        parser.error("--offset must be sector aligned")
    if args.path == "firmware" and not args.flasher:
        parser.error("--flasher is required for the firmware programming path")
    with Board(args.port) as board:
        board.command("A")
        flash = FirmwareFlash(board, args.flasher) if args.path == "firmware" else Flash(board)
        session = Session(flash, args.backup, sectors)
        if args.mode in {"test", "program", "cleanup"}:
            for sector in sectors:
                session.erase(sector)
        if args.mode == "program":
            session.program(args.offset, data)
        elif args.mode == "test":
            for index, displacement in enumerate((0, 0xfc, 0x100, 0xffc)):
                pattern = 0x91e1f00d ^ (index * 0x01020408)
                session.program(args.offset + displacement, struct.pack("<I", pattern))
                session.program(args.offset + displacement, bytes(4))
            # Host refusal is checked without issuing forbidden physical requests.
            for offset, length in ((0, 4), (0x10000, 4), (FIRST - 4, 4), (END, 4),
                                   (END - 4, 8), (FIRST + 0xfe, 4)):
                try:
                    checked_range(offset, length)
                except ValueError:
                    continue
                raise ValueError("host accepted an out-of-range or unaligned mutation")
            session.erase(args.offset)
        session.compare()
        record = {"pass": True, "path": args.path, "mode": args.mode,
                  "id": f"{flash.identity:06x}", "sectors": sectors,
                  "protected": [0, 0x10000], "backup": str(args.backup)}
        (args.output / "result.json").write_text(json.dumps(record, indent=2) + "\n")
        print(f"RAPT_HW_FLASH_{args.mode.upper()}_PASS path={args.path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
