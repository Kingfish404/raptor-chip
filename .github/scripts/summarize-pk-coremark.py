#!/usr/bin/env python3
"""Validate the CI 2K performance profile and report smoke/standard results."""
import argparse
from pathlib import Path
import re

ANSI = re.compile(r"\x1b\[[0-9;]*m")
SHORT_RUN = "ERROR! Must execute for at least 10 secs for a valid result!"
# known_id=3 in CoreMark core_main.c: 2K, seeds 0/0/0x66.
EXPECTED_CRC = {"seedcrc": 0xE9F5, "crclist": 0xE714,
                "crcmatrix": 0x1FD7, "crcstate": 0x8E3A}


def field(log, label, pattern=r"\d+", base=10, spaced=False):
    padding = r"\s+" if spaced else r"\s*"
    matches = re.findall(r"^" + re.escape(label) + padding + r":\s*(" + pattern + r")\s*$",
                         log, re.MULTILINE)
    return int(matches[0], base) if len(matches) == 1 else None


def good_trap(log):
    return re.findall(r"HIT (?:GOOD|BAD) TRAP", log) == ["HIT GOOD TRAP"]


def evaluate(log, expected_iterations, allow_short, timebase_hz=10_000_000):
    errors = []
    # The outer Makefile prints another Iterations/score table after the run.
    measurement = log.partition("CoreMark: done.")[0]
    if not good_trap(log):
        errors.append("missing, duplicate, or bad final trap")
    for name, expected in EXPECTED_CRC.items():
        label = name if name == "seedcrc" else "[0]" + name
        if field(measurement, label, r"0x[0-9a-fA-F]+", 16) != expected:
            errors.append(f"{name} missing or mismatched")
    final_crc = field(measurement, "[0]crcfinal", r"0x[0-9a-fA-F]+", 16)
    if final_crc is None:
        errors.append("missing final CRC")
    if field(measurement, "CoreMark Size") != 666:
        errors.append("unexpected CoreMark size")
    iterations = field(measurement, "Iterations", spaced=True)
    if iterations != expected_iterations:
        errors.append("unexpected iteration count (possibly stale binary)")
    if iterations == 1 and final_crc != EXPECTED_CRC["crclist"]:
        errors.append("one-iteration final CRC mismatched")
    cycles = field(measurement, "CoreMark ROI cycles")
    instructions = field(measurement, "CoreMark ROI instructions")
    if not cycles or not instructions:
        errors.append("missing or zero ROI counters")
    ticks = field(measurement, "Total ticks")
    seconds = field(measurement, "Total time (secs)")
    timer_hz = field(measurement, "CoreMark timer Hz")
    if (timer_hz != timebase_hz or ticks is None or ticks <= 0
            or seconds is None or seconds != ticks // timebase_hz):
        errors.append("missing or inconsistent timer frequency/timing")
    lines = log.splitlines()
    short = lines.count(SHORT_RUN) == 1 and seconds is not None and 0 <= seconds < 10
    diagnostics = [line for line in lines if re.search(r"ERROR|Errors detected|Cannot validate", line)]
    if short:
        if not allow_short:
            errors.append("run shorter than the standard 10-second requirement")
        if diagnostics != [SHORT_RUN, "Errors detected"]:
            errors.append("additional or incomplete CoreMark error diagnostics")
        if "Correct operation validated" in log:
            errors.append("conflicting validation results")
    elif (diagnostics or "Correct operation validated" not in log
          or seconds is None or seconds < 10):
        errors.append("standard validation missing or failed")
    if lines.count("CoreMark: done.") != 1:
        errors.append("missing or duplicate completion marker")
    return {"errors": errors, "short": short, "iterations": iterations,
            "ticks": ticks, "timer_hz": timer_hz, "seconds": seconds, "cycles": cycles,
            "instructions": instructions}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("hello", type=Path)
    parser.add_argument("coremark", type=Path)
    parser.add_argument("summary", type=Path)
    parser.add_argument("--expected-iterations", type=int, required=True)
    parser.add_argument("--timebase-hz", type=int, default=10_000_000,
                        help="expected CLINT/DTS timebase (default sim: 10 MHz)")
    parser.add_argument("--allow-short", action="store_true",
                        help="accept CRC-checked smoke runs; never certify a standard score")
    args = parser.parse_args()
    if args.timebase_hz <= 0:
        parser.error("--timebase-hz must be positive")
    if args.expected_iterations <= 0:
        parser.error("--expected-iterations must be positive")
    def read(path):
        return ANSI.sub("", path.read_text(errors="replace")) if path.is_file() else ""
    hello_ok = good_trap(read(args.hello))
    result = evaluate(read(args.coremark), args.expected_iterations, args.allow_short, args.timebase_hz)
    ok = not result["errors"]
    status = ("SMOKE PASS" if result["short"] else "PASS") if ok else "FAIL"
    standard = "NOT VALID (less than 10 seconds)" if result["short"] else ("VALID" if ok else "NOT VALID")
    # Use the measured loop interval, excluding pk startup and reporting.
    estimate = (f'{result["iterations"] * 1e6 / result["cycles"]:.4f}'
                if ok else "N/A")
    rows = ["## App Tests — CoreMark (pk on sim)", "",
            "| Test | Status |", "|---|---|",
            f'| Hello | {"PASS" if hello_ok else "FAIL"} |',
            f"| CoreMark functional check | {status} |", "",
            "| Metric | Value |", "|---|---|",
            f"| Standard CoreMark validation | {standard} |",
            f"| {'Smoke estimate (iterations × 1e6 / ROI cycles)' if result['short'] else 'CoreMark/MHz'} | {estimate} |"]
    for key in ("iterations", "timer_hz", "ticks", "seconds", "cycles", "instructions"):
        rows.append(f"| {key} | {result[key] if result[key] is not None else 'N/A'} |")
    rows += ["", *[f"- {error}" for error in result["errors"]], ""]
    with args.summary.open("a") as output:
        output.write("\n".join(rows))
    return 0 if hello_ok and ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
