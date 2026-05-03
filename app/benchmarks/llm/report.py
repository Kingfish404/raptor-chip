#!/usr/bin/env python3
"""Generate RLLMBench summary reports from benchmark log files."""

import argparse
import csv
import json
import math
from datetime import datetime, timezone
from pathlib import Path


MODE_ORDER = {"ops": 0, "infer": 1, "train": 2}


def parse_fields(line):
    fields = {}
    for token in line.strip().split()[1:]:
        if "=" not in token:
            continue
        key, value = token.split("=", 1)
        fields[key] = value.rstrip(",")
    return fields


def parse_log(path):
    parsed = {
        "path": str(path),
        "info": {},
        "config": {},
        "results": [],
        "scores": [],
        "status": "UNKNOWN",
    }
    with path.open("r", encoding="utf-8", errors="replace") as log_file:
        for raw_line in log_file:
            line = raw_line.strip()
            if line.startswith("RLLMBENCH_INFO"):
                parsed["info"].update(parse_fields(line))
            elif line.startswith("RLLMBENCH_CONFIG"):
                parsed["config"].update(parse_fields(line))
            elif line.startswith("RLLMBENCH_RESULT"):
                parsed["results"].append(parse_fields(line))
            elif line.startswith("RLLMBENCH_SCORE"):
                parsed["scores"].append(parse_fields(line))
            elif line.startswith("RLLMBENCH_END"):
                end_fields = parse_fields(line)
                parsed["status"] = end_fields.get("status", parsed["status"])
                parsed["end"] = end_fields
    return parsed


def as_int(value, default=0):
    try:
        return int(str(value), 0)
    except (TypeError, ValueError):
        return default


def as_float(value, default=0.0):
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def format_sci(value):
    if value == 0:
        return "0.000e+00"
    return f"{value:.3e}"


def collect_time_fields(record, core_clock_mhz):
    seconds = as_float(record.get("seconds"))
    work = as_int(record.get("work"))
    score_per_sec = as_int(record.get("score_per_sec"))
    if score_per_sec == 0 and seconds > 0.0:
        score_per_sec = int(work / seconds)
    score_per_mhz = 0.0
    if core_clock_mhz > 0.0:
        score_per_mhz = score_per_sec / core_clock_mhz
    return {
        "seconds": seconds,
        "score_per_sec": score_per_sec,
        "score_per_sec_sci": format_sci(score_per_sec),
        "core_clock_mhz": core_clock_mhz,
        "score_per_mhz": score_per_mhz,
        "score_per_mhz_sci": format_sci(score_per_mhz),
    }


def collect_rows(parsed_logs, default_core_clock_mhz):
    mode_rows = []
    result_rows = []
    for parsed in parsed_logs:
        info = parsed.get("info", {})
        config = parsed.get("config", {})
        core_clock_mhz = as_float(info.get("core_clock_mhz"), default_core_clock_mhz)
        for score in parsed.get("scores", []):
            row = {
                "mode": score.get("mode", config.get("mode", "unknown")),
                "profile": info.get("profile", config.get("profile", "unknown")),
                "target": info.get("target", config.get("target", "unknown")),
                "arch": info.get("arch", config.get("arch", "unknown")),
                "xlen": info.get("xlen", config.get("xlen", "unknown")),
                "work": as_int(score.get("work")),
                **collect_time_fields(score, core_clock_mhz),
                "checksum": score.get("checksum", ""),
                "status": parsed.get("status", "UNKNOWN"),
                "log": Path(parsed.get("path", "")).name,
            }
            mode_rows.append(row)
        for result in parsed.get("results", []):
            row = {
                "name": result.get("name", "unknown"),
                "class": result.get("class", "unknown"),
                "unit": result.get("unit", "work"),
                "work": as_int(result.get("work")),
                **collect_time_fields(result, core_clock_mhz),
                "checksum": result.get("checksum", ""),
                "mode": config.get("mode", "unknown"),
                "log": Path(parsed.get("path", "")).name,
            }
            result_rows.append(row)
    mode_rows.sort(key=lambda row: (MODE_ORDER.get(row["mode"], 99), row["mode"]))
    result_rows.sort(key=lambda row: (MODE_ORDER.get(row["mode"], 99), row["mode"]))
    return mode_rows, result_rows


