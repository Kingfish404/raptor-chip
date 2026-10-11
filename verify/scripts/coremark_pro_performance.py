#!/usr/bin/env python3
"""Measure matched instruction windows from unchanged upstream FP workloads.

Full NEMU runs supply reference validation and ROI lengths. NEMU architectural
checkpoints fast-forward to fixed fractions of each performance ROI. The RTL
then warms for 4096 instructions and measures approximately 16384 instructions.
Per-cycle progress counters select identical retired-instruction boundaries in
both RTL versions. A fixed cycle budget bounds each simulation; it need not
drain the pipeline or save another checkpoint at the end of the interval.
This is a sampling experiment, not a full-program or official benchmark score.
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
WORKLOADS = ("linear_alg-mid-100x100-sp", "loops-all-mid-10k-sp", "nnet_test", "radix2-big-64k")
ANSI = re.compile(r"\x1b\[[0-9;]*m")
PROGRESS = re.compile(r"progress: (\d+) cycles, (\d+) insts,")


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def build_capture(output: Path, xlen: int) -> Path:
    directory = output / "tools"
    directory.mkdir(parents=True, exist_ok=True)
    source = (ROOT / "nemu/src/cpu/difftest/ref.c").read_text()
    match = re.search(r"typedef struct\s*\{.*?\} NPCState;", source, re.S)
    if not match:
        raise ValueError("cannot locate the canonical NEMU NPCState ABI")
    (directory / "ref_state.h").write_text(
        f"#include <stdint.h>\ntypedef uint{xlen}_t word_t;\n" + match[0] + "\n")
    executable = directory / "capture"
    subprocess.run(["cc", "-O2", "-Wall", "-Wextra", "-Werror", f"-DXLEN={xlen}",
                    "-I", str(directory), str(ROOT / "verify/scripts/coremark_pro_sample.c"),
                    "-ldl", "-o", str(executable)], check=True)
    return executable


def prepare(args, capture: Path, workload: str, roi: dict) -> list[dict]:
    elf = args.image_dir / f"{workload}.elf"
    image = elf.with_suffix(".bin")
    directory = args.output / workload
    directory.mkdir(parents=True, exist_ok=True)
    offsets = [int(roi["instructions"] * fraction) for fraction in args.fractions]
    if any(offset + args.warmup + args.window + 128 >= roi["instructions"] for offset in offsets):
        raise ValueError(f"{workload}: sampling window exceeds the performance ROI")
    meta = {"image_sha256": digest(image), "reference_sha256": digest(args.reference),
            "helper_source_sha256": digest(ROOT / "verify/scripts/coremark_pro_sample.c"),
            "offsets": offsets, "warmup": args.warmup, "window": args.window}
    manifest = directory / "capture.json"
    if manifest.exists():
        if json.loads(manifest.read_text())["inputs"] != meta:
            raise ValueError(f"{directory}: existing checkpoints have different inputs; choose a new output directory")
    else:
        symbols = {}
        for line in subprocess.check_output([args.cross_compile + "nm", str(elf)], text=True).splitlines():
            parts = line.split()
            if len(parts) == 3:
                symbols[parts[2]] = int(parts[0], 16)
        command = [str(capture), str(args.reference), str(image), hex(symbols["al_signal_start"]),
                   str(directory), str(args.warmup), str(args.window), *map(str, offsets)]
        with (directory / "capture.log").open("w") as stream:
            subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT, check=True, timeout=1800)
        manifest.write_text(json.dumps({"inputs": meta, "command": command}, indent=2) + "\n")
    samples = []
    for index, fraction in enumerate(args.fractions):
        checkpoint = directory / f"sample-{index}"
        samples.append({"workload": workload, "sample": index, "fraction": fraction,
                        "checkpoint": str(checkpoint), "image_sha256": meta["image_sha256"],
                        "state_sha256": digest(checkpoint / "state.txt"),
                        "memory_sha256": digest(checkpoint / "mem_pmem.bin"),
                        "memory_metadata_sha256": digest(checkpoint / "mem_pmem.bin.meta"),
                        **json.loads((checkpoint / "sample.json").read_text())})
    print(f"Prepared RV{args.xlen} {workload}: {len(samples)} checkpoints", flush=True)
    return samples


def run_one(args, sample: dict, profile: str, simulator: Path) -> dict:
    directory = args.output / sample["workload"] / f"{profile}-{sample['sample']}"
    directory.mkdir(parents=True, exist_ok=True)
    log = directory / "run.log"
    command = [str(simulator), "-b", "-n", "--no-lightsss", "-t", str(args.timeout),
               "--mem-random-delay=0", "--mem-random-seed=1", "-d", str(args.reference),
               "--ckpt-load=" + sample["checkpoint"], "-m", str(args.cycle_limit)]
    # NPC's historical -m help says instructions, but cpu_exec(n) decrements n
    # once per simulated cycle. Progress counters below supply exact retirement
    # boundaries, independently of this run limit.
    environment = {**os.environ, "NSIM_PROGRESS_CYCLES": "1", "NSIM_HEARTBEAT_SECONDS": "0"}
    row = {"workload": sample["workload"], "sample": sample["sample"], "profile": profile,
           "command": command, "log": str(log), "simulator_sha256": digest(simulator),
           "passed": False}
    started = time.monotonic()
    try:
        with log.open("w") as stream:
            process = subprocess.run(command, cwd=ROOT / "sim", env=environment, stdout=stream,
                                     stderr=subprocess.STDOUT, timeout=args.timeout + 15)
        row["returncode"] = process.returncode
        text = ANSI.sub("", log.read_text(errors="replace"))
        if process.returncode:
            raise ValueError("simulator did not finish the bounded cycle run")
        if any(error in text for error in ("ABORT", "Difftest:", "SVA FAIL", "HIT BAD TRAP")) or \
                "resynchronized difftest REF" not in text:
            raise ValueError("missing reference synchronization or differential failure")
        trampoline = re.findall(r"trampoline built \((\d+) insns", text)
        if len(trampoline) != 1:
            raise ValueError("missing unique restore-trampoline length")
        base = int(trampoline[0])
        row["trampoline_instructions"] = base
        boundaries = {}
        progress = PROGRESS.findall(text)
        if not progress or int(progress[-1][0]) != args.cycle_limit:
            raise ValueError("simulation did not reach the configured cycle budget")
        # Progress precedes this cycle's difftest step. Require later progress
        # beyond all eligible end boundaries, so the measured commits have
        # completed differential checking even at the final cycle.
        if int(progress[-1][1]) - base <= args.warmup + args.window + 64:
            raise ValueError("cycle budget too short for a checked measurement window")
        for cycle, instructions in progress:
            retired = int(instructions) - base
            # Preserve first cycle at which each exact retirement boundary is reached.
            if (args.warmup <= retired <= args.warmup + 64 or
                    args.warmup + args.window <= retired <= args.warmup + args.window + 64):
                boundaries.setdefault(retired, int(cycle))
        if not boundaries:
            raise ValueError("no per-cycle retirement boundaries found")
        row["boundaries"] = boundaries
        row["passed"] = True
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        row["error"] = str(error)
    row["wall_seconds"] = round(time.monotonic() - started, 3)
    print(f"{'PASS' if row['passed'] else 'FAIL'} RV{args.xlen} "
          f"{sample['workload']} sample={sample['sample']} {profile}" +
          ("" if row["passed"] else ": " + row["error"]), flush=True)
    return row


def summarize(args, result: dict) -> None:
    indexed = {(row["workload"], row["sample"], row["profile"]): row for row in result["runs"]}
    result["comparisons"] = []
    result["errors"] = []
    result["complete"] = len(result["runs"]) == len(result["samples"]) * 2 and all(r["passed"] for r in result["runs"])
    for sample in result["samples"]:
        before = indexed.get((sample["workload"], sample["sample"], "baseline"))
        after = indexed.get((sample["workload"], sample["sample"], "candidate"))
        if not before or not after or not before["passed"] or not after["passed"]:
            continue
        old = {int(n): cycle for n, cycle in before["boundaries"].items()}
        new = {int(n): cycle for n, cycle in after["boundaries"].items()}
        shared = sorted(old.keys() & new.keys())
        starts = [n for n in shared if args.warmup <= n <= args.warmup + 64]
        ends = [n for n in shared if args.warmup + args.window <= n <= args.warmup + args.window + 64]
        if not starts or not ends:
            result["complete"] = False
            result["errors"].append(f"no matched boundaries: {sample['workload']}/{sample['sample']}")
            continue
        start, end = starts[0], ends[0]
        old_cycles, new_cycles = old[end] - old[start], new[end] - new[start]
        count = end - start
        if min(old_cycles, new_cycles, count) <= 0:
            result["complete"] = False
            result["errors"].append(f"nonpositive interval: {sample['workload']}/{sample['sample']}")
            continue
        result["comparisons"].append({"workload": sample["workload"], "sample": sample["sample"],
                                      "fraction": sample["fraction"], "start_instruction": start,
                                      "end_instruction": end, "instructions": count,
                                      "baseline_cycles": old_cycles, "candidate_cycles": new_cycles,
                                      "baseline_cpi": old_cycles / count, "candidate_cpi": new_cycles / count,
                                      "speedup": old_cycles / new_cycles,
                                      "cycle_reduction_percent": 100 * (1 - new_cycles / old_cycles)})
    temporary = args.output / "results.tmp"
    temporary.write_text(json.dumps(result, indent=2) + "\n")
    temporary.replace(args.output / "results.json")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--xlen", type=int, choices=(32, 64), required=True)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("--image-dir", type=Path, required=True)
    parser.add_argument("--nemu-results", type=Path, required=True)
    parser.add_argument("--validation-results", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--workloads", nargs="+", choices=WORKLOADS, default=list(WORKLOADS))
    parser.add_argument("--fractions", nargs="+", type=float, default=[0.1, 0.5, 0.9])
    parser.add_argument("--warmup", type=int, default=4096)
    parser.add_argument("--window", type=int, default=16384)
    parser.add_argument("--cycle-limit", type=int, default=250000)
    parser.add_argument("--jobs", type=int, default=4)
    parser.add_argument("--timeout", type=int, default=900)
    parser.add_argument("--cross-compile", default="riscv64-unknown-elf-")
    parser.add_argument("--prepare-only", action="store_true")
    args = parser.parse_args()
    if sorted(set(args.fractions)) != args.fractions or any(not 0 < f < 1 for f in args.fractions):
        parser.error("fractions must be distinct, ascending and between 0 and 1")
    if min(args.warmup, args.window, args.cycle_limit, args.jobs, args.timeout) < 1:
        parser.error("warmup, window, cycle-limit, jobs and timeout must be positive")
    for name in ("baseline", "candidate", "reference", "image_dir", "output", "nemu_results", "validation_results"):
        setattr(args, name, getattr(args, name).resolve())
    args.output.mkdir(parents=True, exist_ok=True)
    rois = {row["workload"]: row for row in json.loads(args.nemu_results.read_text())["runs"]}
    validations = {row["workload"]: row for row in json.loads(args.validation_results.read_text())["runs"]}
    for name in args.workloads:
        if not validations.get(name, {}).get("passed") or not validations[name]["verify"]:
            raise ValueError(f"{name}: full upstream reference validation required")
        if not rois.get(name, {}).get("passed") or rois[name]["verify"]:
            raise ValueError(f"{name}: full NEMU performance run required")
        if digest(args.image_dir / f"{name}.bin") != rois[name]["image_sha256"]:
            raise ValueError(f"{name}: performance image differs from the NEMU run")
    capture = build_capture(args.output, args.xlen)
    result = {"xlen": args.xlen, "method": "matched instruction windows, not full workload timing",
              "fractions": args.fractions, "warmup": args.warmup, "window": args.window,
              "cycle_limit": args.cycle_limit,
              "memory_delay": 0, "memory_seed": 1, "progress_interval_cycles": 1,
              "simulators": {name: {"path": str(path), "sha256": digest(path)}
                             for name, path in (("baseline", args.baseline), ("candidate", args.candidate))},
              "reference": {"path": str(args.reference), "sha256": digest(args.reference)},
              "validation_results": str(args.validation_results), "nemu_results": str(args.nemu_results),
              "samples": [], "runs": [], "complete": False}
    for workload in args.workloads:
        result["samples"].extend(prepare(args, capture, workload, rois[workload]))
    summarize(args, result)
    if args.prepare_only:
        return 0
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = [pool.submit(run_one, args, sample, profile, simulator)
                   for sample in result["samples"]
                   for profile, simulator in (("baseline", args.baseline), ("candidate", args.candidate))]
        for future in as_completed(futures):
            result["runs"].append(future.result())
            summarize(args, result)
    for row in result["comparisons"]:
        print(f"COMPARE RV{args.xlen} {row['workload']} {row['fraction']:.0%}: "
              f"{row['baseline_cycles']} -> {row['candidate_cycles']}, {row['speedup']:.3f}x", flush=True)
    return int(not result["complete"])


if __name__ == "__main__":
    raise SystemExit(main())
