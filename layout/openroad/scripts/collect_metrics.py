#!/usr/bin/env python3

import argparse
import re
from pathlib import Path


FLOAT = r"[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace") if path.is_file() else ""


def match_last(pattern: str, text: str) -> str | None:
    matches = re.findall(pattern, text, re.MULTILINE | re.IGNORECASE)
    return matches[-1] if matches else None


def main() -> None:
    parser = argparse.ArgumentParser(description="Collect normalized OpenROAD metrics")
    parser.add_argument("--result-dir", type=Path, required=True)
    parser.add_argument("--top", required=True)
    parser.add_argument("--period-ns", type=float, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    log = read(args.result_dir / "pnr.log")
    power = read(args.result_dir / "power_final.rpt")
    drc = read(args.result_dir / f"{args.top}_route_drc.rpt")
    final_def = read(args.result_dir / f"{args.top}_final.def")
    profile = read(args.result_dir / "pnr.profile")

    die = re.search(r"DIEAREA\s*\(\s*(\d+)\s+(\d+)\s*\)\s*\(\s*(\d+)\s+(\d+)\s*\)", final_def)
    units_match = re.search(r"UNITS DISTANCE MICRONS\s+(\d+)", final_def)
    units = float(units_match.group(1)) if units_match else 1000.0
    die_area = None
    if die:
        width = (int(die.group(3)) - int(die.group(1))) / units
        height = (int(die.group(4)) - int(die.group(2))) / units
        die_area = width * height

    components = match_last(r"^COMPONENTS\s+(\d+)\s*;", final_def)
    design_area = match_last(r"Design area\s+({0})\s+um\^2".format(FLOAT), log)
    utilization = match_last(r"({0})% utilization".format(FLOAT), log)
    wns = match_last(r"wns\s+max\s+({0})".format(FLOAT), log)
    if wns is None:
        wns = match_last(r"^\s*({0})\s+slack\s+\((?:MET|VIOLATED)\)".format(FLOAT), read(args.result_dir / "timing_max_final.rpt"))
    tns = match_last(r"tns\s+max\s+({0})".format(FLOAT), log)
    if tns is None and wns is not None and float(wns) >= 0:
        tns = "0"
    total_power = match_last(r"^Total\s+{0}\s+{0}\s+{0}\s+({0})".format(FLOAT), power)
    drc_count = match_last(r"(?:total violations|number of violations)\s*[:=]?\s*(\d+)", drc)
    if drc_count is None:
        drc_count = str(len(re.findall(r"^\s*violation", drc, re.MULTILINE | re.IGNORECASE)))

    period_min = None
    fmax = None
    if wns is not None:
        period_min = args.period_ns - float(wns)
        if period_min > 0:
            fmax = 1000.0 / period_min

    elapsed_sec = match_last(r"^elapsed_sec=({0})$".format(FLOAT), profile)
    max_rss_kb = match_last(r"^max_rss_kb=({0})$".format(FLOAT), profile)
    max_rss_mb = float(max_rss_kb) / 1024.0 if max_rss_kb is not None else None

    values = {
        "status": "ok" if (args.result_dir / f"{args.top}_final.odb").is_file() else "missing",
        "instances": components,
        "design_area_um2": design_area,
        "die_area_um2": die_area,
        "utilization_pct": utilization,
        "wns_ns": wns,
        "tns_ns": tns,
        "period_min_ns": period_min,
        "fmax_mhz": fmax,
        "total_power_w": total_power,
        "drc_violations": drc_count,
        "elapsed_sec": elapsed_sec,
        "max_rss_mb": max_rss_mb,
    }
    args.output.write_text("".join(f"{key} {value if value is not None else 'N/A'}\n" for key, value in values.items()), encoding="ascii")


if __name__ == "__main__":
    main()