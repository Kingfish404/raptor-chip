#!/usr/bin/env python3
"""Compare F/D scheduling revisions using identical self-checking guest images.

Counters cover a fixed-length kernel after four warmup iterations (including loop/timing overhead),
not UART output or simulator wall time. NEMU difftest remains enabled. The
optional CoreMark image is an integer control; a short run is not an official
CoreMark score. Build both simulators with equivalent presets before running.
"""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import json
from pathlib import Path
import re
import subprocess

from execution_port_workloads import ANSI, validate_output


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "app/tests/baremetal/fp_ooo_perf.S"
CASES = (
    "integer", "add_independent", "add_chain", "mul_independent",
    "fma_independent", "fma_chain", "div_stream", "div_integer",
    "load_add_store", "div_add",
)


def artifact(path: Path) -> dict:
    path = path.resolve()
    return {"path": str(path), "sha256": hashlib.sha256(path.read_bytes()).hexdigest()}


def parse_roi(output: str, coremark: bool) -> dict:
    if coremark:
        cycles = re.findall(r"CoreMark ROI cycles\s*:\s*(\d+)", output)
        instructions = re.findall(r"CoreMark ROI instructions\s*:\s*(\d+)", output)
        if len(cycles) != 1 or len(instructions) != 1:
            raise ValueError("missing or repeated CoreMark ROI counters")
        cycles, instructions = int(cycles[0]), int(instructions[0])
    else:
        counters = re.findall(r"FP_PERF cycles=([0-9a-f]+) instret=([0-9a-f]+)", output)
        if len(counters) != 1:
            raise ValueError("missing or repeated FP ROI counters")
        cycles, instructions = (int(value, 16) for value in counters[0])
    if cycles <= 0 or instructions <= 0:
        raise ValueError("non-positive ROI counters")
    return {"cycles": cycles, "instructions": instructions, "ipc": instructions / cycles}


def build_images(args: argparse.Namespace, output: Path) -> list[dict]:
    images = []
    with (output / "build.log").open("w") as log:
        for case, name in enumerate(CASES):
            if name not in args.cases:
                continue
            for double in ([False] if case == 0 else [False, True]):
                label = name if case == 0 else f"{name}_{'d' if double else 's'}"
                elf, binary = output / f"{label}.elf", output / f"{label}.bin"
                command = [f"{args.cross_compile}gcc", f"-march=rv{args.xlen}imafd_zicsr",
                           "-mabi=" + ("lp64d" if args.xlen == 64 else "ilp32d"),
                           "-nostdlib", "-nostartfiles", "-Wl,--no-relax", "-T",
                           str(ROOT / "verify/scripts/fuzz_link.ld"), f"-DBENCH_CASE={case}",
                           f"-DFP_DOUBLE={int(double)}", f"-DITERATIONS={args.iterations}",
                           f"-DPRELOAD_OUTPUT={int(args.preload_output)}",
                           str(SOURCE), "-o", str(elf)]
                subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True)
                subprocess.run([f"{args.cross_compile}objcopy", "-O", "binary", str(elf),
                                str(binary)], stdout=log, stderr=subprocess.STDOUT, check=True)
                images.append({"name": label, "case": case, "double": double,
                               "image": artifact(binary), "build_command": command})
    if args.coremark:
        images.append({"name": "coremark", "image": artifact(args.coremark)})
    return images