def geometric_mean(values):
    positive_values = [value for value in values if value > 0]
    if not positive_values:
        return 0.0
    return math.exp(sum(math.log(value) for value in positive_values) / len(positive_values))


def markdown_table(headers, rows):
    lines = ["| " + " | ".join(headers) + " |", "| " + " | ".join(["---"] * len(headers)) + " |"]
    for row in rows:
        lines.append("| " + " | ".join(str(row.get(header, "")) for header in headers) + " |")
    return "\n".join(lines)


def write_markdown(path, mode_rows, result_rows, suite_name):
    generated = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    geomean_score_per_sec = geometric_mean([row["score_per_sec"] for row in mode_rows])
    geomean_score_per_mhz = geometric_mean([row["score_per_mhz"] for row in mode_rows])
    total_seconds = sum(row["seconds"] for row in mode_rows)
    total_work = sum(row["work"] for row in mode_rows)
    profile = mode_rows[0]["profile"] if mode_rows else "unknown"
    arch = mode_rows[0]["arch"] if mode_rows else "unknown"
    xlen = mode_rows[0]["xlen"] if mode_rows else "unknown"
    target = mode_rows[0]["target"] if mode_rows else "unknown"
    core_clock_mhz = mode_rows[0]["core_clock_mhz"] if mode_rows else 0.0

    mode_headers = ["mode", "profile", "target", "arch", "xlen", "seconds", "work", "score_per_sec", "score_per_sec_sci", "core_clock_mhz", "score_per_mhz", "score_per_mhz_sci", "checksum", "status", "log"]
    result_headers = ["mode", "name", "class", "unit", "seconds", "work", "score_per_sec", "score_per_sec_sci", "core_clock_mhz", "score_per_mhz", "score_per_mhz_sci", "checksum"]

    content = []
    content.append(f"# {suite_name} Report")
    content.append("")
    content.append(f"Generated: {generated}")
    content.append(f"Profile: `{profile}`")
    content.append(f"Target: `{target}`, arch `{arch}`, XLEN `{xlen}`")
    content.append("Metric: `score_per_sec` is benchmark work items per physical second; higher is better.")
    if core_clock_mhz > 0.0:
        content.append("Frequency-normalized metric: `score_per_mhz` is `score_per_sec / core_clock_mhz`, equivalent to work items per million core cycles; higher is better.")
    content.append("")
    content.append(f"Suite geomean score/sec: `{geomean_score_per_sec:.2f}` (`{format_sci(geomean_score_per_sec)}`)")
    if core_clock_mhz > 0.0:
        content.append(f"Suite geomean score/MHz: `{geomean_score_per_mhz:.6f}` (`{format_sci(geomean_score_per_mhz)}`)")
    content.append(f"Total benchmark work: `{total_work}`")
    content.append(f"Total benchmark seconds: `{total_seconds:.6f}`")
    content.append("")
    content.append("## Mode Scores")
    content.append("")
    content.append(markdown_table(mode_headers, mode_rows))
    content.append("")
    content.append("## Workload Details")
    content.append("")
    content.append(markdown_table(result_headers, result_rows))
    content.append("")
    path.write_text("\n".join(content), encoding="utf-8")


def write_csv(path, mode_rows):
    headers = ["mode", "profile", "target", "arch", "xlen", "seconds", "work", "score_per_sec", "score_per_sec_sci", "core_clock_mhz", "score_per_mhz", "score_per_mhz_sci", "checksum", "status", "log"]
    with path.open("w", newline="", encoding="utf-8") as csv_file:
        writer = csv.DictWriter(csv_file, fieldnames=headers)
        writer.writeheader()
        for row in mode_rows:
            writer.writerow({header: row.get(header, "") for header in headers})


