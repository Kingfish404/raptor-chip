#!/usr/bin/env python3
"""Generate a self-contained HTML dashboard for Vivado text reports."""

from __future__ import annotations

import argparse
import datetime as datetime_module
import html
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import quote


@dataclass(frozen=True)
class ReportKind:
    title: str
    group: str
    description: str
    patterns: tuple[str, ...]


@dataclass(frozen=True)
class Report:
    title: str
    group: str
    description: str
    path: Path
    rel_path: str
    report_id: str
    text: str


REPORT_KINDS: tuple[ReportKind, ...] = (
    ReportKind("Timing Summary", "Timing", "Post-route setup, hold, and pulse-width summary", ("*_timing.rpt",)),
    ReportKind("Timing Summary (synth)", "Timing", "Post-synthesis timing summary", ("*_timing_synth.rpt",)),
    ReportKind("Utilization (place)", "Utilization", "Post-place resource utilization", ("*_utilization_place.rpt",)),
    ReportKind("Utilization Hierarchy (place)", "Utilization", "Post-place hierarchical utilization", ("*_utilization_hierarchical_place.rpt",)),
    ReportKind("Utilization (synth)", "Utilization", "Post-synthesis resource utilization", ("*_utilization_synth.rpt",)),
    ReportKind("Utilization Hierarchy (synth)", "Utilization", "Post-synthesis hierarchical utilization", ("*_utilization_hierarchical_synth.rpt",)),
    ReportKind("Route Status", "Implementation", "Routing completeness and route errors", ("*_route_status.rpt",)),
    ReportKind("DRC", "Implementation", "Design rule checks", ("*_drc.rpt",)),
    ReportKind("Power", "Implementation", "Vivado on-chip power estimate", ("*_power.rpt",)),
    ReportKind("Clock Utilization", "Clocks and IO", "Clock primitive and global clock usage", ("*_clock_utilization.rpt",)),
    ReportKind("Control Sets", "Clocks and IO", "Control set distribution", ("*_control_sets.rpt",)),
    ReportKind("IO", "Clocks and IO", "Package pin and IO assignments", ("*_io.rpt",)),
)


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace")


def make_report_id(name: str, used_ids: set[str]) -> str:
    report_id = re.sub(r"[^a-zA-Z0-9]+", "-", name.lower()).strip("-") or "report"
    original_id = report_id
    suffix = 2
    while report_id in used_ids:
        report_id = f"{original_id}-{suffix}"
        suffix += 1
    used_ids.add(report_id)
    return report_id


def collect_reports(gateware_dir: Path) -> list[Report]:
    reports: list[Report] = []
    seen_paths: set[Path] = set()
    used_ids: set[str] = set()

    for kind in REPORT_KINDS:
        matches = []
        for pattern in kind.patterns:
            matches.extend(sorted(gateware_dir.glob(pattern)))
        unique_matches = []
        for path in matches:
            resolved = path.resolve()
            if resolved not in seen_paths:
                seen_paths.add(resolved)
                unique_matches.append(path)
        for path in unique_matches:
            title = kind.title if len(unique_matches) == 1 else f"{kind.title} - {path.name}"
            reports.append(
                Report(
                    title=title,
                    group=kind.group,
                    description=kind.description,
                    path=path,
                    rel_path=path.relative_to(gateware_dir).as_posix(),
                    report_id=make_report_id(path.name, used_ids),
                    text=read_text(path),
                )
            )

    for path in sorted(gateware_dir.glob("*.rpt")):
        if path.resolve() in seen_paths:
            continue
        reports.append(
            Report(
                title=path.stem,
                group="Other Reports",
                description="Additional Vivado report",
                path=path,
                rel_path=path.relative_to(gateware_dir).as_posix(),
                report_id=make_report_id(path.name, used_ids),
                text=read_text(path),
            )
        )
    return reports


def parse_header(report_text: str) -> dict[str, str]:
    header: dict[str, str] = {}
    for line in report_text.splitlines()[:40]:
        stripped = line.strip()
        if stripped.startswith("|") and ":" in stripped:
            key, value = stripped.strip("|").split(":", 1)
            header[key.strip()] = value.strip()
    return header


def find_report(reports: list[Report], suffix: str) -> Report | None:
    for report in reports:
        if report.path.name.endswith(suffix):
            return report
    return None


