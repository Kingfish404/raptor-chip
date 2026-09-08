#!/usr/bin/env python3
"""Compare two full-ROU mapped runs, preserving provenance and source differences.

This is a physical-cost comparison, not a functional-equivalence proof. The
caller must review the reported HDL differences and run functional regression.
"""
import argparse
import json
from pathlib import Path

from dispatch_steer_ppa import compare, parse_case


def sources(directory):
    result = {}
    for line in (directory / "source_manifest.sha256").read_text().splitlines():
        digest, filename = line.split(None, 1)
        # Frozen HDL trees have different prefixes but the same logical names.
        name = filename.strip()
        if "/hdl/" in name:
            name = "hdl/" + name.split("/hdl/", 1)[1]
        if name in result:
            raise ValueError(f"duplicate manifest source: {name}")
        result[name] = digest
    if not result:
        raise ValueError("empty source manifest")
    return result


def evaluate(baseline, candidate, baseline_label="baseline", candidate_label="candidate"):
    old = parse_case(baseline_label, baseline, "rou", 4)
    new = parse_case(candidate_label, candidate, "rou", 4)
    for key in ("module", "config", "pdk", "sram_mode", "clock_mhz", "extra_defines"):
        if old[key] != new[key]:
            raise ValueError(f"configuration mismatch: {key}")
    for key in ("period_ns", "io_delay_frac", "io_delay_ns", "output_load_ff"):
        if old["timing"][key] != new["timing"][key]:
            raise ValueError(f"constraint mismatch: {key}")
    old_sources, new_sources = sources(baseline), sources(candidate)
    changes = {key: {"baseline": old_sources.get(key), "candidate": new_sources.get(key)}
               for key in sorted(old_sources.keys() | new_sources.keys())
               if old_sources.get(key) != new_sources.get(key)}
    if any(not key.startswith("hdl/") for key in changes):
        raise ValueError("implementation flow sources differ between runs")
    return {"complete": True, "baseline": old, "candidate": new,
            "delta": compare(old, new), "source_differences": changes,
            "scope": "full isolated ROU, K=4; exact configuration recorded per run; pre-layout, not core Fmax",
            "output_retention": "all outputs of each standalone ROU retained; review interface differences, especially observation payload; not integrated-core area",
            "functional_equivalence_proven": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--baseline-label", default="baseline")
    parser.add_argument("--candidate-label", default="candidate")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    report = args.output / "results.json"
    report.write_text(json.dumps({"complete": False}) + "\n")
    result = evaluate(args.baseline, args.candidate, args.baseline_label, args.candidate_label)
    report.write_text(json.dumps(result, indent=2) + "\n")
    lines = ["# Full ROU state ownership comparison", "", result["scope"], "",
             result["output_retention"], "",
             "| State organization | Cells | Area | Delay (ns) | Power (mW) |",
             "| --- | ---: | ---: | ---: | ---: |"]
    for key in ("baseline", "candidate"):
        row = result[key]
        lines.append(f"| {row['label']} | {row['cell_count']} | {row['area']:.3f} | "
                     f"{row['timing']['period_min_ns']:.4f} | {row['power_w']['total']*1000:.4f} |")
    lines.extend(["", "All input hashes and constraint values were checked. This is not an",
                  "equivalence proof. Source differences requiring scope review:", ""])
    lines.extend(f"- `{name}`" for name in result["source_differences"])
    (args.output / "report.md").write_text("\n".join(lines) + "\n")
    print(json.dumps(result["delta"], indent=2))


if __name__ == "__main__":
    main()
