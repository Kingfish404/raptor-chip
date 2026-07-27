#!/usr/bin/env python3
"""Generate an Embench-IoT Markdown report from per-benchmark NPC logs."""

import argparse
import json
import math
import re
from collections import Counter
from pathlib import Path


BENCHMARKS = [
    "aha-mont64",
    "crc32",
    "depthconv",
    "edn",
    "huffbench",
    "matmult-int",
    "md5sum",
    "nettle-aes",
    "nettle-sha256",
    "nsichneu",
    "picojpeg",
    "qrduino",
    "sglib-combined",
    "slre",
    "statemate",
    "tarfind",
    "ud",
    "wikisort",
    "xgboost",
]

ANSI_ESCAPE = re.compile(r"\x1b\[[0-9;]*m")
STALL_LABELS = ["IFU", "RS", "IoQ", "L1D", "SQ", "Bubble"]


def first_match(pattern, text, cast=str):
    match = re.search(pattern, text, re.MULTILINE)
    if not match:
        return None
    try:
        return cast(match.group(1))
    except ValueError:
        return None


def parse_top_stall(lines):
    for index, line in enumerate(lines[:-1]):
        if re.search(r"\|\s*IFU, %\|", line):
            cells = lines[index + 1].split("|")[1:-1]
            percentages = []
            for cell in cells[: len(STALL_LABELS)]:
                parts = cell.split(",")
                match = re.search(r"-?\d+", parts[1]) if len(parts) > 1 else None
                percentages.append(int(match.group()) if match else 0)
            if percentages:
                best = max(range(len(percentages)), key=percentages.__getitem__)
                return STALL_LABELS[best], percentages[best]
    return None, None


def parse_log(path, reference_ms, timing):
    if not path.is_file():
        return {"name": path.stem, "status": "FAIL", "log": path.name}

    text = ANSI_ESCAPE.sub("", path.read_text(encoding="utf-8", errors="replace"))
    lines = text.splitlines()
    ticks = first_match(r"^Ticks:\s*(\d+)", text, int)
    benchmark_cycles = first_match(r"^Cycles:\s*(\d+)", text, int)
    if timing == "ticks":
        benchmark_cycles = ticks * 1000 if ticks is not None else None
    pmu = re.search(r"#inst:\s*(\d+),\s*cycle:\s*(\d+),\s*IPC:\s*([0-9.]+)", text)
    bpu = first_match(r"BPU Success.*?Rate:\s*([0-9.]+)%", text, float)
    dual = first_match(r"Dual commit:[^\n]*?([0-9.]+)% of insts", text, float)
    stall_name, stall_percent = parse_top_stall(lines)
    passed = "HIT GOOD TRAP" in text and benchmark_cycles is not None
    if timing == "cycles":
        passed = passed and re.search(r"^\[PASS\]$", text, re.MULTILINE)

    speed = None
    if benchmark_cycles and reference_ms:
        speed = reference_ms * 1000.0 / benchmark_cycles

    return {
        "name": path.stem,
        "status": "PASS" if passed else "FAIL",
        "ticks": ticks,
        "benchmark_cycles": benchmark_cycles,
        "pmu_cycles": int(pmu.group(2)) if pmu else None,
        "instructions": int(pmu.group(1)) if pmu else None,
        "ipc": float(pmu.group(3)) if pmu else None,
        "bpu": bpu,
        "dual": dual,
        "stall_name": stall_name,
        "stall_percent": stall_percent,
        "speed": speed,
        "log": path.name,
    }


def geometric_mean(values):
    values = [value for value in values if value is not None and value > 0]
    return math.exp(sum(math.log(value) for value in values) / len(values)) if values else None


def arithmetic_mean(values):
    values = [value for value in values if value is not None]
    return sum(values) / len(values) if values else None


def format_float(value, digits=3):
    return f"{value:.{digits}f}" if value is not None else "N/A"


def format_int(value):
    return str(value) if value is not None else "N/A"