def parse_timing(report_text: str) -> dict[str, str]:
    lines = report_text.splitlines()
    for index, line in enumerate(lines):
        if "WNS(ns)" not in line or "WHS(ns)" not in line or "WPWS(ns)" not in line:
            continue
        for data_line in lines[index + 1 : index + 8]:
            fields = re.findall(r"-?\d+(?:\.\d+)?", data_line)
            if len(fields) >= 12:
                return {
                    "wns": fields[0], "tns": fields[1], "setup_failing": fields[2], "setup_total": fields[3],
                    "whs": fields[4], "ths": fields[5], "hold_failing": fields[6], "hold_total": fields[7],
                    "wpws": fields[8], "tpws": fields[9], "pulse_failing": fields[10], "pulse_total": fields[11],
                }
    return {}


def parse_table_row(report_text: str, label: str) -> list[str] | None:
    for line in report_text.splitlines():
        if "|" not in line:
            continue
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if cells and cells[0] == label:
            return cells
    return None


def parse_utilization(report_text: str) -> dict[str, dict[str, str]]:
    utilization: dict[str, dict[str, str]] = {}
    for label in ("CLB", "CLB LUTs", "CLB Registers", "Block RAM Tile", "DSPs", "BUFGCE", "MMCM"):
        cells = parse_table_row(report_text, label)
        if cells and len(cells) >= 6:
            utilization[label] = {"used": cells[1], "available": cells[-2], "util": cells[-1]}
    return utilization


def parse_power(report_text: str) -> dict[str, str]:
    power: dict[str, str] = {}
    for label, key in (
        ("Total On-Chip Power (W)", "total"),
        ("Dynamic (W)", "dynamic"),
        ("Device Static (W)", "static"),
        ("Junction Temperature (C)", "junction"),
        ("Confidence Level", "confidence"),
    ):
        cells = parse_table_row(report_text, label)
        if cells and len(cells) >= 2:
            power[key] = cells[1]
    return power


def parse_drc(report_text: str) -> str | None:
    match = re.search(r"Checks found:\s*(\d+)", report_text)
    return match.group(1) if match else None


def parse_route_errors(report_text: str) -> str | None:
    match = re.search(r"# of nets with routing errors\.*\s*:\s*(\d+)\s*:", report_text)
    return match.group(1) if match else None


def parse_control_sets(report_text: str) -> str | None:
    cells = parse_table_row(report_text, "Total control sets")
    return cells[1] if cells and len(cells) >= 2 else None


def parse_clock_summary(report_text: str) -> list[dict[str, str]]:
    clocks: list[dict[str, str]] = []
    pattern = re.compile(r"^\s*(\S+)\s+\{[^}]+\}\s+([0-9.]+)\s+([0-9.]+)\s*$")
    for line in report_text.splitlines():
        match = pattern.match(line)
        if match:
            clocks.append({"name": match.group(1), "period": match.group(2), "frequency": match.group(3)})
    return clocks


def as_float(value: str | None) -> float | None:
    try:
        return float(value) if value is not None else None
    except ValueError:
        return None


def as_int(value: str | None) -> int | None:
    try:
        return int(value.replace(",", "")) if value is not None else None
    except ValueError:
        return None


def status_class(is_bad: bool) -> str:
    return "bad" if is_bad else "good"


def make_card(label: str, value: str, detail: str, level: str = "good") -> str:
    return f"""
        <div class=\"card {level}\">
          <span class=\"card-label\">{html.escape(label)}</span>
          <strong>{html.escape(value)}</strong>
          <span class=\"card-detail\">{html.escape(detail)}</span>
        </div>"""


