#!/usr/bin/env python3
"""Summarize raw BPU predictions from the image-backed frontend trace replay."""

import argparse
import csv
import hashlib
import json
from collections import Counter
from pathlib import Path


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def fields(line: str) -> dict[str, str]:
    return dict(part.split("=", 1) for part in line.split() if "=" in part)


def ratio(correct: int, total: int) -> float:
    return correct / total if total else 0.0


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--events", type=Path)
    parser.add_argument("--trace", type=Path, required=True)
    parser.add_argument("--image", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--xlen", type=int, choices=(32, 64), required=True)
    parser.add_argument("--config", required=True)
    parser.add_argument("--defines", default="")
    parser.add_argument("--executable", type=Path)
    parser.add_argument("--baseline", type=Path)
    args = parser.parse_args()

    lines = args.log.read_text().splitlines()
    fe_line = next((line for line in lines if line.startswith("PASS: FE trace=")), None)
    bp_line = next((line for line in lines if line.startswith("BPU: ")), None)
    if fe_line is None or bp_line is None:
        raise ValueError("FE replay did not finish with both FE and BPU records")
    fe = fields(fe_line)
    bp = {name: int(value) for name, value in fields(bp_line).items()}
    required = (
        "cond", "cond_raw_miss", "cond_dir_miss", "cond_target_miss",
        "cond_ambiguous_miss", "cond_primary", "cond_primary_miss",
        "cond_aux", "cond_aux_miss", "direct", "direct_raw_miss",
        "indirect", "indirect_raw_miss", "returns", "return_raw_miss",
        "noncontrol_steer", "decode_repairs", "decode_repairs_correct",
        "feedback_delay", "sink_width", "fetch_gap",
    )
    if any(name not in bp for name in required):
        raise ValueError("BPU record is missing required counters")
    if bp["cond"] != bp["cond_primary"] + bp["cond_aux"]:
        raise ValueError("primary/auxiliary conditional counts do not partition the trace")
    if bp["cond_raw_miss"] != bp["cond_primary_miss"] + bp["cond_aux_miss"]:
        raise ValueError("primary/auxiliary misses do not partition conditional misses")
    if bp["cond_raw_miss"] != (
        bp["cond_dir_miss"] + bp["cond_target_miss"] + bp["cond_ambiguous_miss"]
    ):
        raise ValueError("conditional miss causes do not partition raw misses")
    if bp["returns"] > bp["indirect"] or bp["return_raw_miss"] > bp["indirect_raw_miss"]:
        raise ValueError("return counts exceed indirect jump counts")
    if bp["decode_repairs_correct"] > bp["decode_repairs"]:
        raise ValueError("correct decode repairs exceed all decode repairs")
    if int(fe["correct"]) != int(fe["instructions"]):
        raise ValueError("FE did not deliver the entire oracle instruction window")
    if Path(fe["trace"]).resolve() != args.trace.resolve():
        raise ValueError("FE run used a different trace")

    control = bp["cond"] + bp["direct"] + bp["indirect"]
    if int(fe["controls"]) != control:
        raise ValueError("FE and BPU control counts disagree")
    raw_misses = (bp["cond_raw_miss"] + bp["direct_raw_miss"]
                  + bp["indirect_raw_miss"])
    instructions = int(fe["instructions"])
    result = {
        "image": str(args.image.resolve()),
        "image_sha256": sha256(args.image),
        "trace": str(args.trace.resolve()),
        "trace_sha256": sha256(args.trace),
        "xlen": args.xlen,
        "config": args.config,
        "defines": args.defines,
        "instructions": instructions,
        "cycles": int(fe["cycles"]),
        "feedback_delay": bp["feedback_delay"],
        "sink_width": bp["sink_width"],
        "fetch_gap": bp["fetch_gap"],
        "raw": bp,
        "rates": {
            "control_raw_accuracy": ratio(control - raw_misses, control),
            "control_raw_mpki": 1000 * ratio(raw_misses, instructions),
            "conditional_raw_accuracy": ratio(bp["cond"] - bp["cond_raw_miss"], bp["cond"]),
            "conditional_raw_mpki": 1000 * ratio(bp["cond_raw_miss"], instructions),
            "conditional_primary_accuracy": ratio(
                bp["cond_primary"] - bp["cond_primary_miss"], bp["cond_primary"]),
            "conditional_aux_accuracy": ratio(bp["cond_aux"] - bp["cond_aux_miss"], bp["cond_aux"]),
            "conditional_aux_fraction": ratio(bp["cond_aux"], bp["cond"]),
            "direct_raw_accuracy": ratio(bp["direct"] - bp["direct_raw_miss"], bp["direct"]),
            "indirect_raw_accuracy": ratio(
                bp["indirect"] - bp["indirect_raw_miss"], bp["indirect"]),
            "return_raw_accuracy": ratio(
                bp["returns"] - bp["return_raw_miss"], bp["returns"]),
        },
    }
    if args.events:
        per_pc: dict[str, Counter[str]] = {}
        by_kind: dict[str, Counter[str]] = {}
        event_count = event_misses = 0
        names = ("conditional", "direct", "indirect", "return")
        with args.events.open(newline="") as source:
            for event in csv.DictReader(source):
                event_count += 1
                event_misses += int(event["raw_miss"])
                kind = names[int(event["kind"])]
                category = by_kind.setdefault(kind, Counter())
                category["count"] += 1
                category["raw_miss"] += int(event["raw_miss"])
                category["final_miss"] += int(event["final_miss"])
                pc = event["pc"].lower().lstrip("0") or "0"
                bucket = per_pc.setdefault(pc, Counter())
                bucket["count"] += 1
                bucket["raw_miss"] += int(event["raw_miss"])
                if int(event["kind"]) == 0:
                    bucket["conditional"] += 1
                    if int(event["aux"]):
                        bucket["aux"] += 1
                        bucket["aux_miss"] += int(event["raw_miss"])
        if event_count != control or event_misses != raw_misses:
            raise ValueError("BPU event stream disagrees with aggregate counters")
        result["events_sha256"] = sha256(args.events)
        result["by_kind"] = {name: dict(counts) for name, counts in by_kind.items()}
        result["hotspots"] = [
            {"pc": f"0x{pc}", **dict(counts)}
            for pc, counts in sorted(
                per_pc.items(), key=lambda item: (-item[1]["aux_miss"], -item[1]["raw_miss"])
            )[:20]
        ]
    if args.executable:
        result["executable_sha256"] = sha256(args.executable)
    if args.baseline:
        baseline = json.loads(args.baseline.read_text())
        matched = ("trace_sha256", "image_sha256", "xlen", "config",
                   "feedback_delay", "sink_width", "fetch_gap")
        if any(baseline[name] != result[name] for name in matched):
            raise ValueError("baseline and candidate use different inputs or replay settings")
        result["delta_vs_baseline"] = {
            name: value - baseline["rates"][name]
            for name, value in result["rates"].items() if name in baseline["rates"]
        }
        result["delta_vs_baseline"].update({
            "cycles": result["cycles"] - baseline["cycles"],
            "control_raw_misses": raw_misses - (
                baseline["raw"]["cond_raw_miss"]
                + baseline["raw"]["direct_raw_miss"]
                + baseline["raw"]["indirect_raw_miss"]
            ),
            "conditional_raw_misses": bp["cond_raw_miss"] - baseline["raw"]["cond_raw_miss"],
        })
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(
        f"BPU report: controls={control} raw_misses={raw_misses} "
        f"raw_accuracy={result['rates']['control_raw_accuracy']:.6f} "
        f"cond={result['rates']['conditional_raw_accuracy']:.6f} "
        f"primary={result['rates']['conditional_primary_accuracy']:.6f} "
        f"aux={result['rates']['conditional_aux_accuracy']:.6f}"
    )


if __name__ == "__main__":
    main()
