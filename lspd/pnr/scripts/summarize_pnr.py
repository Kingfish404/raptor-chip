#!/usr/bin/env python3

import argparse
from datetime import datetime, timezone
from pathlib import Path


def parse_metrics(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.is_file():
        return {"status": "missing"}
    for line in path.read_text(encoding="ascii", errors="replace").splitlines():
        key, separator, value = line.partition(" ")
        if separator:
            values[key] = value
    return values


def value(metrics: dict[str, str], key: str, digits: int = 3) -> str:
    raw = metrics.get(key, "N/A")
    if raw == "N/A":
        return raw
    try:
        return f"{float(raw):.{digits}f}"
    except ValueError:
        return raw


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate LSPD physical-design summary")
    parser.add_argument("--build-root", type=Path, required=True)
    parser.add_argument("--config", required=True)
    parser.add_argument("--pdk", required=True)
    parser.add_argument("--frequency-mhz", type=int, required=True)
    parser.add_argument("--modules", nargs="+", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    rows = []
    complete = 0
    for module in args.modules:
        result_dir = args.build_root / args.config / args.pdk / module / f"{args.frequency_mhz}MHz"
        metrics = parse_metrics(result_dir / "pnr_metrics.txt")
        status = metrics.get("status", "missing")
        image = next((result_dir / "images").glob("*_layout.png"), None) if (result_dir / "images").is_dir() else None
        image_status = "yes" if image else "no"
        if status == "ok":
            complete += 1
        rows.append(
            f"| {module} | {status} | {metrics.get('instances', 'N/A')} | "
            f"{value(metrics, 'design_area_um2')} | {value(metrics, 'die_area_um2')} | "
            f"{value(metrics, 'utilization_pct', 2)} | {value(metrics, 'wns_ns', 4)} | "
            f"{value(metrics, 'tns_ns', 4)} | {value(metrics, 'fmax_mhz', 2)} | "
            f"{value(metrics, 'total_power_w', 6)} | {metrics.get('drc_violations', 'N/A')} | "
            f"{value(metrics, 'elapsed_sec', 2)} | {value(metrics, 'max_rss_mb', 1)} | {image_status} |"
        )

    generated = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    content = "\n".join([
        f"# Physical Design Summary: {args.pdk}",
        "",
        f"- Configuration: `{args.config}`",
        f"- Target frequency: `{args.frequency_mhz} MHz`",
        f"- Complete layouts: `{complete}/{len(args.modules)}`",
        f"- Generated: `{generated}`",
        "",
        "| Module | Status | Instances | Cell area (um^2) | Die area (um^2) | Util. (%) | WNS (ns) | TNS (ns) | Fmax (MHz) | Power (W) | DRC | Runtime (s) | Peak RSS (MB) | PNG |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
        *rows,
        "",
        "Power is vectorless. Timing and area are post-route estimates from OpenROAD; DRC is the detailed-router report count.",
        "",
    ])
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(content, encoding="utf-8")
    print(f"Physical-design summary: {args.output}")


if __name__ == "__main__":
    main()