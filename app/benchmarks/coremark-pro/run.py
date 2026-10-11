#!/usr/bin/env python3
"""Run unchanged upstream workloads and report local cycle measurements."""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import time

WORKLOADS = (
    "cjpeg-rose7-preset", "core", "linear_alg-mid-100x100-sp", "loops-all-mid-10k-sp",
    "nnet_test", "parser-125k", "radix2-big-64k", "sha-test", "zip-test",
)
ANSI = re.compile(r"\x1b\[[0-9;]*m")
ROI = re.compile(r"RAPTOR ROI cycles=(\d+) instructions=(\d+) ticks=(\d+)")
CONFIG = re.compile(r"Raptor benchmark run: iterations=(\d+) verify=([01]) timebase=(\d+) Hz")


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save_json(destination: Path, value: dict) -> None:
    temporary = destination.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    temporary.replace(destination)


def parse_output(output: str, workload: str) -> dict:
    text = ANSI.sub("", output)
    if "HIT GOOD TRAP" not in text:
        raise ValueError("missing simulator good trap")
    if re.search(r":(?:ERRORS|fails)=[1-9]\d*|RAPTOR ERROR|HIT BAD TRAP|ABORT", text):
        raise ValueError("workload or simulator reported a failure")
    config = CONFIG.findall(text)
    roi = ROI.findall(text)
    if len(config) != 1 or len(roi) != 1:
        raise ValueError("expected exactly one configuration and one ROI record")
    iterations, verify, timebase = map(int, config[0])
    cycles, instructions, ticks = map(int, roi[0])
    if min(iterations, cycles, instructions, ticks, timebase) <= 0:
        raise ValueError("nonpositive timing or configuration value")
    if not re.search(rf"Workload:{re.escape(workload)}=\d+", text):
        raise ValueError("missing or mismatched upstream workload result")
    if verify and not re.search(r":fails=0\b", text):
        raise ValueError("missing upstream reference validation")
    return {"iterations": 1 if verify else iterations, "verify": bool(verify),
            "timebase_hz": timebase, "cycles": cycles, "instructions": instructions,
            "ticks": ticks, "timer_resolution_pass": ticks >= 1000}


def compare(runs: list[dict]) -> list[dict]:
    indexed = {(r["workload"], r["profile"]): r for r in runs}
    comparisons = []
    for workload in WORKLOADS:
        before = indexed.get((workload, "baseline"))
        after = indexed.get((workload, "candidate"))
        if not before or not after or not before["passed"] or not after["passed"]:
            continue
        for key in ("image_sha256", "instructions", "iterations", "verify", "timebase_hz"):
            if before[key] != after[key]:
                raise ValueError(f"{workload}: mismatched {key}")
        comparisons.append({"workload": workload, "baseline_cycles": before["cycles"],
                            "candidate_cycles": after["cycles"],
                            "speedup": before["cycles"] / after["cycles"],
                            "cycle_reduction_percent": 100 * (1 - after["cycles"] / before["cycles"])})
    return comparisons


def report(result: dict, destination: Path) -> None:
    lines = ["# Raptor workload cycle measurements", "",
             "Internal engineering measurements using upstream CoreMark®-PRO workloads. "
             "These results are not a certified or aggregate CoreMark-PRO score. "
             "CoreMark is a registered trademark of EEMBC.", "",
             "Validation runs include reference checking in their timed region; use separate "
             "`CMP_VERIFY=0` runs for performance after checking the same build with `CMP_VERIFY=1`. "
             "Simulator cycles do not establish hardware clock frequency.", "",
             "| Workload | Profile | Run | Cycles | Instructions | Reference check |",
             "|---|---|---|---:|---:|---|"]
    for row in sorted(result["runs"], key=lambda r: (r["workload"], r["profile"])):
        check = "passed" if row.get("verify") and row["passed"] else "disabled"
        if not row["passed"]:
            check = row.get("error", "failed")
        lines.append(f"| {row['workload']} | {row['profile']} | "
                     f"{'PASS' if row['passed'] else 'FAIL'} | {row.get('cycles', '—')} | "
                     f"{row.get('instructions', '—')} | {check} |")
    if result.get("comparisons"):
        lines += ["", "| Workload | Before cycles | After cycles | Speedup |",
                  "|---|---:|---:|---:|"]
        for row in result["comparisons"]:
            lines.append(f"| {row['workload']} | {row['baseline_cycles']} | "
                         f"{row['candidate_cycles']} | {row['speedup']:.3f}× |")
    if result.get("comparison_error"):
        lines += ["", "Comparison rejected: " + result["comparison_error"]]
    lines += ["", "The companion JSON records commands, image hashes, configuration, logs, "
              "and the 1000-timer-tick duration check. No suite score is calculated. "
              "Commercial product marketing using these results is subject to the upstream "
              "Commercial COREMARK-PRO License requirement; see `LICENSE.upstream.md`.", ""]
    destination.write_text("\n".join(lines))


def progress(log: Path, status_dir: Path | None) -> dict:
    text = log.read_text(errors="replace") if log.exists() else ""
    phase = "completed" if "RAPTOR ROI" in text else (
        "timed workload" if "Starting Run..." in text else "initialization")
    result = {"phase": phase}
    if status_dir:
        try:
            state = json.loads((status_dir / "nemu-uarch_state.json").read_text())
            result.update(guest_instructions=int(state["inst_cnt"]), pc=state["pc"])
        except (OSError, ValueError, KeyError):
            # NEMU may be between truncating and rewriting its periodic snapshot.
            pass
    return result