def render_overview(reports: list[Report], gateware_dir: Path) -> str:
    timing_report = find_report(reports, "_timing.rpt")
    utilization_report = find_report(reports, "_utilization_place.rpt")
    power_report = find_report(reports, "_power.rpt")
    drc_report = find_report(reports, "_drc.rpt")
    route_report = find_report(reports, "_route_status.rpt")
    control_report = find_report(reports, "_control_sets.rpt")

    header = parse_header(timing_report.text if timing_report else reports[0].text if reports else "")
    timing = parse_timing(timing_report.text) if timing_report else {}
    utilization = parse_utilization(utilization_report.text) if utilization_report else {}
    power = parse_power(power_report.text) if power_report else {}
    drc_checks = parse_drc(drc_report.text) if drc_report else None
    route_errors = parse_route_errors(route_report.text) if route_report else None
    control_sets = parse_control_sets(control_report.text) if control_report else None
    clocks = parse_clock_summary(timing_report.text) if timing_report else []

    cards = []
    if timing:
        setup_bad = (as_int(timing.get("setup_failing")) or 0) > 0 or (as_float(timing.get("wns")) or 0.0) < 0.0
        hold_bad = (as_int(timing.get("hold_failing")) or 0) > 0 or (as_float(timing.get("whs")) or 0.0) < 0.0
        pulse_bad = (as_int(timing.get("pulse_failing")) or 0) > 0 or (as_float(timing.get("wpws")) or 0.0) < 0.0
        cards.append(make_card("Setup WNS", f"{timing['wns']} ns", f"{timing['setup_failing']} failing endpoints", status_class(setup_bad)))
        cards.append(make_card("Hold WHS", f"{timing['whs']} ns", f"{timing['hold_failing']} failing endpoints", status_class(hold_bad)))
        cards.append(make_card("Pulse WPWS", f"{timing['wpws']} ns", f"{timing['pulse_failing']} failing endpoints", status_class(pulse_bad)))
    if route_errors is not None:
        cards.append(make_card("Route Errors", route_errors, "nets with routing errors", status_class((as_int(route_errors) or 0) > 0)))
    if drc_checks is not None:
        cards.append(make_card("DRC Checks", drc_checks, "checks found", status_class((as_int(drc_checks) or 0) > 0)))
    if power:
        cards.append(make_card("Power", f"{power.get('total', '?')} W", f"confidence {power.get('confidence', '?')}", "neutral"))
    if control_sets is not None:
        cards.append(make_card("Control Sets", control_sets, "total control sets", "neutral"))

    resource_rows = []
    for label in ("CLB", "CLB LUTs", "CLB Registers", "Block RAM Tile", "DSPs", "BUFGCE", "MMCM"):
        item = utilization.get(label)
        if item:
            resource_rows.append(
                "<tr>"
                f"<td>{html.escape(label)}</td><td>{html.escape(item['used'])}</td>"
                f"<td>{html.escape(item['available'])}</td><td>{html.escape(item['util'])}%</td>"
                "</tr>"
            )

    clock_rows = []
    for clock in clocks:
        clock_rows.append(
            "<tr>"
            f"<td>{html.escape(clock['name'])}</td><td>{html.escape(clock['period'])} ns</td>"
            f"<td>{html.escape(clock['frequency'])} MHz</td>"
            "</tr>"
        )

    bitstreams = sorted(path.name for path in gateware_dir.glob("*.bit"))
    bitstream_items = "".join(f"<li>{html.escape(name)}</li>" for name in bitstreams) or "<li>none</li>"
    meta_rows = "".join(
        f"<tr><th>{html.escape(key)}</th><td>{html.escape(value)}</td></tr>"
        for key, value in header.items()
        if key in ("Tool Version", "Date", "Design", "Device", "Design State")
    )

    return f"""
      <section class=\"overview active\" id=\"overview\">
        <div class=\"section-head\"><h2>Overview</h2><span>{html.escape(str(gateware_dir))}</span></div>
        <div class=\"cards\">{''.join(cards) or '<p class=\"empty\">No parsed summary metrics found.</p>'}</div>
        <div class=\"tables\">
          <section><h3>Build Metadata</h3><table>{meta_rows or '<tr><td>No metadata found</td></tr>'}</table></section>
          <section><h3>Resources</h3><table><thead><tr><th>Resource</th><th>Used</th><th>Available</th><th>Util</th></tr></thead><tbody>{''.join(resource_rows) or '<tr><td colspan=\"4\">No utilization report found</td></tr>'}</tbody></table></section>
          <section><h3>Clocks</h3><table><thead><tr><th>Clock</th><th>Period</th><th>Frequency</th></tr></thead><tbody>{''.join(clock_rows) or '<tr><td colspan=\"3\">No timing clock summary found</td></tr>'}</tbody></table></section>
          <section><h3>Bitstreams</h3><ul class=\"bits\">{bitstream_items}</ul></section>
        </div>
      </section>"""