def run_one(args: argparse.Namespace, output: Path, profile: str,
            binary: Path, image: dict, delay: int) -> dict:
    name = image["name"]
    log = output / f"{profile}-{name}-delay-{delay}.log"
    command = [str(binary.resolve()), "-b", "-n", "--no-lightsss", "-t", str(args.timeout),
               f"--mem-random-delay={delay}", f"--mem-random-seed={args.seed}",
               "-d", str(args.reference.resolve()), "-r", str(args.mrom.resolve()),
               image["image"]["path"]]
    row = {"profile": profile, "workload": name, "delay": delay, "seed": args.seed,
           "image_sha256": image["image"]["sha256"], "command": command,
           "log": str(log), "passed": False}
    with log.open("w") as stream:
        try:
            status = subprocess.run(command, cwd=ROOT / "sim", stdout=stream,
                                    stderr=subprocess.STDOUT, timeout=args.timeout + 15).returncode
        except subprocess.TimeoutExpired:
            status = 124
    row["returncode"] = status
    text = ANSI.sub("", log.read_text())
    try:
        if status:
            raise ValueError(f"simulator exited {status}")
        row["validation"] = validate_output(text)
        row.update(parse_roi(text, name == "coremark"))
        row["passed"] = True
    except ValueError as error:
        row["error"] = str(error)
    print(f"{'PASS' if row['passed'] else 'FAIL'} RV{args.xlen} {profile}/{name} "
          f"delay={delay}: " + (f"{row['cycles']} cycles, {row['instructions']} instructions"
                               if row["passed"] else row["error"]), flush=True)
    return row


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--xlen", type=int, choices=(32, 64), required=True)
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("--mrom", type=Path, required=True)
    parser.add_argument("--coremark", type=Path)
    parser.add_argument("--preload-output", action="store_true",
                        help="read output words before warmup to make partial-store data resident")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--cross-compile", default="riscv64-unknown-elf-")
    parser.add_argument("--iterations", type=int, default=64)
    parser.add_argument("--cases", nargs="+", choices=CASES, default=list(CASES))
    parser.add_argument("--delays", nargs="+", type=int, default=[0, 63])
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--jobs", type=int, default=2)
    parser.add_argument("--timeout", type=int, default=600)
    args = parser.parse_args()
    if not 1 <= args.iterations <= 32768 or args.jobs <= 0 or args.timeout <= 0:
        parser.error("iterations must be in [1, 32768]; jobs and timeout must be positive")
    if not args.delays or len(set(args.delays)) != len(args.delays) or min(args.delays) < 0:
        parser.error("delays must be unique non-negative integers")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    profiles = {"baseline": args.baseline, "candidate": args.candidate}
    result = {
        "schema_version": 1, "complete": False, "xlen": args.xlen,
        "scope": "same-image architectural ROI cycle comparison under NEMU difftest",
        "caveat": "No clock frequency, PPA or official CoreMark score is established.",
        "iterations": args.iterations, "warmup_iterations": 4,
        "preload_output": args.preload_output,
        "source": artifact(SOURCE), "reference": artifact(args.reference),
        "mrom": artifact(args.mrom), "profiles": {k: artifact(v) for k, v in profiles.items()},
        "compiler": subprocess.check_output([f"{args.cross_compile}gcc", "--version"],
                                            text=True).splitlines()[0],
        "workloads": build_images(args, output), "runs": [], "comparisons": [],
    }
    summary = output / "results.json"
    summary.write_text(json.dumps(result, indent=2) + "\n")
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = [pool.submit(run_one, args, output, profile, binary, image, delay)
                   for image in result["workloads"] for delay in args.delays
                   for profile, binary in profiles.items()]
        for future in as_completed(futures):
            result["runs"].append(future.result())
            summary.write_text(json.dumps(result, indent=2) + "\n")
    indexed = {(row["profile"], row["workload"], row["delay"]): row for row in result["runs"]}
    failed = any(not row["passed"] for row in result["runs"])
    for image in result["workloads"]:
        for delay in args.delays:
            old, new = (indexed[(profile, image["name"], delay)] for profile in profiles)
            if not old["passed"] or not new["passed"]:
                continue
            if old["instructions"] != new["instructions"] or old["image_sha256"] != new["image_sha256"]:
                failed = True
                print(f"FAIL: instruction stream changed: {image['name']} delay={delay}", flush=True)
                continue
            row = {"workload": image["name"], "delay": delay, "instructions": old["instructions"],
                   "baseline_cycles": old["cycles"], "candidate_cycles": new["cycles"],
                   "speedup": old["cycles"] / new["cycles"],
                   "cycle_reduction_percent": 100 * (1 - new["cycles"] / old["cycles"])}
            result["comparisons"].append(row)
            print(f"COMPARE: RV{args.xlen} {image['name']} delay={delay}: "
                  f"{old['cycles']} -> {new['cycles']} cycles, {row['speedup']:.3f}x", flush=True)
    result["complete"] = not failed
    result["runs"].sort(key=lambda r: (r["workload"], r["delay"], r["profile"]))
    summary.write_text(json.dumps(result, indent=2) + "\n")
    return int(failed)


if __name__ == "__main__":
    raise SystemExit(main())
