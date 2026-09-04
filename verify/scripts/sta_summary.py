#!/usr/bin/env python3
"""Display existing STA results without running synthesis or STA."""

from __future__ import annotations

import argparse
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


NUMBER = r"[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?"


def read_text(path: Path) -> str:
    try:
        return path.read_text(errors="replace")
    except OSError:
        return ""


def match_float(pattern: str, text: str, flags: int = 0) -> float | None:
    match = re.search(pattern, text, flags)
    return float(match.group(1)) if match else None


def fmt_number(value: float | None, digits: int = 2) -> str:
    if value is None:
        return "-"
    return f"{value:.{digits}f}"


def fmt_area(value: float | None) -> str:
    if value is None:
        return "-"
    return f"{value:,.0f}"


def fmt_power(value: float | None) -> str:
    if value is None:
        return "-"
    return f"{value:.3e}"


def table(headers: list[str], rows: Iterable[list[str]]) -> None:
    rows = list(rows)
    widths = [len(header) for header in headers]
    for row in rows:
        for index, value in enumerate(row):
            widths[index] = max(widths[index], len(value))

    def line(values: list[str]) -> str:
        return "  ".join(value.ljust(widths[index]) for index, value in enumerate(values))

    print(line(headers))
    print(line(["-" * width for width in widths]))
    for row in rows:
        print(line(row))


def parse_area(path: Path) -> tuple[int | None, float | None]:
    text = read_text(path)
    cells_match = re.search(r"^\s*(\d+)\s+(?:\S+)\s+cells\s*$", text, re.MULTILINE)
    area = match_float(r"Chip area for module .*?:\s*(" + NUMBER + r")", text)
    return (int(cells_match.group(1)) if cells_match else None, area)


def parse_power(path: Path) -> float | None:
    text = read_text(path)
    matches = re.findall(
        r"^Total\s+" + NUMBER + r"\s+" + NUMBER + r"\s+" + NUMBER + r"\s+(" + NUMBER + r")\s+100\.0%",
        text,
        re.MULTILINE,
    )
    return float(matches[-1]) if matches else None


@dataclass
class WholeResult:
    pdk: str
    design: str
    target_mhz: float
    wns_ns: float | None
    fmax_mhz: float | None
    area: float | None
    power_w: float | None
    directory: Path


def parse_whole_result(directory: Path) -> WholeResult | None:
    match = re.match(r"^(asap7|nangate45|sky130hd)-(.+)-(\d+(?:\.\d+)?)MHz$", directory.name)
    if not match or not match.group(2).startswith("rapt"):
        return None

    pdk, design, target_text = match.groups()
    sta_text = read_text(directory / "sta.log")
    if not sta_text:
        return None

    target_mhz = float(target_text)
    fmax_matches = re.findall(r"period_min\s*=\s*" + NUMBER + r"\s+fmax\s*=\s*(" + NUMBER + r")", sta_text)
    fmax_mhz = float(fmax_matches[0]) if fmax_matches else None

    slack_matches = re.findall(r"^\s*(" + NUMBER + r")\s+slack\s+\((?:MET|VIOLATED)\)", sta_text, re.MULTILINE)
    wns_ns = min(map(float, slack_matches)) if slack_matches else None
    if "fmax Summary (period: ps" in sta_text and wns_ns is not None:
        wns_ns /= 1000.0

    _, area = parse_area(directory / "synth_stat.txt")
    return WholeResult(
        pdk=pdk,
        design=design,
        target_mhz=target_mhz,
        wns_ns=wns_ns,
        fmax_mhz=fmax_mhz,
        area=area,
        power_w=parse_power(directory / "sta.log"),
        directory=directory,
    )


def whole_results(root: Path) -> list[WholeResult]:
    if not root.is_dir():
        return []
    results = [result for directory in root.iterdir() if directory.is_dir() if (result := parse_whole_result(directory))]
    return sorted(results, key=lambda item: (item.pdk, item.design, item.target_mhz))


@dataclass
class ModuleResult:
    config: str
    pdk: str
    module: str
    target_mhz: float
    wns_ns: float
    tns_ns: float
    fmax_mhz: float
    cells: int | None
    area: float | None
    power_w: float | None
    report: Path


