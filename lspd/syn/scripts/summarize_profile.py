#!/usr/bin/env python3

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate an evaluation overhead summary")
    parser.add_argument("--build-root", type=Path, required=True)
    parser.add_argument("--config", required=True)
    parser.add_argument("--pdk", required=True)
    parser.add_argument("--frequency-mhz", type=int, required=True)
    parser.add_argument("--modules", nargs="+", required=True)
    parser.add_argument("--output", type=Path, required=True)
    return parser.parse_args()


def parse_profile(path: Path) -> dict[str, float | int] | None:
    if not path.is_file():
        return None
    values: dict[str, float | int] = {}
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        key, separator, value = line.partition("=")
        if not separator:
            continue
        try:
            values[key] = int(value) if key in {"status", "max_rss_kb"} else float(value)
        except ValueError:
            return None
    required = {"status", "elapsed_sec", "user_sec", "system_sec", "max_rss_kb"}
    return values if required <= values.keys() else None


def collect_rtl_metrics(module_dir: Path) -> tuple[int | None, int | None]:
    json_files = sorted(module_dir.glob("*.json"))
    if not json_files or json_files[0].stat().st_size == 0:
        return None, None
    try:
        design = json.loads(json_files[0].read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None, None

    source_files: set[Path] = set()
    for module in design.get("modules", {}).values():
        source = module.get("attributes", {}).get("src")
        if not isinstance(source, str):
            continue
        file_name = source.rsplit(":", 1)[0]
        path = Path(file_name)
        if path.is_file():
            source_files.add(path)

    rtl_lines = 0
    for path in source_files:
        try:
            rtl_lines += sum(1 for line in path.read_text(encoding="utf-8", errors="replace").splitlines() if line.strip())
        except OSError:
            return None, None
    return len(source_files), rtl_lines


def format_seconds(value: float | int | None) -> str:
    return "N/A" if value is None else f"{float(value):.2f}"


def format_memory(value: float | int | None) -> str:
    return "N/A" if value is None else f"{float(value) / 1024.0:.1f}"


def directory_size_mib(path: Path) -> float | None:
    if not path.is_dir():
        return None
    try:
        return sum(file.stat().st_size for file in path.rglob("*") if file.is_file()) / (1024.0 * 1024.0)
    except OSError:
        return None


def main() -> None:
    args = parse_args()
    pdk_dir = args.build_root / args.config / args.pdk
    frequency_dir = f"{args.frequency_mhz}MHz"
    rows = []
    complete = 0

    for module_name in args.modules:
        module_dir = pdk_dir / module_name / frequency_dir
        synth = parse_profile(module_dir / "synth.profile")
        sta = parse_profile(module_dir / "sta.profile")
        rtl_files, rtl_lines = collect_rtl_metrics(module_dir)
        if synth and sta:
            status = "ok" if synth["status"] == 0 and sta["status"] == 0 else "failed"
        else:
            status = "missing"
        if status == "ok":
            complete += 1
        total_elapsed = None if not synth or not sta else synth["elapsed_sec"] + sta["elapsed_sec"]
        total_cpu = None if not synth or not sta else (
            synth["user_sec"] + synth["system_sec"] + sta["user_sec"] + sta["system_sec"]
        )
        peak_rss = None if not synth or not sta else max(synth["max_rss_kb"], sta["max_rss_kb"])
        build_size = directory_size_mib(module_dir)
        build_size_text = "N/A" if build_size is None else f"{build_size:.1f}"
        rows.append(
            f"| {module_name} | {status} | {rtl_files if rtl_files is not None else 'N/A'} | "
            f"{rtl_lines if rtl_lines is not None else 'N/A'} | "
            f"{format_seconds(synth['elapsed_sec'] if synth else None)} | "
            f"{format_seconds(sta['elapsed_sec'] if sta else None)} | {format_seconds(total_elapsed)} | "
            f"{format_seconds(total_cpu)} | {format_memory(peak_rss)} | "
            f"{build_size_text} |"
        )

    generated = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
    content = "\n".join(
        [
            f"# Profile Summary: {args.pdk}",
            "",
            f"- Configuration: `{args.config}`",
            f"- Target frequency: `{args.frequency_mhz} MHz`",
            f"- Complete profiles: `{complete}/{len(args.modules)}`",
            f"- Generated: `{generated}`",
            "",
            "| Module | Status | RTL files | RTL nonblank lines | Synthesis wall (s) | STA wall (s) | Total wall (s) | CPU time (s) | Peak RSS (MiB) | Build size (MiB) |",
            "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
            *rows,
            "",
            "RTL metrics count source files retained in the synthesized hierarchy and serve as development-complexity proxies.",
            "Wall/CPU time and peak RSS are measured by GNU time; parallel matrix wall time is not the sum of module times.",
            "",
        ]
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.output.with_suffix(args.output.suffix + ".tmp")
    temporary.write_text(content, encoding="utf-8")
    temporary.replace(args.output)
    print(f"Profile summary: {args.output}")


if __name__ == "__main__":
    main()