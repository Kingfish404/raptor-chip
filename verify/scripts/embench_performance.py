#!/usr/bin/env python3
"""Compare Embench instruction windows with the CoreMark-PRO sampling method.

Profiles every instruction between start_trigger and stop_trigger in NEMU to
establish ROI length and dynamic FP use. Runs full reference validation, then
compares identical checkpoints in two archived RTL models. Results are sampled
phase speedups, not full benchmark timings or an official Embench score.
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import json
import os
from pathlib import Path
import subprocess

from coremark_pro_performance import ANSI, ROOT, build_capture, digest, run_one, summarize

WORKLOADS = ("aha-mont64", "crc32", "depthconv", "edn", "huffbench", "matmult-int",
             "md5sum", "nettle-aes", "nettle-sha256", "nsichneu", "picojpeg",
             "qrduino", "sglib-combined", "slre", "statemate", "tarfind", "ud",
             "wikisort", "xgboost")


def prepare(args, capture: Path, workload: str) -> dict:
    elf = args.image_dir / workload / f"{workload}.elf"
    image = elf.with_suffix(".bin")
    directory = args.output / workload
    directory.mkdir(parents=True, exist_ok=True)
    inputs = {"image_sha256": digest(image), "elf_sha256": digest(elf),
              "reference_sha256": digest(args.reference), "nemu_sha256": digest(args.nemu),
              "helper_source_sha256": digest(ROOT / "verify/scripts/coremark_pro_sample.c"),
              "fractions": args.fractions, "warmup": args.warmup, "window": args.window}
    manifest = directory / "capture.json"
    if manifest.exists():
        saved = json.loads(manifest.read_text())
        if saved["inputs"] != inputs:
            raise ValueError(f"{directory}: checkpoint inputs changed; use a new output directory")
        for sample in saved["samples"]:
            checkpoint = Path(sample["checkpoint"])
            for filename, key in (("state.txt", "state_sha256"),
                                  ("mem_pmem.bin", "memory_sha256"),
                                  ("mem_pmem.bin.meta", "memory_metadata_sha256")):
                if digest(checkpoint / filename) != sample[key]:
                    raise ValueError(f"{checkpoint / filename}: checkpoint hash mismatch")
        return saved

    symbols = {}
    for line in subprocess.check_output([args.cross_compile + "nm", str(elf)], text=True).splitlines():
        parts = line.split()
        if len(parts) == 3:
            symbols[parts[2]] = int(parts[0], 16)
    commands = []

    def execute(command, filename, cwd=ROOT):
        commands.append(command)
        with (directory / filename).open("w") as stream:
            subprocess.run(command, cwd=cwd, stdout=stream, stderr=subprocess.STDOUT,
                           env={**os.environ, "NEMU_PC_DEBUG": "0", "NEMU_ITRACE_ALL": "0"},
                           timeout=args.timeout, check=True)

    execute([str(args.nemu), "-b", str(image)], "validation.log", ROOT / "nemu")
    validation = ANSI.sub("", (directory / "validation.log").read_text())
    if "HIT GOOD TRAP" not in validation or any(t in validation for t in ("HIT BAD TRAP", "ABORT")):
        raise ValueError(f"{workload}: full benchmark validation failed")
    execute([str(capture), "--profile-roi", str(args.reference), str(image),
             hex(symbols["start_trigger"]), str(directory), hex(symbols["stop_trigger"])],
            "profile.log")
    roi = json.loads((directory / "roi.json").read_text())
    offsets = [int(roi["instructions"] * f) for f in args.fractions]
    if any(n + args.warmup + args.window + 128 >= roi["instructions"] for n in offsets):
        raise ValueError(f"{workload}: sampling window exceeds ROI")
    execute([str(capture), str(args.reference), str(image), hex(symbols["start_trigger"]),
             str(directory), str(args.warmup), str(args.window), *map(str, offsets)], "capture.log")
    samples = []
    for index, fraction in enumerate(args.fractions):
        checkpoint = directory / f"sample-{index}"
        samples.append({"workload": workload, "sample": index, "fraction": fraction,
                        "checkpoint": str(checkpoint), "image_sha256": inputs["image_sha256"],
                        "state_sha256": digest(checkpoint / "state.txt"),
                        "memory_sha256": digest(checkpoint / "mem_pmem.bin"),
                        "memory_metadata_sha256": digest(checkpoint / "mem_pmem.bin.meta"),
                        **json.loads((checkpoint / "sample.json").read_text())})
    result = {"workload": workload, "inputs": inputs, "commands": commands, "roi": roi,
              "full_reference_passed": True, "samples": samples}
    manifest.write_text(json.dumps(result, indent=2) + "\n")
    print(f"Prepared RV{args.xlen} {workload}: ROI {roi['instructions']} instructions; "
          f"FP ALU/load/store={roi['fp_alu']}/{roi['fp_load']}/{roi['fp_store']}", flush=True)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--models", type=Path, required=True,
                        help="prior CoreMark-PRO results JSON identifying archived models and reference")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--workloads", nargs="+", choices=WORKLOADS, default=list(WORKLOADS))
    parser.add_argument("--fractions", nargs="+", type=float, default=[0.1, 0.5, 0.9])
    parser.add_argument("--warmup", type=int, default=4096)
    parser.add_argument("--window", type=int, default=16384)
    parser.add_argument("--cycle-limit", type=int, default=60000)
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--timeout", type=int, default=600)
    parser.add_argument("--cross-compile", default="riscv64-unknown-elf-")
    parser.add_argument("--prepare-only", action="store_true")
    args = parser.parse_args()
    if sorted(set(args.fractions)) != args.fractions or any(not 0 < f < 1 for f in args.fractions):
        parser.error("fractions must be distinct, ascending and between 0 and 1")
    if min(args.warmup, args.window, args.cycle_limit, args.jobs, args.timeout) < 1:
        parser.error("warmup, window, cycle-limit, jobs and timeout must be positive")
    args.output = args.output.resolve()
    args.models = args.models.resolve()
    models = json.loads(args.models.read_text())
    args.xlen = models["xlen"]
    for key, item in {**models["simulators"], "reference": models["reference"]}.items():
        path = Path(item["path"])
        if digest(path) != item["sha256"]:
            raise ValueError(f"{key}: archived executable hash mismatch")
        setattr(args, key, path)
    args.image_dir = ROOT / f"app/build/rv{args.xlen}/embench-baremetal"
    args.nemu = ROOT / f"nemu/build/riscv{args.xlen}-nemu-interpreter"
    args.output.mkdir(parents=True, exist_ok=True)
    capture = build_capture(args.output, args.xlen)
    configuration = {"xlen": args.xlen, "models_results": str(args.models),
                     "models_results_sha256": digest(args.models), "simulators": models["simulators"],
                     "reference": models["reference"], "warmup": args.warmup, "window": args.window,
                     "cycle_limit": args.cycle_limit, "memory_delay": 0, "memory_seed": 1,
                     "fractions": args.fractions, "workloads": args.workloads}
    previous = args.output / "results.json"
    result = {**configuration, "method": "matched instruction windows, not full workload timing",
              "profiles": [], "samples": [], "runs": [], "complete": False}
    if previous.exists():
        old = json.loads(previous.read_text())
        if any(old.get(key) != value for key, value in configuration.items()):
            raise ValueError("existing measurement configuration differs; use a new output directory")
        result["runs"] = [r for r in old["runs"] if r["passed"]]
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        for profile in pool.map(lambda w: prepare(args, capture, w), args.workloads):
            result["profiles"].append(profile)
            result["samples"].extend(profile["samples"])
    summarize(args, result)
    if args.prepare_only:
        return 0
    completed = {(r["workload"], r["sample"], r["profile"]) for r in result["runs"]}
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = [pool.submit(run_one, args, sample, profile, simulator)
                   for sample in result["samples"]
                   for profile, simulator in (("baseline", args.baseline), ("candidate", args.candidate))
                   if (sample["workload"], sample["sample"], profile) not in completed]
        for future in as_completed(futures):
            result["runs"].append(future.result())
            summarize(args, result)
    return 0 if result["complete"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
