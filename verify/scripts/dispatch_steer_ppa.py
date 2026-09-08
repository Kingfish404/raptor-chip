#!/usr/bin/env python3
"""Validate and compare technology-mapped K=4/K=8 dispatch-steering reports."""

import argparse
import hashlib
import json
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[2]
EXPECTED = {
    "dpu-k4": ("dpu", 4),
    "dpu-k8": ("dpu", 8),
    "select-k4": ("dispatch_select", 4),
    "select-k8": ("dispatch_select", 8),
    "steer-k4": ("dispatch_steer", 4),
    "steer-k8": ("dispatch_steer", 8),
}


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def parse_key_values(path: Path) -> dict[str, str]:
    values = {}
    for line in path.read_text().splitlines():
        if not line.strip():
            continue
        if "=" in line:
            key, value = line.split("=", 1)
        else:
            key, value = line.split(None, 1)
        values[key.strip()] = value.strip()
    return values


def one(directory: Path, pattern: str) -> Path:
    matches = sorted(directory.glob(pattern))
    if len(matches) != 1:
        raise ValueError(f"expected one {pattern} in {directory}, found {len(matches)}")
    return matches[0]


def parse_profile(path: Path) -> dict[str, float | int]:
    raw = parse_key_values(path)
    result = {"status": int(raw["status"])}
    for key in ("elapsed_sec", "user_sec", "system_sec"):
        result[key] = float(raw[key])
    result["max_rss_kb"] = int(raw["max_rss_kb"])
    if result["status"] != 0:
        raise ValueError(f"failed tool profile: {path}")
    return result


def verify_manifest(path: Path) -> str:
    for line in path.read_text().splitlines():
        expected, filename = line.split(None, 1)
        source = Path(filename.strip())
        if not source.is_file() or digest(source) != expected:
            raise ValueError(f"source provenance mismatch: {source}")
    return digest(path)


def parse_case(label: str, directory: Path, expected_module: str, expected_k: int) -> dict:
    run = parse_key_values(directory / "run_config.txt")
    if run.get("module") != expected_module:
        raise ValueError(f"{label}: expected module {expected_module}, got {run.get('module')}")
    define = f"-DRAPT_STEER_SCAN_ENTRIES={expected_k}"
    if define not in run.get("extra_defines", "").split():
        raise ValueError(f"{label}: missing exact {define} build define")

    stat_path = one(directory, "*.stat.rpt")
    sta_path = one(directory, "*.sta_summary.rpt")
    netlist = one(directory, "*.netlist.v")
    stat = stat_path.read_text()
    sta = parse_key_values(sta_path)
    log = (directory / "sta.log").read_text()

    area_matches = re.findall(r"Chip area for module .*?:\s*([0-9.eE+-]+)", stat)
    cell_matches = re.findall(r"^\s*(\d+)\s+[0-9.eE+-]+\s+cells\s*$", stat, re.MULTILINE)
    power_matches = re.findall(
        r"^Total\s+([0-9.eE+-]+)\s+([0-9.eE+-]+)\s+"
        r"([0-9.eE+-]+)\s+([0-9.eE+-]+)\s+100\.0%$", log, re.MULTILINE)
    startpoint = re.search(r"^Startpoint:\s+(.+)$", log, re.MULTILINE)
    endpoint = re.search(r"^Endpoint:\s+(.+)$", log, re.MULTILINE)
    if not all((area_matches, cell_matches, power_matches, startpoint, endpoint)):
        raise ValueError(f"{label}: incomplete synthesis/STA report")

    recorded_hash = (directory / "netlist.sha256").read_text().split()[0]
    actual_hash = digest(netlist)
    if recorded_hash != actual_hash:
        raise ValueError(f"{label}: mapped netlist hash mismatch")

    timing = {key: float(sta[key]) for key in
              ("period_ns", "io_delay_frac", "io_delay_ns", "output_load_ff",
               "wns_ns", "tns_ns", "period_min_ns", "fmax_mhz")}
    if abs(float(run["io_delay_frac"]) - timing["io_delay_frac"]) > 1e-12:
        raise ValueError(f"{label}: run/STA I/O constraint mismatch")
    if timing["tns_ns"] < -1e-12 or timing["period_min_ns"] <= 0:
        raise ValueError(f"{label}: invalid timing result")

    internal, switching, leakage, total = map(float, power_matches[-1])
    return {
        "label": label,
        "module": expected_module,
        "scan_entries": expected_k,
        "directory": str(directory.resolve()),
        "config": run["config"],
        "pdk": run["pdk"],
        "sram_mode": run["sram_mode"],
        "clock_mhz": float(run["clock_mhz"]),
        "extra_defines": run["extra_defines"],
        "cell_count": int(cell_matches[-1]),
        "area": float(area_matches[-1]),
        "timing": timing,
        "power_w": {"internal": internal, "switching": switching,
                    "leakage": leakage, "total": total},
        "critical_path": {"startpoint": startpoint.group(1), "endpoint": endpoint.group(1)},
        "synthesis": parse_profile(directory / "synth.profile"),
        "sta": parse_profile(directory / "sta.profile"),
        "netlist_sha256": actual_hash,
        "source_manifest_sha256": verify_manifest(directory / "source_manifest.sha256"),
    }


