#!/usr/bin/env python3
"""Preflight RAM loading and a bounded CPU/link/console/finisher boot over UART."""

import argparse
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from host import Board


def check_loader(board, build=None, output=None):
    board.command("A")
    status = board.command("S")
    if status & 1 or not status & 0x10000:
        raise ValueError(f"expected stopped internal-link build, status={status:#x}")
    board.command("Z")
    cases = []
    for address, length in ((0x80000000, 16), (0x80000100, 256),
                            (0x80001000, 4096), (0x8003fff0, 16)):
        data = bytes((index ^ (index >> 8) ^ 0xa5) & 255 for index in range(length))
        board.command("W", address, data)
        for offset in range(0, length, 4):
            expected = int.from_bytes(data[offset:offset + 4], "little")
            actual = board.command("R", address + offset)
            if actual != expected:
                raise ValueError(f"RAM mismatch at {address + offset:#x}: "
                                 f"{actual:#x} expected {expected:#x}")
        cases.append({"address": f"{address:#010x}", "bytes": length, "pass": True})
        print(f"LOADER_WR_PASS address={address:#010x} bytes={length}", flush=True)
    board.command("Z")
    if board.command("R", 0x80000000) != 0:
        raise ValueError("RAM clear/readback failed")
    result = {"pass": True, "initial_status": f"{status:#x}", "cases": cases}
    if build is not None:
        boot = {"pass": False}
        try:
            boot = board.run(build / "boot_check.bin", 4, timeout=5)
            boot["console_pass"] = b"BOOT_CHECK_PASS\n" in board.console
            boot["pass"] &= boot["console_pass"]
        except (TimeoutError, ValueError, OSError) as error:
            boot = {"pass": False, "error": str(error), **board.last_run}
        finally:
            try:
                board.command("A")
            except (TimeoutError, ValueError, OSError) as error:
                boot["recovery_error"] = str(error)
                boot["pass"] = False
        result["boot"] = boot
        result["pass"] &= boot["pass"]
        if output is not None:
            (output / "boot.console.txt").write_bytes(board.console)
        print("LOADER_BOOT_" + ("PASS" if boot["pass"] else "FAIL") + " "
              + json.dumps(boot), flush=True)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", required=True)
    parser.add_argument("--build", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    try:
        with Board(args.port) as board:
            result = check_loader(board, args.build, args.output)
    except (OSError, TimeoutError, ValueError) as error:
        result = {"pass": False, "error": str(error)}
    (args.output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result), flush=True)
    print("RAPT_HW_LOADER_" + ("PASS" if result["pass"] else "FAIL"))
    return int(not result["pass"])


if __name__ == "__main__":
    raise SystemExit(main())