def parse_key_values(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in read_text(path).splitlines():
        key, separator, value = line.partition(" ")
        if separator:
            values[key] = value.strip()
    return values


def parse_module_result(build_root: Path, report: Path) -> ModuleResult | None:
    try:
        config, pdk, module, frequency = report.relative_to(build_root).parts[:4]
    except (ValueError, IndexError):
        return None
    frequency_match = re.fullmatch(r"(\d+(?:\.\d+)?)MHz", frequency)
    values = parse_key_values(report)
    required = ("wns_ns", "tns_ns", "fmax_mhz")
    if not frequency_match or not all(key in values for key in required):
        return None

    stat_report = report.with_name(report.name.replace(".sta_summary.rpt", ".stat.rpt"))
    cells, area = parse_area(stat_report)
    return ModuleResult(
        config=config,
        pdk=pdk,
        module=module,
        target_mhz=float(frequency_match.group(1)),
        wns_ns=float(values["wns_ns"]),
        tns_ns=float(values["tns_ns"]),
        fmax_mhz=float(values["fmax_mhz"]),
        cells=cells,
        area=area,
        power_w=parse_power(report.parent / "sta.log"),
        report=report,
    )


def module_results(build_root: Path) -> list[ModuleResult]:
    if not build_root.is_dir():
        return []
    newest_reports: dict[Path, Path] = {}
    for report in build_root.glob("*/*/*/*MHz/*.sta_summary.rpt"):
        previous = newest_reports.get(report.parent)
        if previous is None or report.stat().st_mtime > previous.stat().st_mtime:
            newest_reports[report.parent] = report
    results = [result for report in newest_reports.values() if (result := parse_module_result(build_root, report))]
    return sorted(results, key=lambda item: (item.config, item.pdk, item.target_mhz, item.module))


def status(wns_ns: float | None) -> str:
    if wns_ns is None:
        return "unknown"
    return "MET" if wns_ns >= -1e-9 else "VIOLATED"


def print_whole(results: list[WholeResult]) -> None:
    print("Whole-design STA (make sta)")
    if not results:
        print("  No existing whole-design STA reports found.\n")
        return
    table(
        ["PDK", "Design", "Target", "Status", "WNS(ns)", "Fmax(MHz)", "Area(µm²)", "Power(W)"],
        [
            [
                result.pdk,
                result.design,
                f"{result.target_mhz:g}MHz",
                status(result.wns_ns),
                fmt_number(result.wns_ns),
                fmt_number(result.fmax_mhz),
                fmt_area(result.area),
                fmt_power(result.power_w),
            ]
            for result in results
        ],
    )
    print()


def grouped_modules(results: list[ModuleResult]) -> dict[tuple[str, str, float], list[ModuleResult]]:
    groups: dict[tuple[str, str, float], list[ModuleResult]] = {}
    for result in results:
        groups.setdefault((result.config, result.pdk, result.target_mhz), []).append(result)
    return groups


def print_modules(results: list[ModuleResult], detail: bool) -> None:
    print("Module STA (lspd/syn)")
    if not results:
        print("  No existing module STA reports found.")
        return

    groups = grouped_modules(results)
    summary_rows: list[list[str]] = []
    for (config, pdk, target_mhz), members in groups.items():
        worst = min(members, key=lambda item: item.wns_ns)
        core = next((item for item in members if item.module == "core"), None)
        met = sum(item.wns_ns >= -1e-9 for item in members)
        summary_rows.append(
            [
                config,
                pdk,
                f"{target_mhz:g}MHz",
                f"{met}/{len(members)}",
                worst.module,
                fmt_number(worst.wns_ns),
                fmt_number(worst.fmax_mhz),
                fmt_number(core.fmax_mhz if core else None),
                fmt_area(core.area if core else None),
                fmt_power(core.power_w if core else None),
            ]
        )
    table(
        [
            "Config",
            "PDK",
            "Target",
            "MET",
            "Worst module",
            "WNS(ns)",
            "Fmax(MHz)",
            "Core Fmax(MHz)",
            "Core area(µm²)",
            "Core power(W)",
        ],
        summary_rows,
    )

    if not detail:
        return
    for (config, pdk, target_mhz), members in groups.items():
        print(f"\n[{config} / {pdk} / {target_mhz:g}MHz]")
        table(
            ["Module", "Status", "WNS(ns)", "TNS(ns)", "Fmax(MHz)", "Cells", "Area(µm²)", "Power(W)"],
            [
                [
                    item.module,
                    status(item.wns_ns),
                    fmt_number(item.wns_ns),
                    fmt_number(item.tns_ns),
                    fmt_number(item.fmax_mhz),
                    f"{item.cells:,}" if item.cells is not None else "-",
                    fmt_area(item.area),
                    fmt_power(item.power_w),
                ]
                for item in members
            ],
        )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--whole-root", type=Path, required=True)
    parser.add_argument("--module-root", type=Path, required=True)
    parser.add_argument("--detail", action="store_true", help="show every LSPD module result")
    args = parser.parse_args()

    print_whole(whole_results(args.whole_root))
    print_modules(module_results(args.module_root), args.detail)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
