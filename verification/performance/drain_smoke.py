#!/usr/bin/env python3
"""Check real-core halt and DDR writeback against independent NEMU snapshots."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import struct
import subprocess
import time

from fpga_image import PAGE, RAM, SparseRam, read_state, restore_image
from fpga_replay import config_words
from simpoints import digest, write_json

HERE = Path(__file__).resolve().parent
LENGTHS = (1, 2, 3, 4, 16, 64, 1000, 10000)


def run(command, log, timeout):
    with log.open("w") as output:
        subprocess.run(list(map(str, command)), cwd=log.parent, check=True, timeout=timeout,
                       env={**os.environ, "NEMU_STATUS_DIR": str(log.parent)},
                       stdout=output, stderr=subprocess.STDOUT)


def capture(args, root, offsets):
    root.mkdir()
    points = root / "points.txt"
    points.write_text("".join(f"{offset}\n" for offset in sorted(set(offsets))))
    run([args.nemu, "-b", f"--sample-points={points}",
         f"--sample-directory={root / 'checkpoints'}", "-t", args.dtb,
         args.output / "drain.bin"], root / "capture.log", args.timeout)
    return root / "checkpoints"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("model", "exporter", "nemu", "dtb", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--cross", default="riscv64-unknown-elf-")
    parser.add_argument("--timeout", type=int, default=180)
    args = parser.parse_args()
    result = None
    try:
        if args.timeout <= 0:
            raise ValueError("timeout must be positive")
        for name in ("model", "exporter", "nemu", "dtb", "output"):
            setattr(args, name, getattr(args, name).resolve())
        args.output.mkdir(parents=True, exist_ok=False)
        result = {"schema": "raptor-fpga-drain-regression-v1", "complete": False,
                  "fpga_board_measurement": False, "cases": [],
                  "inputs": {name: {"path": str(getattr(args, name)),
                                    "sha256": digest(getattr(args, name))}
                             for name in ("model", "exporter", "nemu", "dtb")},
                  "fixture_sha256": digest(HERE / "drain_checkpoint.S")}
        elf, image = args.output / "drain.elf", args.output / "drain.bin"
        run([args.cross + "gcc", "-march=rv64gc", "-mabi=lp64d", "-nostdlib", "-nostartfiles",
             "-Wl,-Ttext=0x80000000", "-Wl,--no-relax", "-o", elf, HERE / "drain_checkpoint.S"],
            args.output / "compile.log", args.timeout)
        run([args.cross + "objcopy", "-O", "binary", elf, image],
            args.output / "objcopy.log", args.timeout)
        symbols = subprocess.check_output([args.cross + "nm", "-n", str(elf)], text=True)
        probe = next(int(line.split()[0], 16) for line in symbols.splitlines()
                     if line.split()[-1] == "memory")
        origin = 40
        initial = capture(args, args.output / "initial", [origin]) / f"sample-{origin}"
        trampoline = args.output / "trampoline.bin"
        run([args.exporter, f"--ckpt-export={initial / 'state.txt'},{trampoline}"],
            args.output / "export.log", args.timeout)
        state = read_state(initial / "state.txt")
        restored, mret_pc = restore_image(state, trampoline.read_bytes())
        restore_path = args.output / "restore.bin"
        restore_path.write_bytes(restored)
        for length in LENGTHS:
            root = args.output / str(length)
            root.mkdir()
            config = root / "config.txt"
            words = config_words(state, {"warmup": 0, "instructions": length}, mret_pc, 10000000)
            config.write_text("".join(f"{offset:x} {value:x}\n" for offset, value in words.items()) +
                              "8 1\n")
            start = time.monotonic()
            run([args.model, initial, restore_path, config, root / "hardware.json", hex(probe), "4"],
                root / "model.log", args.timeout)
            hardware = json.loads((root / "hardware.json").read_text())
            if not hardware.get("complete") or hardware["retired"] < length:
                raise ValueError(f"incomplete drain at length {length}")
            result["cases"].append({"instructions": length, "retired": hardware["retired"],
                                    "wall_seconds": time.monotonic() - start})
        references = capture(args, args.output / "reference",
                             [origin + case["retired"] for case in result["cases"]])
        for case in result["cases"]:
            length = case["instructions"]
            hardware = json.loads((args.output / str(length) / "hardware.json").read_text())
            checkpoint = references / f"sample-{origin + case['retired']}"
            expected = read_state(checkpoint / "state.txt")
            if [int(value, 0) for value in hardware["gpr"]] != [expected[f"gpr{r}"] for r in range(32)]:
                raise ValueError(f"architectural registers differ at length {length}")
            memory = SparseRam(checkpoint)
            try:
                expected_words = [struct.unpack_from("<Q", memory.page((probe - RAM + i * 8) // PAGE),
                                  (probe - RAM + i * 8) % PAGE)[0] for i in range(4)]
            finally:
                memory.close()
            actual = hardware["memory_probe"]
            if (int(actual["address"], 0) != probe or
                    [int(value, 0) for value in actual["words"]] != expected_words):
                raise ValueError(f"DDR did not publish committed stores at length {length}")
            case.update(gpr_match=True, published_ddr_match=True)
        result["complete"] = True
        print("PASS: eight real-core drain boundaries, all GPRs and published DDR match NEMU")
    except (OSError, ValueError, KeyError, StopIteration, subprocess.SubprocessError) as error:
        if result is not None:
            result["error"] = str(error)
        parser.exit(1, f"{error}\n")
    finally:
        if result is not None:
            write_json(args.output / "validation.json", result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