def render_markdown(rows, title, timing):
    passed = sum(row["status"] == "PASS" for row in rows)
    score = geometric_mean([row.get("speed") for row in rows])
    benchmark_geomean = geometric_mean([row.get("benchmark_cycles") for row in rows])
    pmu_geomean = geometric_mean([row.get("pmu_cycles") for row in rows])
    average_ipc = arithmetic_mean([row.get("ipc") for row in rows])
    average_dual = arithmetic_mean([row.get("dual") for row in rows])
    average_bpu = arithmetic_mean([row.get("bpu") for row in rows])
    total_cycles = sum(row.get("pmu_cycles") or 0 for row in rows)
    total_instructions = sum(row.get("instructions") or 0 for row in rows)
    aggregate_ipc = total_instructions / total_cycles if total_cycles else None
    stall_counts = Counter(row.get("stall_name") for row in rows if row.get("stall_name"))
    worst_stall = "N/A"
    if stall_counts:
        stall, count = stall_counts.most_common(1)[0]
        worst_stall = f"{stall} (x{count})"

    output = [
        f"# {title}",
        "",
        "## Overview",
        "",
        "| Test | Status | IPC | Details |",
        "| --- | --- | ---: | --- |",
        f"| Embench-IoT | {passed}/{len(rows)} pass | {format_float(aggregate_ipc)} | Score=**{format_float(score)}** (vs Cortex-M4@16MHz), dual={format_float(average_dual)}%, BPU={format_float(average_bpu)}% |",
        "",
        "## Per Benchmark",
        "",
        "Embench Score is the geometric mean of per-benchmark speed relative to",
        "Cortex-M4 @ 16 MHz (Embench v2.0 reference baseline, `gsf=1` here).",
        "Higher is better; **1.0 = parity with the M4 reference**.",
        (
            "Timed cycles are read directly from the benchmark `Cycles:` interval."
            if timing == "cycles"
            else "Timed cycles are `Ticks * 1000`; pk `clock()` ticks are microseconds derived from the 1 GHz `cycle` CSR. PMU cycles include pk startup and shutdown and are not used for scoring."
        ),
        "",
        "| Benchmark | Status | Speed (vs M4) | Benchmark cycles | IPC | PMU cycles | Instructions | Dual% | BPU% | Top stall |",
        "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |",
    ]

    for row in rows:
        top_stall = "N/A"
        if row.get("stall_name") is not None:
            top_stall = f"{row['stall_name']}({row['stall_percent']}%)"
        output.append(
            f"| {row['name']} | {row['status']} | {format_float(row.get('speed'))} | "
            f"{format_int(row.get('benchmark_cycles'))} | {format_float(row.get('ipc'))} | "
            f"{format_int(row.get('pmu_cycles'))} | {format_int(row.get('instructions'))} | "
            f"{format_float(row.get('dual'))}% | {format_float(row.get('bpu'))}% | {top_stall} |"
        )

    output.extend(
        [
            "",
            f"## Aggregates ({passed}/{len(rows)} pass)",
            "",
            "| Metric | Value |",
            "| --- | ---: |",
            f"| **Embench Score (geomean speed vs M4@16MHz)** | **{format_float(score)}** |",
            f"| Geomean benchmark cycles | {format_float(benchmark_geomean)} |",
            f"| Geomean PMU cycles | {format_float(pmu_geomean)} |",
            f"| Aggregate IPC (total inst / total cycles) | {format_float(aggregate_ipc)} |",
            f"| Avg per-bench IPC | {format_float(average_ipc)} |",
            f"| Avg Dual-issue commit % | {format_float(average_dual)}% |",
            f"| Avg BPU hit rate % | {format_float(average_bpu)}% |",
            f"| Most frequent top stall | {worst_stall} |",
            "",
        ]
    )
    return "\n".join(output), passed == len(rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log-dir", type=Path, required=True)
    parser.add_argument("--reference", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--timing", choices=("cycles", "ticks"), default="cycles")
    parser.add_argument("--title", default="Embench-IoT Report")
    parser.add_argument("--benchmarks", nargs="*", default=BENCHMARKS)
    args = parser.parse_args()

    reference = json.loads(args.reference.read_text(encoding="utf-8"))
    rows = [
        parse_log(args.log_dir / f"{name}.log", reference.get(name), args.timing)
        for name in args.benchmarks
    ]
    markdown, all_passed = render_markdown(rows, args.title, args.timing)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(markdown, encoding="utf-8")
    print(f"Embench Markdown report: {args.output}")
    return 0 if all_passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