def render_nav(reports: list[Report]) -> str:
    groups: dict[str, list[Report]] = {}
    for report in reports:
        groups.setdefault(report.group, []).append(report)

    nav_sections = ["<h2>Summary</h2><ul><li><a class=\"active\" data-report=\"overview\" href=\"#overview\">Overview<span>Parsed Vivado metrics</span></a></li></ul>"]
    for group, group_reports in groups.items():
        links = []
        for report in group_reports:
            links.append(
                f"<li><a data-report=\"{html.escape(report.report_id)}\" href=\"#{html.escape(report.report_id)}\">"
                f"{html.escape(report.title)}<span>{html.escape(report.rel_path)}</span></a></li>"
            )
        nav_sections.append(f"<h2>{html.escape(group)}</h2><ul>{''.join(links)}</ul>")
    return "".join(nav_sections)


def render_report_sections(reports: list[Report]) -> str:
    sections = []
    for report in reports:
        raw_href = quote(report.rel_path)
        sections.append(
            f"""
      <section class=\"report\" id=\"{html.escape(report.report_id)}\">
        <div class=\"section-head\">
          <div><h2>{html.escape(report.title)}</h2><span>{html.escape(report.description)}</span></div>
          <a href=\"{raw_href}\" target=\"_blank\" rel=\"noopener\">Open raw</a>
        </div>
        <pre>{html.escape(report.text)}</pre>
      </section>"""
        )
    return "".join(sections)


