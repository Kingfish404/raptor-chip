#!/usr/bin/env python3
"""Run cpu-tests, the link sweep, MicroBench or RAM March through the board UART."""

import argparse
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from host import Board
from image import prepare
from sources import ROOT


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", required=True)
    parser.add_argument("--build", type=Path, required=True)
    parser.add_argument("--suite", choices=["cpu", "sweep", "microbench", "march", "xip"],
                        required=True)
    parser.add_argument("--microbench", type=Path)
    parser.add_argument("--delay", type=int, choices=range(8), default=0)
    parser.add_argument("--timeout", type=int, default=300)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    images = sorted((ROOT / "abstract-machine/app/am-kernels/tests/cpu-tests/build").glob(
        "*-riscv32-npc.bin"))
    if args.suite == "cpu":
        cases = [(p.stem, p, 4, False) for p in images]
    elif args.suite == "sweep":
        source = next(p for p in images if p.name.startswith("load-store-"))
        cases = [(f"half-{half}", source, half, False) for half in range(2, 16)]
    elif args.suite == "microbench":
        if not args.microbench:
            parser.error("--microbench is required for that suite")
        cases = [("microbench", args.microbench, 4, False)]
    elif args.suite == "march":
        cases = [("ram-march", args.build / "ram_march.bin", 4, True)]
    else:
        cases = [("flash-xip", args.build / "xip_probe.bin", 4, True)]
    if not cases:
        parser.error("no cpu-test images found")
    results = []
    with Board(args.port) as board:
        status = board.command("S")
        for name, source, half, raw in cases:
            image = args.output / f"{name}.bin"
            if raw:
                image.write_bytes(source.read_bytes())
            else:
                prepare(source, image, args.build / "finish.bin")
            try:
                result = board.run(image, half, args.timeout, args.delay)
            except (TimeoutError, ValueError, OSError) as error:
                result = {"pass": False, "error": str(error), "half_period": half}
                result.update(board.last_run)
                try:
                    board.command("A")
                except (TimeoutError, ValueError, OSError) as recovery_error:
                    result["recovery_error"] = str(recovery_error)
            result.update(name=name, initial_status=f"{status:08x}",
                          internal_join=bool(status & 0x10000), delay=args.delay)
            if args.suite == "xip":
                result["pass"] &= b"flash XIP: PASS" in board.console
            if args.suite == "microbench":
                result["pass"] &= (b"MicroBench PASS" in board.console
                                   and b"Ignored" not in board.console
                                   and b"Failed" not in board.console)
            if args.suite == "march":
                result["pass"] &= b"RAM March C-: PASS" in board.console
            results.append(result)
            (args.output / f"{name}.console.txt").write_bytes(board.console)
            (args.output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
            print(json.dumps(result), flush=True)
            if "recovery_error" in result or not result["pass"]:
                break
    passed = all(item["pass"] for item in results)
    print(f"RAPT_HW_{args.suite.upper()}_{'PASS' if passed else 'FAIL'} cases={len(results)}")
    return int(not passed)


if __name__ == "__main__":
    raise SystemExit(main())
