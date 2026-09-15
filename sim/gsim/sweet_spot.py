#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""
Sweet-spot analysis for the grid_search.py results.

Reads per-workload CSVs under sim/build/gsim/results/grid-*.csv, normalizes
IPC to the historical ROB64 baseline point, computes a transparent area/cost
proxy per point, and prints phase-by-phase tables plus the sweet-spot (knee)
recommendation.

Cost model (per point, relative units; only swept structures vary, constants
drop out of comparisons):
    ROB: rob entries        x 104 b (payload 32 b + control/tag overhead)
    IQ : iq entries         x  72 b
    SQ : sq entries         x  96 b
    PHY: phys entries       x  32 b
    L1I: size x 8 x 1.15 b (data + tag/status overhead)
    L1D: size x 8 x 1.15 b
    BTB: entries x (7 tag + 2 ctr + 32 target) b
    RSB: entries x 48 b
Fixed across most points: TAGE (~5.4 Kb), PHT bimodal base (512 b), fetch
buffers, TLBs. Baseline = historical default preset (before the ROB32 change).
This analysis is for the ROB64-baseline grid; do not mix new ROB32-preset
grid results into these CSVs or reinterpret old measurements as ROB32.
"""
from __future__ import annotations

import argparse
import csv
import math
import sys
from pathlib import Path

RAPTOR_HOME = Path(__file__).resolve().parents[2]
RESULTS = RAPTOR_HOME / "sim" / "build" / "gsim" / "results"

BASELINE = {
    "rob": 32, "iq": 16, "sq": 16, "phys_int": 128,
    "l1i_assoc": 4, "l1d_assoc": 4, "btb_entries": 128, "rsb_size": 4,
    "decode_w": 2, "rename_w": 2, "dispatch_w": 2, "commit_w": 2,
    "integer_issue_ports": 2,
}

# Relative cost weights (per bit / per entry / per lane).  SRAM bits are
# weighted 0.15x a flip-flop bit: in a real implementation the L1 data/tag
# arrays are dense SRAM, whereas the ROB/IQ/SQ/PRF state is flop-based.
CACHE_BIT_W = 0.15
LANE_W = 150          # fetch/decode/rename/dispatch/commit lane logic
PORT_W = 150          # integer issue port (RS read, bypass, ALU pipe)


def cost(row: dict) -> float:
    rob = int(row.get("rob") or BASELINE["rob"])
    iq = int(row.get("iq") or BASELINE["iq"])
    sq = int(row.get("sq") or BASELINE["sq"])
    phys = int(row.get("phys_int") or BASELINE["phys_int"])
    l1i_w = int(row.get("l1i_assoc") or BASELINE["l1i_assoc"])
    l1d_w = int(row.get("l1d_assoc") or BASELINE["l1d_assoc"])
    btb = int(row.get("btb_entries") or BASELINE["btb_entries"])
    rsb = int(row.get("rsb_size") or BASELINE["rsb_size"])
    dec = int(row.get("decode_w") or BASELINE["decode_w"])
    ren = int(row.get("rename_w") or BASELINE["rename_w"])
    dis = int(row.get("dispatch_w") or BASELINE["dispatch_w"])
    cmt = int(row.get("commit_w") or BASELINE["commit_w"])
    ports = int(row.get("integer_issue_ports") or BASELINE["integer_issue_ports"])
    l1i_size = 64 * 64 * l1i_w
    l1d_size = 64 * 64 * l1d_w
    return (
        rob * 104
        + iq * 72
        + sq * 96
        + phys * 32
        + (l1i_size + l1d_size) * 8 * 1.15 * CACHE_BIT_W
        + btb * 41
        + rsb * 48
        + (dec + ren + dis + cmt) * LANE_W
        + ports * PORT_W
    )


def load(bench: str) -> list[dict]:
    candidates = [
        RESULTS / f"grid-{bench}-rv32.csv",
        RESULTS / f"grid-embench-{bench}-rv32.csv",
    ]
    path = next((p for p in candidates if p.exists()), None)
    if path is None:
        print(f"[sweet] missing grid-{bench}-rv32.csv", file=sys.stderr)
        return []
    with path.open() as f:
        return list(csv.DictReader(f))


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--benches", default="coremark,crc32,aha-mont64,matmult-int,slre,wikisort,qrduino,huffbench,ud",
                    help="comma list of bench base names")
    ap.add_argument("--out", default=str(RESULTS / "sweet-spot.md"))
    args = ap.parse_args()

    benches = [b for b in args.benches.split(",") if b]
    tables: dict[str, list[dict]] = {}
    for bench in benches:
        rows = [r for r in load(bench) if "error" not in r and r.get("ipc")]
        if rows:
            tables[bench] = rows
    active = [b for b in benches if b in tables]

    # Baseline IPC per bench: the default-preset point.  The grid contains it
    # under several labels (rob64 / iq16 / sq16 / l1i16k-l1d16k); pick the
    # first one present per workload.
    baseline_labels = {"iq16", "sq16", "l1i16k-l1d16k", "rob32"}
    base_ipc: dict[str, float] = {}
    for bench in active:
        for row in tables[bench]:
            if row["label"] == "iq16":
                base_ipc[bench] = float(row["ipc"])
                break
        if bench not in base_ipc:
            for row in tables[bench]:
                if row["label"] in baseline_labels:
                    base_ipc[bench] = float(row["ipc"])
                    break
    missing_base = [b for b in active if b not in base_ipc]
    if missing_base:
        print(f"[sweet] no baseline point for {missing_base}", file=sys.stderr)
        return 2
    print(f"[sweet] baseline IPC: "
          + ", ".join(f"{b}={v:.3f}" for b, v in base_ipc.items()))

    base_c = cost(dict(BASELINE))
    meta: dict[str, dict] = {}   # label -> first row seen (phase/rtl/cost)
    per_bench: dict[str, dict[str, float]] = {b: {} for b in active}
    for bench in active:
        for row in tables[bench]:
            label = row["label"]
            meta.setdefault(label, row)
            per_bench[bench][label] = float(row["ipc"]) / base_ipc[bench]
    labels = sorted(meta)

    def geo_ipc(label: str) -> float | None:
        vals = [per_bench[b][label] for b in active if label in per_bench[b]]
        if not vals:
            return None
        return math.exp(sum(math.log(v) for v in vals) / len(vals))

    lines: list[str] = []
    lines.append("# gem5 DSE sweet-spot analysis")
    lines.append("")
    lines.append("Baseline = current HDL `default` preset "
                 "(ROB 32, RS+IOQ 16, SQ 16, PHY 128, L1I/L1D 16 KiB 4-way, "
                 "widths 2, TAGE). IPC normalized per workload to baseline.")
    lines.append("")
    lines.append("Cost model: ROB/IQ/SQ/PHY/BTB/RAS flop entries, width lanes and "
                 "ALU ports at full weight; L1 SRAM bits weighted 0.15×.")
    lines.append("")
    hdr = ("| point | phase | RTL | cost(x) | "
           + " | ".join(b.split("-", 1)[1] if "-" in b else b for b in active)
           + " | geoIPC(x) | IPC/cost(x) |")
    lines.append(hdr)
    lines.append("|" + "---|" * (4 + len(active) + 2))

    for label in labels:
        row = meta[label]
        c = cost(row)
        cells = []
        for bench in active:
            v = per_bench[bench].get(label)
            cells.append("—" if v is None else f"{v:.3f}")
        geo = geo_ipc(label)
        lines.append(
            f"| {label} | {row.get('phase', '')} | {row.get('rtl_legal', 'Y')} "
            f"| {c / base_c:.2f} | " + " | ".join(cells) +
            f" | {geo:.3f} | {geo / (c / base_c):.3f} |"
        )

    # Sweet spot: RTL-legal points only, sorted by cost.  Knee = cheapest
    # point reaching >= 95% of the best geo IPC among points costing <= 2x
    # baseline (standard performance-knee rule).
    legal = []
    for label in labels:
        row = meta[label]
        if row.get("rtl_legal", "Y") != "Y":
            continue
        geo = geo_ipc(label)
        if geo is not None:
            legal.append((cost(row), geo, label))
    legal.sort()

    lines.append("")
    lines.append("## Sweet-spot / knee analysis")
    lines.append("")
    lines.append("RTL-legal points ordered by cost (knee = cheapest point at")
    lines.append("≥ 95% of the best geo IPC within a 2× cost envelope):")
    lines.append("")
    lines.append("| point | cost(x) | geoIPC(x) | ΔIPC / Δcost |")
    lines.append("|---|---:|---:|---:|")
    envelope = [g for c, g, _ in legal if c / base_c <= 2.0]
    if envelope:
        knee_target = 0.95 * max(envelope)
        knee = None
        prev_c, prev_g = None, None
        for c, g, label in legal:
            d = "—"
            if prev_c is not None and c > prev_c:
                d = f"{(g - prev_g) / ((c - prev_c) / base_c):.3f}"
            lines.append(f"| {label} | {c / base_c:.2f} | {g:.3f} | {d} |")
            if knee is None and c / base_c <= 2.0 and g >= knee_target:
                knee = (label, g, c / base_c)
            prev_c, prev_g = c, g
        if knee:
            lines.append("")
            lines.append(
                f"**Sweet spot (RTL-legal, ≥ 95% of best IPC within 2× cost): "
                f"`{knee[0]}`** — geo IPC {knee[1]:.3f}× baseline at "
                f"{knee[2]:.2f}× baseline cost."
            )

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(lines) + "\n")
    print(f"[sweet] wrote {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