def write_json(path, mode_rows, result_rows, suite_name):
    geomean_score_per_sec = geometric_mean([row["score_per_sec"] for row in mode_rows])
    geomean_score_per_mhz = geometric_mean([row["score_per_mhz"] for row in mode_rows])
    payload = {
        "suite": suite_name,
        "generated_utc": datetime.now(timezone.utc).isoformat(),
        "geomean_score_per_sec": geomean_score_per_sec,
        "geomean_score_per_sec_sci": format_sci(geomean_score_per_sec),
        "geomean_score_per_mhz": geomean_score_per_mhz,
        "geomean_score_per_mhz_sci": format_sci(geomean_score_per_mhz),
        "mode_scores": mode_rows,
        "results": result_rows,
    }
    path.write_text(json.dumps(payload, indent=2), encoding="utf-8")


def print_console_summary(mode_rows, markdown_path, csv_path, json_path):
    geomean_score_per_sec = geometric_mean([row["score_per_sec"] for row in mode_rows])
    geomean_score_per_mhz = geometric_mean([row["score_per_mhz"] for row in mode_rows])
    has_score_per_mhz = any(row["core_clock_mhz"] > 0.0 for row in mode_rows)
    print("=== RLLMBench Summary ===")
    if has_score_per_mhz:
        print("mode,score/sec,score/sec_sci,score/MHz,score/MHz_sci,seconds,checksum,status")
        for row in mode_rows:
            print(f"{row['mode']},{row['score_per_sec']},{row['score_per_sec_sci']},{row['score_per_mhz']:.6f},{row['score_per_mhz_sci']},{row['seconds']:.6f},{row['checksum']},{row['status']}")
    else:
        print("mode,score/sec,score/sec_sci,seconds,checksum,status")
        for row in mode_rows:
            print(f"{row['mode']},{row['score_per_sec']},{row['score_per_sec_sci']},{row['seconds']:.6f},{row['checksum']},{row['status']}")
    print(f"geomean_score_per_sec={geomean_score_per_sec:.2f}")
    print(f"geomean_score_per_sec_sci={format_sci(geomean_score_per_sec)}")
    if has_score_per_mhz:
        print(f"geomean_score_per_mhz={geomean_score_per_mhz:.6f}")
        print(f"geomean_score_per_mhz_sci={format_sci(geomean_score_per_mhz)}")
    print(f"markdown= {markdown_path}")
    print(f"csv= {csv_path}")
    print(f"json= {json_path}")


def main():
    parser = argparse.ArgumentParser(description="Generate RLLMBench reports from benchmark logs")
    parser.add_argument("--log-dir", required=True, type=Path)
    parser.add_argument("--markdown", required=True, type=Path)
    parser.add_argument("--csv", required=True, type=Path)
    parser.add_argument("--json", required=True, type=Path)
    parser.add_argument("--suite", default="RLLMBench")
    parser.add_argument("--core-clock-mhz", default=0.0, type=float,
                        help="core clock in MHz for score_per_mhz; 0 disables frequency-normalized scores")
    args = parser.parse_args()

    log_paths = sorted(args.log_dir.glob("*.log"))
    parsed_logs = [parse_log(log_path) for log_path in log_paths]
    mode_rows, result_rows = collect_rows(parsed_logs, args.core_clock_mhz)
    if not mode_rows:
        raise SystemExit(f"no RLLMBENCH_SCORE lines found in {args.log_dir}")

    args.markdown.parent.mkdir(parents=True, exist_ok=True)
    args.csv.parent.mkdir(parents=True, exist_ok=True)
    args.json.parent.mkdir(parents=True, exist_ok=True)
    write_markdown(args.markdown, mode_rows, result_rows, args.suite)
    write_csv(args.csv, mode_rows)
    write_json(args.json, mode_rows, result_rows, args.suite)
    print_console_summary(mode_rows, args.markdown, args.csv, args.json)


if __name__ == "__main__":
    main()