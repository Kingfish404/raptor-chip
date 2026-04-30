#!/usr/bin/env python3
"""Compare Raptor config presets under configs/*/rapt_config.svh.

Usage:
  python3 configs/compare_configs.py
  python3 configs/compare_configs.py --format markdown
  python3 configs/compare_configs.py --format plain
"""

from __future__ import annotations

import argparse
import re
from pathlib import Path
from typing import Dict, List

DEFINE_RE = re.compile(r"^\s*`define\s+([A-Za-z0-9_]+)(?:\s+(.+?))?\s*(?://.*)?$")


def parse_defines(cfg_path: Path) -> Dict[str, str]:
    macros: Dict[str, str] = {}
    for line in cfg_path.read_text(encoding="utf-8").splitlines():
        match = DEFINE_RE.match(line)
        if not match:
            continue
        name, value = match.group(1), match.group(2)
        macros[name] = (value or "1").strip()
    return macros


def is_enabled(macros: Dict[str, str], name: str) -> bool:
    return name in macros


def as_int(macros: Dict[str, str], name: str, default: int = 0) -> int:
    value = macros.get(name)
    if value is None:
        return default
    value = value.strip()
    if value.startswith("'h"):
        return int(value[2:], 16)
    if value.startswith("0x"):
        return int(value, 16)
    return int(value)


def l1_size_kib(macros: Dict[str, str], prefix: str, line_bytes: int) -> str:
    sets = 1 << as_int(macros, f"{prefix}_LEN")
    ways = as_int(macros, f"{prefix}_N_WAYS", 1)
    total = sets * ways * line_bytes
    if total % 1024 == 0:
        return f"{total // 1024} KiB"
    return f"{total} B"


def format_bool(enabled: bool) -> str:
    return "on" if enabled else "off"


def build_rows(macros: Dict[str, Dict[str, str]], names: List[str]) -> List[List[str]]:
    rows: List[List[str]] = []

    def col(name: str) -> Dict[str, str]:
        return macros[name]

    rows.append([
        "L1I (S x W x CL)",
        *[
            (
                f"{1 << as_int(col(n), 'RAPT_L1I_LEN')} x "
                f"{as_int(col(n), 'RAPT_L1I_N_WAYS', 1)} x 16B "
                f"({l1_size_kib(col(n), 'RAPT_L1I', 16)})"
            )
            for n in names
        ],
    ])

    rows.append([
        "L1D (S x W x CL)",
        *[
            (
                f"{1 << as_int(col(n), 'RAPT_L1D_LEN')} x "
                f"{as_int(col(n), 'RAPT_L1D_N_WAYS', 1)} x 8B "
                f"({l1_size_kib(col(n), 'RAPT_L1D', 8)})"
            )
            for n in names
        ],
    ])

    rows.append([
        "PHT / BTB / RSB",
        *[
            f"{as_int(col(n), 'RAPT_PHT_SIZE')} / {as_int(col(n), 'RAPT_BTB_SIZE')} / {as_int(col(n), 'RAPT_RSB_SIZE')}"
            for n in names
        ],
    ])

    rows.append([
        "RIQ / IIQ",
        *[
            f"{as_int(col(n), 'RAPT_RIQ_SIZE')} / {as_int(col(n), 'RAPT_IIQ_SIZE')}"
            for n in names
        ],
    ])

    rows.append([
        "ROB",
        *[str(as_int(col(n), "RAPT_ROB_SIZE")) for n in names],
    ])

    rows.append([
        "RS / IOQ",
        *[
            f"{as_int(col(n), 'RAPT_RS_SIZE')} / {as_int(col(n), 'RAPT_IOQ_SIZE')}"
            for n in names
        ],
    ])

    rows.append([
        "SQ",
        *[str(as_int(col(n), "RAPT_SQ_SIZE")) for n in names],
    ])

    rows.append([
        "PHY regs",
        *[str(as_int(col(n), "RAPT_PHY_SIZE")) for n in names],
    ])

    rows.append([
        "Dual issue/commit",
        *[
            f"{format_bool(is_enabled(col(n), 'RAPT_DUAL_ISSUE'))}/{format_bool(is_enabled(col(n), 'RAPT_DUAL_COMMIT'))}"
            for n in names
        ],
    ])

    return rows


def render_markdown(headers: List[str], rows: List[List[str]]) -> str:
    widths = [len(h) for h in headers]
    for row in rows:
        for i, cell in enumerate(row):
            widths[i] = max(widths[i], len(cell))

    def fmt_row(cells: List[str]) -> str:
        return "| " + " | ".join(cells[i].ljust(widths[i]) for i in range(len(cells))) + " |"

    out = []
    out.append(fmt_row(headers))
    out.append("| " + " | ".join("-" * widths[i] for i in range(len(widths))) + " |")
    for row in rows:
        out.append(fmt_row(row))
    return "\n".join(out)


def render_plain(headers: List[str], rows: List[List[str]]) -> str:
    widths = [len(h) for h in headers]
    for row in rows:
        for i, cell in enumerate(row):
            widths[i] = max(widths[i], len(cell))

    def fmt_line(cells: List[str]) -> str:
        return " | ".join(cell.ljust(widths[i]) for i, cell in enumerate(cells))

    sep = "-+-".join("-" * w for w in widths)
    out = [fmt_line(headers), sep]
    out.extend(fmt_line(row) for row in rows)
    return "\n".join(out)


def main() -> int:
    parser = argparse.ArgumentParser(description="Compare configs/*/rapt_config.svh")
    parser.add_argument(
        "--format",
        choices=["markdown", "plain"],
        default="plain",
        help="output format",
    )
    args = parser.parse_args()

    configs_dir = Path(__file__).resolve().parent
    cfg_files = sorted(configs_dir.glob("*/rapt_config.svh"))
    if not cfg_files:
        raise SystemExit("No configs found under configs/*/rapt_config.svh")

    macros_by_name: Dict[str, Dict[str, str]] = {}
    names: List[str] = []
    for cfg_file in cfg_files:
        name = cfg_file.parent.name
        names.append(name)
        macros_by_name[name] = parse_defines(cfg_file)

    # Keep classic order first if present, then append others.
    preferred = ["default", "small", "large"]
    ordered = [n for n in preferred if n in names] + [n for n in names if n not in preferred]

    headers = ["Knob", *ordered]
    rows = build_rows(macros_by_name, ordered)

    if args.format == "markdown":
        print(render_markdown(headers, rows))
    else:
        print(render_plain(headers, rows))

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