def progress_text(snapshot: dict) -> str:
    text = snapshot["phase"]
    if "guest_instructions" in snapshot:
        text += f", {snapshot['guest_instructions']:,} guest instructions, pc={snapshot['pc']}"
    return text


def run_one(args, profile: str, command: list[str], workload: str) -> dict:
    image = (args.image_dir / f"{workload}.bin").resolve()
    log = args.log_dir / f"{profile}-{workload}.log"
    row = {"profile": profile, "workload": workload, "passed": False,
           "image": str(image), "log": str(log), "command": command + [str(image)]}
    started = time.monotonic()
    status_dir = None
    try:
        row["image_sha256"] = sha256(image)
        environment = os.environ.copy()
        if args.nemu_status:
            status_dir = args.log_dir / f"{profile}-{workload}-status"
            status_dir.mkdir(parents=True, exist_ok=True)
            for name in ("nemu-status.log", "nemu-uarch_state.json"):
                (status_dir / name).unlink(missing_ok=True)
            environment["NEMU_STATUS_DIR"] = str(status_dir.resolve())
            row["status_directory"] = str(status_dir.resolve())
        print(f"RUN {profile}/{workload}: timeout={args.timeout}s", flush=True)
        with log.open("w") as stream:
            process = subprocess.Popen(row["command"], cwd=args.cwd, stdout=stream,
                                       stderr=subprocess.STDOUT, env=environment)
            try:
                while True:
                    remaining = args.timeout - (time.monotonic() - started)
                    if remaining <= 0:
                        raise subprocess.TimeoutExpired(row["command"], args.timeout)
                    try:
                        process.wait(timeout=min(args.progress_interval, remaining))
                        break
                    except subprocess.TimeoutExpired:
                        row["last_progress"] = progress(log, status_dir)
                        elapsed = time.monotonic() - started
                        print(f"WAIT {profile}/{workload}: {elapsed:.0f}s, "
                              + progress_text(row["last_progress"]), flush=True)
            finally:
                if process.poll() is None:
                    process.kill()
                process.wait()
        row["returncode"] = process.returncode
        if process.returncode:
            raise ValueError(f"simulator exited {process.returncode}")
        row.update(parse_output(log.read_text(errors="replace"), workload))
        row["passed"] = True
    except subprocess.TimeoutExpired:
        row["last_progress"] = progress(log, status_dir)
        row["error"] = (f"timed out after {args.timeout}s during "
                        + progress_text(row["last_progress"]))
    except (OSError, ValueError) as error:
        row["error"] = str(error)
    row["wall_seconds"] = round(time.monotonic() - started, 3)
    print(f"{'PASS' if row['passed'] else 'FAIL'} {profile}/{workload}: "
          + (f"{row['cycles']} cycles" if row["passed"] else row["error"]), flush=True)
    return row


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--command", help="simulator command, excluding the final image argument")
    parser.add_argument("--baseline-command", help="optional simulator for a matched before/after run")
    parser.add_argument("--image-dir", type=Path)
    parser.add_argument("--log-dir", type=Path, required=True)
    parser.add_argument("--cwd", type=Path, default=Path.cwd())
    parser.add_argument("--workloads", nargs="+", choices=WORKLOADS, default=list(WORKLOADS))
    parser.add_argument("--jobs", type=int, default=1)
    parser.add_argument("--timeout", type=int, default=7200)
    parser.add_argument("--progress-interval", type=int, default=60)
    parser.add_argument("--nemu-status", action="store_true",
                        help="isolate and report NEMU's periodic instruction/PC snapshots")
    parser.add_argument("--report-only", action="store_true")
    args = parser.parse_args()
    args.log_dir = args.log_dir.resolve()
    summary = args.log_dir / "results.json"
    if args.report_only:
        result = json.loads(summary.read_text())
        report(result, args.log_dir / "report.md")
        return int(not result["complete"])
    if (not args.command or not args.image_dir or args.jobs < 1 or args.timeout < 1
            or args.progress_interval < 1):
        parser.error("provide --command, --image-dir, and positive jobs/time intervals")
    args.log_dir.mkdir(parents=True, exist_ok=True)
    profiles = {"candidate": shlex.split(args.command)}
    if args.baseline_command:
        profiles["baseline"] = shlex.split(args.baseline_command)
    for command in profiles.values():
        if not command or not shutil.which(command[0]):
            parser.error("simulator executable not found")
        command[0] = str(Path(shutil.which(command[0])).resolve())
    result = {"workloads": args.workloads, "runs": [], "complete": False,
              "timeout_seconds": args.timeout, "cwd": str(args.cwd.resolve()),
              "simulators": {name: {"command": cmd, "sha256": sha256(Path(cmd[0]))}
                             for name, cmd in profiles.items()}}
    config = args.image_dir.parent / ".build-config"
    if config.exists():
        result["build_configuration"] = config.read_text()
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = [pool.submit(run_one, args, name, cmd, workload)
                   for workload in args.workloads for name, cmd in profiles.items()]
        for future in as_completed(futures):
            result["runs"].append(future.result())
            save_json(summary, result)
    result["complete"] = all(row["passed"] for row in result["runs"])
    try:
        result["comparisons"] = compare(result["runs"])
    except ValueError as error:
        result["complete"] = False
        result["comparison_error"] = str(error)
    save_json(summary, result)
    report(result, args.log_dir / "report.md")
    print(f"Report: {args.log_dir / 'report.md'}")
    return int(not result["complete"])


if __name__ == "__main__":
    raise SystemExit(main())