def percent(new: float, old: float) -> float:
    return (new / old - 1.0) * 100.0


def compare(k4: dict, k8: dict) -> dict:
    return {
        "area_delta_percent": percent(k8["area"], k4["area"]),
        "cell_count_delta_percent": percent(k8["cell_count"], k4["cell_count"]),
        "delay_delta_percent": percent(k8["timing"]["period_min_ns"],
                                         k4["timing"]["period_min_ns"]),
        "fmax_delta_percent": percent(k8["timing"]["fmax_mhz"],
                                        k4["timing"]["fmax_mhz"]),
        "power_delta_percent": percent(k8["power_w"]["total"],
                                         k4["power_w"]["total"]),
    }


def markdown(results: dict) -> str:
    lines = [
        "# Dispatch steering technology-mapped comparison",
        "",
        "NanGate45, pre-layout mapped logic, ideal clock, zero input/output delay, "
        "5 fF output load, no SRAM, vectorless 0.1 activity. This is a relative estimate, "
        "not signoff.",
        "",
        "| Cone | K | Cells | Area | Delay (ns) | Fmax (MHz) | Power (mW) |",
        "| --- | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]
    names = (("DPU compact", "dpu"), ("ROB select", "select"),
             ("Integrated steer", "steer"))
    for display, prefix in names:
        for k in (4, 8):
            row = results["cases"][f"{prefix}-k{k}"]
            lines.append(
                f"| {display} | {k} | {row['cell_count']:,} | {row['area']:.3f} | "
                f"{row['timing']['period_min_ns']:.4f} | {row['timing']['fmax_mhz']:.2f} | "
                f"{row['power_w']['total'] * 1000:.4f} |")
    lines.extend(["", "| Cone | K8 area | K8 delay | K8 Fmax | K8 power |",
                  "| --- | ---: | ---: | ---: | ---: |"])
    for display, prefix in names:
        row = results["comparisons"][prefix]
        lines.append(
            f"| {display} | {row['area_delta_percent']:+.2f}% | "
            f"{row['delay_delta_percent']:+.2f}% | {row['fmax_delta_percent']:+.2f}% | "
            f"{row['power_delta_percent']:+.2f}% |")
    lines.append("")
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path,
                        default=ROOT / "verify/build/dispatch-timing/nangate45")
    parser.add_argument("--output", type=Path,
                        default=ROOT / "verify/build/dispatch-timing/report")
    args = parser.parse_args()

    cases = {}
    for label, (module, k) in EXPECTED.items():
        cases[label] = parse_case(label, args.root / f"{label}-io0", module, k)

    constraint_keys = ("config", "pdk", "clock_mhz", "sram_mode")
    reference = cases["dpu-k4"]
    for label, row in cases.items():
        if any(row[key] != reference[key] for key in constraint_keys):
            raise ValueError(f"{label}: comparison configuration differs")
        timing = row["timing"]
        if timing["io_delay_frac"] != 0.0 or timing["output_load_ff"] != 5.0:
            raise ValueError(f"{label}: expected zero I/O delay and 5 fF load")
        if row["sram_mode"] != "flops":
            raise ValueError(f"{label}: combinational proxy must not load unrelated SRAM models")

    results = {
        "schema_version": 1,
        "complete": True,
        "methodology": {
            "scope": "pre-layout technology-mapped combinational proxies",
            "clock": "ideal",
            "io_delay_frac": 0.0,
            "output_load_ff": 5.0,
            "power_activity": 0.1,
            "sram_mode": "flops (no SRAM exists in these cones)",
            "limitations": [
                "No placement, routing, clock tree, or extracted parasitics.",
                "Integrated steer excludes wide operand payload read and endpoint adapters.",
                "Vectorless power is suitable only for same-flow relative comparison.",
            ],
        },
        "cases": cases,
        "comparisons": {
            prefix: compare(cases[f"{prefix}-k4"], cases[f"{prefix}-k8"])
            for prefix in ("dpu", "select", "steer")
        },
    }
    args.output.mkdir(parents=True, exist_ok=True)
    (args.output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    (args.output / "report.md").write_text(markdown(results))
    print(markdown(results), end="")


if __name__ == "__main__":
    main()