def render_html(title: str, gateware_dir: Path, reports: list[Report]) -> str:
    generated_at = datetime_module.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    report_ids_json = json.dumps(["overview"] + [report.report_id for report in reports])
    return f"""<!DOCTYPE html>
<html lang=\"en\">
<head>
  <meta charset=\"UTF-8\" />
  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\" />
  <title>{html.escape(title)}</title>
  <style>
    :root {{ --bg:#f5f6f7; --panel:#fff; --ink:#1f2328; --muted:#68707a; --line:#d6dae0; --line-strong:#aeb6c1; --accent:#2f6f62; --good:#1f7a4d; --bad:#b42318; --neutral:#3d5366; --code-bg:#101419; --code-ink:#d7dde5; }}
    * {{ box-sizing: border-box; }}
    html, body {{ margin: 0; min-height: 100%; }}
    body {{ color: var(--ink); background: var(--bg); font-family: -apple-system, BlinkMacSystemFont, \"Segoe UI\", sans-serif; font-size: 14px; }}
    header {{ position: sticky; top: 0; z-index: 20; display: flex; align-items: center; justify-content: space-between; gap: 16px; min-height: 58px; padding: 10px 18px; border-bottom: 1px solid var(--line); background: rgba(255,255,255,0.96); backdrop-filter: blur(10px); }}
    header h1 {{ margin: 0; font-size: 18px; font-weight: 650; }}
    header span {{ color: var(--muted); font-size: 12px; white-space: nowrap; }}
    .shell {{ display: grid; grid-template-columns: 280px minmax(0, 1fr); min-height: calc(100vh - 58px); }}
    nav {{ position: sticky; top: 58px; height: calc(100vh - 58px); overflow: auto; border-right: 1px solid var(--line); background: #eceff1; padding: 10px 0 18px; }}
    nav h2 {{ margin: 16px 16px 6px; color: var(--muted); font-size: 11px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.04em; }}
    nav ul {{ list-style: none; margin: 0; padding: 0; }}
    nav a {{ display: block; padding: 8px 16px; border-left: 4px solid transparent; color: var(--ink); text-decoration: none; line-height: 1.25; }}
    nav a:hover, nav a.active {{ background: var(--panel); border-left-color: var(--accent); }}
    nav a span {{ display: block; margin-top: 2px; color: var(--muted); font-size: 11px; overflow-wrap: anywhere; }}
    main {{ min-width: 0; padding: 18px; }}
    section.overview, section.report {{ display: none; }}
    section.active {{ display: block; }}
    .section-head {{ display: flex; justify-content: space-between; align-items: flex-start; gap: 14px; margin-bottom: 14px; }}
    .section-head h2 {{ margin: 0; font-size: 20px; font-weight: 650; }}
    .section-head span {{ color: var(--muted); font-size: 12px; overflow-wrap: anywhere; }}
    .section-head a {{ border: 1px solid var(--line-strong); border-radius: 6px; padding: 6px 10px; color: var(--ink); background: var(--panel); text-decoration: none; white-space: nowrap; }}
    .cards {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(170px, 1fr)); gap: 12px; margin-bottom: 18px; }}
    .card {{ min-height: 94px; padding: 12px; border: 1px solid var(--line); border-top: 4px solid var(--neutral); border-radius: 8px; background: var(--panel); }}
    .card.good {{ border-top-color: var(--good); }}
    .card.bad {{ border-top-color: var(--bad); }}
    .card.neutral {{ border-top-color: var(--neutral); }}
    .card-label, .card-detail {{ display: block; color: var(--muted); font-size: 12px; }}
    .card strong {{ display: block; margin: 8px 0 5px; font-size: 22px; font-weight: 700; }}
    .tables {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(300px, 1fr)); gap: 14px; }}
    .tables section {{ border: 1px solid var(--line); border-radius: 8px; background: var(--panel); padding: 12px; overflow: auto; }}
    .tables h3 {{ margin: 0 0 10px; font-size: 15px; }}
    table {{ width: 100%; border-collapse: collapse; }}
    th, td {{ border-bottom: 1px solid var(--line); padding: 7px 6px; text-align: left; vertical-align: top; }}
    th {{ color: var(--muted); font-weight: 600; }}
    tr:last-child th, tr:last-child td {{ border-bottom: 0; }}
    .bits {{ margin: 0; padding-left: 18px; }}
    pre {{ margin: 0; padding: 16px; min-height: calc(100vh - 130px); overflow: auto; border-radius: 8px; background: var(--code-bg); color: var(--code-ink); font: 12px/1.45 ui-monospace, SFMono-Regular, Menlo, Consolas, \"Liberation Mono\", monospace; tab-size: 2; }}
    .empty {{ color: var(--muted); margin: 0; }}
    @media (max-width: 760px) {{ header {{ align-items: flex-start; flex-direction: column; }} header span {{ white-space: normal; }} .shell {{ grid-template-columns: 1fr; }} nav {{ position: relative; top: 0; height: auto; max-height: 40vh; border-right: 0; border-bottom: 1px solid var(--line); }} main {{ padding: 12px; }} }}
  </style>
</head>
<body>
  <header><h1>{html.escape(title)}</h1><span>Generated {html.escape(generated_at)} from {html.escape(str(gateware_dir))}</span></header>
  <div class=\"shell\"><nav>{render_nav(reports)}</nav><main>{render_overview(reports, gateware_dir)}{render_report_sections(reports)}</main></div>
  <script>
    (function () {{
      const reportIds = {report_ids_json};
      const links = Array.from(document.querySelectorAll('nav a[data-report]'));
      function activate(reportId) {{
        if (!reportIds.includes(reportId)) reportId = 'overview';
        for (const reportIdItem of reportIds) {{
          const section = document.getElementById(reportIdItem);
          if (section) section.classList.toggle('active', reportIdItem === reportId);
        }}
        for (const link of links) link.classList.toggle('active', link.dataset.report === reportId);
        if (location.hash !== '#' + reportId) history.replaceState(null, '', '#' + reportId);
      }}
      for (const link of links) link.addEventListener('click', function (event) {{ event.preventDefault(); activate(link.dataset.report); }});
      window.addEventListener('hashchange', function () {{ activate((location.hash || '#overview').slice(1)); }});
      activate((location.hash || '#overview').slice(1));
    }})();
  </script>
</body>
</html>
"""


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate a Vivado report HTML dashboard")
    parser.add_argument("gateware_dir", type=Path, help="Vivado gateware build directory containing .rpt files")
    parser.add_argument("--output", type=Path, default=None, help="Output HTML path, defaults to <gateware_dir>/index.html")
    parser.add_argument("--title", default="Vivado Build Reports", help="Dashboard title")
    args = parser.parse_args()

    gateware_dir = args.gateware_dir.resolve()
    output_path = (args.output or gateware_dir / "index.html").resolve()
    if not gateware_dir.is_dir():
        print(f"error: gateware directory not found: {gateware_dir}", file=sys.stderr)
        return 1

    reports = collect_reports(gateware_dir)
    if not reports:
        print(f"error: no Vivado .rpt files found under {gateware_dir}", file=sys.stderr)
        return 1

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(render_html(args.title, gateware_dir, reports), encoding="utf-8")
    print(f"[INFO] Vivado reports index: {output_path}")
    print(f"[INFO] Embedded reports: {len(reports)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())