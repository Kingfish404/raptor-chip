#!/usr/bin/env python3
"""Program or test the external flash through the SoC's standard SBA master."""

import argparse
import hashlib
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from flash import FIRST, SECTOR, checked_range
from flash_image import inspect_image
from debug import run_openocd
from common import tcl_string


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--offset", type=lambda text: int(text, 0), default=FIRST + 0x4000)
    parser.add_argument("--image", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    data = args.image.read_bytes() if args.image else b""
    if data:
        inspect_image(data)
    checked_range(args.offset, max(SECTOR, (len(data) + 3) // 4 * 4), SECTOR if not data else 4)
    if args.offset % SECTOR:
        parser.error("offset must be sector aligned")
    args.output.mkdir(parents=True, exist_ok=True)
    runner = args.output.resolve() / "run.tcl"
    padded = data + b"\xff" * (-len(data) % 4)
    words = [str(int.from_bytes(padded[i:i + 4], "little")) for i in range(0, len(padded), 4)]
    image_words = args.output.resolve() / "image-words.tcl"
    image_words.write_text("set IMAGE_WORDS {\n" + "\n".join(words) + "\n}\n")
    runner.write_text(f"set OFFSET {args.offset}\n"
                      f"set IMAGE {tcl_string(args.image.resolve() if args.image else '')}\n"
                      f"source {tcl_string(image_words)}\n"
                      f"set OUT {tcl_string(args.output.resolve() / 'backups')}\n"
                      "init\n"
                      f"source {tcl_string(Path(__file__).with_name('flash_sba.tcl').resolve())}\n")
    arguments = ["-f", "tap.cfg", "-f", "sba.tcl", "-c", "gdb_port disabled",
                 "-c", "tcl_port disabled", "-c", "telnet_port disabled", "-f", str(runner)]
    code, output = run_openocd(arguments, args.output / "sba-flash.log", timeout=1800)
    passed = code == 0 and "RAPT_HW_SBA_FLASH_PASS" in output
    record = {"pass": passed, "exit_code": code, "offset": args.offset,
              "image_sha256": hashlib.sha256(data).hexdigest() if data else None}
    (args.output / "result.json").write_text(json.dumps(record, indent=2) + "\n")
    print(output, end="")
    return 77 if code == 77 else int(not passed)


if __name__ == "__main__":
    raise SystemExit(main())
