#!/usr/bin/env python3
"""Run isolated RV32/RV64 memory regressions with existing simulators/NEMU.

Builds only the standalone test image, never shared simulator configuration.
Additional prebuilt images must match --xlen. Logs record commands and hashes;
exit status alone is insufficient: every run must report GOOD TRAP.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
ANSI = re.compile(r"\x1b\[[0-9;]*m")


def fingerprint(path: Path) -> dict:
    return {"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--xlen", type=int, choices=(32, 64), required=True)
    parser.add_argument("--sim", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--image", type=Path, action="append", default=[])
    parser.add_argument("--delays", type=int, nargs="+", default=[0, 7, 63])
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--timeout", type=int, default=120)
    args = parser.parse_args()
    if args.timeout <= 0 or any(delay < 0 or delay >= 1048575 for delay in args.delays):
        parser.error("positive timeout and delays in [0, 1048574] required")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    simulator = args.sim.resolve()
    reference = ROOT / f"nemu/build/riscv{args.xlen}-nemu-interpreter-so"
    boot = ROOT / f"sim/csrc/mem/mrom-data/build/rv{args.xlen}-spike-rv{args.xlen}ima/mrom-data.bin"
    source = ROOT / "app/tests/baremetal/memory_quality.S"
    elf = output / "memory_quality.elf"
    image = output / "memory_quality.bin"
    build_command = ["riscv64-elf-gcc", "-nostdlib", "-nostartfiles", "-mno-relax",
                     f"-march=rv{args.xlen}imafdc_zicsr_zifencei",
                     "-mabi=ilp32d" if args.xlen == 32 else "-mabi=lp64d",
                     "-Wl,-Ttext=0x80000000", "-Wl,-e,_start", str(source), "-o", str(elf)]
    subprocess.run(build_command, check=True, cwd=ROOT)
    subprocess.run(["riscv64-elf-objcopy", "-O", "binary", str(elf), str(image)], check=True)
    images = [image] + [path.resolve() for path in args.image]
    result = {"xlen": args.xlen, "complete": False, "seed": args.seed,
              "simulator": fingerprint(simulator), "reference": fingerprint(reference),
              "boot": fingerprint(boot), "source": fingerprint(source),
              "build_command": build_command, "images": [fingerprint(p) for p in images],
              "runs": []}
    for index, workload in enumerate(images):
        for delay in args.delays:
            label = f"{index:02d}-{workload.stem}-delay{delay}"
            command = [str(simulator), "-b", "-n", "--no-lightsss", "-t", str(args.timeout),
                       "-d", str(reference), "-r", str(boot),
                       f"--mem-random-delay={delay}", f"--mem-random-seed={args.seed}",
                       str(workload)]
            row = {"label": label, "command": command, "cwd": str(ROOT / "sim")}
            try:
                process = subprocess.run(command, cwd=ROOT / "sim", text=True,
                                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                         timeout=args.timeout + 10)
                raw = process.stdout
                clean = ANSI.sub("", raw)
                row["returncode"] = process.returncode
                row["passed"] = (process.returncode == 0 and "HIT GOOD TRAP" in clean
                                 and not re.search(r"HIT BAD TRAP|\[ERROR\]|mismatch|ERROR!",
                                                   clean, re.IGNORECASE))
                counts = re.findall(r"#inst:\s*(\d+), cycle:\s*(\d+)", clean)
                if counts:
                    row["instructions"], row["cycles"] = map(int, counts[-1])
            except subprocess.TimeoutExpired as error:
                raw = error.stdout or b""
                if isinstance(raw, bytes):
                    raw = raw.decode(errors="replace")
                row.update(passed=False, error="wall-time timeout")
            (output / f"{label}.log").write_text(raw)
            result["runs"].append(row)
            (output / "results.json").write_text(json.dumps(result, indent=2) + "\n")
            print(f"{'PASS' if row['passed'] else 'FAIL'}: RV{args.xlen}/{label}", flush=True)
    result["complete"] = True
    result["passed"] = all(row["passed"] for row in result["runs"])
    (output / "results.json").write_text(json.dumps(result, indent=2) + "\n")
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
