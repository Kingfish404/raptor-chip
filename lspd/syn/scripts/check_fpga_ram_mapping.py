#!/usr/bin/env python3
"""Check module-level Vivado RAM mapping against the recorded minima."""

import argparse
import csv
from pathlib import Path


def expectations(path: Path, module: str, config: str, xlen: str) -> tuple[int, int] | None:
    with path.open(newline="") as stream:
        rows = (line for line in stream if line.strip() and not line.startswith("#"))
        for row in csv.reader(rows, delimiter="\t"):
            if len(row) != 5:
                raise ValueError(f"invalid RAM expectation row: {row}")
            if row[:2] == [module, config] and row[2] in (xlen, "*"):
                return int(row[3]), int(row[4])
    return None


def top_resources(path: Path, top: str) -> dict[str, int]:
    lines = path.read_text().splitlines()
    for position, line in enumerate(lines):
        if not line.startswith("|"):
            continue
        header = [part.strip() for part in line.strip().strip("|").split("|")]
        if header[0] != "Instance" or "RAMB36" not in header:
            continue
        for candidate in lines[position + 1 :]:
            if candidate.startswith("+"):
                continue
            if not candidate.startswith("|"):
                break
            cells = [part.strip() for part in candidate.strip().strip("|").split("|")]
            if len(cells) != len(header) or cells[0] != top:
                continue
            return {key: int(value) for key, value in zip(header, cells) if key in ("RAMB36", "LUTRAMs")}
    raise ValueError(f"top instance {top!r} missing from utilization report {path}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--module", required=True)
    parser.add_argument("--config", required=True)
    parser.add_argument("--xlen", choices=("32", "64"), required=True)
    parser.add_argument("--top", required=True)
    parser.add_argument("--defines", default="")
    args = parser.parse_args()

    minimum = expectations(args.manifest, args.module, args.config, args.xlen)
    if minimum is None:
        print(f"[fpga-ram] no mapping minimum for {args.module}/{args.config}/RV{args.xlen}")
        return
    min_bram, min_lutram = minimum
    if "-DRAPT_FPGA_LUTRAM=0" in args.defines.split():
        min_lutram = 0
    stream_disabled = "-DRAPT_FPGA_STREAM_BRAM=0" in args.defines.split() or (
        "-DRAPT_FPGA_LUTRAM=0" in args.defines.split()
        and "-DRAPT_FPGA_STREAM_BRAM=1" not in args.defines.split()
    )
    if args.module == "rnu" and stream_disabled:
        min_bram = 0
    actual = top_resources(args.report, args.top)
    bram, lutram = actual["RAMB36"], actual["LUTRAMs"]
    failed = []
    if bram < min_bram:
        failed.append(f"RAMB36 {bram} < {min_bram}")
    if lutram < min_lutram:
        failed.append(f"LUTRAM {lutram} < {min_lutram}")
    if failed:
        raise SystemExit(f"[fpga-ram] FAIL {args.module}/{args.config}/RV{args.xlen}: " + ", ".join(failed))
    print(
        f"[fpga-ram] PASS {args.module}/{args.config}/RV{args.xlen}: "
        f"RAMB36 {bram} >= {min_bram}, LUTRAM {lutram} >= {min_lutram}"
    )


if __name__ == "__main__":
    main()
