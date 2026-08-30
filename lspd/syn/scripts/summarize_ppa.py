#!/usr/bin/env python3

import argparse
import math
import re
from datetime import datetime, timezone
from pathlib import Path


AREA_RE = re.compile(r"Chip area for module '\\\S+':\s+(\S+)")
CELLS_RE = re.compile(r"^\s*(\d+)\s+\S+\s+cells\s*$")
POWER_RE = re.compile(
    r"^Total\s+(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s+\S+%\s*$"
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate a per-PDK PPA summary")
    parser.add_argument("--build-root", type=Path, required=True)
    parser.add_argument("--config", required=True)
    parser.add_argument("--pdk", required=True)
    parser.add_argument("--frequency-mhz", type=int, required=True)
    parser.add_argument("--modules", nargs="+", required=True)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def parse_stat(path: Path) -> tuple[int | None, float | None]:
    cells = None
    area = None
    for line in read_text(path).splitlines():
        cells_match = CELLS_RE.match(line)
        if cells_match:
            cells = int(cells_match.group(1))
        area_match = AREA_RE.search(line)
        if area_match:
            area = float(area_match.group(1))
    return cells, area


def parse_sta_summary(path: Path) -> dict[str, str]:
    values = {}
    for line in read_text(path).splitlines():
        key, separator, value = line.partition(" ")
        if separator:
            values[key] = value.strip()
    return values


def parse_total_power(path: Path) -> float | None:
    total_power = None
    for line in read_text(path).splitlines():
        match = POWER_RE.match(line)
        if match:
            total_power = float(match.group(4))
    return total_power


def number(value: str | float | int | None, digits: int = 4) -> str:
    if value is None:
        return "N/A"
    numeric = float(value)
    if not math.isfinite(numeric):
        return str(value)
    return f"{numeric:.{digits}f}"


def power(value: float | None) -> str:
    return "N/A" if value is None else f"{value:.4e}"


def collect_module(module_dir: Path) -> dict[str, object]:
    stat_reports = sorted(module_dir.glob("*.stat.rpt"))
    sta_reports = sorted(module_dir.glob("*.sta_summary.rpt"))
    sta_log = module_dir / "sta.log"
    if not stat_reports or not sta_reports or not sta_log.is_file():
        return {"status": "missing"}

    cells, area = parse_stat(stat_reports[0])
    timing = parse_sta_summary(sta_reports[0])
    period_min = timing.get("period_min_ns")
    fmax = timing.get("fmax_mhz")
    if period_min is None and "period_ns" in timing and "wns_ns" in timing:
        period_min_value = float(timing["period_ns"]) - float(timing["wns_ns"])
        period_min = str(period_min_value)
        if period_min_value > 0.0:
            fmax = str(1000.0 / period_min_value)
    return {
        "status": "ok",
        "cells": cells,
        "area": area,
        "wns": timing.get("wns_ns"),
        "tns": timing.get("tns_ns"),
        "period_min": period_min,
        "fmax": fmax,
        "power": parse_total_power(sta_log),
    }


def main() -> None:
    args = parse_args()
    pdk_dir = args.build_root / args.config / args.pdk
    frequency_dir = f"{args.frequency_mhz}MHz"
    rows = []
    complete = 0

    for module in args.modules:
        result = collect_module(pdk_dir / module / frequency_dir)
        if result["status"] == "ok":
            complete += 1
        rows.append(
            "| {module} | {status} | {cells} | {area} | {wns} | {tns} | "
            "{period_min} | {fmax} | {power} |".format(
                module=module,
                status=result["status"],
                cells=result.get("cells", "N/A"),
                area=number(result.get("area")),
                wns=number(result.get("wns")),
                tns=number(result.get("tns")),
                period_min=number(result.get("period_min")),
                fmax=number(result.get("fmax"), 2),
                power=power(result.get("power")),
            )
        )

    generated = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    content = "\n".join(
        [
            f"# PPA Summary: {args.pdk}",
            "",
            f"- Configuration: `{args.config}`",
            f"- Target frequency: `{args.frequency_mhz} MHz`",
            f"- Complete reports: `{complete}/{len(args.modules)}`",
            f"- Generated: `{generated}`",
            "",
            "| Module | Status | Cells | Area (PDK units) | WNS (ns) | TNS (ns) | Min period (ns) | Fmax (MHz) | Total power (W) |",
            "|---|---:|---:|---:|---:|---:|---:|---:|---:|",
            *rows,
            "",
            "Power is an OpenSTA vectorless estimate. Area units follow the selected Liberty library.",
            "",
        ]
    )

    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.output.with_suffix(args.output.suffix + ".tmp")
    temporary.write_text(content, encoding="utf-8")
    temporary.replace(args.output)
    print(f"PPA summary: {args.output}")


if __name__ == "__main__":
    main()